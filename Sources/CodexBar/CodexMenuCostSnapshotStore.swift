import CodexBarCore
import Foundation

struct FileCodexMenuCostSnapshotStore: @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        let records: [Record]
    }

    private struct RelayPayload: Codable {
        let version: Int
        let records: [RelayRecord]
    }

    private struct Record: Codable {
        let identity: CompositeIdentity
        let snapshot: SnapshotRecord
    }

    private struct RelayRecord: Codable {
        let profileID: UUID
        let snapshot: SnapshotRecord
    }

    private struct CompositeIdentity: Codable, Hashable {
        let normalizedEmail: String
        let workspaceAccountID: String

        init?(account: CodexVisibleAccount) {
            guard let normalizedEmail = CodexIdentityResolver.normalizeEmail(account.email),
                  let workspaceAccountID = CodexOpenAIWorkspaceResolver.normalizeWorkspaceAccountID(
                      account.workspaceAccountID)
            else {
                return nil
            }
            self.normalizedEmail = normalizedEmail
            self.workspaceAccountID = workspaceAccountID
        }
    }

    private struct ProviderBreakdownRecord: Codable {
        let modelProvider: String
        let totalTokens: Int
        let costUSD: Double?

        init(_ value: CostUsageModelProviderBreakdown) {
            self.modelProvider = value.modelProvider
            self.totalTokens = value.totalTokens
            self.costUSD = value.costUSD
        }

        var value: CostUsageModelProviderBreakdown {
            CostUsageModelProviderBreakdown(
                modelProvider: self.modelProvider,
                totalTokens: self.totalTokens,
                costUSD: self.costUSD)
        }
    }

    private struct RollingRecord: Codable {
        let totalTokens: Int
        let costUSD: Double?
        let modelProviderBreakdowns: [ProviderBreakdownRecord]

        init(_ value: CostUsageRolling24HourSummary) {
            self.totalTokens = value.totalTokens
            self.costUSD = value.costUSD
            self.modelProviderBreakdowns = value.modelProviderBreakdowns.map(ProviderBreakdownRecord.init)
        }

        var value: CostUsageRolling24HourSummary {
            CostUsageRolling24HourSummary(
                totalTokens: self.totalTokens,
                costUSD: self.costUSD,
                modelProviderBreakdowns: self.modelProviderBreakdowns.map(\.value))
        }
    }

    private struct HourlyRecord: Codable {
        let startDate: Date
        let totalTokens: Int
        let costUSD: Double?
        let modelProviderBreakdowns: [ProviderBreakdownRecord]

        init(_ value: CostUsageHourlyEntry) {
            self.startDate = value.startDate
            self.totalTokens = value.totalTokens
            self.costUSD = value.costUSD
            self.modelProviderBreakdowns = value.modelProviderBreakdowns.map(ProviderBreakdownRecord.init)
        }

        var value: CostUsageHourlyEntry {
            CostUsageHourlyEntry(
                startDate: self.startDate,
                totalTokens: self.totalTokens,
                costUSD: self.costUSD,
                modelProviderBreakdowns: self.modelProviderBreakdowns.map(\.value))
        }
    }

    private struct ModelBreakdownRecord: Codable {
        let modelName: String
        let costUSD: Double?
        let totalTokens: Int?
        let requestCount: Int?
        let standardCostUSD: Double?
        let priorityCostUSD: Double?
        let standardTokens: Int?
        let priorityTokens: Int?
        let splitEstimateNormalized: Bool

        init(_ value: CostUsageDailyReport.ModelBreakdown) {
            self.modelName = value.modelName
            self.costUSD = value.costUSD
            self.totalTokens = value.totalTokens
            self.requestCount = value.requestCount
            self.standardCostUSD = value.standardCostUSD
            self.priorityCostUSD = value.priorityCostUSD
            self.standardTokens = value.standardTokens
            self.priorityTokens = value.priorityTokens
            self.splitEstimateNormalized = value.splitEstimateNormalized
        }

        var value: CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: self.modelName,
                costUSD: self.costUSD,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                standardCostUSD: self.standardCostUSD,
                priorityCostUSD: self.priorityCostUSD,
                standardTokens: self.standardTokens,
                priorityTokens: self.priorityTokens,
                splitEstimateNormalized: self.splitEstimateNormalized)
        }
    }

    private struct DailyRecord: Codable {
        let date: String
        let inputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?
        let requestCount: Int?
        let costUSD: Double?
        let modelsUsed: [String]?
        let modelBreakdowns: [ModelBreakdownRecord]?

        init(_ value: CostUsageDailyReport.Entry) {
            self.date = value.date
            self.inputTokens = value.inputTokens
            self.cacheReadTokens = value.cacheReadTokens
            self.cacheCreationTokens = value.cacheCreationTokens
            self.outputTokens = value.outputTokens
            self.totalTokens = value.totalTokens
            self.requestCount = value.requestCount
            self.costUSD = value.costUSD
            self.modelsUsed = value.modelsUsed
            self.modelBreakdowns = value.modelBreakdowns?.map(ModelBreakdownRecord.init)
        }

        var value: CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: self.date,
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cacheReadTokens: self.cacheReadTokens,
                cacheCreationTokens: self.cacheCreationTokens,
                totalTokens: self.totalTokens,
                requestCount: self.requestCount,
                costUSD: self.costUSD,
                modelsUsed: self.modelsUsed,
                modelBreakdowns: self.modelBreakdowns?.map(\.value))
        }
    }

    private struct SnapshotRecord: Codable {
        let sessionTokens: Int?
        let sessionCostUSD: Double?
        let sessionRequests: Int?
        let last30DaysTokens: Int?
        let last30DaysCostUSD: Double?
        let last30DaysRequests: Int?
        let rolling24Hours: RollingRecord?
        let hourly24Hours: [HourlyRecord]
        let currencyCode: String
        let historyDays: Int
        let historyCoverageIsEstablished: Bool
        let historyLabel: String?
        let meteredCostUSD: Double?
        let codexCorpusRevision: String?
        let codexCorpusCoverageIsComplete: Bool?
        let daily: [DailyRecord]
        let updatedAt: Date

        init(_ value: CostUsageTokenSnapshot) {
            self.sessionTokens = value.sessionTokens
            self.sessionCostUSD = value.sessionCostUSD
            self.sessionRequests = value.sessionRequests
            self.last30DaysTokens = value.last30DaysTokens
            self.last30DaysCostUSD = value.last30DaysCostUSD
            self.last30DaysRequests = value.last30DaysRequests
            self.rolling24Hours = value.rolling24Hours.map(RollingRecord.init)
            self.hourly24Hours = value.hourly24Hours.map(HourlyRecord.init)
            self.currencyCode = value.currencyCode
            self.historyDays = value.historyDays
            self.historyCoverageIsEstablished = value.historyCoverageIsEstablished
            self.historyLabel = value.historyLabel
            self.meteredCostUSD = value.meteredCostUSD
            self.codexCorpusRevision = value.codexCorpusRevision
            self.codexCorpusCoverageIsComplete = value.codexCorpusCoverageIsComplete
            self.daily = value.daily.map(DailyRecord.init)
            self.updatedAt = value.updatedAt
        }

        var value: CostUsageTokenSnapshot {
            CostUsageTokenSnapshot(
                sessionTokens: self.sessionTokens,
                sessionCostUSD: self.sessionCostUSD,
                sessionRequests: self.sessionRequests,
                last30DaysTokens: self.last30DaysTokens,
                last30DaysCostUSD: self.last30DaysCostUSD,
                last30DaysRequests: self.last30DaysRequests,
                rolling24Hours: self.rolling24Hours?.value,
                hourly24Hours: self.hourly24Hours.map(\.value),
                currencyCode: self.currencyCode,
                historyDays: self.historyDays,
                historyCoverageIsEstablished: self.historyCoverageIsEstablished,
                historyLabel: self.historyLabel,
                meteredCostUSD: self.meteredCostUSD,
                codexCorpusRevision: self.codexCorpusRevision,
                codexCorpusCoverageIsComplete: self.codexCorpusCoverageIsComplete,
                daily: self.daily.map(\.value),
                updatedAt: self.updatedAt)
        }
    }

    private static let currentVersion = 1

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = Self.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(for projection: CodexVisibleAccountProjection) -> [String: CostUsageTokenSnapshot] {
        guard self.fileManager.fileExists(atPath: self.fileURL.path),
              let data = try? Data(contentsOf: self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return [:]
        }
        let snapshotsByIdentity = Dictionary(
            payload.records.map { ($0.identity, $0.snapshot.value) },
            uniquingKeysWith: { first, _ in first })
        return Dictionary(
            projection.visibleAccounts.compactMap { account -> (String, CostUsageTokenSnapshot)? in
                guard let identity = CompositeIdentity(account: account),
                      let snapshot = snapshotsByIdentity[identity]
                else {
                    return nil
                }
                return (account.id, snapshot)
            },
            uniquingKeysWith: { first, _ in first })
    }

    func store(
        _ snapshotsByAccountID: [String: CostUsageTokenSnapshot],
        for projection: CodexVisibleAccountProjection)
    {
        let records = projection.visibleAccounts.compactMap { account -> Record? in
            guard let identity = CompositeIdentity(account: account),
                  let snapshot = snapshotsByAccountID[account.id]
            else {
                return nil
            }
            return Record(identity: identity, snapshot: SnapshotRecord(snapshot))
        }
        self.write(Payload(version: Self.currentVersion, records: records))
    }

    func loadRelay(profileIDs: Set<UUID>) -> [UUID: CostUsageTokenSnapshot] {
        let url = self.relayFileURL
        guard self.fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(RelayPayload.self, from: data),
              payload.version == Self.currentVersion
        else {
            return [:]
        }
        return Dictionary(
            payload.records
                .filter { profileIDs.contains($0.profileID) }
                .map { ($0.profileID, $0.snapshot.value) },
            uniquingKeysWith: { first, _ in first })
    }

    func storeRelay(_ snapshotsByProfileID: [UUID: CostUsageTokenSnapshot]) {
        let records = snapshotsByProfileID.map { profileID, snapshot in
            RelayRecord(profileID: profileID, snapshot: SnapshotRecord(snapshot))
        }
        self.writeRelay(RelayPayload(version: Self.currentVersion, records: records))
    }

    private func write(_ payload: Payload) {
        let directory = self.fileURL.deletingLastPathComponent()
        do {
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: self.fileURL, options: [.atomic])
            #if os(macOS)
            try self.fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.fileURL.path)
            #endif
        } catch {
            // Last-good hydration is best-effort and must never block a refresh.
        }
    }

    private func writeRelay(_ payload: RelayPayload) {
        let directory = self.relayFileURL.deletingLastPathComponent()
        do {
            if !self.fileManager.fileExists(atPath: directory.path) {
                try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(payload).write(to: self.relayFileURL, options: [.atomic])
            #if os(macOS)
            try self.fileManager.setAttributes([
                .posixPermissions: NSNumber(value: Int16(0o600)),
            ], ofItemAtPath: self.relayFileURL.path)
            #endif
        } catch {
            // Relay last-good hydration is best-effort and must never block a refresh.
        }
    }

    private var relayFileURL: URL {
        self.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("menu-relay-last-good.json", isDirectory: false)
    }

    private static func defaultURL() -> URL {
        UsageDomain.costUsageCacheDirectory()
            .appendingPathComponent("menu-official-last-good.json", isDirectory: false)
    }
}
