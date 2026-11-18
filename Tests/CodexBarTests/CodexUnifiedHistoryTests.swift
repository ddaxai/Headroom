#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import CodexBarCore
import Foundation
import Testing

struct CodexUnifiedHistoryTests {
    @Test
    func `unified relay config uses the shared provider bucket`() throws {
        let fixture = try UnifiedHistoryFixture()
        defer { fixture.cleanup() }

        _ = try fixture.transaction.apply(
            profile: fixture.profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials,
            codexProviderMode: .unified)

        let text = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(text.contains("model_provider = \"codexbar_shared\""))
        #expect(text.contains("[model_providers.codexbar_shared]"))
        #expect(!text.contains("[model_providers.codexbar_relay]"))
    }

    @Test
    func `official restore stays in the shared provider bucket`() throws {
        let fixture = try UnifiedHistoryFixture()
        defer { fixture.cleanup() }
        try fixture.write("model = \"gpt-5\"\n", to: fixture.paths.codexConfigURL)
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        _ = try fixture.transaction.apply(
            profile: fixture.profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials,
            codexProviderMode: .unified)
        _ = try fixture.transaction.restore(
            backupDirectory: baseline,
            paths: fixture.paths,
            codexProviderMode: .unified)

        let text = try String(contentsOf: fixture.paths.codexConfigURL, encoding: .utf8)
        #expect(text.contains("model_provider = \"codexbar_shared\""))
        #expect(text.contains("[model_providers.codexbar_shared]"))
        #expect(text.contains("requires_openai_auth = true"))
        #expect(!text.contains("base_url ="))
    }

    @Test
    func `official restore deletes Codex config when baseline did not exist`() throws {
        let fixture = try UnifiedHistoryFixture()
        defer { fixture.cleanup() }
        let baseline = try fixture.transaction.captureBaseline(paths: fixture.paths)

        _ = try fixture.transaction.apply(
            profile: fixture.profile,
            paths: fixture.paths,
            credentialStore: fixture.credentials,
            codexProviderMode: .unified)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.codexConfigURL.path))

        _ = try fixture.transaction.restore(
            backupDirectory: baseline,
            paths: fixture.paths,
            codexProviderMode: .unified,
            targets: [.codex])

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.codexConfigURL.path))
    }

    @Test
    func `missing Codex directory has no history to migrate`() throws {
        let fixture = try UnifiedHistoryFixture()
        defer { fixture.cleanup() }
        try? FileManager.default.removeItem(at: fixture.codexDirectory)

        let outcome = try CodexUnifiedHistoryMigrator(
            codexDirectory: fixture.codexDirectory,
            backupRootDirectory: fixture.backupRoot)
            .migrateExistingHistory()

        #expect(outcome.migratedJSONLFiles == 0)
        #expect(outcome.migratedStateRows == 0)
        #expect(outcome.backupDirectory == nil)
    }

    @Test
    func `migration rewrites jsonl and every known state database after backing them up`() throws {
        let fixture = try UnifiedHistoryFixture()
        defer { fixture.cleanup() }
        let sessions = fixture.codexDirectory.appendingPathComponent("sessions/2026/08/01", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sessionURL = sessions.appendingPathComponent("rollout.jsonl")
        let sessionID = "11111111-1111-4111-8111-111111111111"
        try fixture.write(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"(sessionID)\",\"model_provider\":\"openai\"}}\n"
                + "{\"type\":\"response_item\",\"payload\":{\"text\":\"keep\"}}\n",
            to: sessionURL)

        let rootDB = fixture.codexDirectory.appendingPathComponent("state_5.sqlite")
        let legacyDB = fixture.codexDirectory.appendingPathComponent("sqlite/state_5.sqlite")
        try Self.makeStateDatabase(rootDB, threadID: "thread-root", provider: "openai")
        try Self.makeStateDatabase(legacyDB, threadID: "thread-legacy", provider: "codexbar_relay")

        let migrator = CodexUnifiedHistoryMigrator(
            codexDirectory: fixture.codexDirectory,
            backupRootDirectory: fixture.backupRoot)
        let outcome = try migrator.migrateExistingHistory()

        #expect(outcome.migratedJSONLFiles == 1)
        #expect(outcome.migratedStateRows == 2)
        #expect(outcome.backupDirectory != nil)
        #expect(try String(contentsOf: sessionURL, encoding: .utf8).contains("\"model_provider\":\"codexbar_shared\""))
        #expect(try String(contentsOf: sessionURL, encoding: .utf8).contains("\"codexbar_origin_provider\":\"openai\""))
        #expect(try Self.provider(in: rootDB, threadID: "thread-root") == "codexbar_shared")
        #expect(try Self.provider(in: legacyDB, threadID: "thread-legacy") == "codexbar_shared")
        let backupDirectory = try #require(outcome.backupDirectory)
        let manifest = backupDirectory.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func makeStateDatabase(_ url: URL, threadID: String, provider: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw SQLiteFixtureFailure.open }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(
            db,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)",
            nil,
            nil,
            nil)
            == SQLITE_OK
        else { throw SQLiteFixtureFailure.exec }
        let sql = "INSERT INTO threads (id, model_provider) VALUES ('\(threadID)', '\(provider)')"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteFixtureFailure.exec }
    }

    private static func provider(in url: URL, threadID: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw SQLiteFixtureFailure.open
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT model_provider FROM threads WHERE id = ?", -1, &statement, nil)
            == SQLITE_OK,
            let statement
        else { throw SQLiteFixtureFailure.exec }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, threadID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }
    #endif
}

private enum SQLiteFixtureFailure: Error {
    case open
    case exec
}

private struct UnifiedHistoryFixture {
    let root: URL
    let codexDirectory: URL
    let backupRoot: URL
    let paths: RelayConfigurationPaths
    let transaction = RelayConfigurationTransaction()
    let credentials = UnifiedHistoryCredentialStore()
    let profile: RelayProfile

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUnifiedHistoryTests-\(UUID().uuidString)", isDirectory: true)
        self.codexDirectory = self.root.appendingPathComponent(".codex", isDirectory: true)
        self.backupRoot = self.root.appendingPathComponent("history-backups", isDirectory: true)
        let empty = self.root.appendingPathComponent("empty", isDirectory: true)
        self.paths = RelayConfigurationPaths(
            codexConfigURL: self.codexDirectory.appendingPathComponent("config.toml"),
            claudeCodeSettingsURL: empty.appendingPathComponent("claude.json"),
            claudeDesktopNormalConfigURL: empty.appendingPathComponent("desktop-normal.json"),
            claudeDesktopThreePConfigURL: empty.appendingPathComponent("desktop-3p.json"),
            claudeDesktopProfileURL: empty.appendingPathComponent("profile.json"),
            claudeDesktopMetaURL: empty.appendingPathComponent("meta.json"),
            grokBuildConfigURL: empty.appendingPathComponent("grok.toml"),
            openCodeConfigURL: empty.appendingPathComponent("opencode.json"),
            credentialHelperURL: self.root.appendingPathComponent("CodexBarCLI"),
            backupRootURL: self.root.appendingPathComponent("relay-backups", isDirectory: true))
        self.profile = try RelayProfile(
            name: "Test relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "test-reference",
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "gpt-test")])
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private struct UnifiedHistoryCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    func loadCredential(reference _: String) throws -> String? {
        "test-secret"
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}
    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: "test-service", account: reference)
    }
}
