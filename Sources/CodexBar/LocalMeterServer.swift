import CodexBarCore
import Foundation
import Network

struct LoopbackHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct LoopbackHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let bodyChunks: [Data]
    let declaredBodyLength: Int?

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        bodyChunks: [Data]? = nil,
        declaredBodyLength: Int? = nil)
    {
        self.statusCode = statusCode
        self.headers = headers
        let chunks = bodyChunks ?? [body]
        self.bodyChunks = chunks
        self.body = chunks.reduce(into: Data()) { result, chunk in result.append(chunk) }
        self.declaredBodyLength = declaredBodyLength
    }
}

enum LoopbackHTTPServerError: LocalizedError {
    case failedToStart
    case invalidListenPort

    var errorDescription: String? {
        switch self {
        case .failedToStart: "The loopback listener could not start."
        case .invalidListenPort: "The loopback listener did not publish a port."
        }
    }
}

/// Minimal in-memory HTTP/1.1 listener used by Local Meter and its loopback fixtures.
/// It binds only to IPv4 loopback and never writes request headers or bodies to disk or logs.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (LoopbackHTTPRequest) async -> LoopbackHTTPResponse

    private let requestedPort: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.codexbar.local-meter.listener", qos: .utility)
    private let lock = NSLock()
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?

    init(requestedPort: UInt16 = 0, handler: @escaping Handler) {
        self.requestedPort = requestedPort
        self.handler = handler
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let listener: NWListener
            do {
                let parameters = NWParameters.tcp
                let port = self.requestedPort == 0
                    ? NWEndpoint.Port.any
                    : NWEndpoint.Port(rawValue: self.requestedPort) ?? .any
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                listener = try NWListener(using: parameters)
            } catch {
                continuation.resume(throwing: error)
                return
            }

            self.lock.withLock {
                self.listener = listener
                self.startContinuation = continuation
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let rawPort = listener?.port?.rawValue else {
                        self.finishStart(.failure(LoopbackHTTPServerError.invalidListenPort))
                        return
                    }
                    self.finishStart(.success(rawPort))
                case let .failed(error):
                    self.finishStart(.failure(error))
                case .cancelled:
                    self.finishStart(.failure(LoopbackHTTPServerError.failedToStart))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.newConnectionHandler = { [handler = self.handler, queue = self.queue] connection in
                LoopbackHTTPConnection(connection: connection, handler: handler).start(on: queue)
            }
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        let state = self.lock.withLock { () -> (NWListener?, CheckedContinuation<UInt16, any Error>?) in
            let state = (self.listener, self.startContinuation)
            self.listener = nil
            self.startContinuation = nil
            return state
        }
        state.0?.cancel()
        state.1?.resume(throwing: LoopbackHTTPServerError.failedToStart)
    }

    private func finishStart(_ result: Result<UInt16, any Error>) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
            let continuation = self.startContinuation
            self.startContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class LoopbackHTTPConnection: @unchecked Sendable {
    private static let maximumRequestSize = 8 * 1024 * 1024

    private let connection: NWConnection
    private let handler: LoopbackHTTPServer.Handler
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping LoopbackHTTPServer.Handler) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        self.connection.start(queue: queue)
        self.receive()
    }

    private func receive() {
        self.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024)
        { [self] data, _, isComplete, error in
            if let data {
                self.buffer.append(data)
            }
            guard self.buffer.count <= Self.maximumRequestSize else {
                self.send(LoopbackHTTPResponse(statusCode: 413))
                return
            }
            if let request = self.parseRequest() {
                Task {
                    await self.send(self.handler(request))
                }
                return
            }
            if error != nil || isComplete {
                self.send(LoopbackHTTPResponse(statusCode: 400))
                return
            }
            self.receive()
        }
    }

    private func parseRequest() -> LoopbackHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = self.buffer.range(of: separator) else { return nil }
        let headerData = self.buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= Self.maximumRequestSize else { return nil }
        let bodyStart = headerRange.upperBound
        guard self.buffer.count >= bodyStart + contentLength else { return nil }
        let body = self.buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return LoopbackHTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: body)
    }

    private func send(_ response: LoopbackHTTPResponse) {
        var headers = response.headers
        headers["Content-Length"] = String(response.declaredBodyLength ?? response.body.count)
        headers["Connection"] = "close"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/octet-stream"
        let headerLines = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        var data = Data("HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n\(headerLines)\r\n\r\n"
            .utf8)
        // Keep fixture chunks as an explicit value for tests, but send one correctly framed HTTP
        // message. The streaming client slices the in-memory body before invoking its parser.
        data.append(response.body)
        self.connection.send(content: data, completion: .contentProcessed { [connection = self.connection] _ in
            connection.cancel()
        })
    }

    private static func reason(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 413: "Payload Too Large"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}

