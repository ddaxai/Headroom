import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite("M5 S5 local meter Responses integration", .serialized)
struct LocalMeterResponsesIntegrationTests {
    private let profileID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private actor ChunkCollector {
        private(set) var chunks: [Data] = []

        func append(_ chunk: Data) {
            self.chunks.append(chunk)
        }

        var count: Int {
            self.chunks.count
        }
    }

    @Test
    func `healthy fake upstream streams Responses and preserves local plus reported usage`() async throws {
        let upstream = try Self.makeFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-healthy")
        let session = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "Summarize this fixture",
            accumulator: accumulator)
        let collector = ChunkCollector()

        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 17,
            onChunk: { chunk in
                await collector.append(chunk)
                _ = try await session.append(chunk)
            })
        let record = try #require(try await session.finish())

        #expect(result.route == .meter)
        #expect(result.response.statusCode == 200)
        #expect(await collector.count > 1)
        #expect(record.entry.key == context.ledgerKey)
        #expect(record.localEstimate?.totalTokens ?? 0 > 0)
        #expect(record.localEstimate?.provenance == .localEstimated)
        #expect(record.localEstimate?.strategy == LocalMeterTokenEstimator.strategy)
        #expect(record.reportedUsage?.totalTokens == 409)
        #expect(record.reportedUsage?.cachedInputTokens == 123)
        #expect(record.reportedUsage?.reasoningTokens == 17)
        #expect(record.reportedDifference?.localTotalTokens == record.localEstimate?.totalTokens)
        #expect(record.reportedDifference?.reportedTotalTokens == 409)
        #expect(record.reportedDifference?.reportedMinusLocalTotal ==
            409 - (record.localEstimate?.totalTokens ?? 0))

        let encoded = try JSONEncoder().encode(record)
        let serialized = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!serialized.contains("Summarize this fixture"))
        #expect(!serialized.contains("Hello from the fixture."))
        #expect(!serialized.contains("I checked the request."))
    }

    @Test
    func `split output deltas use one aggregate estimate independent of chunk boundaries`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-split-token")
        let session = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "split token input",
            accumulator: accumulator)
        let fullText = "antidisestablishmentarianism"
        let stream = Self.stream([
            Self.event("response.output_text.delta", jsonParts: [
                "{\"type\":\"response.output_text.delta\",\"sequence_number\":1,",
                "\"response_id\":\"resp-split\",\"item_id\":\"msg-split\",",
                "\"output_index\":0,\"content_index\":0,\"delta\":\"antidisestablishmentarian\"}",
            ]),
            Self.event("response.output_text.delta", jsonParts: [
                "{\"type\":\"response.output_text.delta\",\"sequence_number\":2,",
                "\"response_id\":\"resp-split\",\"item_id\":\"msg-split\",",
                "\"output_index\":0,\"content_index\":0,\"delta\":\"ism\"}",
            ]),
            Self.event("response.completed", jsonParts: [
                "{\"type\":\"response.completed\",\"sequence_number\":3,",
                "\"response\":{\"id\":\"resp-split\",\"model\":\"gpt-5.4\",",
                "\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"output_tokens\":6,",
                "\"total_tokens\":8}}}",
            ]),
        ])

        _ = try await session.append(Data(stream.utf8))
        let record = try #require(try await session.finish())

        #expect(record.entry.amounts.outputTokens == LocalMeterTokenEstimator.estimate(fullText).tokens)
    }

    @Test
    func `meter absent streams directly without losing local accounting`() async throws {
        let upstream = try Self.makeFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let absent = try Self.makeFixtureServer()
        let absentPort = try await absent.start()
        absent.stop()

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterResponsesSession(
            context: self.context(requestID: "responses-absent"),
            attemptID: "attempt-1",
            inputText: "direct fallback",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(),
            meterBaseURL: Self.baseURL(port: absentPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `occupied meter port streams directly`() async throws {
        let occupied = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(statusCode: 200, body: Data("not-headroom".utf8))
        }
        let occupiedPort = try await occupied.start()
        defer { occupied.stop() }
        let upstream = try Self.makeFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterResponsesSession(
            context: self.context(requestID: "responses-occupied"),
            attemptID: "attempt-1",
            inputText: "occupied fallback",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(),
            meterBaseURL: Self.baseURL(port: occupiedPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `meter crash after health probe retries streaming request directly`() async throws {
        let upstream = try Self.makeFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterResponsesSession(
            context: self.context(requestID: "responses-crash"),
            attemptID: "attempt-1",
            inputText: "crash fallback",
            accumulator: accumulator)
        let transport = LocalMeterFailOpenTransport(afterHealthyProbe: { meter.stop() })
        let result = try await transport.stream(
            for: Self.request(),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            onChunk: { chunk in try await session.append(chunk) })

        #expect(result.route == .direct)
        #expect(try await session.finish() != nil)
    }

    @Test
    func `meter disconnect after partial SSE discards partial bytes before direct replay`() async throws {
        let upstream = try Self.makeFixtureServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let partialBody = Data(Self.firstOutputEventPrefix.utf8)
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
                declaredBodyLength: Self.completedFixture.utf8.count)
        }
        let meterPort = try await meter.start()
        defer { meter.stop() }

        let accumulator = LocalMeterUsageAccumulator()
        let session = LocalMeterResponsesSession(
            context: self.context(requestID: "responses-partial-crash"),
            attemptID: "attempt-1",
            inputText: "partial crash fallback",
            accumulator: accumulator)
        let result = try await LocalMeterFailOpenTransport().stream(
            for: Self.request(),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort),
            chunkSize: 13,
            onChunk: { chunk in try await session.append(chunk) })
        let record = try #require(try await session.finish())

        #expect(result.route == .direct)
        #expect(record.entry.amounts.requestCount == 1)
        #expect(record.reportedUsage?.totalTokens == 409)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `retry after an aborted stream publishes only the replacement attempt`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-retry")
        let first = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "retry input",
            accumulator: accumulator)
        let firstDeltas = try await first.append(Data(Self.firstOutputEventPrefix.utf8))
        #expect(!firstDeltas.isEmpty)
        await first.abort()

        let second = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-2",
            inputText: "retry input",
            accumulator: accumulator)
        _ = try await second.append(Data(Self.completedFixture.utf8))
        let record = try #require(try await second.finish())

        #expect(record.entry.amounts.outputTokens > 0)
        #expect(await accumulator.records.count == 1)
    }

    @Test
    func `disconnect inside a JSON event aborts without publishing partial usage`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-truncated-json")
        let session = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "truncated input",
            accumulator: accumulator)
        let truncated = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","sequence_number":1,"item_id":"msg-truncated",
        """

        _ = try await session.append(Data(truncated.utf8))
        let record = try await session.finish()

        #expect(record == nil)
        #expect(await accumulator.records.isEmpty)
    }

    @Test
    func `reconnect replay across sessions counts each output unit once`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-reconnect")
        let first = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        let firstDeltas = try await first.append(Data(Self.firstOutputEventPrefix.utf8))
        #expect(!firstDeltas.isEmpty)

        let resumed = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "reconnect input",
            accumulator: accumulator)
        _ = try await resumed.append(Data(Self.afterFirstOutputEvent.utf8))
        let record = try #require(try await resumed.finish())

        #expect(record.entry.amounts.outputTokens ==
            LocalMeterTokenEstimator.estimate("I checked the request.Hello from the fixture.").tokens)
    }

    @Test
    func `same request id completed repeatedly remains one ledger entry`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-duplicate")
        for attempt in ["attempt-1", "attempt-2"] {
            let session = LocalMeterResponsesSession(
                context: context,
                attemptID: attempt,
                inputText: "duplicate input",
                accumulator: accumulator)
            _ = try await session.append(Data(Self.completedFixture.utf8))
            _ = try await session.finish()
        }

        let records = await accumulator.records
        #expect(records.count == 1)
        #expect(records.first?.entry.amounts.requestCount == 1)
    }

    @Test
    func `streaming records share M4 key and conserve all three windows`() async throws {
        let now = Date(timeIntervalSince1970: 1_787_500_000)
        let accumulator = LocalMeterUsageAccumulator()
        let fixtures: [(String, TimeInterval)] = [
            ("responses-24h", 60 * 60),
            ("responses-7d", 2 * 24 * 60 * 60),
            ("responses-30d", 10 * 24 * 60 * 60),
        ]
        for (requestID, age) in fixtures {
            let context = self.context(requestID: requestID, startedAt: now.addingTimeInterval(-age))
            let session = LocalMeterResponsesSession(
                context: context,
                attemptID: "attempt-1",
                inputText: "ledger input",
                accumulator: accumulator)
            _ = try await session.append(Data(Self.completedFixture.utf8))
            _ = try await session.finish()
        }

        let entries = await accumulator.records.map(\.entry)
        let ledger = UsageLedger(entries: entries)
        for window in UsageLedgerWindow.allCases {
            let partition = ledger.partition(for: window, endingAt: now)
            #expect(partition.isConserved)
            #expect(partition.componentTotal == partition.total)
        }
    }

    @Test
    func `final output item text is estimated when added event was empty`() async throws {
        let accumulator = LocalMeterUsageAccumulator()
        let context = self.context(requestID: "responses-final-item")
        let session = LocalMeterResponsesSession(
            context: context,
            attemptID: "attempt-1",
            inputText: "final item input",
            accumulator: accumulator)
        let stream = Self.stream([
            Self.event("response.output_item.added", jsonParts: [
                #"{"type":"response.output_item.added","sequence_number":1,"response_id":"resp-final-item","#,
                #""output_index":0,"item":{"id":"msg-final-item","type":"message","#,
                #""status":"in_progress","content":[]}}"#,
            ]),
            Self.event("response.output_item.done", jsonParts: [
                #"{"type":"response.output_item.done","sequence_number":2,"response_id":"resp-final-item","#,
                #""output_index":0,"item":{"id":"msg-final-item","type":"message","status":"completed","#,
                #""content":[{"type":"output_text","text":"final item body","annotations":[]}]}}"#,
            ]),
            Self.event("response.completed", jsonParts: [
                #"{"type":"response.completed","sequence_number":3,"response":{"id":"resp-final-item","#,
                #""model":"gpt-5.4","#,
                #""status":"completed","usage":{"input_tokens":4,"output_tokens":3,"total_tokens":7}}}"#,
            ]),
        ])

        _ = try await session.append(Data(stream.utf8))
        let record = try #require(try await session.finish())

        #expect(record.entry.amounts.outputTokens ==
            LocalMeterTokenEstimator.estimate("final item body").tokens)
        #expect(record.reportedUsage?.totalTokens == 7)
    }

    @Test
    func `legacy ledger records without Responses fields remain readable`() throws {
        let entry = UsageLedgerEntry(
            key: UsageLedgerKey(
                identityID: "relay:legacy-profile:codex",
                routeProfileID: self.profileID,
                targetApp: .codex,
                model: "gpt-4.1",
                requestID: "legacy-request",
                sessionID: "legacy-session",
                timestamp: Date(timeIntervalSince1970: 1_787_500_000)),
            attribution: .relay,
            amounts: UsageLedgerAmounts(
                inputTokens: 8,
                outputTokens: 13,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                totalTokens: 21,
                requestCount: 1,
                costUSD: nil))
        let entryObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        let legacyPayload: [String: Any] = [
            "entry": entryObject,
            "credentialFingerprint": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPayload)

        let decoded = try JSONDecoder().decode(LocalMeterUsageRecord.self, from: data)

        #expect(decoded.entry == entry)
        #expect(decoded.credentialFingerprint == nil)
        #expect(decoded.localEstimate == nil)
        #expect(decoded.reportedUsage == nil)
    }

    private func context(requestID: String, startedAt: Date = Date(timeIntervalSince1970: 1_787_500_000))
        -> LocalMeterRequestContext
    {
        LocalMeterRequestContext(
            requestID: requestID,
            sessionID: "responses-session",
            routeProfileID: self.profileID,
            targetApp: .codex,
            model: "gpt-5.4",
            startedAt: startedAt,
            credentialFingerprint: nil)
    }

    private static func makeFixtureServer() throws -> LoopbackHTTPServer {
        LoopbackHTTPServer { request in
            guard request.method == "POST", request.path == "/v1/responses" else {
                return LoopbackHTTPResponse(statusCode: 404)
            }
            return LoopbackHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                bodyChunks: Self.sseChunks)
        }
    }

    private static var sseChunks: [Data] {
        let bytes = Array(Self.completedFixture.utf8)
        let sizes = [3, 7, 11, 19, 29, 43]
        var chunks: [Data] = []
        var offset = 0
        var index = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + sizes[index % sizes.count])
            chunks.append(Data(bytes[offset..<end]))
            offset = end
            index += 1
        }
        return chunks
    }

    private static func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{\"model\":\"gpt-5.4\",\"input\":\"fixture\",\"stream\":true}".utf8)
        return request
    }

    private static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private static let completedFixture = OpenAIResponsesSSEParserTests.completedFixture

    private static var firstOutputEventPrefix: String {
        guard let marker = completedFixture.range(of: "event: response.output_text.delta"),
              let eventEnd = completedFixture.range(
                  of: "\n\n",
                  range: marker.lowerBound..<completedFixture.endIndex)
        else {
            return completedFixture
        }
        return String(Self.completedFixture[..<eventEnd.upperBound])
    }

    private static var afterFirstOutputEvent: String {
        guard let marker = completedFixture.range(of: "event: response.output_text.delta"),
              let eventEnd = completedFixture.range(
                  of: "\n\n",
                  range: marker.lowerBound..<completedFixture.endIndex)
        else {
            return ""
        }
        return String(Self.completedFixture[eventEnd.upperBound...])
    }

    private static func event(_ name: String, jsonParts: [String]) -> String {
        "event: \(name)\ndata: \(jsonParts.joined())"
    }

    private static func stream(_ events: [String]) -> String {
        events.joined(separator: "\n\n") + "\n\n"
    }
}
