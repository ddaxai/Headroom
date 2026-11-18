import Foundation
import Testing
@testable import CodexBar

struct HeadroomIdentityMigrationTests {
    @Test
    func `relay defaults override older upstream defaults during first Headroom launch`() {
        let upstream: [String: Any] = [
            "multiAccountMenuLayout": "segmented",
            "refreshFrequency": "5m",
        ]
        let relay: [String: Any] = [
            "multiAccountMenuLayout": "stacked",
            "relay.codexUnifiedHistoryEnabled": true,
        ]

        let merged = HeadroomDefaultsMigration.mergedLegacyDomain([
            upstream,
            relay,
        ])

        #expect(merged["multiAccountMenuLayout"] as? String == "stacked")
        #expect(merged["refreshFrequency"] as? String == "5m")
        #expect(merged["relay.codexUnifiedHistoryEnabled"] as? Bool == true)
    }

    @Test
    func `existing Headroom values are never overwritten by legacy defaults`() throws {
        let suite = "HeadroomIdentityMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("manual", forKey: "refreshFrequency")

        let copied = HeadroomDefaultsMigration.copyMissingValues(
            ["refreshFrequency": "5m", "multiAccountMenuLayout": "stacked"],
            to: defaults)

        #expect(copied == 1)
        #expect(defaults.string(forKey: "refreshFrequency") == "manual")
        #expect(defaults.string(forKey: "multiAccountMenuLayout") == "stacked")
    }

    @Test
    func `Headroom identity keeps both prior app domains as migration sources`() {
        #expect(HeadroomIdentity.bundleIdentifier == "com.ddaxia.headroom")
        #expect(HeadroomIdentity.legacyDefaultsDomains == [
            "com.steipete.codexbar",
            "com.theodore.codexbar.relay",
        ])
        #expect(HeadroomIdentity.keychainService == "com.ddaxia.headroom")
        #expect(HeadroomIdentity.keychainCacheService == "com.ddaxia.headroom.cache")
    }
}
