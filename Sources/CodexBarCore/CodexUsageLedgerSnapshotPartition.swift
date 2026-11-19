import Foundation

/// Menu-card snapshots projected from one already-normalized Codex scan cache.
///
/// Every bucket is built from the same row generation, so official accounts,
/// relay profiles, and unassigned history remain a disjoint partition without
/// reopening the rollout files once per card.
public struct CodexUsageLedgerSnapshotPartition: Sendable, Equatable {
    public let fullCorpus: CostUsageTokenSnapshot?
    public let officialByAccountKey: [String: CostUsageTokenSnapshot]
    public let relayByProfileID: [UUID: CostUsageTokenSnapshot]
    public let relayAggregate: CostUsageTokenSnapshot?
    public let unassigned: CostUsageTokenSnapshot?
    public let coverageIsComplete: Bool

    public static func load(
        now: Date = Date(),
        sharedCodexHomePath: String,
        timeline: CodexSessionOwnershipTimeline,
        historyDays: Int = 30,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current,
        requireCurrentCorpus: Bool = false) -> Self?
    {
        let home = URL(fileURLWithPath: sharedCodexHomePath, isDirectory: true).standardizedFileURL
        let options = CostUsageScanner.Options(
            codexSessionsRoot: home.appendingPathComponent("sessions", isDirectory: true),
            cacheRoot: cacheRoot,
            calendar: calendar)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
        let cache = CostUsageScanner.codexCache(
            CostUsageCacheIO.load(provider: .codex, cacheRoot: cacheRoot),
            scopedTo: roots)
        if requireCurrentCorpus {
            // Menu publication is allowed to use a cache that is still catching up, as long as
            // it belongs to the exact source corpus currently on disk.  The partition retains
            // its partial-coverage marker; callers use the conservation check before publishing
            // it.  A missing or stale revision must still fail closed; older rows are not current.
            guard let currentRevision = CostUsageScanner.codexSessionCorpusRevision(roots: roots),
                  cache.codexCorpusRevision == currentRevision
            else { return nil }
        }
        let entries = cache.files
            .sorted { $0.key < $1.key }
            .flatMap { _, usage in
                CodexUsageLedgerAdapter.entries(
                    sessionID: usage.sessionId ?? usage.codexSession?.sessionId,
                    modelProvider: usage.codexSession?.modelProvider,
                    rows: usage.codexRows ?? [],
                    timeline: timeline)
            }
        guard !entries.isEmpty else { return nil }

        let updatedAt = cache.lastScanUnixMs > 0
            ? Date(timeIntervalSince1970: TimeInterval(cache.lastScanUnixMs) / 1000)
            : now
        let metadata = SnapshotMetadata(
            now: now,
            updatedAt: updatedAt,
            historyDays: max(1, min(365, historyDays)),
            calendar: calendar,
            corpusRevision: cache.codexCorpusRevision,
            coverageIsComplete: cache.codexCorpusCoverageIsComplete == true)
        let officialEntries = Dictionary(grouping: entries.filter(Self.isOfficial), by: \.key.identityID)
        let relayEntries = entries.filter(Self.isRelay)
        let relayEntriesByProfile = Dictionary(
            grouping: relayEntries.compactMap { entry in
                entry.key.routeProfileID.map { ($0, entry) }
            },
            by: \.0)

        // A cache can contain only rows outside the requested display window (for example,
        // immediately after a restart when the newest rollout has not been scanned yet).  Do
        // not return an empty partition in that state: callers use `nil` as the signal to run a
        // fresh corpus scan.  Returning a non-nil partition here would leave every menu card at
        // "no local usage" indefinitely while incorrectly treating the cache as publishable.
        guard let fullCorpus = Self.snapshot(entries: entries, metadata: metadata) else {
            return nil
        }

        return Self(
            fullCorpus: fullCorpus,
            officialByAccountKey: officialEntries.compactMapValues {
                Self.snapshot(entries: $0, metadata: metadata)
            },
            relayByProfileID: relayEntriesByProfile.compactMapValues { pairs in
                Self.snapshot(entries: pairs.map(\.1), metadata: metadata)
            },
            relayAggregate: Self.snapshot(entries: relayEntries, metadata: metadata),
            unassigned: Self.snapshot(
                entries: entries.filter { !Self.isOfficial($0) && !Self.isRelay($0) },
                metadata: metadata),
            coverageIsComplete: metadata.coverageIsComplete)
    }

    private struct SnapshotMetadata {
        let now: Date
        let updatedAt: Date
        let historyDays: Int
        let calendar: Calendar
        let corpusRevision: String?
        let coverageIsComplete: Bool
    }

    private struct AmountAccumulator {
        var input = 0
        var cacheRead = 0
        var output = 0
        var total = 0
        var requests = 0
        var cost = 0.0
        var hasUnpricedTokens = false

        mutating func add(_ entry: UsageLedgerEntry) {
            self.input += entry.amounts.inputTokens + entry.amounts.cacheReadTokens
            self.cacheRead += entry.amounts.cacheReadTokens
            self.output += entry.amounts.outputTokens
            self.total += entry.amounts.totalTokens
            self.requests += entry.amounts.requestCount
            if let cost = entry.amounts.costUSD {
                self.cost += cost
            } else if entry.amounts.totalTokens > 0 {
                self.hasUnpricedTokens = true
            }
        }

