import Foundation

enum HeadroomUpdaterPolicy {
    static func unavailabilityReason(
        feedURL: String?,
        isBundledApp: Bool,
        isHomebrew: Bool,
        isDeveloperIDSigned: Bool) -> String?
    {
        guard isBundledApp else {
            return "Updates unavailable in this build."
        }
        guard !isHomebrew else {
            return "Updates are managed by the package manager used to install Headroom."
        }
        guard let feedURL, !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Updates unavailable because this build has no Sparkle feed."
        }
        guard isDeveloperIDSigned else {
            return "Updates unavailable because this build is not signed with Developer ID."
        }
        return nil
    }
}
