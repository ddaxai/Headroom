import CodexBarCore
import Foundation

enum HeadroomIdentity {
    static let appName = "Headroom"
    static let bundleIdentifier = "com.ddaxia.headroom"
    static let keychainService = "com.ddaxia.headroom"
    static let keychainCacheService = "com.ddaxia.headroom.cache"
    static let legacyDefaultsDomains = [
        "com.steipete.codexbar",
        "com.theodore.codexbar.relay",
    ]
}

enum HeadroomDefaultsMigration {
    private static let completedKey = "headroom.defaultsMigration.v1"

    static func migrateIfNeeded(defaults: UserDefaults = CodexBarPreferences.processDefaults) {
        guard !CodexBarPreferences.isIsolatedProcess else { return }
        guard !defaults.bool(forKey: self.completedKey) else { return }
        let domains = HeadroomIdentity.legacyDefaultsDomains.compactMap {
            defaults.persistentDomain(forName: $0)
        }
        _ = self.copyMissingValues(self.mergedLegacyDomain(domains), to: defaults)
        defaults.set(true, forKey: self.completedKey)
    }

    static func mergedLegacyDomain(_ domains: [[String: Any]]) -> [String: Any] {
        domains.reduce(into: [:]) { result, domain in
            result.merge(domain) { _, newer in newer }
        }
    }

    @discardableResult
    static func copyMissingValues(_ values: [String: Any], to defaults: UserDefaults) -> Int {
        var count = 0
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            count += 1
        }
        return count
    }
}
