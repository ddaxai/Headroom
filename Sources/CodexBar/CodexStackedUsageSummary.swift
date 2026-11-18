import CodexBarCore
import Foundation

enum CodexStackedUsageSummary {
    static func mergedUnassignedSnapshot(_ snapshots: [CostUsageTokenSnapshot]) -> CostUsageTokenSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        guard snapshots.count > 1 else { return snapshots[0] }
        let daily = CostUsageDailyReport.merged(snapshots.map { .init(data: $0.daily, summary: nil) }).data
        let hourly = Dictionary(grouping: snapshots.flatMap(\.hourly24Hours), by: \.startDate).map { date, entries in
            CostUsageHourlyEntry(
                startDate: date,
                totalTokens: entries.reduce(0) { $0 + $1.totalTokens },
                costUSD: Self.optionalSum(entries.map(\.costUSD)),
                modelProviderBreakdowns: Self.mergedProviderBreakdowns(entries.map(\.modelProviderBreakdowns)))
        }.sorted { $0.startDate < $1.startDate }
        let rolling = snapshots.compactMap(Self.rolling24Hours(from:))
        let mergedRolling: CostUsageRolling24HourSummary? = rolling.count == snapshots.count
            ? .init(
                totalTokens: rolling.reduce(0) { $0 + $1.totalTokens },
                costUSD: Self.optionalSum(rolling.map(\.costUSD)),
                modelProviderBreakdowns: Self.mergedProviderBreakdowns(rolling.map(\.modelProviderBreakdowns)))
            : nil
        let corpusRevisions = snapshots.compactMap(\.codexCorpusRevision)
        let corpusRevision = corpusRevisions.count == snapshots.count && Set(corpusRevisions).count == 1
            ? corpusRevisions.first
            : nil
        return CostUsageTokenSnapshot(
            sessionTokens: Self.optionalSum(snapshots.map(\.sessionTokens)),
            sessionCostUSD: Self.optionalSum(snapshots.map(\.sessionCostUSD)),
            sessionRequests: Self.optionalSum(snapshots.map(\.sessionRequests)),
            last30DaysTokens: Self.optionalSum(snapshots.map(\.last30DaysTokens)),
            last30DaysCostUSD: Self.optionalSum(snapshots.map(\.last30DaysCostUSD)),
            last30DaysRequests: Self.optionalSum(snapshots.map(\.last30DaysRequests)),
            rolling24Hours: mergedRolling,
            hourly24Hours: hourly,
            currencyCode: snapshots.first?.currencyCode ?? "USD",
            historyDays: snapshots.map(\.historyDays).min() ?? 30,
            historyCoverageIsEstablished: snapshots.allSatisfy(\.historyCoverageIsEstablished),
            codexCorpusRevision: corpusRevision,
            codexCorpusCoverageIsComplete: corpusRevision == nil
                ? false
                : snapshots.allSatisfy { $0.codexCorpusCoverageIsComplete == true },
            daily: daily,
            projects: Self.mergedProjects(snapshots.flatMap(\.projects)),
            sessions: Self.mergedSessions(snapshots.flatMap(\.sessions)),
            updatedAt: snapshots.map(\.updatedAt).min() ?? Date())
    }

    private static func mergedProviderBreakdowns(
        _ groups: [[CostUsageModelProviderBreakdown]]) -> [CostUsageModelProviderBreakdown]
    {
        Dictionary(grouping: groups.flatMap(\.self), by: \.modelProvider)
            .map { provider, values in
                CostUsageModelProviderBreakdown(
                    modelProvider: provider,
                    totalTokens: values.reduce(0) { $0 + $1.totalTokens },
                    costUSD: Self.optionalSum(values.map(\.costUSD)))
            }
            .sorted { $0.modelProvider < $1.modelProvider }
    }

    private static func mergedProjects(
        _ projects: [CostUsageProjectBreakdown]) -> [CostUsageProjectBreakdown]
    {
        Dictionary(grouping: projects, by: { "\($0.path ?? "")\u{0}\($0.name)" })
            .map { _, values in
                let first = values[0]
                return CostUsageProjectBreakdown(
                    name: first.name,
                    path: first.path,
                    totalTokens: Self.optionalSum(values.map(\.totalTokens)),
                    totalCostUSD: Self.optionalSum(values.map(\.totalCostUSD)),
                    daily: CostUsageDailyReport.merged(values.map { .init(data: $0.daily, summary: nil) }).data,
                    modelBreakdowns: Self.mergedModelBreakdowns(values.compactMap(\.modelBreakdowns)),
                    sources: Self.mergedProjectSources(values.flatMap(\.sources)))
            }
            .sorted { lhs, rhs in
                (lhs.path ?? lhs.name) < (rhs.path ?? rhs.name)
            }
    }

    private static func mergedProjectSources(
        _ sources: [CostUsageProjectSourceBreakdown]) -> [CostUsageProjectSourceBreakdown]
    {
        Dictionary(grouping: sources, by: { "\($0.path ?? "")\u{0}\($0.name)" })
            .map { _, values in
                let first = values[0]
                return CostUsageProjectSourceBreakdown(
                    name: first.name,
                    path: first.path,
                    totalTokens: Self.optionalSum(values.map(\.totalTokens)),
                    totalCostUSD: Self.optionalSum(values.map(\.totalCostUSD)),
                    daily: CostUsageDailyReport.merged(values.map { .init(data: $0.daily, summary: nil) }).data,
                    modelBreakdowns: Self.mergedModelBreakdowns(values.compactMap(\.modelBreakdowns)))
            }
            .sorted { lhs, rhs in
                (lhs.path ?? lhs.name) < (rhs.path ?? rhs.name)
            }
    }

    private static func mergedSessions(
        _ sessions: [CostUsageSessionBreakdown]) -> [CostUsageSessionBreakdown]
    {
        Dictionary(grouping: sessions, by: \.sessionID)
            .map { sessionID, values in
                let first = values[0]
                return CostUsageSessionBreakdown(
                    sessionID: sessionID,
                    lastActivity: values.map(\.lastActivity).max() ?? first.lastActivity,
                    inputTokens: Self.optionalSum(values.map(\.inputTokens)),
                    cachedInputTokens: Self.optionalSum(values.map(\.cachedInputTokens)),
                    outputTokens: Self.optionalSum(values.map(\.outputTokens)),
                    totalTokens: Self.optionalSum(values.map(\.totalTokens)),
                    requestCount: Self.optionalSum(values.map(\.requestCount)),
                    costUSD: Self.optionalSum(values.map(\.costUSD)),
                    modelBreakdowns: Self.mergedModelBreakdowns(values.map(\.modelBreakdowns)) ?? [])
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func mergedModelBreakdowns(
        _ groups: [[CostUsageDailyReport.ModelBreakdown]]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        guard !groups.isEmpty else { return nil }
        return CostUsageDailyReport.merged(groups.map {
            .init(data: [.init(
                date: "aggregate",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: nil,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: $0)], summary: nil)
        }).data.first?.modelBreakdowns
    }

    private static func optionalSum<T: BinaryInteger>(_ values: [T?]) -> T? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap(\.self).reduce(0, +)
    }

    private static func optionalSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap(\.self).reduce(0, +)
    }

    static let relayModelProvider = "codexbar_relay"
    static let officialModelProvider = "openai"

    static func officialTotal(_ snapshots: [CostUsageTokenSnapshot]) -> CostUsageRolling24HourSummary? {
        self.providerTotal(self.officialModelProvider, snapshots: snapshots)
    }

    static func relayTotal(_ snapshots: [CostUsageTokenSnapshot]) -> CostUsageRolling24HourSummary? {
        self.providerTotal(self.relayModelProvider, snapshots: snapshots)
    }

    private static func providerTotal(
        _ modelProvider: String,
        snapshots: [CostUsageTokenSnapshot]) -> CostUsageRolling24HourSummary?
    {
        let summaries = snapshots.flatMap { snapshot in
            snapshot.rolling24Hours?.modelProviderBreakdowns.filter {
                $0.modelProvider == modelProvider
            } ?? []
        }.map { breakdown in
            CostUsageRolling24HourSummary(
                totalTokens: breakdown.totalTokens,
                costUSD: breakdown.costUSD)
        }
        return self.aggregate(summaries)
    }

    static func menuTotal(
        accountSnapshots: [CostUsageTokenSnapshot],
        expectedAccountCount: Int,
        sharedSnapshot: CostUsageTokenSnapshot?,
        fullCorpusSnapshot: CostUsageTokenSnapshot? = nil) -> CostUsageRolling24HourSummary?
    {
        _ = expectedAccountCount
        if let fullCorpusSnapshot,
           let total = self.rolling24Hours(from: fullCorpusSnapshot)
        {
            return total
        }
        if let fullCorpusSnapshot,
           self.hasTrackedUsage(fullCorpusSnapshot)
        {
            return CostUsageRolling24HourSummary(totalTokens: 0, costUSD: nil)
        }
        let snapshots = accountSnapshots + (sharedSnapshot.map { [$0] } ?? [])
        return self.aggregate(snapshots.compactMap(Self.rolling24Hours(from:)))
    }

    static func hasTrackedUsage(_ snapshot: CostUsageTokenSnapshot) -> Bool {
        !snapshot.daily.isEmpty || !snapshot.projects.isEmpty || !snapshot.sessions.isEmpty ||
            snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil ||
            snapshot.last30DaysRequests != nil
    }

    static func unassignedTotal(
        accountSnapshots: [CostUsageTokenSnapshot],
        relaySnapshot: CostUsageTokenSnapshot?,
        sharedSnapshot: CostUsageTokenSnapshot?,
        fullCorpusSnapshot: CostUsageTokenSnapshot?) -> CostUsageRolling24HourSummary?
    {
        if let sharedSnapshot,
           let shared = self.rolling24Hours(from: sharedSnapshot),
           shared.totalTokens > 0
        {
            return shared
        }
        guard let fullCorpusSnapshot,
              let full = self.rolling24Hours(from: fullCorpusSnapshot)
        else { return nil }
        let assigned = self.aggregate(
            accountSnapshots.compactMap(Self.rolling24Hours(from:))
                + [relaySnapshot.flatMap(Self.rolling24Hours)].compactMap(\.self))
        let assignedTokens = assigned?.totalTokens ?? 0
        guard full.totalTokens > assignedTokens else { return nil }
        let costUSD: Double? = if let fullCost = full.costUSD {
            max(0, fullCost - (assigned?.costUSD ?? 0))
        } else {
            nil
        }
        return CostUsageRolling24HourSummary(
            totalTokens: full.totalTokens - assignedTokens,
            costUSD: costUSD)
    }

    static func shareCorpusGeneration(_ snapshots: [CostUsageTokenSnapshot]) -> Bool {
        guard let first = snapshots.first,
              let revision = first.codexCorpusRevision,
              first.codexCorpusCoverageIsComplete == true
        else { return false }
        return snapshots.dropFirst().allSatisfy {
            $0.codexCorpusRevision == revision && $0.codexCorpusCoverageIsComplete == true
        }
    }

    static func isConservedPartition(
        total: CostUsageRolling24HourSummary?,
        official: [CostUsageRolling24HourSummary],
        relay: CostUsageRolling24HourSummary?,
        unassigned: CostUsageRolling24HourSummary?) -> Bool
    {
        guard let total else { return false }
        let components = official + [relay, unassigned].compactMap(\.self)
        guard components.reduce(0, { $0 + $1.totalTokens }) == total.totalTokens else { return false }
        let componentCosts = components.map(\.costUSD)
        guard let totalCost = total.costUSD, componentCosts.allSatisfy({ $0 != nil }) else {
            return total.costUSD == nil
        }
        let sum = componentCosts.compactMap(\.self).reduce(0, +)
        return abs(sum - totalCost) < 0.000_001
    }

    /// A large live rollout corpus can require more than one bounded scan. During that catch-up
    /// there is no complete corpus revision yet, but independently filtered snapshots are still
    /// safe to publish when every participant is explicitly partial and their totals conserve
    /// exactly. Mixed complete/partial generations continue to fail closed.
    static func isPublishableMenuPartition(
        fullCorpusSnapshot: CostUsageTokenSnapshot,
        officialSnapshots: [CostUsageTokenSnapshot],
        relaySnapshot: CostUsageTokenSnapshot?,
        unassignedSnapshot: CostUsageTokenSnapshot?) -> Bool
    {
        let snapshots = [fullCorpusSnapshot]
            + officialSnapshots
            + [relaySnapshot, unassignedSnapshot].compactMap(\.self)
        let hasOneCompleteGeneration = self.shareCorpusGeneration(snapshots)
        let isExplicitlyPartial = snapshots.allSatisfy { $0.codexCorpusCoverageIsComplete == false }
        guard hasOneCompleteGeneration || isExplicitlyPartial else { return false }
        return self.isConservedPartition(
            total: self.rolling24Hours(from: fullCorpusSnapshot),
            official: officialSnapshots.compactMap(self.rolling24Hours(from:)),
            relay: relaySnapshot.flatMap(self.rolling24Hours(from:)),
            unassigned: unassignedSnapshot.flatMap(self.rolling24Hours(from:)))
    }

    static func rolling24Hours(from snapshot: CostUsageTokenSnapshot) -> CostUsageRolling24HourSummary? {
        if let rolling24Hours = snapshot.rolling24Hours {
            return rolling24Hours
        }
        if !snapshot.hourly24Hours.isEmpty {
            return self.aggregate(snapshot.hourly24Hours.map {
                CostUsageRolling24HourSummary(totalTokens: $0.totalTokens, costUSD: $0.costUSD)
            })
        }
        let currentDay = snapshot.currentDayEntry()
        guard let tokens = currentDay?.totalTokens else { return nil }
        return CostUsageRolling24HourSummary(totalTokens: tokens, costUSD: currentDay?.costUSD)
    }

    static func line(
        _ summary: CostUsageRolling24HourSummary?,
        preferredCurrencyCode: String,
        emptyText: String,
        estimateSnapshot: CostUsageTokenSnapshot? = nil) -> String
    {
        guard let summary else { return emptyText }
        let exactCost = summary.costUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: "USD")
        }
        let estimatedCost = estimateSnapshot.flatMap(self.estimatedRollingCost).map {
            "≈" + UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: "USD")
        }
        let cost = exactCost ?? estimatedCost ?? "—"
        let tokens = summary.totalTokens == 0
            ? "0"
            : UsageFormatter.tokenCountString(summary.totalTokens)
        return "24h: \(tokens) tokens · \(cost)"
    }

    static func unassignedLine(
        _ summary: CostUsageRolling24HourSummary?,
        label: String,
        preferredCurrencyCode: String,
        estimateSnapshot: CostUsageTokenSnapshot? = nil) -> String?
    {
        guard let summary, summary.totalTokens > 0 else { return nil }
        let exactCost = summary.costUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: "USD")
        }
        let estimatedCost = estimateSnapshot.flatMap(self.estimatedRollingCost).map {
            "≈" + UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: "USD")
        }
        return "\(label) \(UsageFormatter.tokenCountString(summary.totalTokens)) tokens · "
            + (exactCost ?? estimatedCost ?? "—")
    }

    static func estimatedRollingCost(snapshot: CostUsageTokenSnapshot) -> Double? {
        guard let rollingTokens = snapshot.rolling24Hours?.totalTokens, rollingTokens > 0 else { return nil }
        for (cost, tokens) in [
            (snapshot.last30DaysCostUSD, snapshot.last30DaysTokens),
            (snapshot.sessionCostUSD, snapshot.sessionTokens),
        ] {
            guard let cost, let tokens, cost >= 0, tokens > 0 else { continue }
            return cost * Double(rollingTokens) / Double(tokens)
        }
        return nil
    }

    private static func aggregate(
        _ summaries: [CostUsageRolling24HourSummary]) -> CostUsageRolling24HourSummary?
    {
        guard !summaries.isEmpty else { return nil }
        let totalTokens = summaries.reduce(0) { $0 + $1.totalTokens }
        let costs = summaries.compactMap(\.costUSD)
        let costUSD = costs.count == summaries.count ? costs.reduce(0, +) : nil
        return CostUsageRolling24HourSummary(totalTokens: totalTokens, costUSD: costUSD)
    }
}
