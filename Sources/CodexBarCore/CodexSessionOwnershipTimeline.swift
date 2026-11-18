import Foundation

/// A local, credential-free record of which managed Codex account was active
/// while the shared system Codex home was receiving token events.
public struct CodexSessionOwnershipTimeline: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public enum Confidence: String, Codable, Equatable, Sendable {
        case observed
        case assumed
    }

    public enum AttributionSource: String, Codable, Equatable, Sendable {
        case observed
        case assumed
        case manual
    }

    public struct Event: Codable, Equatable, Sendable {
        public let timestampUnixMs: Int64
        public let accountKey: String
        public let confidence: Confidence

        public init(
            timestampUnixMs: Int64,
            accountKey: String,
            confidence: Confidence = .observed)
        {
            self.timestampUnixMs = timestampUnixMs
            self.accountKey = accountKey
            self.confidence = confidence
        }

        private enum CodingKeys: String, CodingKey {
            case timestampUnixMs
            case accountKey
            case confidence
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.timestampUnixMs = try container.decode(Int64.self, forKey: .timestampUnixMs)
            self.accountKey = try container.decode(String.self, forKey: .accountKey)
            self.confidence = try container.decodeIfPresent(Confidence.self, forKey: .confidence) ?? .observed
        }
    }

    public enum CodexRoute: Equatable, Sendable {
        case official
        case relay(profileID: UUID)
        case unknown

        public var isRelay: Bool {
            if case .relay = self { return true }
            return false
        }
    }

    public struct CodexRouteEvent: Codable, Equatable, Sendable {
        public let timestampUnixMs: Int64
        public let route: CodexRoute

        public init(timestampUnixMs: Int64, route: CodexRoute) {
            self.timestampUnixMs = timestampUnixMs
            self.route = route
        }

        private enum CodingKeys: String, CodingKey {
            case timestampUnixMs
            case kind
            case profileID
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.timestampUnixMs = try container.decode(Int64.self, forKey: .timestampUnixMs)
            switch try container.decodeIfPresent(String.self, forKey: .kind) {
            case "official":
                self.route = .official
            case "relay":
                self.route = if let profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID) {
                    .relay(profileID: profileID)
                } else {
                    .unknown
                }
            default:
                self.route = .unknown
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.timestampUnixMs, forKey: .timestampUnixMs)
            switch self.route {
            case .official:
                try container.encode("official", forKey: .kind)
            case let .relay(profileID):
                try container.encode("relay", forKey: .kind)
                try container.encode(profileID, forKey: .profileID)
            case .unknown:
                try container.encode("unknown", forKey: .kind)
            }
        }
    }

    public struct ManualAttribution: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let accountKey: String
        public let startUnixMs: Int64?
        public let endUnixMsExclusive: Int64?
        public let createdAtUnixMs: Int64
        public let source: AttributionSource

        fileprivate init(
            id: UUID = UUID(),
            accountKey: String,
            startUnixMs: Int64?,
            endUnixMsExclusive: Int64?,
            createdAtUnixMs: Int64)
        {
            self.id = id
            self.accountKey = accountKey
            self.startUnixMs = startUnixMs
            self.endUnixMsExclusive = endUnixMsExclusive
            self.createdAtUnixMs = createdAtUnixMs
            self.source = .manual
        }

        fileprivate func contains(_ timestampUnixMs: Int64) -> Bool {
            if let startUnixMs, timestampUnixMs < startUnixMs { return false }
            if let endUnixMsExclusive, timestampUnixMs >= endUnixMsExclusive { return false }
            return true
        }
    }

    public struct Attribution: Equatable, Sendable {
        public let accountKey: String
        public let source: AttributionSource
        public let manualAttributionID: UUID?
    }

    public enum ManualAttributionError: LocalizedError, Equatable, Sendable {
        case emptyAccountKey
        case incompleteRange
        case invalidRange

        public var errorDescription: String? {
            switch self {
            case .emptyAccountKey:
                "The target account key cannot be empty."
            case .incompleteRange:
                "A manual attribution must cover the whole unassigned bucket or provide both range boundaries."
            case .invalidRange:
                "The manual attribution end must be later than its start."
            }
        }
    }

    public private(set) var schemaVersion: Int
    public private(set) var events: [Event]
    public private(set) var manualAttributions: [ManualAttribution]
    public private(set) var codexRouteEvents: [CodexRouteEvent]

    public init(
        events: [Event] = [],
        manualAttributions: [ManualAttribution] = [],
        codexRouteEvents: [CodexRouteEvent] = [])
    {
        self.schemaVersion = Self.currentSchemaVersion
        self.events = Self.normalized(events)
        self.manualAttributions = manualAttributions
        self.codexRouteEvents = Self.normalized(codexRouteEvents)
    }

    /// A deterministic cache discriminator. It changes only when provenance
    /// changes, including adding or removing a manual attribution.
    public var revision: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for event in self.events {
            Self.hash(
                "event\u{0}\(event.timestampUnixMs)\u{0}\(event.accountKey)\u{0}\(event.confidence.rawValue)\u{1f}",
                into: &hash)
        }
        for attribution in self.manualAttributions {
            let start = attribution.startUnixMs.map(String.init) ?? "nil"
            let end = attribution.endUnixMsExclusive.map(String.init) ?? "nil"
            Self.hash(
                "manual\u{0}\(attribution.id.uuidString.lowercased())\u{0}\(attribution.accountKey)\u{0}"
                    + "\(start)\u{0}"
                    + "\(end)\u{0}"
                    + "\(attribution.createdAtUnixMs)\u{1f}",
                into: &hash)
        }
        for event in self.codexRouteEvents {
            let route = switch event.route {
            case .official: "official"
            case let .relay(profileID): "relay:\(profileID.uuidString.lowercased())"
            case .unknown: "unknown"
            }
            Self.hash("route\u{0}\(event.timestampUnixMs)\u{0}\(route)\u{1f}", into: &hash)
        }
        return String(format: "v3:%016llx", hash)
    }

    @discardableResult
    public mutating func recordActivation(accountKey: String, at: Date = Date()) -> Bool {
        self.recordActivation(
            accountKey: accountKey,
            atUnixMilliseconds: Self.unixMilliseconds(at))
    }

    @discardableResult
    public mutating func recordActivation(accountKey: String, atUnixMilliseconds: Int64) -> Bool {
        let normalizedKey = Self.normalizedAccountKey(accountKey)
        guard !normalizedKey.isEmpty,
              self.events.last?.accountKey != normalizedKey || self.events.last?.confidence != .observed
        else { return false }
        self.events.append(Event(
            timestampUnixMs: atUnixMilliseconds,
            accountKey: normalizedKey,
            confidence: .observed))
        self.events = Self.normalized(self.events)
        return true
    }

    /// Adds at most one assumed boundary. This is deliberately distinct from
    /// an observed activation so a later scan can explain where the boundary came from.
    @discardableResult
    public mutating func seedAssumedStartingBoundaryIfNeeded(
        accountKey: String,
        atUnixMilliseconds: Int64) -> Bool
    {
        let normalizedKey = Self.normalizedAccountKey(accountKey)
        guard !normalizedKey.isEmpty,
              !self.events.contains(where: { $0.confidence == .assumed })
        else { return false }
        self.events.append(Event(
            timestampUnixMs: atUnixMilliseconds,
            accountKey: normalizedKey,
            confidence: .assumed))
        self.events = Self.normalized(self.events)
        return true
    }

    @discardableResult
    public mutating func recordManualAttribution(
        accountKey: String,
        startUnixMilliseconds: Int64?,
        endUnixMillisecondsExclusive: Int64?,
        createdAtUnixMilliseconds: Int64) throws -> ManualAttribution
    {
        let normalizedKey = Self.normalizedAccountKey(accountKey)
        guard !normalizedKey.isEmpty else { throw ManualAttributionError.emptyAccountKey }
        guard (startUnixMilliseconds == nil) == (endUnixMillisecondsExclusive == nil) else {
            throw ManualAttributionError.incompleteRange
        }
        if let startUnixMilliseconds, let endUnixMillisecondsExclusive,
           startUnixMilliseconds >= endUnixMillisecondsExclusive
        {
            throw ManualAttributionError.invalidRange
        }
        let attribution = ManualAttribution(
            accountKey: normalizedKey,
            startUnixMs: startUnixMilliseconds,
            endUnixMsExclusive: endUnixMillisecondsExclusive,
            createdAtUnixMs: createdAtUnixMilliseconds)
        self.manualAttributions.append(attribution)
        return attribution
    }

    @discardableResult
    public mutating func removeManualAttribution(id: UUID) -> Bool {
        guard let index = self.manualAttributions.firstIndex(where: { $0.id == id }) else { return false }
        self.manualAttributions.remove(at: index)
        return true
    }

    public func attribution(atUnixMilliseconds timestampUnixMs: Int64) -> Attribution? {
        if let event = self.events.last(where: { $0.timestampUnixMs <= timestampUnixMs }) {
            return Attribution(
                accountKey: event.accountKey,
                source: event.confidence == .observed ? .observed : .assumed,
                manualAttributionID: nil)
        }
        guard let manual = self.manualAttributions.last(where: { $0.contains(timestampUnixMs) }) else {
            return nil
        }
        return Attribution(
            accountKey: manual.accountKey,
            source: .manual,
            manualAttributionID: manual.id)
    }

    public func ownerAccountKey(atUnixMilliseconds timestampUnixMs: Int64) -> String? {
        self.attribution(atUnixMilliseconds: timestampUnixMs)?.accountKey
    }

    public func codexRoute(atUnixMilliseconds timestampUnixMs: Int64) -> CodexRoute? {
        self.codexRouteEvents.last(where: { $0.timestampUnixMs <= timestampUnixMs })?.route
    }

    public var codexRelayProfileIDs: Set<UUID> {
        Set(self.codexRouteEvents.compactMap { event in
            if case let .relay(profileID) = event.route { return profileID }
            return nil
        })
    }

    @discardableResult
    public mutating func recordCodexRelayActivation(
        profileID: UUID,
        atUnixMilliseconds: Int64) -> Bool
    {
        self.recordCodexRoute(.relay(profileID: profileID), atUnixMilliseconds: atUnixMilliseconds)
    }

    @discardableResult
    public mutating func recordOfficialCodexRoute(atUnixMilliseconds: Int64) -> Bool {
        self.recordCodexRoute(.official, atUnixMilliseconds: atUnixMilliseconds)
    }

    @discardableResult
    public mutating func recordUnknownCodexRoute(atUnixMilliseconds: Int64) -> Bool {
        self.recordCodexRoute(.unknown, atUnixMilliseconds: atUnixMilliseconds)
    }

    @discardableResult
    private mutating func recordCodexRoute(_ route: CodexRoute, atUnixMilliseconds: Int64) -> Bool {
        let normalized = Self.normalized(
            self.codexRouteEvents + [CodexRouteEvent(timestampUnixMs: atUnixMilliseconds, route: route)])
        guard normalized != self.codexRouteEvents else { return false }
        self.codexRouteEvents = normalized
        return true
    }

    public static func managedAccountKey(id: UUID) -> String {
        "codex:managed:\(id.uuidString.lowercased())"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case events
        case manualAttributions
        case codexRouteEvents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedSchemaVersion <= Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported future ownership schema version \(decodedSchemaVersion).")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.events = try Self.normalized(container.decodeIfPresent([Event].self, forKey: .events) ?? [])
        self.manualAttributions = try container.decodeIfPresent(
            [ManualAttribution].self,
            forKey: .manualAttributions) ?? []
        self.codexRouteEvents = try Self.normalized(container.decodeIfPresent(
            [CodexRouteEvent].self,
            forKey: .codexRouteEvents) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(self.events, forKey: .events)
        try container.encode(self.manualAttributions, forKey: .manualAttributions)
        try container.encode(self.codexRouteEvents, forKey: .codexRouteEvents)
    }

    private static func normalized(_ events: [Event]) -> [Event] {
        let sorted = events.enumerated()
            .compactMap { offset, event -> (offset: Int, event: Event)? in
                let accountKey = self.normalizedAccountKey(event.accountKey)
                guard !accountKey.isEmpty else { return nil }
                return (offset, Event(
                    timestampUnixMs: event.timestampUnixMs,
                    accountKey: accountKey,
                    confidence: event.confidence))
            }
            .sorted {
                if $0.event.timestampUnixMs != $1.event.timestampUnixMs {
                    return $0.event.timestampUnixMs < $1.event.timestampUnixMs
                }
                return $0.offset < $1.offset
            }
        var result: [Event] = []
        for (_, event) in sorted
            where result.last?.accountKey != event.accountKey || result.last?.confidence != event.confidence
        {
            result.append(event)
        }
        return result
    }

    private static func normalized(_ events: [CodexRouteEvent]) -> [CodexRouteEvent] {
        let sorted = events.enumerated().sorted {
            if $0.element.timestampUnixMs != $1.element.timestampUnixMs {
                return $0.element.timestampUnixMs < $1.element.timestampUnixMs
            }
            return $0.offset < $1.offset
        }
        var result: [CodexRouteEvent] = []
        for (_, event) in sorted where result.last?.route != event.route {
            result.append(event)
        }
        return result
    }

    private static func normalizedAccountKey(_ accountKey: String) -> String {
        accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func hash(_ value: String, into hash: inout UInt64) {
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }
    }
}

