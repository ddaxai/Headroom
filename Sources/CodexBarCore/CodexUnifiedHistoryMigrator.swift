#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct CodexUnifiedHistoryReverseMigrationOutcome: Equatable, Sendable {
    public let dryRun: Bool
    public let rewrittenJSONLFiles: Int
    public let rewrittenStateRows: Int
    public let unresolvedStateRows: Int
    public let changedJSONLFiles: [URL]
    public let changedStateDatabases: [URL]
    public let backupDirectory: URL?

    public init(
        dryRun: Bool,
        rewrittenJSONLFiles: Int,
        rewrittenStateRows: Int,
        unresolvedStateRows: Int,
        changedJSONLFiles: [URL] = [],
        changedStateDatabases: [URL] = [],
        backupDirectory: URL? = nil)
    {
        self.dryRun = dryRun
        self.rewrittenJSONLFiles = rewrittenJSONLFiles
        self.rewrittenStateRows = rewrittenStateRows
        self.unresolvedStateRows = unresolvedStateRows
        self.changedJSONLFiles = changedJSONLFiles.map(\.standardizedFileURL)
        self.changedStateDatabases = changedStateDatabases.map(\.standardizedFileURL)
        self.backupDirectory = backupDirectory?.standardizedFileURL
    }

    public var migratedJSONLFiles: Int {
        self.rewrittenJSONLFiles
    }

    public var migratedStateRows: Int {
        self.rewrittenStateRows
    }
}

public struct CodexUnifiedHistoryMigrationOutcome: Equatable, Sendable {
    public let migratedJSONLFiles: Int
    public let migratedStateRows: Int
    public let backupDirectory: URL?

    public init(migratedJSONLFiles: Int, migratedStateRows: Int, backupDirectory: URL?) {
        self.migratedJSONLFiles = migratedJSONLFiles
        self.migratedStateRows = migratedStateRows
        self.backupDirectory = backupDirectory
    }
}

public enum CodexUnifiedHistoryMigrationError: LocalizedError, Sendable {
    case fileOperation(String)
    case invalidSessionFile(String)
    case sqliteUnavailable
    case sqlite(String)
    case backupIncomplete(String)

    public var errorDescription: String? {
        switch self {
        case let .fileOperation(message): "统一 Codex 历史的文件操作失败：\(message)"
        case let .invalidSessionFile(path): "Codex 会话文件格式无效：\(path)"
        case .sqliteUnavailable: "当前构建不支持 SQLite，不能安全迁移 Codex 会话索引。"
        case let .sqlite(message): "统一 Codex 历史的数据库操作失败：\(message)"
        case let .backupIncomplete(message): "统一 Codex 历史的备份不完整，已拒绝执行：\(message)"
        }
    }
}

/// Migrates Codex's provider-filtered history indexes into a shared provider bucket.
/// Every changed JSONL and SQLite database is backed up before its first write.
public struct CodexUnifiedHistoryMigrator: Sendable {
    public static let sharedProviderID = "codexbar_shared"
    public static let legacyProviderIDs: Set<String> = ["openai", "codexbar_relay"]

