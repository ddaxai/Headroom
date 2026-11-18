import Foundation

/// Shared endpoint policy for relay drafts and configuration rendering.
/// Remote relays must use TLS; plain HTTP is reserved for an explicitly local process.
public enum RelayEndpointValidator {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public static func validatedURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value), self.isAllowed(components: components) else {
            return nil
        }
        return components.url
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return self.isAllowed(components: components)
    }

    private static func isAllowed(components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(),
              let rawHost = components.host,
              !rawHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return self.loopbackHosts.contains(self.normalizedHost(rawHost))
    }

    private static func normalizedHost(_ rawHost: String) -> String {
        let lowercased = rawHost.lowercased()
        guard lowercased.hasPrefix("["), lowercased.hasSuffix("]") else {
            return lowercased
        }
        return String(lowercased.dropFirst().dropLast())
    }
}