public protocol CodexSessionOwnershipRecording: Sendable {
    @discardableResult
    func recordActivation(accountKey: String, at: Date) throws -> Bool
}

public final class FileCodexSessionOwnershipTimelineStore: CodexSessionOwnershipRecording, @unchecked Sendable {
    public static let `default` = FileCodexSessionOwnershipTimelineStore()

    public let fileURL: URL
    public let legacyFileURL: URL?
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default)
    {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
            self.legacyFileURL = nil
        } else {
            let root = applicationSupportDirectory
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = root
                .appendingPathComponent("Headroom", isDirectory: true)
                .appendingPathComponent("ownership", isDirectory: true)
                .appendingPathComponent("timeline.json", isDirectory: false)
            self.legacyFileURL = root
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("codex-session-ownership.json", isDirectory: false)
        }
    }

    public func load() throws -> CodexSessionOwnershipTimeline {
        self.lock.lock()
        defer { self.lock.unlock() }
        return try self.loadUnlocked()
    }

    @discardableResult
    public func recordActivation(accountKey: String, at: Date = Date()) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        var timeline = try self.loadUnlocked()
        guard timeline.recordActivation(accountKey: accountKey, at: at) else { return false }
        try self.saveUnlocked(timeline)
        return true
    }

    @discardableResult
    public func seedAssumedStartingBoundaryIfNeeded(accountKey: String, at: Date = Date()) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        var timeline = try self.loadUnlocked()
        guard timeline.seedAssumedStartingBoundaryIfNeeded(
            accountKey: accountKey,
            atUnixMilliseconds: Int64((at.timeIntervalSince1970 * 1000).rounded(.down)))
        else { return false }
        try self.saveUnlocked(timeline)
        return true
    }

    @discardableResult
    public func recordCodexRelayActivation(profileID: UUID, at: Date = Date()) throws -> Bool {
        try self.mutateCodexRoute(at: at) {
            $0.recordCodexRelayActivation(profileID: profileID, atUnixMilliseconds: $1)
        }
    }

    @discardableResult
    public func recordOfficialCodexRoute(at: Date = Date()) throws -> Bool {
        try self.mutateCodexRoute(at: at) {
            $0.recordOfficialCodexRoute(atUnixMilliseconds: $1)
        }
    }

    @discardableResult
    public func recordUnknownCodexRoute(at: Date = Date()) throws -> Bool {
        try self.mutateCodexRoute(at: at) {
            $0.recordUnknownCodexRoute(atUnixMilliseconds: $1)
        }
    }

    @discardableResult
    public func recordManualAttribution(
        accountKey: String,
        start: Date?,
        endExclusive: Date?,
        createdAt: Date = Date()) throws -> CodexSessionOwnershipTimeline.ManualAttribution
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        var timeline = try self.loadUnlocked()
        let attribution = try timeline.recordManualAttribution(
            accountKey: accountKey,
            startUnixMilliseconds: start.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) },
            endUnixMillisecondsExclusive: endExclusive.map {
                Int64(($0.timeIntervalSince1970 * 1000).rounded(.down))
            },
            createdAtUnixMilliseconds: Int64((createdAt.timeIntervalSince1970 * 1000).rounded(.down)))
        try self.saveUnlocked(timeline)
        return attribution
    }

    @discardableResult
    public func removeManualAttribution(id: UUID) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        var timeline = try self.loadUnlocked()
        guard timeline.removeManualAttribution(id: id) else { return false }
        try self.saveUnlocked(timeline)
        return true
    }

    private func mutateCodexRoute(
        at date: Date,
        _ mutation: (inout CodexSessionOwnershipTimeline, Int64) -> Bool) throws -> Bool
    {
        self.lock.lock()
        defer { self.lock.unlock() }
        var timeline = try self.loadUnlocked()
        let timestamp = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        guard mutation(&timeline, timestamp) else { return false }
        try self.saveUnlocked(timeline)
        return true
    }

    private func loadUnlocked() throws -> CodexSessionOwnershipTimeline {
        if self.fileManager.fileExists(atPath: self.fileURL.path) {
            return try self.decodeTimeline(at: self.fileURL)
        }
        if let legacyFileURL,
           self.fileManager.fileExists(atPath: legacyFileURL.path)
        {
            let migrated = try self.decodeTimeline(at: legacyFileURL)
            try self.saveUnlocked(migrated)
            return migrated
        }
        return CodexSessionOwnershipTimeline()
    }

    private func decodeTimeline(at fileURL: URL) throws -> CodexSessionOwnershipTimeline {
        try JSONDecoder().decode(
            CodexSessionOwnershipTimeline.self,
            from: Data(contentsOf: fileURL))
    }

    private func saveUnlocked(_ timeline: CodexSessionOwnershipTimeline) throws {
        let directory = self.fileURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(timeline).write(to: self.fileURL, options: .atomic)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.fileURL.path)
    }
}

public struct NoopCodexSessionOwnershipRecorder: CodexSessionOwnershipRecording {
    public init() {}

    @discardableResult
    public func recordActivation(accountKey _: String, at _: Date) throws -> Bool {
        false
    }
}
