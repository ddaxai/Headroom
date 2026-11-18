import Foundation
import Testing
@testable import CodexBar

struct HeadroomRuntimePolicyTests {
    @Test
    func `a second process with the same bundle is never allowed to launch`() {
        #expect(
            HeadroomSingleInstancePolicy.decision(
                currentProcessIdentifier: 42,
                runningProcessIdentifiers: [42, 99]) == .activateExisting)
        #expect(
            HeadroomSingleInstancePolicy.decision(
                currentProcessIdentifier: 42,
                runningProcessIdentifiers: [42]) == .launch)
    }

    @Test
    func `runtime policy contains a cross-process lock for simultaneous launches`() throws {
        let root = Self.repositoryRoot
        let source = try String(
            contentsOf: root.appending(path: "Sources/CodexBar/HeadroomSingleInstancePolicy.swift"),
            encoding: .utf8)
        #expect(source.contains("LOCK_NB"))
        #expect(source.contains("HeadroomIdentity.bundleIdentifier"))
    }

    @Test
    func `relay packaging keeps the runnable app out of the repository root`() throws {
        let root = Self.repositoryRoot
        let script = try String(
            contentsOf: root.appending(path: "Scripts/package_relay_app.sh"),
            encoding: .utf8)
        let launch = try String(
            contentsOf: root.appending(path: "Scripts/launch.sh"),
            encoding: .utf8)
        let installer = try String(
            contentsOf: root.appending(path: "Scripts/install_headroom.sh"),
            encoding: .utf8)
        #expect(script.contains("CODEXBAR_OUTPUT_DIR"))
        #expect(script.contains(".build/headroom-artifacts"))
        #expect(!script.contains("open -n"))
        #expect(!launch.contains("open -n"))
        #expect(installer.contains("ditto \"$SOURCE_APP\" \"$TARGET_APP\""))
    }

    @Test
    func `cleanup scripts stop only known legacy CodexBar paths`() throws {
        let root = Self.repositoryRoot
        let compile = try String(
            contentsOf: root.appending(path: "Scripts/compile_and_run.sh"),
            encoding: .utf8)
        let launch = try String(
            contentsOf: root.appending(path: "Scripts/launch.sh"),
            encoding: .utf8)
        let stop = try String(
            contentsOf: root.appending(path: "Scripts/stop_headroom.sh"),
            encoding: .utf8)
        let legacyPath = "/Applications/CodexBar.app/Contents/MacOS/CodexBar"
        #expect(compile.contains("LEGACY_INSTALLED_PROCESS_PATH"))
        #expect(compile.contains(legacyPath))
        #expect(launch.contains(legacyPath))
        #expect(stop.contains(legacyPath))
        #expect(!compile.contains("pkill"))
        #expect(!launch.contains("pkill"))
        #expect(!stop.contains("pkill"))
    }

    @Test
    func `upstream automation is manual and the release feed is fork-owned`() throws {
        let root = Self.repositoryRoot
        let monitor = try String(
            contentsOf: root.appending(path: ".github/workflows/upstream-monitor.yml"),
            encoding: .utf8)
        let release = try String(
            contentsOf: root.appending(path: ".github/workflows/release-cli.yml"),
            encoding: .utf8)
        let package = try String(
            contentsOf: root.appending(path: "Scripts/package_app.sh"),
            encoding: .utf8)
        #expect(!monitor.contains("schedule:"))
        #expect(!release.contains("steipete/homebrew-tap"))
        #expect(!package.contains("raw.githubusercontent.com/steipete/"))
        #expect(package.contains("swift_build_for_arch"))
        #expect(!package.contains("SWIFT_BUILD_ARGS[@]"))
        #expect(!package.contains("SWIFT_BUILD_TOOL_ARGS[@]"))
    }

    @Test
    func `custom Headroom bundles preserve an explicitly configured update feed`() throws {
        let root = Self.repositoryRoot
        let package = try String(
            contentsOf: root.appending(path: "Scripts/package_app.sh"),
            encoding: .utf8)
        let relay = try String(
            contentsOf: root.appending(path: "Scripts/package_relay_app.sh"),
            encoding: .utf8)
        #expect(package.contains("if [[ -z \"${CODEXBAR_FEED_URL:-}\" ]]; then"))
        #expect(relay.contains("HEADROOM_FEED_URL"))
        #expect(relay.contains("CODEXBAR_FEED_URL"))
    }

    @Test
    func `local identity packages omit the unprovisioned widget app group`() throws {
        let root = Self.repositoryRoot
        let package = try String(
            contentsOf: root.appending(path: "Scripts/package_app.sh"),
            encoding: .utf8)
        #expect(package.contains("APP_GROUP_ACCESS_ENABLED=0"))
        #expect(package.contains("CODEXBAR_ALLOW_LOCAL_SIGNING"))
        #expect(package.contains("if [[ \"$APP_GROUP_ACCESS_ENABLED\" == \"1\" ]]; then"))
        #expect(package.contains("App Group disabled for this local-signing package"))
    }

    @Test
    func `Codex session scans never launch Git for project metadata`() throws {
        let root = Self.repositoryRoot
        let source = try String(
            contentsOf: root.appending(
                path: "Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner.swift"),
            encoding: .utf8)
        #expect(!source.contains(#"process.arguments = ["git", "-C", projectPath"#))
    }

    @Test
    func `updater policy explains missing feed and development signing`() {
        #expect(
            HeadroomUpdaterPolicy.unavailabilityReason(
                feedURL: nil,
                isBundledApp: true,
                isHomebrew: false,
                isDeveloperIDSigned: true) == "Updates unavailable because this build has no Sparkle feed.")
        #expect(
            HeadroomUpdaterPolicy.unavailabilityReason(
                feedURL: "https://updates.example.test/appcast.xml",
                isBundledApp: true,
                isHomebrew: false,
                isDeveloperIDSigned: false) ==
                "Updates unavailable because this build is not signed with Developer ID.")
        #expect(
            HeadroomUpdaterPolicy.unavailabilityReason(
                feedURL: "https://updates.example.test/appcast.xml",
                isBundledApp: true,
                isHomebrew: false,
                isDeveloperIDSigned: true) == nil)
    }

    @Test
    func `fork docs keep a verifiable upstream baseline`() throws {
        let root = Self.repositoryRoot
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let sources = try String(
            contentsOf: root.appending(path: "docs/UPSTREAM_FEATURE_SOURCES.md"),
            encoding: .utf8)
        #expect(!readme.contains("## Upstream CodexBar README"))
        #expect(!readme.contains("brew install --cask codexbar"))
        #expect(!sources.contains("/Users/theodore/Downloads/AgentDuck-v0.12"))
        #expect(sources.contains("8ef86077e70ac27d45ddddaf49e409824ccdf668"))
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
