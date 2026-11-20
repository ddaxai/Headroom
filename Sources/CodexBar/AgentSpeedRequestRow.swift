import CodexBarCore
import Foundation

/// One reply in the per-request list shown on a speed card and in its submenu.
struct AgentSpeedRequestRow: Equatable, Sendable {
    static let placeholder = "—"
    /// Rows a card shows without opening the submenu.
    static let inlineLimit = 4

    let timestamp: Date
    /// Already shortened for display; see `AgentSpeedModelLabel`.
    let model: String?
    let speedText: String?
    let firstTokenText: String?
    let cacheHitText: String?
    /// False for replies too short to measure (tool calls, yes/no judgements). Their speed is still shown, dimmed,
    /// because a few tokens over a few milliseconds produce figures no model sustains.
    let countsAsRealUsage: Bool

    init(sample: AgentSpeedSample) {
        self.timestamp = sample.timestamp
        self.model = AgentSpeedModelLabel.short(sample.model, source: sample.source)
        if let speed = sample.effectiveSpeed {
            self.speedText = AgentSpeedSummary.formatTokensPerSecond(speed.tokensPerSecond, kind: speed.kind)
            self.countsAsRealUsage = true
        } else {
            // Mark the figure by the duration it was divided by, so "≈" only appears when the wait is included.
            let kind: AgentSpeedMeasurementKind = sample.streamingGenerationMs == nil
                ? .endToEndEstimated
                : .streamingExact
            self.speedText = sample.unfilteredTokensPerSecond.map {
                AgentSpeedSummary.formatTokensPerSecond($0, kind: kind)
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

    /// Deadline set by the newest request that read or wrote the prompt cache. A later request that missed the
    /// cache neither extends nor ends it. Only Claude logs state the cache tier.
    static func cacheExpiry(from summary: AgentSpeedSummary) -> Date? {
        summary.recentSamples.lazy.compactMap(\.cacheExpiresAt).first
    }

    /// "3m ago" / "3分钟前": shorter than a clock time and readable without knowing what time it is now.
    func ageText(now: Date = Date()) -> String {
        switch AgentSpeedRelativeAge(from: self.timestamp, now: now) {
        case .justNow: L("agent_speed_age_now")
        case let .minutes(count): L("agent_speed_age_minutes_format", count)
        case let .hours(count): L("agent_speed_age_hours_format", count)
        case let .days(count): L("agent_speed_age_days_format", count)
        }
    }

    /// Age, model, speed, first token, cache hit rate. Missing values are dashes.
    func columns(now: Date = Date()) -> [String] {
        [
            self.ageText(now: now),
            Self.truncatedModel(self.model),
            self.speedText ?? Self.placeholder,
            self.firstTokenText ?? Self.placeholder,
            self.cacheHitText ?? Self.placeholder,
        ]
    }

    static let speedColumnIndex = 2
    static let modelColumnCharacterLimit = 18

    static func truncatedModel(_ model: String?) -> String {
        guard let model else { return self.placeholder }
        guard model.count > self.modelColumnCharacterLimit else { return model }
        return String(model.prefix(self.modelColumnCharacterLimit - 1)) + "…"
    }

    static var columnTitles: [String] {
        [
            L("agent_speed_requests_column_time"),
            L("agent_speed_requests_column_model"),
            L("agent_speed_requests_column_speed"),
            L("agent_speed_requests_column_first_token"),
            L("agent_speed_requests_column_cache"),
        ]
    }
}
