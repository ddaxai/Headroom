import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("Process preference isolation", .serialized)
struct ProcessPreferenceIsolationTests {
    @Test
    func `no injected suite preserves the official UserDefaults domain`() throws {
        // Before the seam, the app used UserDefaults.standard for this exact
        // application domain. Keep the expected identity explicit so a changed
        // fallback fails instead of silently starting a new preference store.
        let officialDomain = HeadroomIdentity.bundleIdentifier
        let legacyDefaults = try #require(UserDefaults(suiteName:
            "com.ddaxia.headroom.isolated.default-domain-regression.\(UUID().uuidString)"))
        let resolved = CodexBarPreferences.resolve(environment: [:], standardDefaults: legacyDefaults)
        let resolvedDomain = CodexBarPreferences.resolvedApplicationDomain(
            officialDomain,
            environment: [:])

        print("pre-change UserDefaults domain: \(officialDomain)")
        print("seam domain without \(CodexBarPreferences.suiteEnvironmentKey): \(resolvedDomain)")
        print("seam suite without injection: none (UserDefaults.standard)")
        print("seam returns the legacy standard object: \(resolved === legacyDefaults)")

        #expect(officialDomain == "com.ddaxia.headroom")
        #expect(resolvedDomain == officialDomain)
        #expect(CodexBarPreferences.isolationSuiteName(environment: [:]) == nil)
        #expect(resolved === legacyDefaults)
        if ProcessInfo.processInfo.environment[CodexBarPreferences.suiteEnvironmentKey] == nil {
            #expect(CodexBarPreferences.processDefaults === UserDefaults.standard)
        }
    }

    @Test
    func `explicit suite resolves away from the fallback preference domain`() throws {
        let hostSuite = "com.ddaxia.headroom.isolated.test-host.\(UUID().uuidString)"
        let isolatedSuite = "com.ddaxia.headroom.isolated.test-target.\(UUID().uuidString)"
        let hostDefaults = try #require(UserDefaults(suiteName: hostSuite))
        #expect(hostDefaults.persistentDomain(forName: hostSuite) == nil)

        let resolved = CodexBarPreferences.resolve(
            environment: [CodexBarPreferences.suiteEnvironmentKey: isolatedSuite],
            standardDefaults: hostDefaults)

        #expect(resolved !== hostDefaults)
        #expect(hostDefaults.persistentDomain(forName: hostSuite) == nil)
        #expect(resolved.persistentDomain(forName: isolatedSuite) == nil)
    }

    @Test
    func `missing suite preserves the supplied defaults object`() throws {
        let suite = "com.ddaxia.headroom.isolated.test-fallback.\(UUID().uuidString)"
        let fallback = try #require(UserDefaults(suiteName: suite))

        let resolved = CodexBarPreferences.resolve(environment: [:], standardDefaults: fallback)

        #expect(resolved === fallback)
    }

    @Test
    func `production application domains are redirected but fixture domains stay explicit`() {
        let isolatedSuite = "com.ddaxia.headroom.isolated.test-domain.\(UUID().uuidString)"
        let environment = [CodexBarPreferences.suiteEnvironmentKey: isolatedSuite]

        #expect(CodexBarPreferences.resolvedApplicationDomain(
            "com.steipete.codexbar",
            environment: environment) == isolatedSuite)
        #expect(CodexBarPreferences.resolvedApplicationDomain(
            "fixture.custom.domain",
            environment: environment) == "fixture.custom.domain")
    }
}
