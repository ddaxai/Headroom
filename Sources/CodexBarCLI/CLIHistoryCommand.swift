import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    static func restoreProviderBuckets(
        codexDirectory: URL,
        backupRootDirectory: URL,
        dryRun: Bool = true) throws -> CodexUnifiedHistoryReverseMigrationOutcome
    {
        try CodexUnifiedHistoryMigrator(
            codexDirectory: codexDirectory,
            backupRootDirectory: backupRootDirectory)
            .restoreOriginalProviderBuckets(dryRun: dryRun)
    }

    static func runRestoreProviderBuckets(_ values: ParsedValues) -> Never {
        let output = CLIOutputPreferences.from(values: values)
        let apply = values.flags.contains("apply")
        let explicitDryRun = values.flags.contains("dryRun")
        guard !(apply && explicitDryRun) else {
            self.exit(
                code: .failure,
                message: "Use either --dry-run or --apply, not both.",
                output: output,
                kind: .args)
        }

        let environment = ProcessInfo.processInfo.environment
        let codexDirectory = self.restoreProviderBucketsCodexDirectory(
            values: values,
            environment: environment)
        let backupRoot = self.restoreProviderBucketsBackupRoot(
            values: values,
            environment: environment)
        do {
            let report = try self.restoreProviderBuckets(
                codexDirectory: codexDirectory,
                backupRootDirectory: backupRoot,
                dryRun: !apply)
            self.printRestoreProviderBucketsReport(report, output: output)
            self.platformExit(ExitCode.success.rawValue)
        } catch {
            self.exit(
                code: .failure,
                message: "Could not restore Codex history provider buckets: \(error.localizedDescription)",
                output: output,
                kind: .config)
        }
    }

    static func restoreProviderBucketsText(
        _ report: CodexUnifiedHistoryReverseMigrationOutcome) -> String
    {
        var lines: [String] = []
        if report.rewrittenJSONLFiles == 0, report.rewrittenStateRows == 0 {
            lines.append("No shared provider records with provenance are ready to restore.")
        } else {
            let fileWord = report.rewrittenJSONLFiles == 1 ? "file" : "files"
            let rowWord = report.rewrittenStateRows == 1 ? "row" : "rows"
            let verb = report.dryRun ? "would be restored" : "restored"
            lines.append(
                "\(report.rewrittenJSONLFiles) JSONL \(fileWord) and " +
                    "\(report.rewrittenStateRows) state \(rowWord) \(verb).")
        }
        if report.unresolvedStateRows > 0 {
            let word = report.unresolvedStateRows == 1 ? "row" : "rows"
            lines.append(
                "\(report.unresolvedStateRows) state \(word) have no unambiguous rollout provenance; " +
                    "they were left unchanged.")
        }
        if !report.changedJSONLFiles.isEmpty {
            lines.append(report.dryRun ? "JSONL files that would change:" : "JSONL files changed:")
            lines.append(contentsOf: report.changedJSONLFiles.map { "  \($0.path)" })
        }
        if !report.changedStateDatabases.isEmpty {
            lines.append(report.dryRun ? "State databases that would change:" : "State databases changed:")
            lines.append(contentsOf: report.changedStateDatabases.map { "  \($0.path)" })
        }
        if let backupDirectory = report.backupDirectory {
            lines.append("Verified backup: \(backupDirectory.path)")
        } else if report.dryRun {
            lines.append("Dry run: no source or backup files were changed.")
        }
        return lines.joined(separator: "\n")
    }

    private static func printRestoreProviderBucketsReport(
        _ report: CodexUnifiedHistoryReverseMigrationOutcome,
        output: CLIOutputPreferences)
    {
        guard output.usesJSONOutput else {
            print(self.restoreProviderBucketsText(report))
            return
        }
        var payload: [String: Any] = [
            "dryRun": report.dryRun,
            "rewrittenJSONLFiles": report.rewrittenJSONLFiles,
            "rewrittenStateRows": report.rewrittenStateRows,
            "unresolvedStateRows": report.unresolvedStateRows,
            "changedJSONLFiles": report.changedJSONLFiles.map(\.path),
            "changedStateDatabases": report.changedStateDatabases.map(\.path),
        ]
        if let backupDirectory = report.backupDirectory {
            payload["backupDirectory"] = backupDirectory.path
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: output.pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            self.exit(code: .failure, message: "Could not encode restore report.", output: output, kind: .runtime)
        }
        print(text)
    }

    private static func restoreProviderBucketsCodexDirectory(
        values: ParsedValues,
        environment: [String: String]) -> URL
    {
        let raw = values.options["codexDirectory"]?.last
            ?? environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .path
        return self.restoreProviderBucketsURL(raw)
    }

    private static func restoreProviderBucketsBackupRoot(
        values: ParsedValues,
        environment: [String: String]) -> URL
    {
        if let raw = values.options["backupRoot"]?.last ?? environment["CODEXBAR_HISTORY_BACKUP_ROOT"],
           !raw.isEmpty
        {
            return self.restoreProviderBucketsURL(raw)
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("CodexBar/RelayBackups/UnifiedHistory/Reverse", isDirectory: true)
    }

    private static func restoreProviderBucketsURL(_ raw: String) -> URL {
        if raw == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if raw.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
}

struct RestoreProviderBucketsOptions: CommanderParsable {
    @Flag(name: .long("dry-run"), help: "Plan changes without writing source or backup files (default)")
    var dryRun: Bool = false

    @Flag(name: .long("apply"), help: "Apply the reverse migration after a verified backup")
    var apply: Bool = false

    @Option(name: .long("codex-directory"), help: "Codex home containing sessions and state_5.sqlite")
    var codexDirectory: String?

    @Option(name: .long("backup-root"), help: "Directory for verified reverse-migration backups")
    var backupRoot: String?

    @Flag(name: .long("json"), help: "Emit machine-readable JSON")
    var jsonShortcut: Bool = false

    @Flag(name: .long("json-only"), help: "Emit JSON only")
    var jsonOnly: Bool = false

    @Flag(name: .long("pretty"), help: "Pretty-print JSON")
    var pretty: Bool = false

    @Option(name: .long("format"), help: "Output format: text | json")
    var format: OutputFormat?

    @Flag(names: [.short("v"), .long("verbose")], help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long("json-output"), help: "Emit machine-readable logs")
    var jsonOutput: Bool = false

    @Option(name: .long("log-level"), help: "Set log level")
    var logLevel: String?
}
