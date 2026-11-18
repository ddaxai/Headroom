import CodexBarCore
import CryptoKit
import Foundation

@MainActor
struct CodexResetCreditExpiryNotifier {
    static let expiryWindow: TimeInterval = 3 * 24 * 60 * 60
    static let notificationPrefix = "codex-reset-credit-expiry"
    static let summaryFingerprintsKey = "codexResetCreditExpirySummaryFingerprints"
    static let maximumRememberedSummaries = 64

    private let userDefaults: UserDefaults
    private let clock: () -> Date
    private let notificationPoster: (String, String, String) -> Void

    init(
        userDefaults: UserDefaults = CodexBarPreferences.processDefaults,
        clock: @escaping () -> Date = Date.init,
        notificationPoster: @escaping (String, String, String) -> Void = { prefix, title, body in
            AppNotifications.shared.post(idPrefix: prefix, title: title, body: body)
        })
    {
        self.userDefaults = userDefaults
        self.clock = clock
        self.notificationPoster = notificationPoster
    }

    func postExpiringCreditsIfNeeded(
        snapshot: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle)
    {
        let now = self.clock()
        let expiringCredits = snapshot.availableInventory(at: now).credits.filter { credit in
            guard let expiresAt = credit.expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= Self.expiryWindow
        }
        guard !expiringCredits.isEmpty else { return }

        let fingerprint = Self.summaryFingerprint(expiringCredits)
        // Account-scoped refreshes can alternate inventories, so remember more than the latest summary.
        var notifiedFingerprints = self.userDefaults.stringArray(forKey: Self.summaryFingerprintsKey) ?? []
        guard !notifiedFingerprints.contains(fingerprint) else { return }
        notifiedFingerprints.append(fingerprint)
        if notifiedFingerprints.count > Self.maximumRememberedSummaries {
            notifiedFingerprints.removeFirst(notifiedFingerprints.count - Self.maximumRememberedSummaries)
        }
        self.userDefaults.set(notifiedFingerprints, forKey: Self.summaryFingerprintsKey)

        let expiringSnapshot = CodexRateLimitResetCreditsSnapshot(
            credits: expiringCredits,
            availableCount: expiringCredits.count,
            updatedAt: now)
        guard let presentation = CodexResetCreditsPresentation.make(
            snapshot: expiringSnapshot,
            resetStyle: resetStyle,
            now: now)
        else {
            return
        }
        self.notificationPoster(
            Self.notificationPrefix,
            L("Limit Reset Credits"),
            presentation.helpText)
    }

    private static func summaryFingerprint(_ credits: [CodexRateLimitResetCredit]) -> String {
        let material = credits.map { credit in
            "\(credit.id)\u{1f}\(credit.expiresAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
