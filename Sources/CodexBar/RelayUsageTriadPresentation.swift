import CodexBarCore
import Foundation

/// The three independent accounting authorities shown on a relay card.
///
/// Local values are estimates derived from the M4 ledger. Provider values are copied from the
/// relay response, and balance is kept as a separate monetary/credit value. A missing authority
/// remains missing; this type never fills one lane from another lane.
struct RelayUsageTriadPresentation: Equatable, Sendable {
    enum MetricID: String, CaseIterable, Hashable, Sendable {
        case localBaseTokens
        case providerReportedTokens
        case balance

        var titleKey: String {
            switch self {
            case .localBaseTokens: "relay_usage_triad_local_base_tokens"
            case .providerReportedTokens: "relay_usage_triad_provider_reported"
            case .balance: "relay_usage_triad_balance"
            }
        }

        var localizedTitle: String {
            switch self {
            case .localBaseTokens: L("relay_usage_triad_local_base_tokens")
            case .providerReportedTokens: L("relay_usage_triad_provider_reported")
            case .balance: L("relay_usage_triad_balance")
            }
        }
    }

    enum DetailID: String, Sendable {
        case noData = "relay_usage_triad_no_data"
        case localEstimate = "relay_usage_triad_local_estimate"
        case unsupported = "local_meter_protocol_unsupported"
        case providerReported = "relay_usage_triad_provider_reported"
        case balance = "relay_usage_triad_balance"
        case cacheAccounting = "relay_usage_triad_cache_accounting_note"

        var localizedText: String {
            switch self {
            case .noData: L("relay_usage_triad_no_data")
            case .localEstimate: L("relay_usage_triad_local_estimate")
            case .unsupported: L("local_meter_protocol_unsupported")
            case .providerReported: L("relay_usage_triad_provider_reported")
            case .balance: L("relay_usage_triad_balance")
            case .cacheAccounting: L("relay_usage_triad_cache_accounting_note")
            }
        }
    }

    struct Metric: Equatable, Identifiable, Sendable {
        let id: MetricID
        let valueText: String?
        let detail: DetailID
        let detailText: String?
        let tooltipText: String?

        var detailKey: String {
            self.detail.rawValue
        }
    }

    private struct MetricValues {
        let localMeterStatus: LocalMeterProtocolStatus
        let localBaseTokens: Int?
        let localEstimatedCostUSD: Double?
        let providerReportedTokens: Int?
        let balance: Double?
        let actualChargedUSD: Double?
        let hasReportedCacheTokens: Bool
        let preferredCurrencyCode: String
        let balanceUnit: String?
    }

    let localBaseTokens: Int?
    let localEstimatedCostUSD: Double?
    let providerReportedTokens: Int?
    let balance: Double?
    let actualChargedUSD: Double?
    let hasReportedCacheTokens: Bool
    let effectiveMultiplier: Double?
    let localMeterStatus: LocalMeterProtocolStatus
    let balanceUnit: String?
    let recentPeriod: RelayRecentUsageSummary.Period?
    let metrics: [Metric]

    static func resolve(
        localSnapshot: CostUsageTokenSnapshot?,
        providerSummary: RelayUsageSummary?,
        apiFormat: RelayAPIFormat,
        preferredCurrencyCode: String,
        localMeterStatus explicitLocalMeterStatus: LocalMeterProtocolStatus? = nil,
        hasUnmeteredClientTargets: Bool = false) -> Self
    {
        let localMeterStatus = explicitLocalMeterStatus
            ?? LocalMeterProtocolSupport.status(for: apiFormat)
        let localBaseTokens: Int? = if localMeterStatus == .supported {
            Self.exactRollingTokens(from: localSnapshot)
        } else {
            nil
        }
        let localEstimatedCostUSD: Double? = if localMeterStatus == .supported {
            Self.exactRollingCostUSD(from: localSnapshot)
        } else {
            nil
        }
        let recent = providerSummary?.recentUsage
        let providerReportedTokens = recent?.totalTokens
        let balance = providerSummary?.remaining
        let actualChargedUSD = recent?.actualCostUSD
        let hasReportedCacheTokens = recent?.hasReportedCacheTokens == true
        let effectiveMultiplier: Double?
        if recent?.period == .rolling24Hours,
           !hasUnmeteredClientTargets,
           let localBaseTokens,
           localBaseTokens > 0,
           let providerReportedTokens,
           !hasReportedCacheTokens
        {
            let ratio = Double(providerReportedTokens) / Double(localBaseTokens)
            effectiveMultiplier = ratio.isFinite && abs(ratio - 1) > 0.01 ? ratio : nil
        } else {
            effectiveMultiplier = nil
        }

        let metricValues = MetricValues(
            localMeterStatus: localMeterStatus,
            localBaseTokens: localBaseTokens,
            localEstimatedCostUSD: localEstimatedCostUSD,
            providerReportedTokens: providerReportedTokens,
            balance: balance,
            actualChargedUSD: actualChargedUSD,
            hasReportedCacheTokens: hasReportedCacheTokens,
            preferredCurrencyCode: preferredCurrencyCode,
            balanceUnit: providerSummary?.unit)
        let metrics = MetricID.allCases.map { id in
            Self.metric(id: id, values: metricValues)
        }
        return Self(
            localBaseTokens: localBaseTokens,
            localEstimatedCostUSD: localEstimatedCostUSD,
            providerReportedTokens: providerReportedTokens,
            balance: balance,
            actualChargedUSD: actualChargedUSD,
            hasReportedCacheTokens: hasReportedCacheTokens,
            effectiveMultiplier: effectiveMultiplier,
            localMeterStatus: localMeterStatus,
            balanceUnit: providerSummary?.unit,
            recentPeriod: recent?.period,
            metrics: metrics)
    }