enum LocalMeterRuntimeStatus: Equatable, Sendable {
    case disabled
    case starting
    case healthy(port: UInt16)
    case unavailable
}

final class LocalMeterServer: @unchecked Sendable {
    static let defaultPort = LocalMeterEndpoint.defaultPort
    static let healthPath = LocalMeterEndpoint.healthPath
    static let healthHeader = LocalMeterEndpoint.healthHeader
    static let healthSignature = LocalMeterEndpoint.healthSignature

    private let server: LoopbackHTTPServer

    init(upstreamBaseURL: URL? = nil, requestedPort: UInt16 = 0) {
        self.server = LoopbackHTTPServer(requestedPort: requestedPort) { request in
            if request.method == "GET", request.path == Self.healthPath {
                return LoopbackHTTPResponse(
                    statusCode: 200,
                    headers: [Self.healthHeader: Self.healthSignature],
                    body: Data("ok".utf8))
            }
            guard let upstreamBaseURL else {
                return LoopbackHTTPResponse(statusCode: 503)
            }
            return await Self.forward(request, to: upstreamBaseURL)
        }
    }

    func start() async throws -> UInt16 {
        try await self.server.start()
    }

    func stop() {
        self.server.stop()
    }

    private static func forward(
        _ request: LoopbackHTTPRequest,
        to upstreamBaseURL: URL) async -> LoopbackHTTPResponse
    {
        guard let url = self.retarget(path: request.path, baseURL: upstreamBaseURL) else {
            return LoopbackHTTPResponse(statusCode: 502)
        }
        var forwarded = URLRequest(url: url)
        forwarded.httpMethod = request.method
        forwarded.httpBody = request.body.isEmpty ? nil : request.body
        for (name, value) in request.headers where !self.hopByHopHeaderNames.contains(name) {
            forwarded.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: forwarded)
            guard let response = response as? HTTPURLResponse else {
                return LoopbackHTTPResponse(statusCode: 502)
            }
            let headers: [String: String] = Dictionary(
                uniqueKeysWithValues: response.allHeaderFields.compactMap { key, value -> (String, String)? in
                    guard let key = key as? String else { return nil }
                    return (key, String(describing: value))
                })
            return LoopbackHTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
        } catch {
            return LoopbackHTTPResponse(statusCode: 502)
        }
    }

    private static let hopByHopHeaderNames: Set<String> = [
        "connection",
        "content-length",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]

    fileprivate static func retarget(path: String, baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let requestComponents = URLComponents(string: path)
        else { return nil }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let requestPath = requestComponents.percentEncodedPath.hasPrefix("/")
            ? requestComponents.percentEncodedPath
            : "/\(requestComponents.percentEncodedPath)"
        components.percentEncodedPath = basePath + requestPath
        components.percentEncodedQuery = requestComponents.percentEncodedQuery
        return components.url
    }
}

struct LocalMeterHealthProbe: Sendable {
    private let session: URLSession

    init(timeout: TimeInterval = 0.4) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
    }

    func isHealthy(baseURL: URL) async -> Bool {
        guard let url = LocalMeterServer.retarget(path: LocalMeterServer.healthPath, baseURL: baseURL) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await self.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return response.statusCode == 200
                && response.value(forHTTPHeaderField: LocalMeterServer.healthHeader)
                == LocalMeterServer.healthSignature
        } catch {
            return false
        }
    }
}

enum LocalMeterRoute: Equatable, Sendable {
    case meter
    case direct
}

/// Result of a request consumed through the streaming transport. The collected data is retained
/// for callers that need a replay/debug artifact. Direct-route callbacks receive chunks as they
/// arrive; meter-route callbacks are replayed only after a complete response for fail-open safety.
struct LocalMeterTransportResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    let route: LocalMeterRoute
}

private final class LocalMeterChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ chunk: Data) {
        self.lock.withLock {
            self.chunks.append(chunk)
        }
    }

    func snapshot() -> [Data] {
        self.lock.withLock { self.chunks }
    }
}

enum LocalMeterTransportError: Error {
    case invalidURL
    case invalidResponse
}

struct LocalMeterFailOpenTransport: Sendable {
    typealias HealthyProbeHook = @Sendable () async -> Void

    private let session: URLSession
    private let healthProbe: LocalMeterHealthProbe
    private let afterHealthyProbe: HealthyProbeHook

