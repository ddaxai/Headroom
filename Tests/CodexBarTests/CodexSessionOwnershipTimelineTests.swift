import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodexSessionOwnershipTimelineTests {
    @Test
    func `history before first observation stays unassigned and later events follow account switches`() {
        var timeline = CodexSessionOwnershipTimeline()

        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 999) == nil)
        let recordedFirst = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 1000)
        #expect(recordedFirst)
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 999) == nil)
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 1000) == "codex:managed:first")
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 1999) == "codex:managed:first")

        let recordedSecond = timeline.recordActivation(
            accountKey: "codex:managed:second",
            atUnixMilliseconds: 2000)
        #expect(recordedSecond)
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 2000) == "codex:managed:second")
    }

    @Test
    func `reobserving the active account does not change attribution revision`() {
        var timeline = CodexSessionOwnershipTimeline()
        let recorded = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 1000)
        #expect(recorded)
        let revision = timeline.revision

        let rerecorded = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 2000)
        #expect(!rerecorded)
        #expect(timeline.revision == revision)
        #expect(timeline.events.count == 1)
    }

    @Test
    func `file store round trips activation history without credentials`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(
            fileURL: root.appendingPathComponent("timeline.json"))

        #expect(try store.recordActivation(
            accountKey: "codex:managed:first",
            at: Date(timeIntervalSince1970: 10)))
        #expect(try store.recordActivation(
            accountKey: "codex:managed:second",
            at: Date(timeIntervalSince1970: 20)))

        let loaded = try store.load()
        #expect(loaded.ownerAccountKey(atUnixMilliseconds: 9999) == nil)
        #expect(loaded.ownerAccountKey(atUnixMilliseconds: 10000) == "codex:managed:first")
        #expect(loaded.ownerAccountKey(atUnixMilliseconds: 20000) == "codex:managed:second")
    }

    @Test
    func `default store lives in Headroom ownership application support`() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-path-\(UUID().uuidString)", isDirectory: true)
        let store = FileCodexSessionOwnershipTimelineStore(applicationSupportDirectory: root)

        #expect(store.fileURL == root
            .appendingPathComponent("Headroom", isDirectory: true)
            .appendingPathComponent("ownership", isDirectory: true)
            .appendingPathComponent("timeline.json", isDirectory: false))
        #expect(store.legacyFileURL == root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("codex-session-ownership.json", isDirectory: false))
    }

    @Test
    func `first load migrates legacy file without deleting or rewriting it`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyURL = root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("codex-session-ownership.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let legacyBytes = Data(#"{"events":[{"accountKey":"codex:managed:first","timestampUnixMs":1000}]}"#.utf8)
        try legacyBytes.write(to: legacyURL)
        let store = FileCodexSessionOwnershipTimelineStore(applicationSupportDirectory: root)

        let loaded = try store.load()

        #expect(loaded.schemaVersion == CodexSessionOwnershipTimeline.currentSchemaVersion)
        #expect(loaded.events.first?.confidence == .observed)
        #expect(loaded.ownerAccountKey(atUnixMilliseconds: 1000) == "codex:managed:first")
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
        let migratedObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(migratedObject["schemaVersion"] as? Int == CodexSessionOwnershipTimeline.currentSchemaVersion)
    }

    @Test
    func `future provenance schema is rejected without rewriting its bytes`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("timeline.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let futureBytes = Data(
            #"{"events":[],"futureField":"preserve-me","manualAttributions":[],"schemaVersion":999}"#.utf8)
        try futureBytes.write(to: fileURL)
        let store = FileCodexSessionOwnershipTimelineStore(fileURL: fileURL)

        #expect(throws: DecodingError.self) {
            _ = try store.load()
        }
        #expect(try Data(contentsOf: fileURL) == futureBytes)
    }

    @Test
    func `assumed starting boundary is seeded once even beside one observed boundary`() {
        var empty = CodexSessionOwnershipTimeline()
        let seededEmpty = empty.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 1000)
        #expect(seededEmpty)
        #expect(empty.events.count == 1)
        #expect(empty.events.first?.confidence == .assumed)
        let reseededEmpty = empty.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 2000)
        #expect(!reseededEmpty)

        var migrated = CodexSessionOwnershipTimeline(events: [
            .init(
                timestampUnixMs: 500,
                accountKey: "codex:managed:first",
                confidence: .observed),
        ])
        let seededMigrated = migrated.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 1000)
        #expect(seededMigrated)
        #expect(migrated.events.map(\.confidence) == [.observed, .assumed])
        let reseededMigrated = migrated.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 2000)
        #expect(!reseededMigrated)
    }

    @Test
    func `upgraded timeline seeds current assumed owner after multiple observed boundaries`() {
        var timeline = CodexSessionOwnershipTimeline(events: [
            .init(
                timestampUnixMs: 500,
                accountKey: "codex:managed:first",
                confidence: .observed),
            .init(
                timestampUnixMs: 750,
                accountKey: "codex:managed:second",
                confidence: .observed),
        ])

        let seeded = timeline.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:current",
            atUnixMilliseconds: 1000)

        #expect(seeded)
        #expect(timeline.events.map(\.accountKey) == [
            "codex:managed:first",
            "codex:managed:second",
            "codex:managed:current",
        ])
        #expect(timeline.events.last?.confidence == .assumed)
    }

    @Test
    func `observing an assumed owner records the confidence upgrade`() {
        var timeline = CodexSessionOwnershipTimeline()
        let seeded = timeline.seedAssumedStartingBoundaryIfNeeded(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 1000)
        #expect(seeded)

        let observed = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 2000)
        #expect(observed)
        #expect(timeline.events.map(\.confidence) == [.assumed, .observed])
        let reobserved = timeline.recordActivation(
            accountKey: "codex:managed:first",
            atUnixMilliseconds: 3000)
        #expect(!reobserved)
    }

    @Test
    func `manual attribution claims only unassigned rows and supports half open date ranges`() throws {
        var timeline = CodexSessionOwnershipTimeline(events: [
            .init(
                timestampUnixMs: 2000,
                accountKey: "codex:managed:observed",
                confidence: .observed),
        ])
        let wholeBucket = try timeline.recordManualAttribution(
            accountKey: "codex:managed:whole",
            startUnixMilliseconds: nil,
            endUnixMillisecondsExclusive: nil,
            createdAtUnixMilliseconds: 10)
        let dateRange = try timeline.recordManualAttribution(
            accountKey: "codex:managed:range",
            startUnixMilliseconds: 1000,
            endUnixMillisecondsExclusive: 1500,
            createdAtUnixMilliseconds: 20)

        #expect(wholeBucket.source == .manual)
        #expect(dateRange.source == .manual)
        #expect(timeline.attribution(atUnixMilliseconds: 999)?.accountKey == "codex:managed:whole")
        #expect(timeline.attribution(atUnixMilliseconds: 999)?.source == .manual)
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 1000) == "codex:managed:range")
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 1499) == "codex:managed:range")
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 1500) == "codex:managed:whole")
        #expect(timeline.ownerAccountKey(atUnixMilliseconds: 2000) == "codex:managed:observed")
        #expect(timeline.attribution(atUnixMilliseconds: 2000)?.source == .observed)
    }

    @Test
    func `store persists manual attribution and can remove it by id`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-manual-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(
            fileURL: root.appendingPathComponent("timeline.json"))

        let attribution = try store.recordManualAttribution(
            accountKey: "codex:managed:first",
            start: Date(timeIntervalSince1970: 10),
            endExclusive: Date(timeIntervalSince1970: 20),
            createdAt: Date(timeIntervalSince1970: 30))

        #expect(try store.load().ownerAccountKey(atUnixMilliseconds: 10000) == "codex:managed:first")
        #expect(try store.load().ownerAccountKey(atUnixMilliseconds: 20000) == nil)
        #expect(try store.load().manualAttributions.first?.source == .manual)
        #expect(try store.removeManualAttribution(id: attribution.id))
        #expect(try store.load().manualAttributions.isEmpty)
        #expect(try !(store.removeManualAttribution(id: attribution.id)))
    }

    @Test
    func `scanner version changes derived scope without touching provenance bytes`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-session-ownership-scanner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(
            fileURL: root.appendingPathComponent("timeline.json"))
        #expect(try store.recordActivation(
            accountKey: "codex:managed:first",
            at: Date(timeIntervalSince1970: 10)))
        let before = try Data(contentsOf: store.fileURL)
        let scannerOptions = CostUsageScanner.Options()

        let oldScope = CodexLocalProjectUsageIndexer.stableScopeSignature(
            options: scannerOptions,
            scannerVersion: 2)
        let bumpedScope = CodexLocalProjectUsageIndexer.stableScopeSignature(
            options: scannerOptions,
            scannerVersion: 3)

        #expect(oldScope != bumpedScope)
        #expect(try Data(contentsOf: store.fileURL) == before)
    }
}