    var localStatusKey: String {
        self.localMeterStatus == .unsupported
            ? "local_meter_protocol_unsupported"
            : "relay_usage_triad_local_base_tokens"
    }

    var multiplierText: String? {
        self.effectiveMultiplier.map {
            String(format: "%.2f×", locale: Locale(identifier: "en_US_POSIX"), $0)
        }
    }

    var cacheAccountingTooltip: String? {
        self.hasReportedCacheTokens ? DetailID.cacheAccounting.localizedText : nil
    }

    var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            "status=\(self.localMeterStatus.rawValue)",
            "localization=\(codexBarLocalizationSignature())",
            "rawLocal=\(self.localBaseTokens.map(String.init) ?? "nil")",
            "rawProvider=\(self.providerReportedTokens.map(String.init) ?? "nil")",
            "rawBalance=\(self.balance.map(String.init(describing:)) ?? "nil")",
            "rawCharged=\(self.actualChargedUSD.map(String.init(describing:)) ?? "nil")",
            MenuCardHeightFingerprint.field("period", self.recentPeriod?.rawValue),
            MenuCardHeightFingerprint.field("unit", self.balanceUnit),
            MenuCardHeightFingerprint.join(self.metrics.map { metric in
                MenuCardHeightFingerprint.join([
                    metric.id.rawValue,
                    MenuCardHeightFingerprint.field("value", metric.valueText),
                    metric.detailKey,
                    MenuCardHeightFingerprint.field("detail", metric.detailText),
                ])
            }),
            MenuCardHeightFingerprint.field("multiplier", self.multiplierText),
        ])
    }

    private static func metric(id: MetricID, values: MetricValues) -> Metric {
        switch id {
        case .localBaseTokens:
            if values.localMeterStatus == .unsupported {
                return Metric(
                    id: id,
                    valueText: nil,
                    detail: .unsupported,
                    detailText: nil,
                    tooltipText: nil)
            }
            return Metric(
                id: id,
                valueText: values.localBaseTokens.map(UsageFormatter.tokenCountString),
                detail: values.localBaseTokens == nil ? .noData : .localEstimate,
                detailText: nil,
                tooltipText: Self.localMetricTooltip(values: values))
        case .providerReportedTokens:
            return Metric(
                id: id,
                valueText: self.tokenValue(values.providerReportedTokens),
                detail: values.providerReportedTokens == nil ? .noData : .providerReported,
                detailText: values.actualChargedUSD.map {
                    L("relay_usage_triad_charged_format", UsageFormatter.convertedCostString(
                        $0,
                        preferredCurrency: values.preferredCurrencyCode,
                        providerCurrency: "USD"))
                },
                tooltipText: values.hasReportedCacheTokens
                    ? DetailID.cacheAccounting.localizedText
                    : nil)
        case .balance:
            return Metric(
                id: id,
                valueText: values.balance.map {
                    Self.balanceValueText(
                        $0,
                        unit: values.balanceUnit,
                        preferredCurrencyCode: values.preferredCurrencyCode)
                },
                detail: values.balance == nil ? .noData : .balance,
                detailText: nil,
                tooltipText: nil)
        }
    }

    private static func balanceValueText(
        _ value: Double,
        unit: String?,
        preferredCurrencyCode: String) -> String
    {
        let sourceUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceCode = sourceUnit.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        let normalizedCode = sourceCode.uppercased() == "RMB" ? "CNY" : sourceCode.uppercased()
        guard CurrencyExchange.supportedCurrencies.contains(normalizedCode) else {
            return "\(UsageFormatter.creditsNumberString(from: value)) \(sourceCode)"
        }
        return UsageFormatter.convertedCostString(
            value,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: normalizedCode)
    }

    private static func tokenValue(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value == 0 ? "0" : UsageFormatter.tokenCountString(value)
    }

    private static func exactRollingTokens(from snapshot: CostUsageTokenSnapshot?) -> Int? {
        guard let snapshot else { return nil }
        if let rolling = snapshot.rolling24Hours {
            return max(0, rolling.totalTokens)
        }
        guard !snapshot.hourly24Hours.isEmpty else { return nil }
        return max(0, snapshot.hourly24Hours.reduce(0) { $0 + $1.totalTokens })
    }

    private static func exactRollingCostUSD(from snapshot: CostUsageTokenSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        if let cost = snapshot.rolling24Hours?.costUSD, cost > 0 {
            return cost
        }
        let hourlyCosts = snapshot.hourly24Hours.compactMap(\.costUSD)
        guard !hourlyCosts.isEmpty else { return nil }
        let total = hourlyCosts.reduce(0, +)
        return total > 0 ? total : nil
    }

    private static func localMetricTooltip(values: MetricValues) -> String? {
        guard values.localBaseTokens != nil else { return nil }
        guard let costUSD = values.localEstimatedCostUSD else {
            return L("relay_usage_triad_local_tooltip")
        }
        let costText = UsageFormatter.convertedCostString(
            costUSD,
            preferredCurrency: values.preferredCurrencyCode,
            providerCurrency: "USD")
        return L("relay_usage_triad_local_tooltip_with_cost", costText)
    }
}

