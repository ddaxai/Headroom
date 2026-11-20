import CodexBarCore
import Testing
@testable import CodexBar

struct HeadroomProviderRegistryTests {
    @Test
    func `launch registry contains only the six moved provider directories`() throws {
        #expect(HeadroomProviderRegistry.launchDirectoryNames == [
            "Shared", "Codex", "Claude", "Antigravity", "OpenCode", "Sub2API",
        ])
        #expect(HeadroomProviderRegistry.providerIDs == [
            .codex, .claude, .antigravity, .opencode, .sub2api,
        ])

        let codex = try #require(HeadroomProviderRegistry.descriptor(for: .codex))
        #expect(codex.capabilities == [.quota, .localUsage, .relaySwitch, .login, .cost])
        #expect(codex.quotaAdapter == .usageSnapshot)
        #expect(codex.localUsageAdapter == .sessionLedger)
        #expect(codex.routeWriter == .relayTargets([.codex]))

        let claude = try #require(HeadroomProviderRegistry.descriptor(for: .claude))
        #expect(claude.capabilities == [.quota, .localUsage, .relaySwitch])
        #expect(claude.routeWriter == .relayTargets([.claudeCode]))

        let antigravity = try #require(HeadroomProviderRegistry.descriptor(for: .antigravity))
        #expect(antigravity.capabilities == [.quota, .localUsage])
        #expect(antigravity.quotaAdapter == .usageSnapshot)
        #expect(antigravity.localUsageAdapter == nil)
        #expect(antigravity.routeWriter == nil)

        let openCode = try #require(HeadroomProviderRegistry.descriptor(for: .opencode))
        #expect(openCode.capabilities == [.quota, .localUsage, .relaySwitch, .cost])
        #expect(openCode.localUsageAdapter == .sessionLedger)
        #expect(openCode.tokenCost.supportsTokenCost)
        #expect(openCode.routeWriter == .relayTargets([.openCode]))

        let sub2API = try #require(HeadroomProviderRegistry.descriptor(for: .sub2api))
        #expect(sub2API.capabilities == [.cost])
        #expect(sub2API.quotaAdapter == nil)
        #expect(sub2API.localUsageAdapter == nil)
        #expect(sub2API.routeWriter == nil)

        #expect(HeadroomProviderRegistry.descriptor(for: .opencodego) == nil)
    }

    @Test
    func `provider card policy omits sections without a capability`() throws {
        let codex = try #require(HeadroomProviderCardSectionPolicy(provider: .codex))
        #expect(codex.showsQuota)
        #expect(codex.showsLocalUsage)
        #expect(codex.showsCost)

        let antigravity = try #require(HeadroomProviderCardSectionPolicy(provider: .antigravity))
        #expect(antigravity.showsQuota)
        #expect(antigravity.showsLocalUsage)
        #expect(!antigravity.showsCost)
        #expect(!antigravity.reservesMissingSections)

        let sub2API = try #require(HeadroomProviderCardSectionPolicy(provider: .sub2api))
        #expect(!sub2API.showsQuota)
        #expect(!sub2API.showsLocalUsage)
        #expect(sub2API.showsCost)
        #expect(!sub2API.reservesMissingSections)
    }
}
