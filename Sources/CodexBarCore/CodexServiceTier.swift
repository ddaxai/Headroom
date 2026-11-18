import Foundation

/// A requested speed preference, not evidence of the tier granted by the upstream.
public enum CodexServiceTier: String, CaseIterable, Equatable, Sendable {
    case standard = "default"
    case fast

    public static func configured(in data: Data?) throws -> Self? {
        try RelayConfigurationRenderer.codexServiceTier(in: data)
    }
}