    private let codexDirectory: URL
    private let backupRootDirectory: URL
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        codexDirectory: URL,
        backupRootDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.codexDirectory = codexDirectory.standardizedFileURL
        self.backupRootDirectory = backupRootDirectory.standardizedFileURL
        self.environment = environment
        self.now = { Date() }
        self.makeID = { UUID() }
    }

    init(
        codexDirectory: URL,
        backupRootDirectory: URL,
        environment: [String: String],
        now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable () -> UUID)
    {
        self.codexDirectory = codexDirectory.standardizedFileURL
        self.backupRootDirectory = backupRootDirectory.standardizedFileURL
        self.environment = environment
        self.now = now
        self.makeID = makeID
    }

    public func migrateExistingHistory() throws -> CodexUnifiedHistoryMigrationOutcome {
        let generation = self.backupRootDirectory
            .appendingPathComponent(self.makeID().uuidString.lowercased(), isDirectory: true)
        var manifest = MigrationManifest(createdAt: self.now(), codexDirectory: self.codexDirectory.path)
        var migratedJSONLFiles = 0
        var migratedStateRows = 0
        do {
            for url in self.sessionFiles() {
                if let entry = try self.migrateSessionFile(url, generation: generation) {
                    manifest.sessionFiles.append(entry)
                    migratedJSONLFiles += 1
                }
            }
            for (index, url) in self.stateDatabaseURLs().enumerated()
                where FileManager.default.fileExists(atPath: url.path)
            {
                if let entry = try self.migrateStateDatabase(url, index: index, generation: generation) {
                    manifest.stateDatabases.append(entry)
                    migratedStateRows += entry.threads.count
                }
            }
            guard migratedJSONLFiles > 0 || migratedStateRows > 0 else {
                try? FileManager.default.removeItem(at: generation)
                return CodexUnifiedHistoryMigrationOutcome(
                    migratedJSONLFiles: 0,
                    migratedStateRows: 0,
                    backupDirectory: nil)
            }
            try self.createSecureDirectory(generation)
            let data = try JSONEncoder.unifiedHistory.encode(manifest)
            try self.writeSecurely(data, to: generation.appendingPathComponent("manifest.json"))
            return CodexUnifiedHistoryMigrationOutcome(
                migratedJSONLFiles: migratedJSONLFiles,
                migratedStateRows: migratedStateRows,
                backupDirectory: generation)
        } catch {
            do {
                try self.rollback(manifest: manifest, generation: generation)
                try? FileManager.default.removeItem(at: generation)
            } catch let rollbackError {
                if !manifest.sessionFiles.isEmpty || !manifest.stateDatabases.isEmpty,
                   let data = try? JSONEncoder.unifiedHistory.encode(manifest)
                {
                    try? self.writeSecurely(data, to: generation.appendingPathComponent("manifest.json"))
                }
                throw CodexUnifiedHistoryMigrationError.fileOperation(
                    "迁移失败且自动回滚未完成（\(Self.safeMessage(rollbackError))）；备份保留在 \(generation.path)")
            }
            throw error
        }
    }

    /// Restores provider buckets from the shared Codex history namespace. The default is a
    /// read-only plan; callers must explicitly pass `dryRun: false` before any source file can
    /// change.
    public func restoreOriginalProviderBuckets(
        dryRun: Bool = true) throws -> CodexUnifiedHistoryReverseMigrationOutcome
    {
        let plan = try self.reverseMigrationPlan()
        let changedJSONLFiles = plan.sessionRewrites.map(\.url)
        let changedStateDatabases = plan.stateRewrites
            .map(\.databaseURL)
            .reduce(into: [URL]()) { values, url in
                if !values.contains(url) { values.append(url) }
            }
            .sorted { $0.path < $1.path }
        let planned = CodexUnifiedHistoryReverseMigrationOutcome(
            dryRun: dryRun,
            rewrittenJSONLFiles: plan.sessionRewrites.count,
            rewrittenStateRows: plan.stateRewrites.count,
            unresolvedStateRows: plan.unresolvedStateRows,
            changedJSONLFiles: changedJSONLFiles,
            changedStateDatabases: changedStateDatabases)
        guard !plan.sessionRewrites.isEmpty || !plan.stateRewrites.isEmpty else { return planned }
        guard !dryRun else { return planned }

        let generation = self.backupRootDirectory
            .appendingPathComponent("reverse-\(self.makeID().uuidString.lowercased())", isDirectory: true)
        let manifest: ReverseMigrationManifest
        do {
            manifest = try self.createReverseBackup(plan: plan, generation: generation)
            try self.verifyReverseBackup(manifest: manifest, generation: generation)
        } catch {
            try? FileManager.default.removeItem(at: generation)
            throw error
        }

        do {
            try self.applyReversePlan(plan)
        } catch {
            do {
                try self.rollbackReversePlan(manifest: manifest, generation: generation)
            } catch let rollbackError {
                throw CodexUnifiedHistoryMigrationError.fileOperation(
                    "反向迁移失败且回滚未完成（\(Self.safeMessage(rollbackError))）；备份保留在 \(generation.path)")
            }
            throw error
        }
        return CodexUnifiedHistoryReverseMigrationOutcome(
            dryRun: false,
            rewrittenJSONLFiles: plan.sessionRewrites.count,
            rewrittenStateRows: plan.stateRewrites.count,
            unresolvedStateRows: plan.unresolvedStateRows,
            changedJSONLFiles: changedJSONLFiles,
            changedStateDatabases: changedStateDatabases,
            backupDirectory: generation)
    }

    private func rollback(manifest: MigrationManifest, generation: URL) throws {
        for entry in manifest.sessionFiles.reversed() {
            let backupURL = generation.appendingPathComponent(entry.backupRelativePath)
            let data = try Data(contentsOf: backupURL)
            try self.writeSecurely(data, to: URL(fileURLWithPath: entry.originalPath))
        }
        #if canImport(SQLite3) || canImport(CSQLite3)
        for entry in manifest.stateDatabases.reversed() {
            let backupURL = generation.appendingPathComponent(entry.backupRelativePath)
            try self.restoreSQLiteBackup(
                backupURL: backupURL,
                destinationURL: URL(fileURLWithPath: entry.originalPath))
        }
        #else
        if !manifest.stateDatabases.isEmpty { throw CodexUnifiedHistoryMigrationError.sqliteUnavailable }
        #endif
    }

    private func sessionFiles() -> [URL] {
        let manager = FileManager.default
        var files: [URL] = []
        for directory in ["sessions", "archived_sessions"] {
            let root = self.codexDirectory.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            files.append(contentsOf: enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension.lowercased() == "jsonl" else { return nil }
                return url
            })
        }
        return files.sorted { $0.path < $1.path }
    }

    private func migrateSessionFile(_ url: URL, generation: URL) throws -> MigrationManifest.SessionFile? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw CodexUnifiedHistoryMigrationError.fileOperation(Self.safeMessage(error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexUnifiedHistoryMigrationError.invalidSessionFile(url.path)
        }
        var sourceProvidersBySessionID: [String: String] = [:]
        let hadTrailingNewline = text.hasSuffix("\n")
        var rewritten: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard !line.isEmpty,
                  var root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  root["type"] as? String == "session_meta",
                  var payload = root["payload"] as? [String: Any],
                  let provider = payload["model_provider"] as? String,
                  Self.legacyProviderIDs.contains(provider)
            else {
                rewritten.append(line)
                continue
            }
            if let sessionID = payload["id"] as? String, !sessionID.isEmpty {
                sourceProvidersBySessionID[sessionID] = provider
            }
            // Codex ignores this app-owned field, while CodexBar's local cost scanner uses it to
            // preserve official-vs-relay attribution after both routes share one history bucket.
            payload["codexbar_origin_provider"] = provider
            payload["model_provider"] = Self.sharedProviderID
            root["payload"] = payload
            let replacement = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            guard let replacementLine = String(data: replacement, encoding: .utf8) else {
                throw CodexUnifiedHistoryMigrationError.invalidSessionFile(url.path)
            }
            rewritten.append(replacementLine)
        }
        guard !sourceProvidersBySessionID.isEmpty else { return nil }
        var replacement = rewritten.joined(separator: "\n")
        if hadTrailingNewline, !replacement.hasSuffix("\n") { replacement += "\n" }
        let relative = self.relativePath(url)
        let backupRelative = "jsonl/\(relative)"
        let backupURL = generation.appendingPathComponent(backupRelative)
        try self.createSecureDirectory(backupURL.deletingLastPathComponent())
        try self.writeSecurely(data, to: backupURL)
        try self.writeSecurely(Data(replacement.utf8), to: url)
        return MigrationManifest.SessionFile(
            originalPath: url.path,
            backupRelativePath: backupRelative,
            sourceProvidersBySessionID: sourceProvidersBySessionID)
    }

    private func stateDatabaseURLs() -> [URL] {
        var values = [
            self.codexDirectory.appendingPathComponent("state_5.sqlite"),
            self.codexDirectory.appendingPathComponent("sqlite/state_5.sqlite"),
        ]
        let configURL = self.codexDirectory.appendingPathComponent("config.toml")
        let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if let configured = Self.sqliteHome(from: configText, codexDirectory: self.codexDirectory) {
            values.append(configured.appendingPathComponent("state_5.sqlite"))
        } else if let raw = self.environment["CODEX_SQLITE_HOME"],
                  let environmentURL = Self.resolvedDirectory(raw, codexDirectory: self.codexDirectory)
        {
            values.append(environmentURL.appendingPathComponent("state_5.sqlite"))
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func sqliteHome(from config: String, codexDirectory: URL) -> URL? {
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("sqlite_home"), let equals = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value
                .firstIndex(of: "#") { value = String(value[..<comment]).trimmingCharacters(in: .whitespaces) }
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value.removeFirst()
                value.removeLast()
            }
            return self.resolvedDirectory(value, codexDirectory: codexDirectory)
        }
        return nil
    }

    private static func resolvedDirectory(_ raw: String, codexDirectory: URL) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let home = codexDirectory.deletingLastPathComponent()
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2)), isDirectory: true) }
        guard value.hasPrefix("/") else { return codexDirectory.appendingPathComponent(value, isDirectory: true) }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private func migrateStateDatabase(
        _ url: URL,
        index: Int,
        generation: URL) throws -> MigrationManifest.StateDatabase?
    {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? url.path
            sqlite3_close(database)
            throw CodexUnifiedHistoryMigrationError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        guard try self.tableHasProviderColumn(database) else { return nil }
        let threads = try self.legacyThreads(database)
        guard !threads.isEmpty else { return nil }

        let backupRelative = String(format: "state/%03d-state_5.sqlite", index)
        let backupURL = generation.appendingPathComponent(backupRelative)
        try self.createSecureDirectory(backupURL.deletingLastPathComponent())
        try self.sqliteBackup(source: database, destinationURL: backupURL)

        try self.sqliteExec(database, sql: "BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            let sql = "UPDATE threads SET model_provider = ? WHERE model_provider = ? OR model_provider = ?"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, Self.sharedProviderID, -1, transient)
            sqlite3_bind_text(statement, 2, "openai", -1, transient)
            sqlite3_bind_text(statement, 3, "codexbar_relay", -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            try self.sqliteExec(database, sql: "COMMIT")
        } catch {
            _ = try? self.sqliteExec(database, sql: "ROLLBACK")
            throw error
        }
        return MigrationManifest.StateDatabase(
            originalPath: url.path,
            backupRelativePath: backupRelative,
            threads: threads)
    }

    private func tableHasProviderColumn(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1) { columns.insert(String(cString: value)) }
        }
        return columns.contains("id") && columns.contains("model_provider")
    }

    private func legacyThreads(_ database: OpaquePointer) throws -> [MigrationManifest.Thread] {
        var statement: OpaquePointer?
        let sql = "SELECT id, model_provider FROM threads WHERE model_provider = ? OR model_provider = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "openai", -1, transient)
        sqlite3_bind_text(statement, 2, "codexbar_relay", -1, transient)
        var rows: [MigrationManifest.Thread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let provider = sqlite3_column_text(statement, 1) else {
                continue
            }
            rows.append(.init(id: String(cString: id), sourceProvider: String(cString: provider)))
        }
        return rows
    }

    private func sqliteBackup(source: OpaquePointer, destinationURL: URL) throws {
        var destination: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK, let destination else {
            sqlite3_close(destination)
            throw CodexUnifiedHistoryMigrationError
                .sqlite("cannot create backup for \(destinationURL.lastPathComponent)")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard [SQLITE_DONE, SQLITE_OK].contains(step), finish == SQLITE_OK else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    private func restoreSQLiteBackup(backupURL: URL, destinationURL: URL) throws {
        var source: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            sqlite3_close(source)
            throw CodexUnifiedHistoryMigrationError.sqlite("cannot open rollback database")
        }
        defer { sqlite3_close(source) }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let destination
        else {
            sqlite3_close(destination)
            throw CodexUnifiedHistoryMigrationError.sqlite("cannot open destination database for rollback")
        }
        defer { sqlite3_close(destination) }
        sqlite3_busy_timeout(destination, 1500)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard [SQLITE_DONE, SQLITE_OK].contains(step), finish == SQLITE_OK else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private func sqliteExec(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw CodexUnifiedHistoryMigrationError.sqlite(description)
        }
    }
    #else
    private func migrateStateDatabase(
        _: URL,
        index _: Int,
        generation _: URL) throws -> MigrationManifest.StateDatabase?
    {
        throw CodexUnifiedHistoryMigrationError.sqliteUnavailable
    }
    #endif

    private func relativePath(_ url: URL) -> String {
        let prefix = self.codexDirectory.path.hasSuffix("/") ? self.codexDirectory.path : self.codexDirectory.path + "/"
        if url.path.hasPrefix(prefix) { return String(url.path.dropFirst(prefix.count)) }
        return url.lastPathComponent
    }

    private func createSecureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw CodexUnifiedHistoryMigrationError.fileOperation(Self.safeMessage(error))
        }
    }

    private func writeSecurely(_ data: Data, to url: URL) throws {
        do {
            try self.createSecureDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as CodexUnifiedHistoryMigrationError {
            throw error
        } catch {
            throw CodexUnifiedHistoryMigrationError.fileOperation(Self.safeMessage(error))
        }
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: type(of: error))
    }
}

