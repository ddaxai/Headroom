import CodexBarCore
import Commander
import Foundation

extension CodexBarCLI {
    /// Testable, GUI-independent restore seam. Callers provide all paths and state explicitly;
    /// the command wrapper below is the only place that resolves process/environment defaults.
    static func restoreOfficial(
        paths: RelayConfigurationPaths,
        stateStore: any LocalMeterActivationStateStore,
        dryRun: Bool = false) throws -> LocalMeterRestoreResult
    {
        try LocalMeterRestoreService(paths: paths, stateStore: stateStore)
            .restoreOfficial(dryRun: dryRun)
    }

    static func restoreOfficialReport(
        paths: RelayConfigurationPaths,
        stateStore: any LocalMeterActivationStateStore,
        dryRun: Bool = false) throws -> LocalMeterRestoreReport
    {
        try LocalMeterRestoreService(paths: paths, stateStore: stateStore)
            .restoreOfficialReport(dryRun: dryRun)
    }

    static func runRelayRestoreOfficial(_ values: ParsedValues) -> Never {
        let output = CLIOutputPreferences.from(values: values)
        let environment = ProcessInfo.processInfo.environment
        let home = self.restoreHomeURL(values: values, environment: environment)
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: home,
            bundleURL: Bundle.main.bundleURL,
            environment: environment)
        let stateURL = self.restoreStateURL(values: values, paths: paths, environment: environment)
        let fileStore = LocalMeterActivationStateFileStore(fileURL: stateURL)
        let resolvedDefaults = self.restoreUserDefaults(environment: environment)
        let defaults = LocalMeterActivationStateDefaultsStore(userDefaults: resolvedDefaults)
        let stateStore = LocalMeterActivationStateStoreChain(primary: fileStore, fallback: defaults)
        let unifiedEnabled = resolvedDefaults.bool(forKey: "relay.codexUnifiedHistoryEnabled")
        let isDefaultHome = home.standardizedFileURL ==
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let dryRun = values.flags.contains("dryRun")

        do {
            let report = try LocalMeterRestoreService(
                paths: paths,
                stateStore: stateStore,
                codexProviderMode: unifiedEnabled ? .unified : .isolated,
                ownershipStore: isDefaultHome ? .default : nil)
                .restoreOfficialReport(dryRun: dryRun)
            self.printRestoreReport(report, dryRun: dryRun, output: output)
            self.platformExit(ExitCode.success.rawValue)
        } catch {
            self.exit(
                code: .failure,
                message: "Could not restore the official client configuration: \(error.localizedDescription)",
                output: output,
                kind: .config)
        }
    }

    private static func printRestoreReport(
        _ report: LocalMeterRestoreReport,
        dryRun: Bool,
        output: CLIOutputPreferences)
    {
        guard output.usesJSONOutput else {
            print(self.restoreOfficialText(report, dryRun: dryRun))
            return
        }
        var payload: [String: Any] = switch report.result {
        case .noActivation:
            ["status": "no_activation", "dryRun": dryRun]
        case .alreadyOfficial:
            ["status": "already_official", "dryRun": dryRun]
        case let .restored(changedFileCount):
            ["status": "restored", "changedFileCount": changedFileCount, "dryRun": dryRun]
        }
        payload["changedFiles"] = report.changedConfigurationURLs.map(\.path)
        payload["baselineBackupDirectory"] = report.baselineBackupDirectory?.path
        payload["recoveryBackupDirectory"] = report.recoveryBackupDirectory?.path
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: output.pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
    }

    static func restoreOfficialText(_ report: LocalMeterRestoreReport, dryRun: Bool) -> String {
        var lines: [String] = switch report.result {
        case .noActivation:
            ["No relay activation baseline is recorded; no configuration was changed."]
        case .alreadyOfficial:
            ["Official client configuration is already active; no configuration was changed."]
        case let .restored(changedFileCount):
            [String(
                format: "%d managed configuration file%@%@ to the official baseline.",
                changedFileCount,
                changedFileCount == 1 ? "" : "s",
                dryRun ? " would be restored" : " restored")]
        }
        if !report.changedConfigurationURLs.isEmpty {
            lines.append(dryRun ? "Managed files that would change:" : "Managed files restored:")
            lines.append(contentsOf: report.changedConfigurationURLs.map { "  \($0.path)" })
        }
        if let recoveryBackupDirectory = report.recoveryBackupDirectory {
            lines.append("Recovery backup: \(recoveryBackupDirectory.path)")
        }
        return lines.joined(separator: "\n")
    }

    private static func restoreHomeURL(values: ParsedValues, environment: [String: String]) -> URL {
        let raw = values.options["home"]?.last
            ?? environment["CODEXBAR_RESTORE_HOME"]
            ?? environment["CODEXBAR_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        if raw == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if raw.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(raw.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    private static func restoreStateURL(
        values: ParsedValues,
        paths: RelayConfigurationPaths,
        environment: [String: String]) -> URL
    {
        let raw = values.options["stateFile"]?.last ?? environment["CODEXBAR_RELAY_STATE_FILE"]
        if let raw, !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: false).standardizedFileURL
        }
        return paths.backupRootURL
            .appendingPathComponent(LocalMeterActivationStateFileStore.fileName, isDirectory: false)
    }

    private static func restoreUserDefaults(environment: [String: String]) -> UserDefaults {
        if let suite = environment["CODEXBAR_RELAY_DEFAULTS_SUITE"],
           let defaults = UserDefaults(suiteName: suite)
        {
            return defaults
        }
        // The packaged Headroom app uses this domain. Older domains are read only as a
        // compatibility fallback; no credentials or configuration files are inspected here.
        for suite in ["com.ddaxia.headroom", "com.steipete.codexbar", "com.steipete.codexbar.debug"] {
            if let defaults = UserDefaults(suiteName: suite),
               defaults.object(forKey: LocalMeterActivationState.baselineBackupPathKey) != nil
            {
                return defaults
            }
        }
        return .standard
    }
}

struct RelayRestoreOfficialOptions: CommanderParsable {
    @Flag(name: .long("dry-run"), help: "Show what would be restored without changing files")
    var dryRun: Bool = false

    @Option(name: .long("home"), help: "Isolated home directory (for tests or managed environments)")
    var home: String?

    @Option(name: .long("state-file"), help: "Activation state file path")
    var stateFile: String?

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
