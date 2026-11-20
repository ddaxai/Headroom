import Foundation

/// Short model names for the per-request list, where the full ID does not fit a narrow column.
public enum AgentSpeedModelLabel {
    private static let effortSuffixes: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]
    private static let genericGeminiTiers: Set<String> = ["pro", "flash", "ultra", "nano"]

    /// Antigravity: `gemini-9-quartz-high` and `Gemini 9 Quartz (High)` both become `quartz-high`. Other
    /// sources keep the ID their log states.
    public static func short(_ model: String?, source: LocalAgentSpeedSource) -> String? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard source == .antigravity else { return trimmed }

        let slug = LocalAgentSpeedScanner.normalizeAntigravityModelID(trimmed).lowercased()
        let parts = slug.split(separator: "-").map(String.init)
        if parts.first == "claude", parts.count > 1 {
            return parts.dropFirst().joined(separator: "-")
        }
        guard parts.count >= 3, parts[0] == "gemini", parts[1].first?.isNumber == true else { return slug }

        let rest = Array(parts.dropFirst(2))
        // `gemini-2.5-pro` has no codename, so the version is what tells two of them apart.
        if self.genericGeminiTiers.contains(rest[0]) {
            return parts.dropFirst().joined(separator: "-")
        }
        if rest.count > 1, let effort = rest.last, self.effortSuffixes.contains(effort) {
            return "\(rest[0])-\(effort)"
        }
        return rest[0]
    }
}

/// How long ago a request finished, coarse enough to stay a few characters wide.
public enum AgentSpeedRelativeAge: Equatable, Sendable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case days(Int)

    public init(from timestamp: Date, now: Date) {
        let seconds = now.timeIntervalSince(timestamp)
        if seconds < 60 {
            self = .justNow
        } else if seconds < 3600 {
            self = .minutes(Int(seconds / 60))
        } else if seconds < 86400 {
            self = .hours(Int(seconds / 3600))
        } else {
            self = .days(Int(seconds / 86400))
        }
    }
}
