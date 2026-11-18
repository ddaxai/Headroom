import Foundation
import Testing
@testable import CodexBarCore

struct RelayProviderKeyTests {
    @Test
    func `Chinese profile names become readable ASCII pinyin keys`() {
        #expect(RelayProviderKey.slug(for: "梁") == "liang")
        #expect(RelayProviderKey.slug(for: "梁 API") == "liang-api")
        let scalarsAreASCII = RelayProviderKey.slug(for: "梁").unicodeScalars.allSatisfy(\.isASCII)
        #expect(scalarsAreASCII)
    }

    @Test
    func `ASCII profile names remain stable slugs`() {
        #expect(RelayProviderKey.slug(for: "Open Code") == "open-code")
        #expect(RelayProviderKey.slug(for: "  API_One  ") == "api-one")
    }

    @Test
    func `empty or punctuation-only names use a deterministic fallback`() throws {
        let id = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(RelayProviderKey.slug(for: "", fallbackID: id) == "relay-11111111")
        #expect(RelayProviderKey.slug(for: "!!!", fallbackID: id) == "relay-11111111")
    }

    @Test
    func `profile stores UUID fallbacks for empty and punctuation-only names`() throws {
        let emptyID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let punctuationID = try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        let baseURL = try #require(URL(string: "https://relay.example/v1"))
        let empty = RelayProfile(
            id: emptyID,
            name: "",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: "test-reference",
            targets: [])
        let punctuation = RelayProfile(
            id: punctuationID,
            name: "!!!",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: "test-reference",
            targets: [])

        #expect(empty.providerKey == "relay-44444444")
        #expect(punctuation.providerKey == "relay-55555555")
    }

    @Test
    func `profile stores the generated provider key without changing route identity`() throws {
        let id = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let baseURL = try #require(URL(string: "https://relay.example/v1"))
        let profile = RelayProfile(
            id: id,
            name: "梁",
            baseURL: baseURL,
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: id),
            targets: [.init(app: .openCode, model: "gpt-test")])

        #expect(profile.providerKey == "liang")
        #expect(RelayCodexProviderMode.isolated.providerID == "codexbar_relay")
    }

    @Test
    func `legacy profile without a provider key derives one from its name`() throws {
        let id = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "梁",
              "baseURL": "https://relay.example/v1",
              "apiFormat": "openAIResponses",
              "credentialReference": "\(RelayCredentialReference.make(for: id))",
              "targets": [{"app":"openCode","isEnabled":true}]
            }
            """.utf8)

        let profile = try JSONDecoder().decode(RelayProfile.self, from: data)
        #expect(profile.providerKey == "liang")
    }
}
