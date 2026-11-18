import Foundation

#if os(macOS)
import SweetCookieKit

public typealias BrowserCookieImportOrder = [Browser]
#else
public struct Browser: Sendable, Hashable {
    public init() {}
}

public typealias BrowserCookieImportOrder = [Browser]
#endif

public enum BrowserCookieImportPolicy {
    public static let defaultsKey = "browserCookieImportEnabled"
    @TaskLocal static var enabledOverrideForTesting: Bool?

    /// Browser-cookie import is opt-in for the packaged app. Explicit CLI commands and unit
    /// fixtures remain usable without inheriting an application preference domain.
    public static var isEnabled: Bool {
        if let enabledOverrideForTesting { return enabledOverrideForTesting }
        if KeychainTestSafety.isRunningUnderTests(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment)
        {
            return true
        }
        #if os(macOS)
        if Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") != .orderedSame {
            return ProviderInteractionContext.current == .userInitiated
        }
        #endif
        return CodexBarPreferences.processDefaults.bool(forKey: self.defaultsKey)
    }

    public static func resolve(userDefaults: UserDefaults) -> Bool {
        userDefaults.object(forKey: self.defaultsKey) as? Bool ?? false
    }

    static func withEnabledForTesting<T>(_ enabled: Bool, operation: () throws -> T) rethrows -> T {
        try self.$enabledOverrideForTesting.withValue(enabled, operation: operation)
    }
}

extension [Browser] {
    /// Filters a browser list to sources worth attempting for cookie imports.
    ///
    /// This is intentionally stricter than "app installed": it aims to avoid unnecessary Keychain prompts.
    public func cookieImportCandidates(using detection: BrowserDetection) -> [Browser] {
        guard BrowserCookieImportPolicy.isEnabled else { return [] }
        let candidates = self.filter { browser in
            if KeychainAccessGate.isDisabled, browser.usesKeychainForCookieDecryption {
                return false
            }
            return detection.isCookieSourceAvailable(browser)
        }
        return candidates.filter { BrowserCookieAccessGate.shouldAttempt($0) }
    }

    /// Filters a browser list to sources with usable profile data on disk.
    public func browsersWithProfileData(using detection: BrowserDetection) -> [Browser] {
        self.filter { detection.hasUsableProfileData($0) }
    }
}

#if os(macOS)
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        switch self {
        case .safari, .firefox, .zen:
            return false
        case .chrome, .chromeBeta, .chromeCanary,
             .arc, .arcBeta, .arcCanary,
             .chatgptAtlas,
             .chromium,
             .brave, .braveBeta, .braveNightly,
             .edge, .edgeBeta, .edgeCanary,
             .helium,
             .vivaldi,
             .dia,
             .yandex,
             .comet:
            return true
        @unknown default:
            return true
        }
    }
}
#else
extension Browser {
    var usesKeychainForCookieDecryption: Bool {
        false
    }
}
#endif
