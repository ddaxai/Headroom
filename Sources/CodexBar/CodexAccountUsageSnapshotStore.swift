import CodexBarCore
import Foundation

protocol CodexAccountUsageSnapshotStoring: Sendable {
    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot]
    func store(_ snapshots: [CodexAccountUsageSnapshot])
}

@MainActor
final class CodexQuotaService {
    private let snapshotStore: (any CodexAccountUsageSnapshotStoring)?
    private var snapshotsByIdentity: [CodexAccountIdentity: CodexAccountUsageSnapshot] = [:]

    init(snapshotStore: (any CodexAccountUsageSnapshotStoring)?) {
        self.snapshotStore = snapshotStore
    }

    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        let snapshots = self.snapshotStore?.load(for: accounts) ?? []
        self.replaceCache(with: snapshots)
        return snapshots
    }

    func publish(_ snapshots: [CodexAccountUsageSnapshot]) {
        self.replaceCache(with: snapshots)
        self.snapshotStore?.store(snapshots)
    }

    func cachedQuota(for identity: CodexAccountIdentity) -> UsageSnapshot? {
        self.snapshotsByIdentity[identity]?.snapshot
    }

    func refreshQuota(
        for account: CodexVisibleAccount,
        fetch: () async throws -> UsageSnapshot?) async -> UsageSnapshot?
    {
        guard let identity = CodexAccountIdentity(
            email: account.email,
            workspaceAccountID: account.workspaceAccountID)
        else {
            return nil
        }
        let lastGood = self.snapshotsByIdentity[identity]?.snapshot
        do {
            guard let snapshot = try await fetch() else { return lastGood }
            let record = CodexAccountUsageSnapshot(
                account: account,
                snapshot: snapshot,
                error: nil,
                sourceLabel: nil)
            self.snapshotsByIdentity[identity] = record
            self.snapshotStore?.store(Array(self.snapshotsByIdentity.values))
            return snapshot
        } catch {
            return lastGood
        }
    }

    private func replaceCache(with snapshots: [CodexAccountUsageSnapshot]) {
        var snapshotsByIdentity: [CodexAccountIdentity: CodexAccountUsageSnapshot] = [:]
        for snapshot in snapshots {
            guard let identity = CodexAccountIdentity(
                email: snapshot.account.email,
                workspaceAccountID: snapshot.account.workspaceAccountID)
            else {
                continue
            }
            snapshotsByIdentity[identity] = snapshot
        }
        self.snapshotsByIdentity = snapshotsByIdentity
    }
}

struct FileCodexAccountUsageSnapshotStore: CodexAccountUsageSnapshotStoring, @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Record: Codable {
        let id: String
        let accountIdentity: AccountIdentity?
        let snapshot: UsageSnapshot?
        let error: String?
        let sourceLabel: String?
    }

    private struct AccountIdentity: Codable, Equatable {
        let normalizedEmail: String?
        let workspaceAccountID: String?
        let authFingerprint: String?
        let storedAccountID: UUID?
        let selectionSource: CodexActiveSource?

        init(account: CodexVisibleAccount) {
            self.normalizedEmail = CodexIdentityResolver.normalizeEmail(account.email)
            self.workspaceAccountID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(
                account.workspaceAccountID)
            self.authFingerprint = CodexAuthFingerprint.normalize(account.authFingerprint)
            self.storedAccountID = account.storedAccountID
            self.selectionSource = account.selectionSource
        }

        func matches(_ account: CodexVisibleAccount) -> Bool {
            guard let normalizedEmail = self.normalizedEmail,
                  normalizedEmail == CodexIdentityResolver.normalizeEmail(account.email),
                  let workspaceAccountID = self.workspaceAccountID,
                  workspaceAccountID == CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(
                      account.workspaceAccountID)
            else {
                return false
            }
            return true
        }
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(for accounts: [CodexVisibleAccount]) -> [CodexAccountUsageSnapshot] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return []
        }

        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let accountsByEmail = Dictionary(grouping: accounts, by: {
            CodexIdentityResolver.normalizeEmail($0.email) ?? ""
        })
        var migratedRecords = payload.records
        var didMigrateLegacyRecord = false
        let snapshots: [CodexAccountUsageSnapshot] = payload.records.enumerated().compactMap { index, record in
            guard let account = accountsByID[record.id] else { return nil }
            if let identity = record.accountIdentity {
                guard identity.matches(account) else { return nil }
            } else {
                guard Self.canMigrateLegacyRecord(
                    record,
                    to: account,
                    accountsByEmail: accountsByEmail)
                else { return nil }
                let identity = AccountIdentity(account: account)
                guard identity.normalizedEmail != nil, identity.workspaceAccountID != nil else { return nil }
                migratedRecords[index] = Record(
                    id: record.id,
                    accountIdentity: identity,
                    snapshot: record.snapshot,
                    error: record.error,
                    sourceLabel: record.sourceLabel)
                didMigrateLegacyRecord = true
            }
            return CodexAccountUsageSnapshot(
                account: account,
                snapshot: Self.relabelSnapshot(record.snapshot, for: account),
                error: record.error,
                sourceLabel: record.sourceLabel)
        }
        if didMigrateLegacyRecord {
            self.write(Payload(version: payload.version, records: migratedRecords))
        }
        return snapshots
    }

    func store(_ snapshots: [CodexAccountUsageSnapshot]) {
        let payload = Payload(
            version: Self.currentVersion,
            records: snapshots.compactMap { snapshot in
                let identity = AccountIdentity(account: snapshot.account)
                guard identity.normalizedEmail != nil, identity.workspaceAccountID != nil else { return nil }
                return Record(
                    id: snapshot.id,
                    accountIdentity: identity,
                    snapshot: snapshot.snapshot,
                    error: snapshot.error,
                    sourceLabel: snapshot.sourceLabel)
            })
        self.write(payload)
    }

    private static func canMigrateLegacyRecord(
        _ record: Record,
        to account: CodexVisibleAccount,
        accountsByEmail: [String: [CodexVisibleAccount]]) -> Bool
    {
        guard record.accountIdentity == nil,
              let normalizedRecordID = CodexIdentityResolver.normalizeEmail(record.id),
              normalizedRecordID == CodexIdentityResolver.normalizeEmail(account.email),
              let snapshotEmail = CodexIdentityResolver.normalizeEmail(record.snapshot?.accountEmail(for: .codex)),
              snapshotEmail == normalizedRecordID,
              accountsByEmail[normalizedRecordID]?.count == 1
        else {
            return false
        }
        return true
    }

    private func write(_ payload: Payload) {
        let directory = self.fileURL.deletingLastPathComponent()
        do {
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
            #if os(macOS)
            try self.fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.fileURL.path)
            #endif
        } catch {
            // Snapshot hydration is best-effort; never make menu refresh fail because disk cache failed.
        }
    }

    private static func relabelSnapshot(_ snapshot: UsageSnapshot?, for account: CodexVisibleAccount)
        -> UsageSnapshot?
    {
        guard let snapshot else { return nil }
        let identity = snapshot.identity(for: .codex)
        return snapshot.withIdentity(ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account.email,
            accountOrganization: identity?.accountOrganization,
            loginMethod: identity?.loginMethod ?? account.workspaceLabel))
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("codex-account-snapshots.json", isDirectory: false)
    }
}
