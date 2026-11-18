/// Presentation-facing name for the live usage domain.
///
/// Keeping the name at the domain boundary prevents views and AppKit presentation controllers
/// from depending on the concrete store name while preserving the single observable instance.
typealias UsageDomain = UsageStore
