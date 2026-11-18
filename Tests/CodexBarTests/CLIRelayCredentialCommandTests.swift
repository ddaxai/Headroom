import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIRelayCredentialCommandTests {
    @Test
    func `valid opaque reference resolves the exact stored credential`() throws {
        let reference = RelayCredentialReference.make(for: UUID())
        let resolved = try CodexBarCLI.resolveRelayCredential(
            reference: reference,
            store: TestCLIRelayCredentialStore(value: "  test-secret-value  "))

        #expect(resolved == "test-secret-value")
    }

    @Test
    func `invalid or missing references fail with one generic error`() {
        let store = TestCLIRelayCredentialStore(value: "test-secret-value")
        #expect(throws: RelayCredentialCLIError.unavailable) {
            _ = try CodexBarCLI.resolveRelayCredential(reference: nil, store: store)
        }
        #expect(throws: RelayCredentialCLIError.unavailable) {
            _ = try CodexBarCLI.resolveRelayCredential(reference: "not-an-opaque-reference", store: store)
        }
    }

    @Test
    func `missing credential fails without exposing its reference`() {
        let reference = RelayCredentialReference.make(for: UUID())
        #expect(throws: RelayCredentialCLIError.unavailable) {
            _ = try CodexBarCLI.resolveRelayCredential(
                reference: reference,
                store: TestCLIRelayCredentialStore(value: nil))
        }
    }
}

private struct TestCLIRelayCredentialStore: RelayCredentialStoring {
    let value: String?

    func loadCredential(reference _: String) throws -> String? {
        self.value
    }

    func storeCredential(_: String, reference _: String) throws {}
    func removeCredential(reference _: String) throws {}
}