/// Geometry policy for the triad. The menu card keeps a three-column presentation when there is
/// enough room for readable values and falls back to stacked rows at narrow widths.
enum RelayUsageTriadLayout {
    static let horizontalPadding: CGFloat = 24
    static let detailRailWidth: CGFloat = CardDetailRail.width
    static let interitemSpacing: CGFloat = 8
    static let minimumColumnWidth: CGFloat = 68
    /// Minimum height reserved for one metric in the horizontal presentation.  The value is
    /// shared by the view and the pure geometry model so a missing value cannot collapse a lane.
    static let columnMetricHeight: CGFloat = 48
    /// Rows always include a value line and a detail line (including the "not available" detail).
    static let rowMetricHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 4
    static let multiplierSpacing: CGFloat = 6
    static let multiplierHeight: CGFloat = 16

    enum Mode: Equatable, Sendable {
        case columns
        case rows
    }

    static func contentWidth(forCardWidth cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - self.horizontalPadding - self.detailRailWidth)
    }

    static func columnsFit(cardWidth: CGFloat, metricCount: Int) -> Bool {
        guard metricCount > 0 else { return true }
        let contentWidth = Self.contentWidth(forCardWidth: cardWidth)
        let spacing = Self.interitemSpacing * CGFloat(max(0, metricCount - 1))
        return contentWidth - spacing >= Self.minimumColumnWidth * CGFloat(metricCount)
    }

    static func mode(forCardWidth cardWidth: CGFloat) -> Mode {
        self.columnsFit(cardWidth: cardWidth, metricCount: 3) ? .columns : .rows
    }

    /// Returns one stable height per metric for the selected orientation.  The metric contents
    /// deliberately do not affect the result: placeholders and reported values occupy the same
    /// row, preventing the card from jumping when one accounting authority is unavailable.
    static func metricHeights(
        for presentation: RelayUsageTriadPresentation,
        cardWidth: CGFloat) -> [CGFloat]
    {
        let height = self.mode(forCardWidth: cardWidth) == .columns
            ? self.columnMetricHeight
            : self.rowMetricHeight
        return presentation.metrics.map { _ in height }
    }

    /// Predicts the triad's content height using the same orientation and lane constants as the
    /// SwiftUI view.  The multiplier is an additional line and never changes any lane's value.
    static func contentHeight(
        for presentation: RelayUsageTriadPresentation,
        cardWidth: CGFloat) -> CGFloat
    {
        let mode = self.mode(forCardWidth: cardWidth)
        let metricHeights = self.metricHeights(for: presentation, cardWidth: cardWidth)
        let metricsHeight: CGFloat
        let interMetricHeight: CGFloat
        switch mode {
        case .columns:
            metricsHeight = metricHeights.max() ?? 0
            interMetricHeight = 0
        case .rows:
            metricsHeight = metricHeights.reduce(0, +)
            interMetricHeight = self.rowSpacing * CGFloat(max(0, metricHeights.count - 1))
        }
        let multiplierHeight = presentation.effectiveMultiplier == nil
            ? 0
            : self.multiplierSpacing + self.multiplierHeight
        return metricsHeight + interMetricHeight + multiplierHeight
    }
}
