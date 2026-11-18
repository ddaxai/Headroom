/// Shared publication state for local session-derived usage.
///
/// Consumers must not collapse an unreadable source or an in-flight scan into a
/// confirmed empty result: those states have different recovery and UI semantics.
public enum LocalUsageState: String, Sendable, Equatable {
    case unavailable
    case loading
    case empty
    case available
}