private struct MigrationManifest: Codable, Sendable {
    struct SessionFile: Codable, Sendable {
        let originalPath: String
        let backupRelativePath: String
        let sourceProvidersBySessionID: [String: String]
    }

    struct Thread: Codable, Sendable {
        let id: String
        let sourceProvider: String
    }

    struct StateDatabase: Codable, Sendable {
        let originalPath: String
        let backupRelativePath: String
        let threads: [Thread]
    }

    let createdAt: Date
    let codexDirectory: String
    var sessionFiles: [SessionFile] = []
    var stateDatabases: [StateDatabase] = []
}

extension JSONEncoder {
    fileprivate static var unifiedHistory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private enum ReverseProviderMapping: Sendable {
    case unique(String)
    case ambiguous
}

private struct ReverseSessionRewrite: Sendable {
    let url: URL
    let originalData: Data
    let replacementData: Data
}

private struct ReverseStateRewrite: Sendable {
    let databaseURL: URL
    let threadID: String
    let provider: String
}

private struct ReverseMigrationPlan: Sendable {
    let sessionRewrites: [ReverseSessionRewrite]
    let stateRewrites: [ReverseStateRewrite]
    let unresolvedStateRows: Int
}

private struct ReverseBackupEntry: Codable, Sendable {
    let kind: String
    let originalPath: String
    let backupRelativePath: String
    let byteCount: Int
    let sha256: String
}

private struct ReverseMigrationManifest: Codable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let codexDirectory: String
    let complete: Bool
    let entries: [ReverseBackupEntry]
}