        var costUSD: Double? {
            self.hasUnpricedTokens ? nil : self.cost
        }
    }

    private static func snapshot(
        entries: [UsageLedgerEntry],
        metadata: SnapshotMetadata) -> CostUsageTokenSnapshot?
    {
        let start = metadata.calendar.date(
            byAdding: .day,
            value: -(metadata.historyDays - 1),
            to: metadata.calendar.startOfDay(for: metadata.now)) ?? metadata.now
        let windowEntries = entries.filter { entry in
            entry.key.timestamp >= start && entry.key.timestamp <= metadata.now
        }
        guard !windowEntries.isEmpty else { return nil }

        let entriesByDay = Dictionary(grouping: windowEntries) { entry in
            CostUsageLocalDay.key(from: entry.key.timestamp, calendar: metadata.calendar)
        }
        let daily = entriesByDay.keys.sorted().map { day -> CostUsageDailyReport.Entry in
            let entries = Dictionary(grouping: entriesByDay[day] ?? [], by: \.key.model)
            var dayAmounts = AmountAccumulator()
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []
            for model in entries.keys.sorted() {
                var modelAmounts = AmountAccumulator()
                for entry in entries[model] ?? [] {
                    modelAmounts.add(entry)
                    dayAmounts.add(entry)
                }
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: modelAmounts.costUSD,
                    totalTokens: modelAmounts.total,
                    requestCount: modelAmounts.requests))
            }
            return CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayAmounts.input,
                outputTokens: dayAmounts.output,
                cacheReadTokens: dayAmounts.cacheRead > 0 ? dayAmounts.cacheRead : nil,
                totalTokens: dayAmounts.total,
                requestCount: dayAmounts.requests,
                costUSD: dayAmounts.costUSD,
                modelsUsed: entries.keys.sorted(),
                modelBreakdowns: breakdowns)
        }
        var totals = AmountAccumulator()
        for entry in windowEntries {
            totals.add(entry)
        }
        let report = CostUsageDailyReport(
            data: daily,
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: totals.input,
                totalOutputTokens: totals.output,
                cacheReadTokens: totals.cacheRead > 0 ? totals.cacheRead : nil,
                totalTokens: totals.total,
                totalCostUSD: totals.costUSD))
        let rollingEntries = windowEntries.filter {
            UsageLedgerWindow.rolling24Hours.contains($0.key.timestamp, endingAt: metadata.now)
        }
        let rolling = Self.rollingSummary(entries: rollingEntries)
        let hourly = Self.hourlyEntries(
            entries: rollingEntries,
            calendar: metadata.calendar)
        return CostUsageFetcher.tokenSnapshot(
            from: report,
            now: metadata.now,
            historyDays: metadata.historyDays,
            calendar: metadata.calendar,
            rolling24Hours: rolling,
            hourly24Hours: hourly,
            codexCorpusRevision: metadata.corpusRevision,
            codexCorpusCoverageIsComplete: metadata.coverageIsComplete,
            updatedAt: metadata.updatedAt)
    }

    private static func rollingSummary(
        entries: [UsageLedgerEntry]) -> CostUsageRolling24HourSummary?
    {
        guard !entries.isEmpty else { return nil }
        var total = AmountAccumulator()
        for entry in entries {
            total.add(entry)
        }
        let providerBreakdowns = Dictionary(grouping: entries, by: Self.modelProvider)
            .map { provider, entries in
                var amounts = AmountAccumulator()
                for entry in entries {
                    amounts.add(entry)
                }
                return CostUsageModelProviderBreakdown(
                    modelProvider: provider,
                    totalTokens: amounts.total,
                    costUSD: amounts.costUSD)
            }
            .sorted { $0.modelProvider < $1.modelProvider }
        return CostUsageRolling24HourSummary(
            totalTokens: total.total,
            costUSD: total.costUSD,
            modelProviderBreakdowns: providerBreakdowns)
    }

    private static func hourlyEntries(
        entries: [UsageLedgerEntry],
        calendar: Calendar) -> [CostUsageHourlyEntry]
    {
        Dictionary(grouping: entries) { entry in
            calendar.dateInterval(of: .hour, for: entry.key.timestamp)?.start ?? entry.key.timestamp
        }
        .map { start, entries in
            var amounts = AmountAccumulator()
            for entry in entries {
                amounts.add(entry)
            }
            return CostUsageHourlyEntry(
                startDate: start,
                totalTokens: amounts.total,
                costUSD: amounts.costUSD)
        }
        .sorted { $0.startDate < $1.startDate }
    }

    private static func isOfficial(_ entry: UsageLedgerEntry) -> Bool {
        entry.attribution == .official
            && !entry.key.identityID.hasPrefix("system-unassigned:")
            && entry.key.identityID != UsageIdentity.systemUnassignedAccountKey
    }

    private static func isRelay(_ entry: UsageLedgerEntry) -> Bool {
        entry.attribution == .relay
            || entry.key.routeProfileID != nil
            || entry.key.identityID.hasPrefix("relay:")
            || entry.key.identityID.hasPrefix("api:")
    }

    private static func modelProvider(_ entry: UsageLedgerEntry) -> String {
        if self.isRelay(entry) { return CodexSessionProvenanceClassifier.relayProvider }
        if self.isOfficial(entry) { return CodexSessionProvenanceClassifier.officialProvider }
        return "unknown"
    }
}
