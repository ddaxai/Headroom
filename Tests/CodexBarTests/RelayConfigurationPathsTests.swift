import CodexBarCore
import Foundation
import Testing

struct RelayConfigurationPathsTests {
    @Test
    func `standard paths honor documented environment overrides`() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: home,
            bundleURL: URL(fileURLWithPath: "/Applications/CodexBar.app", isDirectory: true),
            environment: [
                "CODEX_HOME": "/tmp/codex-home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-home",
                "GROK_HOME": "/tmp/grok-home",
                "OPENCODE_CONFIG": "/tmp/opencode/custom.jsonc",
            ])

        #expect(paths.codexConfigURL.path == "/tmp/codex-home/config.toml")
        #expect(paths.claudeCodeSettingsURL.path == "/tmp/claude-home/settings.json")
        #expect(paths.grokBuildConfigURL.path == "/tmp/grok-home/config.toml")
        #expect(paths.openCodeConfigURL.path == "/tmp/opencode/custom.jsonc")
        #expect(paths.piAgentSettingsURL.path == "/Users/example/.pi/agent/settings.json")
        #expect(paths.piAgentModelsURL.path == "/Users/example/.pi/agent/models.json")
        #expect(paths.credentialHelperURL.path == "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
    }

    @Test
    func `relative and blank environment overrides fail closed to defaults`() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: home,
            bundleURL: URL(fileURLWithPath: "/Applications/CodexBar.app", isDirectory: true),
            environment: [
                "CODEX_HOME": "relative/codex",
                "CLAUDE_CONFIG_DIR": "   ",
                "GROK_HOME": "relative/grok",
                "OPENCODE_CONFIG": "relative/opencode.json",
            ])

        #expect(paths.codexConfigURL.path == "/Users/example/.codex/config.toml")
        #expect(paths.claudeCodeSettingsURL.path == "/Users/example/.claude/settings.json")
        #expect(paths.grokBuildConfigURL.path == "/Users/example/.grok/config.toml")
        #expect(paths.openCodeConfigURL.path == "/Users/example/.config/opencode/opencode.json")
        #expect(paths.piAgentSettingsURL.path == "/Users/example/.pi/agent/settings.json")
        #expect(paths.piAgentModelsURL.path == "/Users/example/.pi/agent/models.json")
    }
}