    init(
        timeout: TimeInterval = 1,
        afterHealthyProbe: @escaping HealthyProbeHook = {})
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: configuration)
        self.healthProbe = LocalMeterHealthProbe(timeout: min(timeout, 0.4))
        self.afterHealthyProbe = afterHealthyProbe
    }

    func data(
        for request: URLRequest,
        meterBaseURL: URL,
        upstreamBaseURL: URL) async throws -> LocalMeterTransportResult
    {
        if await self.healthProbe.isHealthy(baseURL: meterBaseURL) {
            await self.afterHealthyProbe()
            do {
                let result = try await self.perform(request, baseURL: meterBaseURL, route: .meter)
                guard result.response.statusCode < 500 else {
                    throw LocalMeterTransportError.invalidResponse
                }
                return result
            } catch {
                // The listener disappeared after a successful probe. Retry the same in-memory
                // request directly; no request contents or credentials are persisted or logged.
            }
        }
        return try await self.perform(request, baseURL: upstreamBaseURL, route: .direct)
    }

    func stream(
        for request: URLRequest,
        meterBaseURL: URL,
        upstreamBaseURL: URL,
        chunkSize: Int = 1024,
        onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> LocalMeterTransportResult
    {
        if await self.healthProbe.isHealthy(baseURL: meterBaseURL) {
            await self.afterHealthyProbe()
            let meterChunks = LocalMeterChunkBuffer()
            let meterResult: LocalMeterTransportResult?
            do {
                // Keep the meter leg transactional. If the helper dies after yielding a partial
                // SSE event, replaying that prefix into a direct request would corrupt the parser
                // state and could double-count a request. The response remains memory-only and is
                // released on either failure or successful replay.
                meterResult = try await self.performStreaming(
                    request,
                    baseURL: meterBaseURL,
                    route: .meter,
                    chunkSize: chunkSize,
                    onChunk: { chunk in meterChunks.append(chunk) })
            } catch {
                // A helper can disappear between the health probe and the first streamed byte.
                // Re-run the same in-memory request directly; no body or credential is persisted.
                meterResult = nil
            }
            if let meterResult {
                // Only expose meter bytes after the complete response has arrived. Errors from the
                // consumer are not transport failures and must not trigger a second request.
                for chunk in meterChunks.snapshot() {
                    try await onChunk(chunk)
                }
                return meterResult
            }
        }
        return try await self.performStreaming(
            request,
            baseURL: upstreamBaseURL,
            route: .direct,
            chunkSize: chunkSize,
            onChunk: onChunk)
    }

    private func perform(
        _ request: URLRequest,
        baseURL: URL,
        route: LocalMeterRoute) async throws -> LocalMeterTransportResult
    {
        guard let sourceURL = request.url,
              let targetURL = LocalMeterServer.retarget(
                  path: sourceURL.path(percentEncoded: true)
                      + sourceURL.query.map { "?\($0)" }.orEmpty,
                  baseURL: baseURL)
        else { throw LocalMeterTransportError.invalidURL }
        var routed = request
        routed.url = targetURL
        routed.setValue(nil, forHTTPHeaderField: "Host")
        let (data, response) = try await self.session.data(for: routed)
        guard let response = response as? HTTPURLResponse else {
            throw LocalMeterTransportError.invalidResponse
        }
        return LocalMeterTransportResult(data: data, response: response, route: route)
    }

    private func performStreaming(
        _ request: URLRequest,
        baseURL: URL,
        route: LocalMeterRoute,
        chunkSize: Int,
        onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> LocalMeterTransportResult
    {
        guard let sourceURL = request.url,
              let targetURL = LocalMeterServer.retarget(
                  path: sourceURL.path(percentEncoded: true)
                      + sourceURL.query.map { "?\($0)" }.orEmpty,
                  baseURL: baseURL)
        else { throw LocalMeterTransportError.invalidURL }
        var routed = request
        routed.url = targetURL
        routed.setValue(nil, forHTTPHeaderField: "Host")
        let (bytes, response) = try await self.session.bytes(for: routed)
        guard let response = response as? HTTPURLResponse else {
            throw LocalMeterTransportError.invalidResponse
        }
        // A healthy helper that cannot handle the request must not turn a fail-open path into a
        // synthetic success. Retry the request against the real upstream instead.
        if route == .meter, response.statusCode >= 500 {
            throw LocalMeterTransportError.invalidResponse
        }
        var collected = Data()
        var chunk = Data()
        let chunkSize = max(1, chunkSize)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= chunkSize {
                try await onChunk(chunk)
                collected.append(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            try await onChunk(chunk)
            collected.append(chunk)
        }
        return LocalMeterTransportResult(data: collected, response: response, route: route)
    }
}

extension String? {
    fileprivate var orEmpty: String {
        self ?? ""
    }
}

@MainActor
final class LocalMeterCoordinator {
    private let settings: SettingsStore
    private let launchdController: LocalMeterLaunchdController?
    private let healthCheck: @Sendable () async -> Bool
    private let activeLoopbackRouteCheck: @Sendable () -> Bool
    private var lifecycleTask: Task<Void, Never>?
    private var appliedEnabledState: Bool?

    init(
        settings: SettingsStore,
        launchdController: LocalMeterLaunchdController? = LocalMeterCoordinator.makeDefaultLaunchdController(),
        healthCheck: (@Sendable () async -> Bool)? = nil,
        activeLoopbackRouteCheck: (@Sendable () -> Bool)? = nil)
    {
        self.settings = settings
        self.launchdController = launchdController
        if let healthCheck {
            self.healthCheck = healthCheck
        } else {
            self.healthCheck = {
                await LocalMeterHealthProbe().isHealthy(baseURL: LocalMeterEndpoint.baseURL())
            }
        }
        if let activeLoopbackRouteCheck {
            self.activeLoopbackRouteCheck = activeLoopbackRouteCheck
        } else {
            // The default is deliberately inert. Production wiring supplies the live,
            // credential-free checker explicitly; tests must inject a fixture checker.
            self.activeLoopbackRouteCheck = { false }
        }
    }

    func restart() {
        let enabled = self.settings.localMeterEnabled
        guard self.appliedEnabledState != enabled else { return }
        self.appliedEnabledState = enabled
        self.lifecycleTask?.cancel()
        self.lifecycleTask = nil
        guard enabled else {
            self.stop(removeJob: true)
            return
        }
        guard let launchdController = self.launchdController else {
            self.settings.localMeterRuntimeStatus = .unavailable
            return
        }
        self.settings.localMeterRuntimeStatus = .starting
        self.lifecycleTask = Task { [weak self] in
            do {
                _ = try launchdController.installAndStart()
                guard !Task.isCancelled else { return }
                var healthy = false
                for attempt in 0..<25 {
                    healthy = await self?.healthCheck() ?? false
                    if healthy { break }
                    if attempt < 24 {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                guard !Task.isCancelled else { return }
                self?.settings.localMeterRuntimeStatus = healthy
                    ? .healthy(port: LocalMeterEndpoint.defaultPort)
                    : .unavailable
                if healthy {
                    self?.reconcileActiveRoute()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.settings.localMeterRuntimeStatus = .unavailable
            }
        }
    }

    /// A route-application notification can arrive after launchd is already healthy. Rechecking
    /// here makes the two prerequisite events order-independent without restarting the helper.
    func reconcileActiveRoute() {
        guard case .healthy = self.settings.localMeterRuntimeStatus,
              self.activeLoopbackRouteCheck()
        else { return }
        LocalMeterStartupPresentation.revokeAfterVerifiedLoopbackActivation(on: self.settings)
    }

    func stop() {
        self.appliedEnabledState = false
        self.stop(removeJob: true)
    }

    /// App termination must not unload the user agent. launchd owns the helper so it can survive
    /// a GUI restart; an explicit setting toggle uses `stop()` and removes the job instead.
    func shutdown() {
        self.lifecycleTask?.cancel()
        self.lifecycleTask = nil
        self.settings.localMeterRuntimeStatus = .disabled
    }

    private func stop(removeJob: Bool) {
        self.lifecycleTask?.cancel()
        self.lifecycleTask = nil
        if removeJob {
            try? self.launchdController?.stopAndRemove()
        }
        self.settings.localMeterRuntimeStatus = .disabled
    }

    private static func makeDefaultLaunchdController() -> LocalMeterLaunchdController? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CodexBarLocalMeterHelper", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return nil }
        return LocalMeterLaunchdController(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            helperURL: helperURL)
    }
}

extension StatusItemController {
    func startLocalMeterIfEnabled() {
        guard !SettingsStore.isRunningTests else { return }
        if self.localMeterCoordinator == nil {
            self.localMeterCoordinator = LocalMeterCoordinator(
                settings: self.settings,
                activeLoopbackRouteCheck: {
                    LocalMeterStartupRecovery.hasActiveLoopbackRoute()
                })
        }
        self.localMeterCoordinator?.restart()
    }
}