extension CodexUnifiedHistoryMigrator {
    private func reverseMigrationPlan() throws -> ReverseMigrationPlan {
        var mappings: [String: ReverseProviderMapping] = [:]
        var sessionRewrites: [ReverseSessionRewrite] = []
        for url in self.sessionFiles() {
            if let rewrite = try self.reverseSessionFile(url, mappings: &mappings) {
                sessionRewrites.append(rewrite)
            }
        }

        var stateRewrites: [ReverseStateRewrite] = []
        var unresolvedStateRows = 0
        for url in self.stateDatabaseURLs()
            .filter({ FileManager.default.fileExists(atPath: $0.path) })
        {
            let result = try self.reverseStateRows(in: url, mappings: mappings)
            stateRewrites.append(contentsOf: result.rows)
            unresolvedStateRows += result.unresolved
        }
        return ReverseMigrationPlan(
            sessionRewrites: sessionRewrites,
            stateRewrites: stateRewrites,
            unresolvedStateRows: unresolvedStateRows)
    }

    private func reverseSessionFile(
        _ url: URL,
        mappings: inout [String: ReverseProviderMapping]) throws -> ReverseSessionRewrite?
    {
        let originalData: Data
        do {
            originalData = try Data(contentsOf: url)
        } catch {
            throw CodexUnifiedHistoryMigrationError.fileOperation(Self.safeMessage(error))
        }
        guard let text = String(data: originalData, encoding: .utf8) else {
            throw CodexUnifiedHistoryMigrationError.invalidSessionFile(url.path)
        }

        var changed = false
        var rewrittenLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  var root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  root["type"] as? String == "session_meta",
                  var payload = root["payload"] as? [String: Any],
                  payload["model_provider"] as? String == Self.sharedProviderID
            else {
                rewrittenLines.append(line)
                continue
            }

            let rawOrigin = (payload["codexbar_origin_provider"] as? String)
                ?? (root["codexbar_origin_provider"] as? String)
            guard let origin = Self.validReverseProvider(rawOrigin) else {
                rewrittenLines.append(line)
                continue
            }
            if let sessionID = Self.reverseSessionID(from: payload) {
                Self.recordReverseMapping(origin, for: sessionID, in: &mappings)
            }
            payload["model_provider"] = origin
            root["payload"] = payload
            let replacement = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            guard let replacementLine = String(data: replacement, encoding: .utf8) else {
                throw CodexUnifiedHistoryMigrationError.invalidSessionFile(url.path)
            }
            rewrittenLines.append(replacementLine)
            changed = true
        }

