import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("M5 S8 Anthropic Messages metering session", .serialized)
struct LocalMeterAnthropicMessagesSessionTests {
    private actor ChunkCollector {
        private(set) var chunks: [Data] = []

        func append(_ chunk: Data) {
            self.chunks.append(chunk)
        }

        var count: Int {
            self.chunks.count
        }
    }

    private actor RequestCapture {
        private var request: LoopbackHTTPRequest?

        func store(_ request: LoopbackHTTPRequest) {
            self.request = request
        }

        func value() -> LoopbackHTTPRequest? {
            self.request
        }
    }

    @Test
    func `streaming session keeps local estimate and all reported lanes separate`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "anthropic-stream")
        let session = LocalMeterAnthropicMessagesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "Summarize this Anthropic fixture",
            accumulator: accumulator)

        _ = try await session.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        let record = try #require(try await session.finish())

        #expect(record.entry.key == context.ledgerKey)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.localEstimate?.provenance == .localEstimated)
        #expect(record.reportedUsage?.inputTokens == 31)
        #expect(record.reportedUsage?.cachedInputTokens == 7)
        #expect(record.reportedUsage?.cacheCreationInputTokens == 12)
        #expect(record.reportedUsage?.outputTokens == 19)
        #expect(record.reportedUsage?.totalTokens == 69)
        #expect(record.entry.amounts.cacheReadTokens == 0)
        #expect(record.entry.amounts.cacheCreationTokens == 0)
        #expect(record.entry.amounts.totalTokens == record.localEstimate?.totalTokens)
        #expect(record.entry.amounts.totalTokens != record.reportedUsage?.totalTokens)
    }

    @Test
    func `non streaming session estimates output without merging reported cache lanes`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-nonstream"),
            attemptID: "attempt-1",
            inputText: "Hello Anthropic",
            accumulator: accumulator)

        let record = try #require(try await session.completeNonStreaming(
            Data(AnthropicMessagesParserTests.nonStreamingFixture.utf8)))

        #expect(record.localEstimate?.outputTokens ?? 0 > 0)
        #expect(record.reportedUsage?.inputTokens == 21)
        #expect(record.reportedUsage?.cachedInputTokens == 8)
        #expect(record.reportedUsage?.cacheCreationInputTokens == 13)
        #expect(record.reportedUsage?.outputTokens == 17)
        #expect(record.reportedUsage?.totalTokens == 59)
    }

    @Test
    func `retry after aborted stream publishes only replacement attempt`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "anthropic-retry")
        let first = LocalMeterAnthropicMessagesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "retry input",
            accumulator: accumulator)
        _ = try await first.append(Data(Self.streamingPrefix.utf8))
        await first.abort()

        let second = LocalMeterAnthropicMessagesSession(
            context: context,
            attemptID: "attempt-2",
            inputText: "retry input",
            accumulator: accumulator)
        _ = try await second.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        let record = try #require(try await second.finish())

        #expect(record.entry.amounts.requestCount == 1)
        #expect(record.reportedUsage?.totalTokens == 69)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `disconnect after message start publishes no partial record`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-disconnect"),
            attemptID: "attempt-1",
            inputText: "disconnect input",
            accumulator: accumulator)

        _ = try await session.append(Data(AnthropicMessagesParserTests.messageStartEvent.utf8))
        let record = try await session.finish()

        #expect(record == nil)
        #expect(await accumulator.records.isEmpty)
    }

    @Test
    func `same attempt replay counts Anthropic output and reasoning units once`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "anthropic-reconnect")
        let first = LocalMeterAnthropicMessagesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        _ = try await first.append(Data(Self.streamingPrefix.utf8))

        let resumed = LocalMeterAnthropicMessagesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        _ = try await resumed.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        let record = try #require(try await resumed.finish())
        let expectedOutput = LocalMeterTokenEstimator.estimate(
            #"Hello from Anthropic.lookup_weather{"city":"Paris"}"#).tokens
            + LocalMeterTokenEstimator.estimate("I checked the request.").tokens

        #expect(record.localEstimate?.outputTokens == expectedOutput)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `same request id completed repeatedly remains one ledger entry`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "anthropic-duplicate")
        for attemptID in ["attempt-1", "attempt-2"] {
            let session = LocalMeterAnthropicMessagesSession(
                context: context,
                attemptID: attemptID,
                inputText: "duplicate input",
                accumulator: accumulator)
            _ = try await session.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
            _ = try await session.finish()
        }

        let records = await accumulator.records
        #expect(records.count == 1)
        #expect(records.first?.entry.amounts.requestCount == 1)
    }

    @Test
    func `serialized Anthropic record stores fingerprint without plaintext contents`() async throws {
        let plaintextKey = "fixture-secret-anthropic-key"
        let fingerprint = try #require(LocalMeterCredentialFingerprint(apiKey: plaintextKey))
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(
                requestID: "anthropic-redaction",
                credentialFingerprint: fingerprint),
            attemptID: "attempt-1",
            inputText: "private Anthropic request contents",
            accumulator: accumulator)

        _ = try await session.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        let record = try #require(try await session.finish())
        let serialized = try #require(String(
            data: JSONEncoder().encode(record),
            encoding: .utf8))

        #expect(serialized.contains(fingerprint.value))
        #expect(!serialized.contains(plaintextKey))
        #expect(!serialized.contains("private Anthropic request contents"))
        #expect(!serialized.contains("Hello from Anthropic."))
        #expect(!serialized.contains("I checked the request."))
    }

    @Test
    func `reported usage written before cache creation support remains readable`() throws {
        let legacyJSON = #"""
        {
          "input_tokens":31,
          "cached_input_tokens":7,
          "output_tokens":19,
          "reasoning_tokens":0,
          "total_tokens":57
        }
        """#

        let usage = try JSONDecoder().decode(
            LocalMeterReportedUsage.self,
            from: Data(legacyJSON.utf8))

        #expect(usage.inputTokens == 31)
        #expect(usage.cachedInputTokens == 7)
        #expect(usage.cacheCreationInputTokens == 0)
        #expect(usage.outputTokens == 19)
        #expect(usage.totalTokens == 57)
    }

    @Test
    func `healthy fake upstream streams Anthropic Messages through meter`() async throws {
        let capture = RequestCapture()
        let upstream = Self.makeStreamingFixtureServer(capture: capture)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-healthy-meter"),
            attemptID: "attempt-1",
            inputText: "healthy Anthropic fixture",
            accumulator: accumulator)
        let collector = ChunkCollector()
        let request = Self.request(stream: true)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: request,
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 11,
            onChunk: { chunk in
                await collector.append(chunk)
                _ = try await session.append(chunk)
            })
        let record = try #require(try await session.finish())
        let forwarded = try #require(await capture.value())

        #expect(result.route == .meter)
        #expect(await collector.count > 1)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.reportedUsage?.totalTokens == 69)
        #expect(forwarded.path == "/v1/messages")
        #expect(forwarded.headers["anthropic-version"] == "2023-06-01")
        #expect(forwarded.body == request.httpBody)
    }

    @Test
    func `meter not started streams Anthropic Messages directly`() async throws {
        let upstream = Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let absent = Self.makeStreamingFixtureServer()
        let absentPort = try await absent.start()
        absent.stop()

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-meter-absent"),
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
    func `occupied meter port streams Anthropic Messages directly`() async throws {
        let occupied = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(statusCode: 200, body: Data("not-headroom".utf8))
        }
        let occupiedPort = try await occupied.start()
        defer { occupied.stop() }
        let upstream = Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-meter-occupied"),
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
    func `helper crash after health probe streams Anthropic Messages directly`() async throws {
        let upstream = Self.makeStreamingFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-meter-crash"),
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
    func `half stream disconnect discards Anthropic prefix before direct replay`() async throws {
        let upstream = Self.makeStreamingFixtureServer()
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
                declaredBodyLength: AnthropicMessagesParserTests.streamingFixture.utf8.count)
        }
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-half-stream"),
            attemptID: "attempt-1",
            inputText: "half stream",
            accumulator: accumulator)
        let collector = ChunkCollector()
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(stream: true),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 13,
            onChunk: { chunk in
                await collector.append(chunk)
                _ = try await session.append(chunk)
            })
        let record = try #require(try await session.finish())
        let delivered = await collector.chunks.reduce(into: Data()) { data, chunk in
            data.append(chunk)
        }

        #expect(result.route == .direct)
        #expect(delivered == Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        #expect(record.reportedUsage?.totalTokens == 69)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `non streaming helper failure retries Anthropic request directly`() async throws {
        let upstream = Self.makeNonStreamingFixtureServer()
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
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-nonstream-fail-open"),
            attemptID: "attempt-1",
            inputText: "nonstream fail-open",
            accumulator: accumulator)
        let record = try #require(try await session.completeNonStreaming(result.data))

        #expect(result.route == .direct)
        #expect(result.response.statusCode == 200)
        #expect(record.reportedUsage?.totalTokens == 59)
    }

    @Test
    func `Anthropic records use the M4 relay key and conserve all three windows`() async throws {
        let now = Date(timeIntervalSince1970: 1_787_700_000)
        let accumulator = LocalMeterUsageAccumulator()
        let fixtures: [(String, TimeInterval)] = [
            ("anthropic-24h", 60 * 60),
            ("anthropic-7d", 2 * 24 * 60 * 60),
            ("anthropic-30d", 10 * 24 * 60 * 60),
        ]
        for (requestID, age) in fixtures {
            let session = LocalMeterAnthropicMessagesSession(
                context: self.context(
                    requestID: requestID,
                    startedAt: now.addingTimeInterval(-age)),
                attemptID: "attempt-1",
                inputText: "Anthropic ledger input",
                accumulator: accumulator)
            _ = try await session.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
            _ = try await session.finish()
        }

        let entries = await accumulator.records.map(\.entry)
        #expect(entries.allSatisfy { $0.key.routeProfileID == self.profileID })
        #expect(entries.allSatisfy { $0.key.targetApp == .claudeCode })
        #expect(entries.allSatisfy {
            $0.key.identityID == "relay:\(self.profileID.uuidString.lowercased()):claudeCode"
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
    func `Anthropic cache lanes stay reported and never enter local ledger`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-cache-lanes"),
            attemptID: "attempt-1",
            inputText: "Anthropic cache lane input",
            accumulator: accumulator)

        _ = try await session.append(Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        let record = try #require(try await session.finish())

        #expect(record.reportedUsage?.cachedInputTokens == 7)
        #expect(record.reportedUsage?.cacheCreationInputTokens == 12)
        #expect(record.entry.amounts.cacheReadTokens == 0)
        #expect(record.entry.amounts.cacheCreationTokens == 0)
        #expect(record.entry.amounts.inputTokens == record.localEstimate?.inputTokens)
        #expect(record.entry.amounts.totalTokens == record.localEstimate?.totalTokens)
        #expect(record.entry.amounts.totalTokens != record.reportedUsage?.totalTokens)
    }

    @Test
    func `completed Anthropic stream without output usage keeps reported usage unavailable`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterAnthropicMessagesSession(
            context: self.context(requestID: "anthropic-no-reported-output"),
            attemptID: "attempt-1",
            inputText: "Anthropic missing reported output",
            accumulator: accumulator)
        let fixture = [
            AnthropicMessagesParserTests.messageStartEvent,
            AnthropicMessagesParserTests.event(
                "content_block_start",
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            AnthropicMessagesParserTests.event(
                "content_block_delta",
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"local only"}}"#),
            AnthropicMessagesParserTests.event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            AnthropicMessagesParserTests.event("message_stop", #"{"type":"message_stop"}"#),
        ].joined()

        _ = try await session.append(Data(fixture.utf8))
        let record = try #require(try await session.finish())

        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.reportedUsage == nil)
        #expect(record.entry.amounts.totalTokens == record.localEstimate?.totalTokens)
    }

    private func context(
        requestID: String,
        startedAt: Date = Date(timeIntervalSince1970: 1_787_700_000),
        credentialFingerprint: LocalMeterCredentialFingerprint? = nil) -> LocalMeterRequestContext
    {
        LocalMeterRequestContext(
            requestID: requestID,
            sessionID: "anthropic-session",
            routeProfileID: self.profileID,
            targetApp: .claudeCode,
            model: "claude-fixture-model",
            startedAt: startedAt,
            credentialFingerprint: credentialFingerprint)
    }

    private var profileID: UUID {
        guard let value = UUID(uuidString: "88888888-8888-4888-8888-888888888888") else {
            preconditionFailure("Invalid deterministic profile fixture")
        }
        return value
    }

    private static var streamingPrefix: String {
        let fixture = AnthropicMessagesParserTests.streamingFixture
        let marker = AnthropicMessagesParserTests.event(
            "message_delta",
            [
                #"{"type":"message_delta","delta":{"stop_reason":null,"stop_sequence":null},"#,
                #""usage":{"output_tokens":8}}"#,
            ].joined())
        guard let range = fixture.range(of: marker) else { return fixture }
        return String(fixture[..<range.lowerBound])
    }

    private static func makeStreamingFixtureServer(
        capture: RequestCapture? = nil) -> LoopbackHTTPServer
    {
        LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/messages" else {
                return LoopbackHTTPResponse(statusCode: 404)
            }
            if let capture {
                await capture.store(request)
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(AnthropicMessagesParserTests.streamingFixture.utf8))
        }
    }

    private static func makeNonStreamingFixtureServer() -> LoopbackHTTPServer {
        LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/messages" else {
                return LoopbackHTTPResponse(statusCode: 404)
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(AnthropicMessagesParserTests.nonStreamingFixture.utf8))
        }
    }

    private static func request(stream: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body = [
            #"{"model":"claude-fixture-model","max_tokens":64,"messages":["#,
            #"{"role":"user","content":"fixture"}],"stream":\#(stream)}"#,
        ].joined()
        request.httpBody = Data(body.utf8)
        return request
    }

    private static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
