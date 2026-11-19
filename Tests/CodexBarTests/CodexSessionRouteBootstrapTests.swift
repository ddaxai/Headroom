import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexSessionRouteBootstrapTests {
    @Test
    @MainActor
    func `external relay configuration is resolved when activation metadata is stale`() throws {
        let relayID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let profile = try RelayProfile(
            id: relayID,
            name: "Relay",
            baseURL: #require(URL(string: "https://relay.example")),
            apiFormat: .openAIResponses,
            credentialReference: "relay",
            targets: [.init(app: .codex)])

        let route = CodexSessionRouteBootstrap.resolveCurrentRoute(
            activationProfileID: UUID(uuidString: "22222222-2222-4222-8222-222222222222"),
            profiles: [profile],
            verification: .init(
                relay: { $0.id == relayID },
                official: { false }))

        #expect(route == .relay(profileID: relayID))
    }

    @Test
    @MainActor
    func `ambiguous external relay matches fail closed to unknown`() throws {
        let firstID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let secondID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let makeProfile: (UUID) -> RelayProfile = { id in
            RelayProfile(
                id: id,
                name: id.uuidString,
                baseURL: URL(string: "https://relay.example")!,
                apiFormat: .openAIResponses,
                credentialReference: id.uuidString,
                targets: [.init(app: .codex)])
        }

        let route = CodexSessionRouteBootstrap.resolveCurrentRoute(
            activationProfileID: nil,
            profiles: [makeProfile(firstID), makeProfile(secondID)],
            verification: .init(
                relay: { _ in true },
                official: { false }))

        #expect(route == .unknown)
    }

    @Test
    @MainActor
    func `external official configuration is resolved after a stale relay activation`() {
        let route = CodexSessionRouteBootstrap.resolveCurrentRoute(
            activationProfileID: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
            profiles: [],
            verification: .init(
                relay: { _ in false },
                official: { true }))

        #expect(route == .official)
    }
}
