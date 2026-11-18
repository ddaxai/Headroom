import CodexBarCore
import Foundation
import Testing

struct RelayEndpointValidatorTests {
    @Test(arguments: [
        "https://relay.example/v1",
        "HTTPS://relay.example/path",
        "http://localhost:8080/v1",
        "http://127.0.0.1:8080/v1",
        "http://[::1]:8080/v1",
    ])
    func `accepts TLS and exact loopback HTTP endpoints`(_ rawValue: String) {
        #expect(RelayEndpointValidator.validatedURL(rawValue) != nil)
    }

    @Test(arguments: [
        "http://relay.example/v1",
        "http://localhost.evil.example/v1",
        "ftp://localhost/v1",
        "https://user:password@relay.example/v1",
        "https://relay.example/v1?key=value",
        "https://relay.example/v1#fragment",
        "relay.example/v1",
    ])
    func `rejects insecure or credential-bearing endpoints`(_ rawValue: String) {
        #expect(RelayEndpointValidator.validatedURL(rawValue) == nil)
    }
}
