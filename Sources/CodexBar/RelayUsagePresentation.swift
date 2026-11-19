import CodexBarCore
import Foundation

enum RelayUsagePresentation {
    static func remainingLine(_ summary: RelayUsageSummary) -> String? {
        summary.remaining.map { L("relay_usage_line_remaining", self.value($0, unit: summary.unit)) }
    }

    static func detailLine(_ summary: RelayUsageSummary) -> String? {
        var parts: [String] = []
        if let used = summary.used, let total = summary.total {
            parts.append(L(
                "relay_usage_line_used_of_total",
                self.value(used, unit: summary.unit),
                self.value(total, unit: summary.unit)))
        } else if let used = summary.used {
            parts.append(L("relay_usage_line_used", self.value(used, unit: summary.unit)))
        } else if let total = summary.total {
            parts.append(L("relay_usage_line_total", self.value(total, unit: summary.unit)))
        }
        if let planName = summary.planName {
            parts.append(planName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func summaryLine(_ summary: RelayUsageSummary) -> String {
        let parts = [self.remainingLine(summary), self.detailLine(summary)].compactMap(\.self)
        return parts.joined(separator: " · ")
    }

    static func recentUsageLine(_ summary: RelayUsageSummary) -> String? {
        guard let recent = summary.recentUsage else { return nil }
        let period = recent.period == .rolling24Hours ? "24h" : L("Today")
        let tokens = UsageFormatter.tokenCountString(recent.totalTokens)
        let cost = recent.actualCostUSD.formatted(.number.precision(.fractionLength(2)))
        return "\(period): \(tokens) tokens · $\(cost)"
    }

    static func costUsageSnapshot(_ summary: RelayUsageSummary) -> CostUsageTokenSnapshot? {
        guard let recent = summary.recentUsage else { return nil }
        let historyLabel = recent.period == .rolling24Hours ? "24h" : L("Today")
        return CostUsageTokenSnapshot(
            sessionTokens: recent.totalTokens,
            sessionCostUSD: recent.actualCostUSD,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            rolling24Hours: CostUsageRolling24HourSummary(
                totalTokens: recent.totalTokens,
                costUSD: recent.actualCostUSD),
            hourly24Hours: [],
            currencyCode: "USD",
            historyDays: 1,
            historyCoverageIsEstablished: false,
            historyLabel: historyLabel,
            daily: [],
            updatedAt: summary.updatedAt)
    }

    private static func value(_ value: Double, unit: String) -> String {
        let formatted = value.formatted(.number.precision(.fractionLength(0...2)))
        switch unit.uppercased() {
        case "USD": return "$\(formatted)"
        case "CNY", "RMB": return "¥\(formatted)"
        default: return "\(formatted) \(unit)"
        }
    }
}
