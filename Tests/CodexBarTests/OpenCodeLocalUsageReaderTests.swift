#if os(macOS)

import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodeLocalUsageReaderTests {
    private enum SQLiteTestError: Error { case open, exec, prepare }
    @Test
    func `reads OpenCode assistant ledger into 24h 7d and 30d compatible history`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("opencode.db")
        try Self.createDatabase(at: dbURL)
        try Self.insertMessage(databaseURL: dbURL, created: "2026-08-20T12:00:00Z", input: 10, output: 5, cost: 0.15)
        try Self.insertMessage(
            databaseURL: dbURL,
            created: "2026-08-18T12:00:00Z",
            input: 20,
            output: 5,
            cost: 0.25,
            modelProviderID: "梁")
        try Self.insertMessage(databaseURL: dbURL, created: "2026-08-01T12:00:00Z", input: 30, output: 5, cost: 0.35)

        let now = Date(timeIntervalSince1970: Self.ms("2026-08-20T15:00:00Z") / 1000)
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: dbURL).fetch(now: now, historyDays: 30)

        #expect(snapshot.report.data.count == 3)
        #expect(snapshot.report.summary?.totalTokens == 75)
        #expect(snapshot.rolling24Hours?.totalTokens == 15)
        #expect(snapshot.report.data.suffix(2).compactMap(\.totalTokens).reduce(0, +) == 40)
        #expect(snapshot.report.data.compactMap(\.totalTokens).reduce(0, +) == 75)
        #expect(snapshot.profileBreakdowns.map(\.providerKey) == ["liang", "unassigned"])
    }

    @Test
    func `missing OpenCode database reports unavailable history`() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: OpenCodeLocalUsageError.historyUnavailable("database not found")) {
            _ = try OpenCodeLocalUsageReader(databaseURL: url).fetch(now: Date())
        }
    }

    @Test
    func `reads usage from step finish parts when assistant messages omit totals`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("opencode.db")
        try Self.createDatabase(at: dbURL, includesPartTable: true)
        let messageID = try Self.insertMessageWithoutUsage(
            databaseURL: dbURL,
            created: "2026-08-20T12:00:00Z")
        try Self.insertStepFinishPart(
            databaseURL: dbURL,
            messageID: messageID,
            created: "2026-08-20T12:01:00Z",
            input: 12,
            output: 8,
            cost: 0.2)

        let now = Date(timeIntervalSince1970: Self.ms("2026-08-20T15:00:00Z") / 1000)
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: dbURL).fetch(now: now, historyDays: 30)

        #expect(snapshot.report.summary?.totalTokens == 20)
        #expect(snapshot.report.summary?.totalCostUSD == 0.2)
        #expect(snapshot.rolling24Hours?.totalTokens == 20)
    }

    @Test
    func `attributes local usage to stable relay provider keys and preserves unassigned rows`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("opencode.db")
        try Self.createDatabase(at: dbURL, includesPartTable: true)
        try Self.insertMessage(
            databaseURL: dbURL,
            created: "2026-08-20T12:00:00Z",
            input: 10,
            output: 5,
            cost: 0.15,
            providerID: "cpa")
        try Self.insertMessage(
            databaseURL: dbURL,
            created: "2026-08-20T13:00:00Z",
            input: 20,
            output: 5,
            cost: 0.25,
            modelProviderID: "梁")
        try Self.insertMessage(
            databaseURL: dbURL,
            created: "2026-08-20T14:00:00Z",
            input: 20,
            output: 5,
            cost: 0.1,
            providerID: nil)
        try Self.insertStepFinishPart(
            databaseURL: dbURL,
            messageID: Self.insertMessageWithoutUsage(
                databaseURL: dbURL,
                created: "2026-08-20T14:30:00Z",
                modelProviderID: "openrouter"),
            created: "2026-08-20T14:31:00Z",
            input: 12,
            output: 8,
            cost: 0.2,
            providerID: nil)

        let now = Date(timeIntervalSince1970: Self.ms("2026-08-20T15:00:00Z") / 1000)
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: dbURL).fetch(now: now, historyDays: 30)

        #expect(snapshot.profileBreakdowns.map(\.providerKey) == ["cpa", "liang", "openrouter", "unassigned"])
        #expect(snapshot.profileBreakdowns.map { $0.totalTokens ?? 0 }.reduce(0, +) == 85)
        #expect(snapshot.report.summary?.totalTokens == 85)
        #expect(snapshot.profileBreakdowns.first(where: { $0.providerKey == "liang" })?.totalCostUSD == 0.25)
        #expect(snapshot.profileBreakdowns.first(where: { $0.providerKey == "unassigned" })?.totalTokens == 25)
        #expect(snapshot.toTokenSnapshot(now: now, historyDays: 30).profileBreakdowns.map(\.providerKey) == [
            "cpa", "liang", "openrouter", "unassigned",
        ])
    }

    @Test
    func `falls back to the session model provider when message metadata is absent`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalUsageReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("opencode.db")
        try Self.createDatabase(at: dbURL, includesSessionTable: true)
        try Self.insertSession(
            databaseURL: dbURL,
            sessionID: "session-cpa",
            providerID: "cpa",
            modelID: "free-model")
        try Self.insertMessage(
            databaseURL: dbURL,
            sessionID: "session-cpa",
            created: "2026-08-20T12:00:00Z",
            input: 10,
            output: 5,
            cost: 0.15)

        let now = Date(timeIntervalSince1970: Self.ms("2026-08-20T15:00:00Z") / 1000)
        let snapshot = try OpenCodeLocalUsageReader(databaseURL: dbURL).fetch(now: now, historyDays: 30)

        #expect(snapshot.profileBreakdowns.map(\.providerKey) == ["cpa"])
    }

    private static func createDatabase(
        at url: URL,
        includesPartTable: Bool = false,
        includesSessionTable: Bool = false) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT,
              data TEXT NOT NULL,
              time_created INTEGER
            );
        """
        if includesPartTable {
            sql += """
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER
                );
            """
        }
        if includesSessionTable {
            sql += """
                CREATE TABLE session (
                  id TEXT PRIMARY KEY,
                  model TEXT
                );
            """
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteTestError.exec }
    }

    @discardableResult
    private static func insertMessageWithoutUsage(
        databaseURL: URL,
        sessionID: String = "session-1",
        created: String,
        providerID: String? = nil,
        modelProviderID: String? = nil) throws -> String
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        let id = UUID().uuidString
        var object: [String: Any] = [
            "role": "assistant",
            "time": ["created": Int(Self.ms(created))],
            "modelID": "gpt-5.4",
        ]
        if let providerID { object["providerID"] = providerID }
        if let modelProviderID {
            object.removeValue(forKey: "modelID")
            object["model"] = ["id": "gpt-5.4", "providerID": modelProviderID]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message(id, session_id, data) VALUES(?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, sessionID, -1, transient)
        data.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt, 3, bytes.bindMemory(to: CChar.self).baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec }
        return id
    }

    private static func insertStepFinishPart(
        databaseURL: URL,
        messageID: String,
        created: String,
        input: Int,
        output: Int,
        cost: Double,
        providerID: String? = nil,
        modelProviderID: String? = nil) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        var object: [String: Any] = [
            "type": "step-finish",
            "time": ["created": Int(Self.ms(created))],
            "tokens": ["input": input, "output": output],
            "cost": cost,
        ]
        if let providerID { object["providerID"] = providerID }
        if let modelProviderID {
            object["model"] = ["id": "gpt-5.4", "providerID": modelProviderID]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO part(id, message_id, data) VALUES(?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, messageID, -1, transient)
        data.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt, 3, bytes.bindMemory(to: CChar.self).baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec }
    }

    private static func insertMessage(
        databaseURL: URL,
        sessionID: String = "session-1",
        created: String,
        input: Int,
        output: Int,
        cost: Double,
        providerID: String? = nil,
        modelProviderID: String? = nil) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        var object: [String: Any] = [
            "role": "assistant",
            "time": ["created": Int(Self.ms(created))],
            "modelID": "gpt-5.4",
            "tokens": ["input": input, "output": output],
            "cost": cost,
        ]
        if let providerID { object["providerID"] = providerID }
        if let modelProviderID {
            object.removeValue(forKey: "modelID")
            object["model"] = ["id": "gpt-5.4", "providerID": modelProviderID]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message(id, session_id, data) VALUES(?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, sessionID, -1, transient)
        data.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt, 3, bytes.bindMemory(to: CChar.self).baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec }
    }

    private static func insertSession(
        databaseURL: URL,
        sessionID: String,
        providerID: String,
        modelID: String) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": modelID,
            "providerID": providerID,
        ])
        let json = String(data: payload, encoding: .utf8) ?? "{}"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO session(id, model) VALUES(?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionID, -1, transient)
        sqlite3_bind_text(stmt, 2, json, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.exec }
    }

    private static func ms(_ text: String) -> TimeInterval {
        ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 * 1000
    }
}

#endif
