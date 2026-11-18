import Foundation

public enum PiAgentProbe {
    public enum Reason: String, Sendable, Equatable {
        case commandMissing
        case sessionsDirectoryMissing
        case noSessions
    }

    public struct Result: Sendable, Equatable {
        public let state: LocalUsageState
        public let reason: Reason?
        public let parseableSessionCount: Int

        public init(
            state: LocalUsageState,
            reason: Reason? = nil,
            parseableSessionCount: Int = 0)
        {
            self.state = state
            self.reason = reason
            self.parseableSessionCount = max(0, parseableSessionCount)
        }

        public static let loading = Result(state: .loading)
    }

    public static func inspectDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> Result
    {
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeURL = home.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        let sessionsRoot = homeURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let commandURL = BinaryLocator.resolvePiBinary(
            env: environment,
            fileManager: fileManager,
            home: homeURL.path).map(URL.init(fileURLWithPath:))
        return self.inspect(commandURL: commandURL, sessionsRoot: sessionsRoot, fileManager: fileManager)
    }

    public static func inspect(
        commandURL: URL?,
        sessionsRoot: URL,
        fileManager: FileManager = .default) -> Result
    {
        guard let commandURL,
              fileManager.isExecutableFile(atPath: commandURL.path)
        else {
            return Result(state: .unavailable, reason: .commandMissing)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return Result(state: .unavailable, reason: .sessionsDirectoryMissing)
        }

        let count = PiSessionCostScanner.parseableSessionCount(
            in: sessionsRoot,
            fileManager: fileManager)
        guard count > 0 else {
            return Result(state: .empty, reason: .noSessions)
        }
        return Result(state: .available, parseableSessionCount: count)
    }

    public static func loadIfEnabled(
        _ isEnabled: Bool,
        probe: () -> Result) -> Result?
    {
        guard isEnabled else { return nil }
        return probe()
    }
}
