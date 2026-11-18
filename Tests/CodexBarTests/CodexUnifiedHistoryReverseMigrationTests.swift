#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CodexUnifiedHistoryReverseMigrationTests {
    @Test
    func `cli report makes dry run and unresolved rows explicit`() {
        let report = CodexUnifiedHistoryReverseMigrationOutcome(
            dryRun: true,
            rewrittenJSONLFiles: 1,
            rewrittenStateRows: 2,
            unresolvedStateRows: 1,
            changedJSONLFiles: [URL(fileURLWithPath: "/fixture/rollout.jsonl")],
            changedStateDatabases: [URL(fileURLWithPath: "/fixture/state_5.sqlite")])

        let text = CodexBarCLI.restoreProviderBucketsText(report)

        #expect(text.contains("would be restored"))
        #expect(text.contains("no unambiguous rollout provenance"))
        #expect(text.contains("Dry run: no source or backup files were changed."))
    }

    @Test
    func `reverse dry run plans provenance and leaves source files untouched`() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.writeRollout(id: "session-openai", origin: "openai")
        try fixture.writeRollout(id: "session-relay", origin: "codexbar_relay")
        try fixture.writeRollout(id: "session-unassigned", origin: nil)
        try fixture.makeStateDatabase(rows: [
            ("session-openai", "codexbar_shared"),
            ("session-relay", "codexbar_shared"),
            ("session-unassigned", "codexbar_shared"),
            ("already-openai", "openai"),
        ])

        let rolloutURL = try #require(fixture.rolloutURLs.first)
        let beforeRollout = try Data(contentsOf: rolloutURL)
        let beforeProvider = try fixture.provider(for: "session-openai")

        let outcome = try fixture.migrator.restoreOriginalProviderBuckets()

        #expect(outcome.dryRun)
        #expect(outcome.rewrittenJSONLFiles == 2)
        #expect(outcome.rewrittenStateRows == 2)
        #expect(outcome.unresolvedStateRows == 1)
        #expect(outcome.changedJSONLFiles.count == 2)
        #expect(outcome.changedStateDatabases == [fixture.databaseURL])
        #expect(outcome.backupDirectory == nil)
        #expect(try Data(contentsOf: rolloutURL) == beforeRollout)
        #expect(try fixture.provider(for: "session-openai") == beforeProvider)
    }

    @Test
    func `reverse dry run does not guess missing origin`() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.writeRollout(id: "session-missing-origin", origin: nil)
        try fixture.makeStateDatabase(rows: [("session-missing-origin", "codexbar_shared")])
        let before = try Data(contentsOf: fixture.rolloutURLs[0])

        let outcome = try fixture.migrator.restoreOriginalProviderBuckets()

        #expect(outcome.rewrittenJSONLFiles == 0)
        #expect(outcome.rewrittenStateRows == 0)
        #expect(outcome.unresolvedStateRows == 1)
        #expect(try Data(contentsOf: fixture.rolloutURLs[0]) == before)
        #expect(try fixture.provider(for: "session-missing-origin") == "codexbar_shared")
    }

    private struct Fixture {
        let root: URL
        let codexDirectory: URL
        let sessionsDirectory: URL
        let backupRoot: URL
        let databaseURL: URL
        let migrator: CodexUnifiedHistoryMigrator
        var rolloutURLs: [URL] = []

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodexUnifiedHistoryReverseMigrationTests-\(UUID().uuidString)",
                    isDirectory: true)
            self.codexDirectory = self.root.appendingPathComponent(".codex", isDirectory: true)
            self.sessionsDirectory = self.codexDirectory
                .appendingPathComponent("sessions/2026/08/30", isDirectory: true)
            self.backupRoot = self.root.appendingPathComponent("backups", isDirectory: true)
            self.databaseURL = self.codexDirectory
                .appendingPathComponent("sqlite/state_5.sqlite", isDirectory: false)
            try FileManager.default.createDirectory(at: self.sessionsDirectory, withIntermediateDirectories: true)
            self.migrator = CodexUnifiedHistoryMigrator(
                codexDirectory: self.codexDirectory,
                backupRootDirectory: self.backupRoot)
        }

        mutating func writeRollout(id: String, origin: String?) throws {
            var payload: [String: Any] = [
                "id": id,
                "model_provider": "codexbar_shared",
            ]
            if let origin { payload["codexbar_origin_provider"] = origin }
            let root: [String: Any] = [
                "type": "session_meta",
                "payload": payload,
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            let url = self.sessionsDirectory.appendingPathComponent("rollout-\(id).jsonl")
            try (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
            self.rolloutURLs.append(url)
        }

        func makeStateDatabase(rows: [(String, String)]) throws {
            try FileManager.default.createDirectory(
                at: self.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            var database: OpaquePointer?
            guard sqlite3_open(self.databaseURL.path, &database) == SQLITE_OK, let database else {
                throw FixtureError.sqlite
            }
            defer { sqlite3_close(database) }
            guard sqlite3_exec(
                database,
                "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)",
                nil,
                nil,
                nil) == SQLITE_OK
            else { throw FixtureError.sqlite }
            for (id, provider) in rows {
                let escapedID = id.replacingOccurrences(of: "'", with: "''")
                let escapedProvider = provider.replacingOccurrences(of: "'", with: "''")
                let sql = "INSERT INTO threads (id, model_provider) VALUES ('\(escapedID)', '\(escapedProvider)')"
                guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                    throw FixtureError.sqlite
                }
            }
        }

        func provider(for id: String) throws -> String? {
            var database: OpaquePointer?
            guard sqlite3_open_v2(self.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database
            else { throw FixtureError.sqlite }
            defer { sqlite3_close(database) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT model_provider FROM threads WHERE id = ?",
                -1,
                &statement,
                nil) == SQLITE_OK,
                let statement
            else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0)
            else { return nil }
            return String(cString: text)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}

private enum FixtureError: Error {
    case sqlite
}
