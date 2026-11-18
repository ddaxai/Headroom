import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
public enum OpenCodeLocalUsageError: LocalizedError, Sendable, Equatable {
    case historyUnavailable(String)
    case sqliteFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .historyUnavailable(message): "OpenCode local usage history is unavailable: \(message)"
        case let .sqliteFailed(message): "OpenCode local usage database failed: \(message)"
        }
    }
}

public struct OpenCodeLocalUsageSnapshot: Sendable {
    public let report: CostUsageDailyReport
    public let rolling24Hours: CostUsageRolling24HourSummary?
    public let profileBreakdowns: [CostUsageProfileBreakdown]

    public init(
        report: CostUsageDailyReport,
        rolling24Hours: CostUsageRolling24HourSummary?,
        profileBreakdowns: [CostUsageProfileBreakdown] = [])
    {
        self.report = report
        self.rolling24Hours = rolling24Hours
        self.profileBreakdowns = profileBreakdowns
    }

    public func toTokenSnapshot(now: Date, historyDays: Int) -> CostUsageTokenSnapshot {
        CostUsageFetcher.tokenSnapshot(
            from: self.report,
            now: now,
            historyDays: historyDays,
            profileBreakdowns: self.profileBreakdowns,
            rolling24Hours: self.rolling24Hours)
    }
}

