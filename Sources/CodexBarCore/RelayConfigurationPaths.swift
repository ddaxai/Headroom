import Foundation

/// Locations touched by direct relay switching.
///
/// The explicit initializer is useful for tests and future custom-path settings. The default layout
/// mirrors the six managed clients' macOS locations.
public struct RelayConfigurationPaths: Equatable, Sendable {
    public var codexConfigURL: URL
    public var claudeCodeSettingsURL: URL
    public var claudeDesktopNormalConfigURL: URL
    public var claudeDesktopThreePConfigURL: URL
    public var claudeDesktopProfileURL: URL
    public var claudeDesktopMetaURL: URL
    public var grokBuildConfigURL: URL
    public var openCodeConfigURL: URL
    public var piAgentSettingsURL: URL
    public var piAgentModelsURL: URL
    public var credentialHelperURL: URL
    public var backupRootURL: URL

    public init(
        codexConfigURL: URL,
        claudeCodeSettingsURL: URL,
        claudeDesktopNormalConfigURL: URL,
        claudeDesktopThreePConfigURL: URL,
        claudeDesktopProfileURL: URL,
        claudeDesktopMetaURL: URL,
        grokBuildConfigURL: URL,
        openCodeConfigURL: URL,
        piAgentSettingsURL: URL? = nil,
        piAgentModelsURL: URL? = nil,
        credentialHelperURL: URL,
        backupRootURL: URL)
    {
        self.codexConfigURL = codexConfigURL
        self.claudeCodeSettingsURL = claudeCodeSettingsURL
        self.claudeDesktopNormalConfigURL = claudeDesktopNormalConfigURL
        self.claudeDesktopThreePConfigURL = claudeDesktopThreePConfigURL
        self.claudeDesktopProfileURL = claudeDesktopProfileURL
        self.claudeDesktopMetaURL = claudeDesktopMetaURL
        self.grokBuildConfigURL = grokBuildConfigURL
        self.openCodeConfigURL = openCodeConfigURL
        self.piAgentSettingsURL = piAgentSettingsURL
            ?? openCodeConfigURL.deletingLastPathComponent().appendingPathComponent("pi/settings.json")
        self.piAgentModelsURL = piAgentModelsURL
            ?? openCodeConfigURL.deletingLastPathComponent().appendingPathComponent("pi/models.json")
        self.credentialHelperURL = credentialHelperURL
        self.backupRootURL = backupRootURL
    }

    public static func standard(
        homeDirectory: URL,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Self
    {
        let applicationSupport = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let claudeThreeP = applicationSupport.appendingPathComponent("Claude-3p", isDirectory: true)
        let claudeConfigLibrary = claudeThreeP.appendingPathComponent("configLibrary", isDirectory: true)
        let codexDirectory = self.environmentDirectory(
            named: "CODEX_HOME",
            environment: environment,
            homeDirectory: homeDirectory)
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let claudeCodeDirectory = self.environmentDirectory(
            named: "CLAUDE_CONFIG_DIR",
            environment: environment,
            homeDirectory: homeDirectory)
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let grokDirectory = self.environmentDirectory(
            named: "GROK_HOME",
            environment: environment,
            homeDirectory: homeDirectory)
            ?? homeDirectory.appendingPathComponent(".grok", isDirectory: true)
        let openCodeDirectory = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        let openCodeJSONC = openCodeDirectory.appendingPathComponent("opencode.jsonc")
        let openCodeConfig = self.environmentFile(
            named: "OPENCODE_CONFIG",
            environment: environment,
            homeDirectory: homeDirectory)
            ?? (FileManager.default.fileExists(atPath: openCodeJSONC.path)
                ? openCodeJSONC
                : openCodeDirectory.appendingPathComponent("opencode.json"))
        let piDirectory = homeDirectory
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)

        return Self(
            codexConfigURL: codexDirectory.appendingPathComponent("config.toml"),
            claudeCodeSettingsURL: claudeCodeDirectory.appendingPathComponent("settings.json"),
            claudeDesktopNormalConfigURL: applicationSupport
                .appendingPathComponent("Claude", isDirectory: true)
                .appendingPathComponent("claude_desktop_config.json"),
            claudeDesktopThreePConfigURL: claudeThreeP
                .appendingPathComponent("claude_desktop_config.json"),
            claudeDesktopProfileURL: claudeConfigLibrary
                .appendingPathComponent("00000000-0000-4000-8000-000000157210.json"),
            claudeDesktopMetaURL: claudeConfigLibrary.appendingPathComponent("_meta.json"),
            grokBuildConfigURL: grokDirectory.appendingPathComponent("config.toml"),
            openCodeConfigURL: openCodeConfig,
            piAgentSettingsURL: piDirectory.appendingPathComponent("settings.json"),
            piAgentModelsURL: piDirectory.appendingPathComponent("models.json"),
            credentialHelperURL: self.credentialHelperURL(bundleURL: bundleURL),
            backupRootURL: applicationSupport
                .appendingPathComponent("CodexBar", isDirectory: true)
                .appendingPathComponent("RelayBackups", isDirectory: true))
    }

    /// Configuration files that direct relay activation is allowed to mutate.  This public view is
    /// also used by the startup guard to detect a loopback route without reading auth material.
    public var managedConfigurationURLs: [URL] {
        [
            self.codexConfigURL,
            self.claudeCodeSettingsURL,
            self.grokBuildConfigURL,
            self.openCodeConfigURL,
            self.piAgentSettingsURL,
            self.piAgentModelsURL,
        ]
    }

    private static func credentialHelperURL(bundleURL: URL) -> URL {
        if bundleURL.standardizedFileURL.path.contains("/.build/") {
            let installedHelper = URL(
                fileURLWithPath: "/Applications/Headroom.app/Contents/Helpers/CodexBarCLI",
                isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: installedHelper.path) {
                return installedHelper
            }
        }
        if let appBundle = self.appBundleURL(containing: bundleURL) {
            return appBundle
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("CodexBarCLI", isDirectory: false)
        }
        return bundleURL.appendingPathComponent("CodexBarCLI", isDirectory: false)
    }

    private static func environmentDirectory(
        named name: String,
        environment: [String: String],
        homeDirectory: URL) -> URL?
    {
        self.environmentPath(named: name, environment: environment, homeDirectory: homeDirectory)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private static func environmentFile(
        named name: String,
        environment: [String: String],
        homeDirectory: URL) -> URL?
    {
        self.environmentPath(named: name, environment: environment, homeDirectory: homeDirectory)
            .map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL }
    }

    private static func environmentPath(
        named name: String,
        environment: [String: String],
        homeDirectory: URL) -> String?
    {
        guard var value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        if value == "~" {
            value = homeDirectory.path
        } else if value.hasPrefix("~/") {
            value = homeDirectory.appendingPathComponent(String(value.dropFirst(2))).path
        }
        guard value.hasPrefix("/") else { return nil }
        return value
    }

    private static func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
