import CodexBarCore
import Foundation
import Security

/// Copies legacy provider credentials into the Headroom-owned service without deleting the
/// original items. Reads deliberately fail instead of presenting UI, so a first launch cannot
/// turn one migration into a cascade of permission prompts.
enum KeychainMigration {
    // TODO(M6): Follow docs/KEYCHAIN_FIX.md before changing the bundle ID or signing identity.
    // Existing ACL trust must be migrated while the old app identity can still authorize reads.
    private static let log = CodexBarLog.logger(LogCategories.keychainMigration)
    private static let migrationKey = "KeychainMigrationV2Completed"
    private static let legacyService = "com.steipete.CodexBar"
    private static let legacyCacheService = "com.steipete.codexbar.cache"

    struct MigrationItem: Hashable {
        let sourceService: String
        let targetService: String
        let account: String?

        init(
            service: String,
            targetService: String = HeadroomIdentity.keychainService,
            account: String?)
        {
            self.sourceService = service
            self.targetService = targetService
            self.account = account
        }

        var service: String {
            self.sourceService
        }

        var label: String {
            let accountLabel = self.account ?? "<any>"
            return "\(self.sourceService):\(accountLabel)"
        }
    }

    static let itemsToMigrate: [MigrationItem] = [
        MigrationItem(service: Self.legacyService, account: "codex-cookie"),
        MigrationItem(service: Self.legacyService, account: "claude-cookie"),
        MigrationItem(service: Self.legacyService, account: "cursor-cookie"),
        MigrationItem(service: Self.legacyService, account: "factory-cookie"),
        MigrationItem(service: Self.legacyService, account: "minimax-cookie"),
        MigrationItem(service: Self.legacyService, account: "minimax-api-token"),
        MigrationItem(service: Self.legacyService, account: "augment-cookie"),
        MigrationItem(service: Self.legacyService, account: "copilot-api-token"),
        MigrationItem(service: Self.legacyService, account: "zai-api-token"),
        MigrationItem(service: Self.legacyService, account: "synthetic-api-key"),
    ]

    /// Run migration once per installation
    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else {
            self.log.info("Keychain access disabled; skipping migration")
            return
        }

        if !CodexBarPreferences.processDefaults.bool(forKey: self.migrationKey) {
            self.log.info("Starting keychain migration to reduce permission prompts")

            var migratedCount = 0
            var errorCount = 0

            for item in self.itemsToMigrate {
                do {
                    if try self.migrateItem(item) {
                        migratedCount += 1
                    }
                } catch {
                    errorCount += 1
                    self.log.error("Failed to migrate \(item.label): \(String(describing: error))")
                }
            }

            do {
                migratedCount += try self.migrateAllItems(
                    fromService: Self.legacyCacheService,
                    toService: HeadroomIdentity.keychainCacheService)
            } catch {
                errorCount += 1
                self.log.error("Failed to migrate legacy cache service: \(String(describing: error))")
            }

            self.log.info("Keychain migration complete: \(migratedCount) migrated, \(errorCount) errors")
            CodexBarPreferences.processDefaults.set(true, forKey: self.migrationKey)

            if migratedCount > 0 {
                self.log.info("✅ Future rebuilds will not prompt for keychain access")
            }
        } else {
            self.log.debug("Keychain migration already completed, skipping")
        }
    }

    /// Copy a single legacy keychain item to the Headroom service.
    /// Returns true if item was migrated, false if item didn't exist
    private static func migrateItem(_ item: MigrationItem) throws -> Bool {
        // First, try to read the existing item
        var result: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        if let account = item.account {
            query[kSecAttrAccount as String] = account
        }
        KeychainNoUIQuery.apply(to: &query)

        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // Item doesn't exist, nothing to migrate
            return false
        }

        guard status == errSecSuccess else {
            throw KeychainMigrationError.readFailed(status)
        }

        guard let rawItem = result as? [String: Any],
              let data = rawItem[kSecValueData as String] as? Data
        else {
            throw KeychainMigrationError.invalidItemFormat
        }

        // Do not overwrite an existing Headroom item. This also makes a repeated migration safe.
        var targetLookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.targetService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: false,
        ]
        if let account = item.account {
            targetLookup[kSecAttrAccount as String] = account
        }
        KeychainNoUIQuery.apply(to: &targetLookup)
        var targetResult: CFTypeRef?
        let targetStatus = KeychainSecurity.copyMatching(targetLookup as CFDictionary, &targetResult)
        if targetStatus == errSecSuccess {
            return false
        }
        guard targetStatus == errSecItemNotFound else {
            throw KeychainMigrationError.readFailed(targetStatus)
        }

        return try self.copyItemData(
            data,
            account: item.account,
            sourceLabel: item.label,
            targetService: item.targetService)
    }

    /// Migrate all entries in the previous cache service. Cache accounts are provider-scoped and
    /// are not a fixed list, so querying the service once avoids a later browser-cookie reimport.
    private static func migrateAllItems(fromService: String, toService: String) throws -> Int {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fromService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &query)

        var result: CFTypeRef?
        let status = KeychainSecurity.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else {
            throw KeychainMigrationError.readFailed(status)
        }
        guard let rawItems = result as? [[String: Any]] else {
            throw KeychainMigrationError.invalidItemFormat
        }

        var migratedCount = 0
        for rawItem in rawItems {
            guard let account = rawItem[kSecAttrAccount as String] as? String,
                  let data = rawItem[kSecValueData as String] as? Data
            else { continue }
            if try self.copyItemData(
                data,
                account: account,
                sourceLabel: "\(fromService):\(account)",
                targetService: toService)
            {
                migratedCount += 1
            }
        }
        return migratedCount
    }

    private static func copyItemData(
        _ data: Data,
        account: String?,
        sourceLabel: String,
        targetService: String) throws -> Bool
    {
        // Add a copy with stable accessibility. The legacy item remains available for rollback.
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: targetService,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let account {
            addQuery[kSecAttrAccount as String] = account
        }

        let addStatus = KeychainSecurity.add(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return false
        }
        guard addStatus == errSecSuccess else {
            throw KeychainMigrationError.addFailed(addStatus)
        }

        self.log.info("Migrated \(sourceLabel) to Headroom keychain service")
        return true
    }

    /// Reset migration flag (for testing)
    static func resetMigrationFlag() {
        CodexBarPreferences.processDefaults.removeObject(forKey: self.migrationKey)
        CodexBarPreferences.processDefaults.removeObject(forKey: "KeychainMigrationV1Completed")
    }
}

enum KeychainMigrationError: Error {
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case addFailed(OSStatus)
    case invalidItemFormat
}
