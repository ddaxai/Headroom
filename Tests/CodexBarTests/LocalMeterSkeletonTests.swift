import Foundation
import Testing
@testable import CodexBar

@Suite("M5 S2 fail-open local meter skeleton", .serialized)
struct LocalMeterSkeletonTests {
    @Test
    func `meter absent routes directly to the upstream`() async throws {
        let upstream = LoopbackHTTPServer { request in
            #expect(request.path == "/v1/responses?case=absent")
            return LoopbackHTTPResponse(statusCode: 200, body: Data("direct-absent".utf8))
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let unavailable = LoopbackHTTPServer { _ in LoopbackHTTPResponse(statusCode: 500) }
        let unavailablePort = try await unavailable.start()
        unavailable.stop()

        let result = try await LocalMeterFailOpenTransport().data(
            for: Self.request(path: "/v1/responses?case=absent"),
            meterBaseURL: Self.baseURL(port: unavailablePort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort))

        #expect(result.route == .direct)
        #expect(String(bytes: result.data, encoding: .utf8) == "direct-absent")
    }

    @Test
    func `unrelated service occupying the meter port routes directly`() async throws {
        let unrelated = LoopbackHTTPServer { request in
            #expect(request.path == LocalMeterServer.healthPath)
            return LoopbackHTTPResponse(statusCode: 200, body: Data("not-headroom".utf8))
        }
        let unrelatedPort = try await unrelated.start()
        defer { unrelated.stop() }

        let upstream = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(statusCode: 200, body: Data("direct-occupied".utf8))
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let result = try await LocalMeterFailOpenTransport().data(
            for: Self.request(path: "/v1/chat/completions"),
            meterBaseURL: Self.baseURL(port: unrelatedPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort))

        #expect(result.route == .direct)
        #expect(String(bytes: result.data, encoding: .utf8) == "direct-occupied")
    }

    @Test
    func `meter crash after health probe retries the request directly`() async throws {
        let upstream = LoopbackHTTPServer { _ in
            LoopbackHTTPResponse(statusCode: 200, body: Data("direct-after-crash".utf8))
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        let transport = LocalMeterFailOpenTransport(afterHealthyProbe: {
            meter.stop()
        })

        let result = try await transport.data(
            for: Self.request(path: "/v1/responses"),
            meterBaseURL: Self.baseURL(port: meterPort),
            upstreamBaseURL: Self.baseURL(port: upstreamPort))

        #expect(result.route == .direct)
        #expect(String(bytes: result.data, encoding: .utf8) == "direct-after-crash")
    }

    @Test
    func `meter can be started health checked forwarded through and stopped`() async throws {
        let upstream = LoopbackHTTPServer { request in
            #expect(request.method == "POST")
            #expect(request.path == "/v1/responses")
            #expect(String(bytes: request.body, encoding: .utf8) == "fixture-body")
            return LoopbackHTTPResponse(statusCode: 201, body: Data("meter-forwarded".utf8))
        }
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }

        let meter = LocalMeterServer(upstreamBaseURL: Self.baseURL(port: upstreamPort))
        let meterPort = try await meter.start()
        let meterURL = Self.baseURL(port: meterPort)
        let probe = LocalMeterHealthProbe()

        #expect(await probe.isHealthy(baseURL: meterURL))

        let result = try await LocalMeterFailOpenTransport().data(
            for: Self.request(path: "/v1/responses", method: "POST", body: Data("fixture-body".utf8)),
            meterBaseURL: meterURL,
            upstreamBaseURL: Self.baseURL(port: upstreamPort))

        #expect(result.route == .meter)
        #expect(result.response.statusCode == 201)
        #expect(String(bytes: result.data, encoding: .utf8) == "meter-forwarded")

        meter.stop()
        #expect(await !probe.isHealthy(baseURL: meterURL))
    }

    @Test @MainActor
    func `local meter setting defaults off and persists explicit opt in`() {
        let settings = testSettingsStore(suiteName: "LocalMeterSkeletonTests-setting")
        #expect(!settings.localMeterEnabled)

        settings.localMeterEnabled = true

        #expect(settings.userDefaults.bool(forKey: "localMeterEnabled"))
    }

    private static func request(
        path: String,
        method: String = "GET",
        body: Data? = nil) -> URLRequest
    {
        var request = URLRequest(url: URL(string: "https://fixture.invalid\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    private static func baseURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }
}
