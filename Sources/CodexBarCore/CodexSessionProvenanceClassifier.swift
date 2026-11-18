import Foundation

public enum CodexSessionProvenance: Equatable, Sendable {
    case official(accountKey: String?)
    case relay(profileID: UUID?)
    case unassigned
}

public enum CodexSessionProvenanceClassifier {
    public static let officialProvider = "openai"
    public static let relayProvider = "codexbar_relay"
    public static let sharedProvider = "codexbar_shared"

    public static func classify(
        timestampUnixMs: Int64?,
        modelProvider: String?,
        timeline: CodexSessionOwnershipTimeline) -> CodexSessionProvenance
    {
        guard let timestampUnixMs else { return .unassigned }
        let provider = modelProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch provider {
        case Self.officialProvider:
            return .official(accountKey: timeline.ownerAccountKey(atUnixMilliseconds: timestampUnixMs))
        case Self.relayProvider:
            if case let .relay(profileID)? = timeline.codexRoute(atUnixMilliseconds: timestampUnixMs) {
                return .relay(profileID: profileID)
            }
            return .relay(profileID: nil)
        case Self.sharedProvider:
            switch timeline.codexRoute(atUnixMilliseconds: timestampUnixMs) {
            case .official:
                return .official(accountKey: timeline.ownerAccountKey(atUnixMilliseconds: timestampUnixMs))
            case let .relay(profileID):
                return .relay(profileID: profileID)
            case .unknown, nil:
                return .unassigned
            }
        default:
            return .unassigned
        }
    }
}
