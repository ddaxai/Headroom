import CodexBarCore
import Foundation
import Network

private enum HelperExitCode {
    static let usage: Int32 = 64
    static let failedToStart: Int32 = 70
}

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Deliberately tiny HTTP listener for the launchd-owned process. It has no AppKit dependency,
/// binds to IPv4 loopback only, and keeps request bytes in memory for the current connection.
private final class HelperServer: @unchecked Sendable {
    private static let maximumRequestSize = 8 * 1024 * 1024

    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "com.ddaxia.headroom.local-meter", qos: .utility)
    private let lock = NSLock()
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?

    init(requestedPort: UInt16) {
        self.requestedPort = requestedPort
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
                    guard let port = listener?.port?.rawValue else {
                        self.finishStart(.failure(HelperError.invalidPort))
                        return
                    }
                    self.finishStart(.success(port))
                case let .failed(error):
                    self.finishStart(.failure(error))
                case .cancelled:
                    self.finishStart(.failure(HelperError.cancelled))
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self, queue = self.queue] connection in
                guard let self else { return }
                HelperConnection(connection: connection) { request in
                    self.response(for: request)
                }.start(on: queue)
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
        state.1?.resume(throwing: HelperError.cancelled)
    }

    private func response(for request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", request.path == LocalMeterEndpoint.healthPath {
            return HTTPResponse(
                statusCode: 200,
                headers: [LocalMeterEndpoint.healthHeader: LocalMeterEndpoint.healthSignature],
                body: Data("ok".utf8))
        }
        // S5 owns protocol forwarding and accounting. Until then, never pretend to have handled
        // a request and never proxy it anywhere by accident.
        return HTTPResponse(statusCode: 503)
    }

    private func finishStart(_ result: Result<UInt16, any Error>) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
            let continuation = self.startContinuation
            self.startContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    fileprivate static var maximumBytes: Int {
        self.maximumRequestSize
    }
}

private enum HelperError: LocalizedError {
    case invalidPort
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidPort: "The helper listener did not publish a port."
        case .cancelled: "The helper listener was cancelled."
        }
    }
}

private final class HelperConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private var buffer = Data()

    init(connection: NWConnection, handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        self.connection.start(queue: queue)
        self.receive()
    }

    private func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [self] data, _, isComplete, error in
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= HelperServer.maximumBytes else {
                self.send(HTTPResponse(statusCode: 413))
                return
            }
            if let request = self.parseRequest() {
                self.send(self.handler(request))
                return
            }
            if error != nil || isComplete {
                self.send(HTTPResponse(statusCode: 400))
                return
            }
            self.receive()
        }
    }

    private func parseRequest() -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = self.buffer.range(of: separator),
              let headerText = String(data: self.buffer[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= HelperServer.maximumBytes else { return nil }
        let bodyStart = headerRange.upperBound
        guard self.buffer.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: parts[0],
            path: parts[1],
            headers: headers,
            body: self.buffer.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }

    private func send(_ response: HTTPResponse) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/octet-stream"
        let lines = headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        var data = Data("HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n\(lines)\r\n\r\n".utf8)
        data.append(response.body)
        self.connection.send(content: data, completion: .contentProcessed { [connection = self.connection] _ in
            connection.cancel()
        })
    }

    private static func reason(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 413: "Payload Too Large"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}

private func parsePort() -> UInt16? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count,
          let value = UInt16(arguments[index + 1])
    else { return nil }
    return value
}

@main
private struct CodexBarLocalMeterHelper {
    static func main() async {
        guard let port = parsePort() else {
            fputs("Usage: CodexBarLocalMeterHelper --port <0..65535>\n", stderr)
            Foundation.exit(HelperExitCode.usage)
        }

        let server = HelperServer(requestedPort: port)
        do {
            let actualPort = try await server.start()
            // launchd sends stdout to /dev/null; this line is intentionally useful only to
            // isolated process fixtures that launch the helper with an ephemeral port.
            print("READY \(actualPort)")
            // Keep the async main task alive without entering a second dispatch main loop. launchd
            // terminates this process explicitly on unload; no request data is retained between
            // connections.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86400))
            }
        } catch {
            fputs("CodexBarLocalMeterHelper: failed to start\n", stderr)
            Foundation.exit(HelperExitCode.failedToStart)
        }
    }
}
