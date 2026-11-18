import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("M5 S7 Chat Completions metering session", .serialized)
struct LocalMeterChatCompletionsSessionTests {
    private let profileID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!

    private actor ChunkCollector {
        private(set) var chunks: [Data] = []

        func append(_ chunk: Data) {
            self.chunks.append(chunk)
        }

        var count: Int {
            self.chunks.count
        }
    }

    private actor RequestBodyCapture {
        private var body: Data?

        func store(_ body: Data) {
            self.body = body
        }

        func value() -> Data? {
            self.body
        }
    }

    @Test
    func `streaming session preserves local estimate beside reported usage`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "chat-stream")
        let session = LocalMeterChatCompletionsSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "Summarize this Chat fixture",
            accumulator: accumulator)

        _ = try await session.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
        let record = try #require(try await session.finish())

        #expect(record.entry.key == context.ledgerKey)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.localEstimate?.provenance == .localEstimated)
        #expect(record.reportedUsage?.totalTokens == 49)
        #expect(record.reportedUsage?.cachedInputTokens == 9)
        #expect(record.reportedUsage?.reasoningTokens == 4)
        #expect(record.reportedDifference?.reportedTotalTokens == 49)
    }

    @Test
    func `non streaming session records output without replacing reported usage`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-nonstream"),
            attemptID: "attempt-1",
            inputText: "Hello",
            accumulator: accumulator)

        let record = try #require(try await session.completeNonStreaming(
            Data(OpenAIChatCompletionsParserTests.nonStreamingFixture.utf8)))

        #expect(record.localEstimate?.outputTokens ?? 0 > 0)
        #expect(record.reportedUsage?.totalTokens == 29)
        #expect(record.entry.amounts.totalTokens == record.localEstimate?.totalTokens)
        #expect(record.entry.amounts.totalTokens != record.reportedUsage?.totalTokens)
    }

    @Test
    func `stream without usage keeps local estimate and leaves reported absent`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-no-usage"),
            attemptID: "attempt-1",
            inputText: "No reported usage fixture",
            accumulator: accumulator)

        _ = try await session.append(Data(OpenAIChatCompletionsParserTests.streamingWithoutUsageFixture.utf8))
        let record = try #require(try await session.finish())

        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.reportedUsage == nil)
        #expect(record.reportedDifference == nil)
    }

    @Test
    func `non streaming reported usage and streaming absence remain independent`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let nonStreaming = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-mixed-nonstream"),
            attemptID: "attempt-1",
            inputText: "Nonstream fixture",
            accumulator: accumulator)
        let streaming = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-mixed-stream"),
            attemptID: "attempt-1",
            inputText: "Stream fixture",
            accumulator: accumulator)

        _ = try await nonStreaming.completeNonStreaming(
            Data(OpenAIChatCompletionsParserTests.nonStreamingFixture.utf8))
        _ = try await streaming.append(
            Data(OpenAIChatCompletionsParserTests.streamingWithoutUsageFixture.utf8))
        _ = try await streaming.finish()

        let records = await Dictionary(uniqueKeysWithValues: accumulator.records.compactMap { record in
            record.entry.key.requestID.map { ($0, record) }
        })
        #expect(records["chat-mixed-nonstream"]?.reportedUsage?.totalTokens == 29)
        #expect(records["chat-mixed-stream"]?.reportedUsage == nil)
        #expect(records["chat-mixed-stream"]?.localEstimate?.totalTokens ?? 0 > 0)
    }

    @Test
    func `multiple choices and tool calls contribute to local output estimate`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-multi-tool"),
            attemptID: "attempt-1",
            inputText: "Use a tool and answer",
            accumulator: accumulator)

        _ = try await session.append(Data(OpenAIChatCompletionsParserTests.multiChoiceToolCallFixture.utf8))
        let record = try #require(try await session.finish())
        let expectedOutput = LocalMeterTokenEstimator.estimate(
            #"Visible answer.lookup_weather{"city":"Paris"}"#).tokens

        #expect(record.localEstimate?.outputTokens == expectedOutput)
        #expect(record.reportedUsage?.totalTokens == 62)
    }

    @Test
    func `meter forwards the original stream request without injecting stream options`() async throws {
        let capture = RequestBodyCapture()
        let upstream = LoopbackHTTPServer { request in
            await capture.store(request.body)
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(OpenAIChatCompletionsParserTests.streamingWithoutUsageFixture.utf8))
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }
        let request = Self.request(stream: true)

        let result = try await LocalMeterFailOpenTransport().stream(
            for: request,
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { _ in })

        #expect(result.route == .meter)
        #expect(await capture.value() == request.httpBody)
        let forwardedBody = try #require(await String(data: capture.value() ?? Data(), encoding: .utf8))
        #expect(!forwardedBody.contains("stream_options"))
    }

    @Test
    func `retry after aborted stream publishes only replacement attempt`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "chat-retry")
        let first = LocalMeterChatCompletionsSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "retry input",
            accumulator: accumulator)
        _ = try await first.append(Data(Self.streamingPrefix.utf8))
        await first.abort()

        let second = LocalMeterChatCompletionsSession(
            context: context,
            attemptID: "attempt-2",
            inputText: "retry input",
            accumulator: accumulator)
        _ = try await second.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
        let record = try #require(try await second.finish())

        #expect(record.entry.amounts.requestCount == 1)
        #expect(record.reportedUsage?.totalTokens == 49)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `disconnect without DONE aborts and publishes no partial record`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-disconnect"),
            attemptID: "attempt-1",
            inputText: "disconnect input",
            accumulator: accumulator)

        _ = try await session.append(Data(Self.streamingPrefix.utf8))
        let record = try await session.finish()

        #expect(record == nil)
        #expect(await accumulator.records.isEmpty)
    }

    @Test
    func `reconnect replay on the same attempt counts each output unit once`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "chat-reconnect")
        let first = LocalMeterChatCompletionsSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        _ = try await first.append(Data(Self.streamingPrefix.utf8))

        let resumed = LocalMeterChatCompletionsSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        _ = try await resumed.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
        let record = try #require(try await resumed.finish())

        #expect(record.entry.amounts.outputTokens ==
            LocalMeterTokenEstimator.estimate("Hello from Chat Completions.").tokens)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `same request id completed repeatedly remains one ledger entry`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "chat-duplicate")
        for attemptID in ["attempt-1", "attempt-2"] {
            let session = LocalMeterChatCompletionsSession(
                context: context,
                attemptID: attemptID,
                inputText: "duplicate input",
                accumulator: accumulator)
            _ = try await session.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
            _ = try await session.finish()
        }

        let records = await accumulator.records
        #expect(records.count == 1)
        #expect(records.first?.entry.amounts.requestCount == 1)
    }

    @Test
    func `healthy fake upstream streams Chat Completions through meter`() async throws {
        let upstream = try Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-healthy-meter"),
            attemptID: "attempt-1",
            inputText: "healthy fixture",
            accumulator: accumulator)
        let collector = ChunkCollector()
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 11,
            onChunk: { chunk in
                await collector.append(chunk)
                _ = try await session.append(chunk)
            })
        let record = try #require(try await session.finish())

        #expect(result.route == .meter)
        #expect(await collector.count > 1)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.reportedUsage?.totalTokens == 49)
    }

    @Test
    func `healthy fake upstream returns non streaming Chat Completions through meter`() async throws {
        let upstream = try Self.makeNonStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let result = try await LocalMeterFailOpenTransport().data(
            for: Self.request(stream: false),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-healthy-nonstream"),
            attemptID: "attempt-1",
            inputText: "healthy nonstream fixture",
            accumulator: accumulator)
        let record = try #require(try await session.completeNonStreaming(result.data))

        #expect(result.route == .meter)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.reportedUsage?.totalTokens == 29)
    }

    @Test
    func `meter not started streams Chat Completions directly`() async throws {
        let upstream = try Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let absent = try Self.makeStreamingFixtureServer()
        let absentPort = try await absent.start()
        absent.stop()

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-meter-absent"),
            attemptID: "attempt-1",
            inputText: "absent meter",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: absentPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in _ = try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `occupied meter port streams Chat Completions directly`() async throws {
        let occupied = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(statusCode: 200, body: Data("not-headroom".utf8))
        }
        let occupiedPort = try await occupied.start()
        defer { occupied.stop() }
        let upstream = try Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-meter-occupied"),
            attemptID: "attempt-1",
            inputText: "occupied meter",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: occupiedPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in _ = try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `helper crash after health probe streams Chat Completions directly`() async throws {
        let upstream = try Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-meter-crash"),
            attemptID: "attempt-1",
            inputText: "crashed meter",
            accumulator: accumulator)
        let transport = LocalMeterFailOpenTransport(afterHealthyProbe: { meter.stop() })
        let result = try await transport.stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in _ = try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `half stream disconnect discards partial Chat bytes before direct replay`() async throws {
        let upstream = try Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let partialBody = Data(Self.streamingPrefix.utf8)
        let meter = LoopbackHTTPServer { request in
            if request.method == "GET", request.path == LocalMeterServer.healthPath {
                return LoopbackHTTPResponse(
                    statusCode: 200,
                    headers: [LocalMeterServer.healthHeader: LocalMeterServer.healthSignature],
                    body: Data("ok".utf8))
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: partialBody,
                declaredBodyLength: OpenAIChatCompletionsParserTests.streamingFixture.utf8.count)
        }
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(requestID: "chat-half-stream"),
            attemptID: "attempt-1",
            inputText: "half stream",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 13,
            onChunk: { chunk in _ = try await session.append(chunk) })
        let record = try #require(try await session.finish())

        #expect(result.route == .direct)
        #expect(record.reportedUsage?.totalTokens == 49)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `non streaming helper server error retries Chat request directly`() async throws {
        let upstream = try Self.makeNonStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LoopbackHTTPServer { request in
            if request.method == "GET", request.path == LocalMeterServer.healthPath {
                return LoopbackHTTPResponse(
                    statusCode: 200,
                    headers: [LocalMeterServer.healthHeader: LocalMeterServer.healthSignature],
                    body: Data("ok".utf8))
            }
            return LoopbackHTTPResponse(statusCode: 503)
        }
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let result = try await LocalMeterFailOpenTransport().data(
            for: Self.request(stream: false),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort))

        #expect(result.route == .direct)
        #expect(result.response.statusCode == 200)
        #expect(result.data == Data(OpenAIChatCompletionsParserTests.nonStreamingFixture.utf8))
    }

    @Test
    func `Chat records use the M4 relay key and conserve all three windows`() async throws {
        let now = Date(timeIntervalSince1970: 1_787_600_000)
        let accumulator = LocalMeterUsageAccumulator()
        let fixtures: [(String, TimeInterval)] = [
            ("chat-24h", 60 * 60),
            ("chat-7d", 2 * 24 * 60 * 60),
            ("chat-30d", 10 * 24 * 60 * 60),
        ]
        for (requestID, age) in fixtures {
            let session = LocalMeterChatCompletionsSession(
                context: self.context(
                    requestID: requestID,
                    startedAt: now.addingTimeInterval(-age)),
                attemptID: "attempt-1",
                inputText: "ledger input",
                accumulator: accumulator)
            _ = try await session.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
            _ = try await session.finish()
        }

        let entries = await accumulator.records.map(\.entry)
        #expect(entries.allSatisfy { $0.key.routeProfileID == self.profileID })
        #expect(entries.allSatisfy { $0.key.targetApp == .codex })
        #expect(entries.allSatisfy {
            $0.key.identityID == "relay:\(self.profileID.uuidString.lowercased()):codex"
        })
        let ledger = UsageLedger(entries: entries)
        let expectedRequestCounts: [UsageLedgerWindow: Int] = [
            .rolling24Hours: 1,
            .rolling7Days: 2,
            .rolling30Days: 3,
        ]
        for window in UsageLedgerWindow.allCases {
            let partition = ledger.partition(for: window, endingAt: now)
            #expect(partition.isConserved)
            #expect(partition.componentTotal == partition.total)
            #expect(partition.total.requestCount == expectedRequestCounts[window])
            #expect(partition.officialByIdentityID.isEmpty)
            #expect(partition.unassigned.requestCount == 0)
        }
    }

    @Test
    func `serialized Chat record stores fingerprint without plaintext key or contents`() async throws {
        let plaintextKey = "fixture-secret-chat-key"
        let fingerprint = try #require(LocalMeterCredentialFingerprint(apiKey: plaintextKey))
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterChatCompletionsSession(
            context: self.context(
                requestID: "chat-redaction",
                credentialFingerprint: fingerprint),
            attemptID: "attempt-1",
            inputText: "private request contents",
            accumulator: accumulator)

        _ = try await session.append(Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
        let record = try #require(try await session.finish())
        let serialized = try #require(String(
            data: JSONEncoder().encode(record),
            encoding: .utf8))

        #expect(serialized.contains(fingerprint.value))
        #expect(!serialized.contains(plaintextKey))
        #expect(!serialized.contains("private request contents"))
        #expect(!serialized.contains("Hello from Chat Completions."))
    }

    private func context(
        requestID: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_787_600_000),
        credentialFingerprint: LocalMeterCredentialFingerprint? = nil) -> LocalMeterRequestContext
    {
        LocalMeterRequestContext(
            requestID: requestID,
            sessionID: "chat-session",
            routeProfileID: self.profileID,
            targetApp: .codex,
            model: "gpt-5.4",
            startedAt: startedAt,
            credentialFingerprint: credentialFingerprint)
    }

    private static var streamingPrefix: String {
        let fixture = OpenAIChatCompletionsParserTests.streamingFixture
        let marker = OpenAIChatCompletionsParserTests.chunk(choices: [
            #"[{"index":0,"delta":{"content":"Chat Completions."},"logprobs":null,"#,
            #""finish_reason":null}]"#,
        ].joined())
        guard let range = fixture.range(of: marker) else { return fixture }
        return String(fixture[..<range.lowerBound])
    }

    private static func makeStreamingFixtureServer() throws -> LoopbackHTTPServer {
        LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/chat/completions" else {
                return LoopbackHTTPResponse(statusCode: 404)
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(OpenAIChatCompletionsParserTests.streamingFixture.utf8))
        }
    }

    private static func makeNonStreamingFixtureServer() throws -> LoopbackHTTPServer {
        LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/chat/completions" else {
                return LoopbackHTTPResponse(statusCode: 404)
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(OpenAIChatCompletionsParserTests.nonStreamingFixture.utf8))
        }
    }

    private static func request(stream: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue(
            stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            "{\"model\":\"gpt-5.4\",\"messages\":[{\"role\":\"user\",\"content\":\"fixture\"}],"
                .appending("\"stream\":\(stream)}")
                .utf8)
        return request
    }

    private static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
