import Foundation

public enum CodexBarPreferences {
    public static let suiteEnvironmentKey = "CODEXBAR_PREFERENCES_SUITE"
    private static let productionApplicationDomains = [
        "com.ddaxia.headroom",
        "com.ddaxia.headroom.debug",
        "com.steipete.codexbar",
        "com.steipete.codexbar.debug",
        "CodexBar",
    ]

    /// UserDefaults is documented as thread-safe. The selected suite is frozen once at process startup.
    public nonisolated(unsafe) static let processDefaults: UserDefaults = resolve(
        environment: ProcessInfo.processInfo.environment,
        standardDefaults: .standard)

    public static let isIsolatedProcess: Bool = isolationSuiteName(
        environment: ProcessInfo.processInfo.environment) != nil

    public static func resolve(
        environment: [String: String],
        standardDefaults: UserDefaults) -> UserDefaults
    {
        guard let suiteName = self.isolationSuiteName(environment: environment) else {
            return standardDefaults
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to open isolated preference suite \(suiteName)")
        }
        return defaults
    }

    public static func isolationSuiteName(environment: [String: String]) -> String? {
        guard let raw = environment[self.suiteEnvironmentKey] else { return nil }
        let suiteName = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!suiteName.isEmpty, "\(self.suiteEnvironmentKey) must not be empty")
        precondition(
            suiteName.hasPrefix("com.ddaxia.headroom.isolated."),
            "\(self.suiteEnvironmentKey) must use the isolated Headroom namespace")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        precondition(
            suiteName.unicodeScalars.allSatisfy(allowed.contains),
            "\(self.suiteEnvironmentKey) contains invalid preference-domain characters")
        return suiteName
    }

    public static func defaults(forApplicationDomain domain: String) -> UserDefaults {
        let resolvedDomain = self.resolvedApplicationDomain(domain)
        return UserDefaults(suiteName: resolvedDomain) ?? self.processDefaults
    }

    public static func resolvedApplicationDomain(
        _ domain: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        if self.productionApplicationDomains.contains(domain),
           let suiteName = self.isolationSuiteName(environment: environment)
        {
            return suiteName
        }
        return domain
    }
}