        guard changed else { return nil }
        let replacementData = Data(rewrittenLines.joined(separator: "\n").utf8)
        guard replacementData != originalData else { return nil }
        return ReverseSessionRewrite(url: url, originalData: originalData, replacementData: replacementData)
    }

    fileprivate static func validReverseProvider(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != Self.sharedProviderID else { return nil }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }

    fileprivate static func reverseSessionID(from payload: [String: Any]) -> String? {
        for key in ["id", "session_id", "conversation_id"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    fileprivate static func recordReverseMapping(
        _ provider: String,
        for sessionID: String,
        in mappings: inout [String: ReverseProviderMapping])
    {
        guard let existing = mappings[sessionID] else {
            mappings[sessionID] = .unique(provider)
            return
        }
        switch existing {
        case .ambiguous:
            return
        case let .unique(previous) where previous == provider:
            return
        case .unique:
            mappings[sessionID] = .ambiguous
        }
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    fileprivate func reverseStateRows(
        in url: URL,
        mappings: [String: ReverseProviderMapping]) throws -> (rows: [ReverseStateRewrite], unresolved: Int)
    {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? url.path
            sqlite3_close(database)
            throw CodexUnifiedHistoryMigrationError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        guard try self.tableHasProviderColumn(database) else { return ([], 0) }

        var statement: OpaquePointer?
        let sql = "SELECT id FROM threads WHERE model_provider = ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, Self.sharedProviderID, -1, transient)
        var rows: [ReverseStateRewrite] = []
        var unresolved = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else {
                unresolved += 1
                continue
            }
            let threadID = String(cString: text)
            guard let mapping = mappings[threadID] else {
                unresolved += 1
                continue
            }
            guard case let .unique(provider) = mapping else {
                unresolved += 1
                continue
            }
            rows.append(ReverseStateRewrite(databaseURL: url, threadID: threadID, provider: provider))
        }
        return (rows, unresolved)
    }
    #else
    fileprivate func reverseStateRows(
        in _: URL,
        mappings _: [String: ReverseProviderMapping]) throws -> (rows: [ReverseStateRewrite], unresolved: Int)
    {
        throw CodexUnifiedHistoryMigrationError.sqliteUnavailable
    }
    #endif

    private func createReverseBackup(
        plan: ReverseMigrationPlan,
        generation: URL) throws -> ReverseMigrationManifest
    {
        try self.createSecureDirectory(generation)
        var entries: [ReverseBackupEntry] = []
        for rewrite in plan.sessionRewrites {
            let relative = "jsonl/\(self.relativePath(rewrite.url))"
            let backupURL = generation.appendingPathComponent(relative)
            try self.writeSecurely(rewrite.originalData, to: backupURL)
            entries.append(self.reverseBackupEntry(
                kind: "jsonl",
                originalURL: rewrite.url,
                backupURL: backupURL,
                relativePath: relative))
        }

        #if canImport(SQLite3) || canImport(CSQLite3)
        let stateURLs = plan.stateRewrites
            .map(\.databaseURL)
            .reduce(into: [URL]()) { values, url in
                if !values.contains(url) { values.append(url) }
            }
            .sorted { $0.path < $1.path }
        for (index, url) in stateURLs.enumerated() {
            let relative = String(format: "state/%03d-state_5.sqlite", index)
            let backupURL = generation.appendingPathComponent(relative)
            try self.createReverseSQLiteBackup(sourceURL: url, destinationURL: backupURL)
            entries.append(self.reverseBackupEntry(
                kind: "sqlite",
                originalURL: url,
                backupURL: backupURL,
                relativePath: relative))
        }
        #else
        if !plan.stateRewrites.isEmpty { throw CodexUnifiedHistoryMigrationError.sqliteUnavailable }
        #endif

        let sortedEntries = entries.sorted { $0.backupRelativePath < $1.backupRelativePath }
        let sums = sortedEntries
            .map { "\($0.sha256)  \($0.backupRelativePath)" }
            .joined(separator: "\n") + (sortedEntries.isEmpty ? "" : "\n")
        try self.writeSecurely(
            Data(sums.utf8),
            to: generation.appendingPathComponent("sha256sums.txt"))
        let manifest = ReverseMigrationManifest(
            schemaVersion: 1,
            createdAt: self.now(),
            codexDirectory: self.codexDirectory.path,
            complete: true,
            entries: sortedEntries)
        let data = try JSONEncoder.unifiedHistory.encode(manifest)
        try self.writeSecurely(data, to: generation.appendingPathComponent("manifest.json"))
        return manifest
    }

    private func reverseBackupEntry(
        kind: String,
        originalURL: URL,
        backupURL: URL,
        relativePath: String) -> ReverseBackupEntry
    {
        let data = (try? Data(contentsOf: backupURL)) ?? Data()
        return ReverseBackupEntry(
            kind: kind,
            originalPath: originalURL.path,
            backupRelativePath: relativePath,
            byteCount: data.count,
            sha256: Self.reverseSHA256Hex(data))
    }

    private func verifyReverseBackup(
        manifest: ReverseMigrationManifest,
        generation: URL) throws
    {
        guard manifest.complete else {
            throw CodexUnifiedHistoryMigrationError.backupIncomplete("manifest is not complete")
        }
        let sumsURL = generation.appendingPathComponent("sha256sums.txt")
        guard let sums = try? String(contentsOf: sumsURL, encoding: .utf8) else {
            throw CodexUnifiedHistoryMigrationError.backupIncomplete("sha256sums.txt is missing")
        }
        let expectedSums = manifest.entries
            .sorted { $0.backupRelativePath < $1.backupRelativePath }
            .map { "\($0.sha256)  \($0.backupRelativePath)" }
            .joined(separator: "\n") + (manifest.entries.isEmpty ? "" : "\n")
        guard sums == expectedSums else {
            throw CodexUnifiedHistoryMigrationError.backupIncomplete("checksum manifest does not match entries")
        }
        for entry in manifest.entries {
            let backupURL = generation.appendingPathComponent(entry.backupRelativePath)
            guard let data = try? Data(contentsOf: backupURL) else {
                throw CodexUnifiedHistoryMigrationError.backupIncomplete(entry.backupRelativePath)
            }
            guard data.count == entry.byteCount, Self.reverseSHA256Hex(data) == entry.sha256 else {
                throw CodexUnifiedHistoryMigrationError.backupIncomplete(entry.backupRelativePath)
            }
        }
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    fileprivate func createReverseSQLiteBackup(sourceURL: URL, destinationURL: URL) throws {
        var source: OpaquePointer?
        guard sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? sourceURL.path
            sqlite3_close(source)
            throw CodexUnifiedHistoryMigrationError.sqlite(message)
        }
        defer { sqlite3_close(source) }
        try self.sqliteBackup(source: source, destinationURL: destinationURL)
    }
    #endif

    private func applyReversePlan(_ plan: ReverseMigrationPlan) throws {
        for rewrite in plan.sessionRewrites {
            try self.writeSecurely(rewrite.replacementData, to: rewrite.url)
        }
        #if canImport(SQLite3) || canImport(CSQLite3)
        let grouped = Dictionary(grouping: plan.stateRewrites, by: \.databaseURL)
        for (url, rows) in grouped.sorted(by: { $0.key.path < $1.key.path }) {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? url.path
                sqlite3_close(database)
                throw CodexUnifiedHistoryMigrationError.sqlite(message)
            }
            defer { sqlite3_close(database) }
            sqlite3_busy_timeout(database, 1500)
            try self.sqliteExec(database, sql: "BEGIN IMMEDIATE")
            do {
                var statement: OpaquePointer?
                let sql = "UPDATE threads SET model_provider = ? WHERE id = ? AND model_provider = ?"
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for row in rows {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, row.provider, -1, transient)
                    sqlite3_bind_text(statement, 2, row.threadID, -1, transient)
                    sqlite3_bind_text(statement, 3, Self.sharedProviderID, -1, transient)
                    guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(database) == 1 else {
                        throw CodexUnifiedHistoryMigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
                    }
                }
                try self.sqliteExec(database, sql: "COMMIT")
            } catch {
                _ = try? self.sqliteExec(database, sql: "ROLLBACK")
                throw error
            }
        }
        #else
        if !plan.stateRewrites.isEmpty { throw CodexUnifiedHistoryMigrationError.sqliteUnavailable }
        #endif
    }

    private func rollbackReversePlan(
        manifest: ReverseMigrationManifest,
        generation: URL) throws
    {
        for entry in manifest.entries where entry.kind == "jsonl" {
            let backupURL = generation.appendingPathComponent(entry.backupRelativePath)
            let data = try Data(contentsOf: backupURL)
            try self.writeSecurely(data, to: URL(fileURLWithPath: entry.originalPath))
        }
        #if canImport(SQLite3) || canImport(CSQLite3)
        for entry in manifest.entries where entry.kind == "sqlite" {
            try self.restoreSQLiteBackup(
                backupURL: generation.appendingPathComponent(entry.backupRelativePath),
                destinationURL: URL(fileURLWithPath: entry.originalPath))
        }
        #else
        if manifest.entries.contains(where: { $0.kind == "sqlite" }) {
            throw CodexUnifiedHistoryMigrationError.sqliteUnavailable
        }
        #endif
    }

    fileprivate static func reverseSHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