public struct OpenCodeLocalUsageReader: Sendable {
    private let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.databaseURL = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
    }

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func fetch(now: Date = Date(), historyDays: Int = 30) throws -> OpenCodeLocalUsageSnapshot {
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            throw OpenCodeLocalUsageError.historyUnavailable("database not found")
        }
        let rows = try self.readRows()
        guard !rows.isEmpty else {
            throw OpenCodeLocalUsageError.historyUnavailable("no local usage rows")
        }
        let days = max(1, min(365, historyDays))
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        let start = calendar.startOfDay(for: since)
        let inWindow = rows.filter { row in
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            return date >= start && date <= now
        }
        let report = Self.makeReport(from: inWindow, calendar: calendar)
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recent = rows.filter {
            let date = Date(timeIntervalSince1970: TimeInterval($0.createdMs) / 1000)
            return date >= cutoff && date <= now
        }
        let recentTokens = recent.reduce(0) { $0 + $1.tokens }
        let recentCosts = recent.compactMap(\.cost)
        let rolling = CostUsageRolling24HourSummary(
            totalTokens: recentTokens,
            costUSD: recentCosts.isEmpty ? nil : recentCosts.reduce(0, +),
            modelProviderBreakdowns: [])
        let profileRows = Dictionary(grouping: inWindow, by: \.providerKey)
        let profileBreakdowns = profileRows.keys.sorted().map { providerKey in
            let profileRows = profileRows[providerKey] ?? []
            let profileRecent = recent.filter { $0.providerKey == providerKey }
            let profileCosts = profileRecent.compactMap(\.cost)
            let profileRolling = CostUsageRolling24HourSummary(
                totalTokens: profileRecent.reduce(0) { $0 + $1.tokens },
                costUSD: profileCosts.isEmpty ? nil : profileCosts.reduce(0, +),
                modelProviderBreakdowns: [])
            let profileReport = Self.makeReport(from: profileRows, calendar: calendar)
            return CostUsageProfileBreakdown(
                providerKey: providerKey,
                daily: profileReport.data,
                summary: profileReport.summary,
                rolling24Hours: profileRolling)
        }
        return OpenCodeLocalUsageSnapshot(
            report: report,
            rolling24Hours: rolling,
            profileBreakdowns: profileBreakdowns)
    }

    private struct Row: Sendable {
        let createdMs: Int64
        let input: Int
        let output: Int
        let tokens: Int
        let cost: Double?
        let model: String
        let providerKey: String
    }

    private struct DailyBucket {
        var input = 0
        var output = 0
        var tokens = 0
        var cost = 0.0
        var costSamples = 0
        var requests = 0
        var models: [String: (tokens: Int, cost: Double?, requests: Int)] = [:]

        mutating func add(_ row: Row) {
            self.input += row.input
            self.output += row.output
            self.tokens += row.tokens
            self.requests += 1
            if let cost = row.cost {
                self.cost += cost
                self.costSamples += 1
            }
            let old = self.models[row.model] ?? (0, nil, 0)
            self.models[row.model] = (
                old.tokens + row.tokens,
                row.cost.map { (old.cost ?? 0) + $0 },
                old.requests + 1)
        }
    }

    private static let unassignedProfileKey = "unassigned"

    private static func makeReport(from rows: [Row], calendar: Calendar) -> CostUsageDailyReport {
        var daily: [String: DailyBucket] = [:]
        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.createdMs) / 1000)
            let key = CostUsageScanner.CostUsageDayRange.dayKey(from: date, calendar: calendar)
            daily[key, default: DailyBucket()].add(row)
        }
        let entries = daily.keys.sorted().compactMap { key -> CostUsageDailyReport.Entry? in
            guard let bucket = daily[key] else { return nil }
            let breakdowns = bucket.models.map { model, value in
                CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: value.cost,
                    totalTokens: value.tokens,
                    requestCount: value.requests)
            }.sorted { $0.modelName < $1.modelName }
            return CostUsageDailyReport.Entry(
                date: key,
                inputTokens: bucket.input > 0 ? bucket.input : nil,
                outputTokens: bucket.output > 0 ? bucket.output : nil,
                totalTokens: bucket.tokens > 0 ? bucket.tokens : nil,
                requestCount: bucket.requests > 0 ? bucket.requests : nil,
                costUSD: bucket.costSamples > 0 ? bucket.cost : nil,
                modelsUsed: bucket.models.isEmpty ? nil : bucket.models.keys.sorted(),
                modelBreakdowns: breakdowns.isEmpty ? nil : breakdowns)
        }
        return CostUsageDailyReport(
            data: entries,
            summary: .init(
                totalInputTokens: entries.compactMap(\.inputTokens).reduce(0, +),
                totalOutputTokens: entries.compactMap(\.outputTokens).reduce(0, +),
                cacheReadTokens: nil,
                cacheCreationTokens: nil,
                totalTokens: entries.compactMap(\.totalTokens).reduce(0, +),
                totalCostUSD: entries.compactMap(\.costUSD).reduce(0, +)))
    }

    private static func profileKey(from rawProviderID: String?) -> String {
        guard let rawProviderID else { return Self.unassignedProfileKey }
        let name = rawProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return Self.unassignedProfileKey }
        let key = RelayProviderKey.slug(for: name)
        // `RelayProviderKey` intentionally uses `relay` as its no-fallback sentinel. A
        // punctuation-only OpenCode value must remain visibly unassigned instead of looking
        // like a real relay named "relay".
        if key == "relay", name.caseInsensitiveCompare("relay") != .orderedSame {
            return Self.unassignedProfileKey
        }
        return key
    }

    private func readRows() throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenCodeLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        // Newer OpenCode schemas keep the selected model on the session row as well as on
        // assistant messages. Some historical rows (and a few imported ledgers) omit the
        // provider from message.data, so use session.model as a read-only attribution fallback.
        // Older fixtures/ledgers may not have either the session table or message.session_id;
        // build the query without the join in that case.
        let hasSessionJoin = self.hasTable(named: "session", db: db) &&
            self.hasColumn(named: "session_id", table: "message", db: db) &&
            self.hasColumn(named: "model", table: "session", db: db)
        let messageData = "m.data"
        let messageModel = Self.modelExpression(for: messageData)
        let messageProvider = Self.providerExpression(for: messageData)
        let sessionModel = hasSessionJoin ? Self.modelExpression(for: "s.model") : "NULL"
        let sessionProvider = hasSessionJoin ? Self.providerExpression(for: "s.model") : "NULL"
        let resolvedModel = "COALESCE(NULLIF(\(messageModel), 'unknown'), \(sessionModel), 'unknown')"
        let resolvedProvider = "COALESCE(\(messageProvider), \(sessionProvider))"
        let partModel = Self.modelExpression(for: "p.data")
        let partProvider = Self.providerExpression(for: "p.data")
        let messageSource = hasSessionJoin
            ? "FROM message m LEFT JOIN session s ON s.id = m.session_id"
            : "FROM message m"
        let sql = self.hasTable(named: "part", db: db)
            ? """
                WITH assistant_messages AS (
                  SELECT m.id,
                    CAST(COALESCE(json_extract(m.data, '$.time.created'), m.time_created) AS INTEGER) AS createdMs,
                    CAST(COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS INTEGER) AS input,
                    CAST(COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS INTEGER) AS output,
                    CAST(json_extract(m.data, '$.cost') AS REAL) AS cost,
                    \(resolvedModel) AS model,
                    \(resolvedProvider) AS provider
                  \(messageSource)
                  WHERE json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant'
                ), step_parts AS (
                  SELECT p.message_id,
                    CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER) AS createdMs,
                    CAST(COALESCE(json_extract(p.data, '$.tokens.input'), 0) AS INTEGER) AS input,
                    CAST(COALESCE(json_extract(p.data, '$.tokens.output'), 0) AS INTEGER) AS output,
                    CAST(json_extract(p.data, '$.cost') AS REAL) AS cost,
                    COALESCE(\(partModel), m.model, 'unknown') AS model,
                    COALESCE(\(partProvider), m.provider) AS provider
                  FROM part p JOIN assistant_messages m ON m.id = p.message_id
                  WHERE json_valid(p.data) AND json_extract(p.data, '$.type') = 'step-finish'
                )
                SELECT createdMs, input, output, cost, model, provider FROM step_parts
                UNION ALL
                SELECT m.createdMs, m.input, m.output, m.cost, m.model, m.provider
                FROM assistant_messages m
                WHERE NOT EXISTS (SELECT 1 FROM step_parts p WHERE p.message_id = m.id)
            """
            : """
                SELECT
                  CAST(COALESCE(json_extract(m.data, '$.time.created'), m.time_created) AS INTEGER),
                  CAST(COALESCE(json_extract(m.data, '$.tokens.input'), 0) AS INTEGER),
                  CAST(COALESCE(json_extract(m.data, '$.tokens.output'), 0) AS INTEGER),
                  CAST(json_extract(m.data, '$.cost') AS REAL),
                  \(resolvedModel),
                  \(resolvedProvider)
                \(messageSource)
                WHERE json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw OpenCodeLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let created = sqlite3_column_int64(stmt, 0)
            guard created > 0 else { continue }
            let input = max(0, Int(sqlite3_column_int64(stmt, 1)))
            let output = max(0, Int(sqlite3_column_int64(stmt, 2)))
            let cost = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
            let model = self.stringValue(stmt, column: 4) ?? "unknown"
            let provider = self.stringValue(stmt, column: 5)
            rows.append(Row(
                createdMs: created,
                input: input,
                output: output,
                tokens: input + output,
                cost: cost,
                model: model,
                providerKey: Self.profileKey(from: provider)))
        }
        return rows
    }

    /// OpenCode's current assistant message shape stores the selected model as
    /// `{ "id": ..., "providerID": ... }`, while older ledgers used a top-level
    /// `modelID`/`providerID` pair. Keep both forms readable so upgrades do not
    /// collapse historical rows into the unassigned bucket.
    private static func modelExpression(for column: String) -> String {
        """
        COALESCE(
            json_extract(\(column), '$.modelID'),
            json_extract(\(column), '$.modelId'),
            json_extract(\(column), '$.model.modelID'),
            json_extract(\(column), '$.model.id'),
            CASE WHEN json_type(\(column), '$.model') IN ('text', 'integer', 'real')
                 THEN json_extract(\(column), '$.model') END,
            'unknown')
        """
    }

    private static func providerExpression(for column: String) -> String {
        """
        NULLIF(COALESCE(
            json_extract(\(column), '$.providerID'),
            json_extract(\(column), '$.providerId'),
            CASE WHEN json_type(\(column), '$.provider') IN ('text', 'integer', 'real')
                 THEN json_extract(\(column), '$.provider') END,
            json_extract(\(column), '$.model.providerID'),
            json_extract(\(column), '$.model.providerId'),
            CASE WHEN json_type(\(column), '$.model.provider') IN ('text', 'integer', 'real')
                 THEN json_extract(\(column), '$.model.provider') END,
            json_extract(\(column), '$.model.provider.id'),
            json_extract(\(column), '$.provider.id')
        ), '')
        """
    }

    private func stringValue(_ stmt: OpaquePointer?, column: Int32) -> String? {
        guard let value = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: value)
    }

    private func hasTable(named name: String, db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func hasColumn(named column: String, table: String, db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let value = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: value) == column { return true }
        }
        return false
    }
}
#endif
