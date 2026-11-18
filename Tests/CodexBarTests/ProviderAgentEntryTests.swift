import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct ProviderAgentEntryTests {
    @Test
    func `narrow catalog contains launch providers and Pi only`() {
        #expect(ProviderAgentEntryCatalog.providerIDs == [
            .codex,
            .claude,
            .antigravity,
            .opencode,
            .sub2api,
        ])
        #expect(ProviderAgentEntryCatalog.allIDs == [
            .provider(.codex),
            .provider(.claude),
            .provider(.antigravity),
            .provider(.opencode),
            .provider(.sub2api),
            .piAgent,
        ])
    }

    @Test
    func `Pi command missing is unavailable`() {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = PiAgentProbe.inspect(commandURL: nil, sessionsRoot: root)

        #expect(result.state == .unavailable)
        #expect(result.reason == .commandMissing)
        #expect(result.parseableSessionCount == 0)
    }

    @Test
    func `Pi sessions directory missing is unavailable for a present command`() throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.makeExecutable(in: root)
        let missingSessions = root.appendingPathComponent("missing", isDirectory: true)

        let result = PiAgentProbe.inspect(commandURL: command, sessionsRoot: missingSessions)

        #expect(result.state == .unavailable)
        #expect(result.reason == .sessionsDirectoryMissing)
        #expect(result.parseableSessionCount == 0)
    }

    @Test
    func `Pi directory without parseable sessions is confirmed empty`() throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.makeExecutable(in: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "not-json\n".write(
            to: sessions.appendingPathComponent("broken.jsonl"),
            atomically: true,
            encoding: .utf8)

        let result = PiAgentProbe.inspect(commandURL: command, sessionsRoot: sessions)

        #expect(result.state == .empty)
        #expect(result.reason == .noSessions)
        #expect(result.parseableSessionCount == 0)
    }

    @Test
    func `Pi probe counts parseable nested sessions and ignores malformed files`() throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = try Self.makeExecutable(in: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let project = sessions.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Self.piSessionJSONL.write(
            to: project.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        try "{broken\n".write(
            to: project.appendingPathComponent("broken.jsonl"),
            atomically: true,
            encoding: .utf8)

        let result = PiAgentProbe.inspect(commandURL: command, sessionsRoot: sessions)

        #expect(result.state == .available)
        #expect(result.reason == nil)
        #expect(result.parseableSessionCount == 1)
    }

    @Test
    func `disabled Pi row does not invoke its probe`() {
        var probeCount = 0

        let result = PiAgentProbe.loadIfEnabled(false) {
            probeCount += 1
            return .init(state: .available, parseableSessionCount: 1)
        }

        #expect(result == nil)
        #expect(probeCount == 0)
    }

    @Test
    @MainActor
    func `Pi usage is enabled by default and persists its toggle`() throws {
        let suite = "ProviderAgentEntryTests-pi-enabled-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = testSettingsStore(suiteName: suite)

        #expect(settings.piAgentUsageEnabled)
        settings.piAgentUsageEnabled = false
        #expect(settings.userDefaults.object(forKey: "piAgentUsageEnabled") as? Bool == false)
    }

    @Test
    func `narrow entry cannot mount legacy provider renderers`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entry = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesProviderAgentPane.swift"),
            encoding: .utf8)
        for forbidden in [
            "PreferencesProviderManagementPane",
            "ProviderManagementPane",
            "ProviderDetailSheet",
            "ProvidersPane(",
        ] {
            #expect(!entry.contains(forbidden), Comment(rawValue: "Forbidden legacy renderer: \(forbidden)"))
        }
    }

    private static let piSessionJSONL = """
    {"type":"session","id":"session-1","timestamp":"2026-08-19T10:00:00Z"}
    {"type":"message","id":"message-1","timestamp":"2026-08-19T10:01:00Z",\
    "message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.4",\
    "timestamp":"2026-08-19T10:01:00Z","usage":{"input":10,"output":2,"totalTokens":12}}}
    """

    private static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-agent-entry-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeExecutable(in root: URL) throws -> URL {
        let command = root.appendingPathComponent("pi")
        try "#!/bin/sh\nexit 0\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return command
    }
}
