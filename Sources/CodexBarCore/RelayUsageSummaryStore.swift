import Foundation

public protocol RelayUsageSummaryStoring: Sendable {
    func load(profileID: UUID) -> RelayUsageSummary?
    func store(_ summary: RelayUsageSummary, profileID: UUID) throws
}

public struct RelayUsageSummaryCacheState: Sendable, Equatable {
    public let summary: RelayUsageSummary?
    public let lastAttemptAt: Date?
    public let lastError: String?
    public let isFresh: Bool
}

public struct FileRelayUsageSummaryStore: RelayUsageSummaryStoring, @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        var summaries: [String: RelayUsageSummary]
        var metadata: [String: Metadata]

        private enum CodingKeys: String, CodingKey { case version, summaries, metadata }

        init(version: Int, summaries: [String: RelayUsageSummary], metadata: [String: Metadata]) {
            self.version = version
            self.summaries = summaries
            self.metadata = metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decode(Int.self, forKey: .version)
            self.summaries = try container.decode([String: RelayUsageSummary].self, forKey: .summaries)
            self.metadata = try container.decodeIfPresent([String: Metadata].self, forKey: .metadata) ?? [:]
        }
    }

    private struct Metadata: Codable {
        var lastAttemptAt: Date?
        var lastError: String?
    }

    public static let defaultTTL: TimeInterval = 5 * 60
    private static let currentVersion = 2
    private static let lock = NSLock()
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load(profileID: UUID) -> RelayUsageSummary? {
        Self.lock.withLock {
            try? self.loadPayload().summaries[profileID.uuidString.lowercased()]
        }
    }

    public func store(_ summary: RelayUsageSummary, profileID: UUID) throws {
        try Self.lock.withLock {
            var payload = try self.loadPayload()
            payload.summaries[profileID.uuidString.lowercased()] = summary
            payload.metadata[profileID.uuidString.lowercased()] = Metadata(
                lastAttemptAt: summary.updatedAt,
                lastError: nil)
            let directory = self.fileURL.deletingLastPathComponent()
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(payload).write(to: self.fileURL, options: .atomic)
            try self.fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: self.fileURL.path)
        }
    }

    public func loadFresh(
        profileID: UUID,
        now: Date = Date(),
        ttl: TimeInterval = Self.defaultTTL) -> RelayUsageSummary?
    {
        let state = self.loadState(profileID: profileID, now: now, ttl: ttl)
        return state.isFresh ? state.summary : nil
    }

    public func loadState(
        profileID: UUID,
        now: Date = Date(),
        ttl: TimeInterval = Self.defaultTTL) -> RelayUsageSummaryCacheState
    {
        Self.lock.withLock {
            let key = profileID.uuidString.lowercased()
            let payload = try? self.loadPayload()
            let summary = payload?.summaries[key]
            let metadata = payload?.metadata[key]
            let updatedAt = summary?.updatedAt
            let fresh = summary != nil
                && metadata?.lastError == nil
                && updatedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < max(0, ttl) } == true
            return RelayUsageSummaryCacheState(
                summary: summary,
                lastAttemptAt: metadata?.lastAttemptAt ?? updatedAt,
                lastError: metadata?.lastError,
                isFresh: fresh)
        }
    }

    public func recordFailure(profileID: UUID, error: String, at: Date = Date()) throws {
        try Self.lock.withLock {
            var payload = try self.loadPayload()
            let key = profileID.uuidString.lowercased()
            let previous = payload.metadata[key]
            payload.metadata[key] = Metadata(
                lastAttemptAt: at,
                lastError: error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? previous?.lastError
                    : error)
            try self.write(payload)
        }
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("relay-usage-cache.json", isDirectory: false)
    }

    private func loadPayload() throws -> Payload {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else {
            return Payload(version: Self.currentVersion, summaries: [:], metadata: [:])
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: self.fileURL))
        guard payload.version == Self.currentVersion else {
            if payload.version == 1 {
                return Payload(
                    version: Self.currentVersion,
                    summaries: payload.summaries,
                    metadata: payload.summaries.mapValues { Metadata(lastAttemptAt: $0.updatedAt, lastError: nil) })
            }
            return Payload(version: Self.currentVersion, summaries: [:], metadata: [:])
        }
        return payload
    }

    private func write(_ payload: Payload) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        if !self.fileManager.fileExists(atPath: directory.path) {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(payload).write(to: self.fileURL, options: .atomic)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }
}
