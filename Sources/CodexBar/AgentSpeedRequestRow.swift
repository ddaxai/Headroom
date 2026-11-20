import CodexBarCore
import Foundation

/// One reply in the per-request list that opens from a speed card.
struct AgentSpeedRequestRow: Equatable, Sendable {
    static let placeholder = "—"

    let timestamp: Date
    let model: String?
    let outputTokens: Int
    let speedText: String?
    let firstTokenText: String?
    let cacheHitText: String?
    /// False for replies too short to measure (tool calls, yes/no judgements). Their speed is still shown, dimmed,
    /// because a few tokens over a few milliseconds produce figures no model sustains.
    let countsAsRealUsage: Bool

    init(sample: AgentSpeedSample) {
        self.timestamp = sample.timestamp
        let model = sample.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model?.isEmpty == false ? model : nil
        self.outputTokens = sample.outputTokens
        if let speed = sample.effectiveSpeed {
            self.speedText = AgentSpeedSummary.formatTokensPerSecond(speed.tokensPerSecond, kind: speed.kind)
            self.countsAsRealUsage = true
        } else {
            self.speedText = sample.unfilteredTokensPerSecond.map {
                AgentSpeedSummary.formatTokensPerSecond($0, kind: .endToEndEstimated)
            }
            self.countsAsRealUsage = false
        }
        self.firstTokenText = sample.firstTokenMs
            .flatMap { $0 > 0 ? AgentSpeedSummary.formatFirstTokenSeconds($0) : nil }
        self.cacheHitText = sample.cacheHitRate.map(AgentSpeedSummary.formatCacheHitRate)
    }

    static func rows(from summary: AgentSpeedSummary) -> [Self] {
        summary.recentSamples.map(Self.init(sample:))
    }

    /// When the newest request's prompt cache lapses. Only Claude logs state the cache tier.
    static func cacheExpiry(from summary: AgentSpeedSummary) -> Date? {
        summary.recentSamples.first?.cacheExpiresAt
    }
}
