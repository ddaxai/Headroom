import CodexBarCore
import Foundation
import Testing

struct RelayProfileModelsTests {
    @Test
    func `relay target list contains the supported applications`() {
        #expect(RelayTargetApp.allCases == [
            .codex,
            .claudeCode,
            .claudeDesktop,
            .grokBuild,
            .openCode,
            .piAgent,
        ])
    }

    @Test
    func `profile resolves only enabled application configurations`() throws {
        let profile = try RelayProfile(
            name: "Relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "keychain-item",
            targets: [
                RelayTargetConfiguration(app: .codex, model: "gpt-5"),
                RelayTargetConfiguration(app: .openCode, isEnabled: false),
            ])

        #expect(profile.configuration(for: .codex)?.model == "gpt-5")
        #expect(profile.configuration(for: .openCode) == nil)
        #expect(profile.configuration(for: .claudeCode) == nil)
    }

    @Test
    func `new relay profile defaults to Sub2API usage queries`() throws {
        let profile = try RelayProfile(
            name: "Relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "keychain-item",
            targets: [.init(app: .codex)])

        #expect(profile.usageQueryMode == .sub2API)
    }

    @Test
    func `visible target filter survives profile encoding`() throws {
        let profile = try RelayProfile(
            name: "Relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: "keychain-item",
            targets: [.init(app: .codex)],
            visibleTargets: [.codex, .openCode, .piAgent])

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RelayProfile.self, from: encoded)

        #expect(decoded.visibleTargets == [.codex, .openCode, .piAgent])
    }

    @Test
    func `legacy profile without credential marker decodes as incomplete`() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy relay",
              "baseURL": "https://relay.example/v1",
              "apiFormat": "openAIResponses",
              "credentialReference": "relay-profile.\(id.uuidString.lowercased())",
              "targets": [{"app":"codex","isEnabled":true}]
            }
            """.utf8)

        let profile = try JSONDecoder().decode(RelayProfile.self, from: data)

        #expect(!profile.credentialConfigured)
        #expect(profile.usageQueryMode == .sub2API)
        #expect(profile.visibleTargets == Set(RelayTargetApp.allCases))
    }
}
