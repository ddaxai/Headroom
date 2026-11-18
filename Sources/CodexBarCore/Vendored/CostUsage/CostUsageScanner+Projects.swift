import Foundation

extension CostUsageScanner {
    struct CodexHourlyUsageEvent: Equatable {
        let timestampUnixMs: Int64
        let modelProvider: String
        let totalTokens: Int
        let knownCostNanos: Int64?
        let hasUnpricedTokens: Bool
    }

    static func buildCodexHourly24HourEntries(
        events: [CodexHourlyUsageEvent],
        now: Date,
        calendar: Calendar) -> [CostUsageHourlyEntry]
    {
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start,
              let firstHour = calendar.date(byAdding: .hour, value: -23, to: currentHour)
        else { return [] }

        struct Total {
            var tokens = 0
            var costNanos: Int64 = 0
            var hasUnpricedTokens = false
        }
        var totalsByHour: [Date: Total] = [:]
        var providersByHour: [Date: [String: Total]] = [:]
        var acceptedEventCount = 0

        for event in events {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(event.timestampUnixMs) / 1000)
            guard timestamp >= firstHour,
                  timestamp <= now,
                  let hour = calendar.dateInterval(of: .hour, for: timestamp)?.start
            else { continue }
            acceptedEventCount += 1
            var total = totalsByHour[hour] ?? Total()
            total.tokens += max(0, event.totalTokens)
            total.costNanos += event.knownCostNanos ?? 0
            total.hasUnpricedTokens = total.hasUnpricedTokens || event.hasUnpricedTokens
            totalsByHour[hour] = total

            var providerTotal = providersByHour[hour]?[event.modelProvider] ?? Total()
            providerTotal.tokens += max(0, event.totalTokens)
            providerTotal.costNanos += event.knownCostNanos ?? 0
            providerTotal.hasUnpricedTokens = providerTotal.hasUnpricedTokens || event.hasUnpricedTokens
            providersByHour[hour, default: [:]][event.modelProvider] = providerTotal
        }
        guard acceptedEventCount > 0 else { return [] }

        return (0..<24).compactMap { offset in
            guard let hour = calendar.date(byAdding: .hour, value: offset, to: firstHour) else { return nil }
            let total = totalsByHour[hour] ?? Total()
            let breakdowns = (providersByHour[hour] ?? [:]).map { provider, providerTotal in
                CostUsageModelProviderBreakdown(
                    modelProvider: provider,
                    totalTokens: providerTotal.tokens,
                    costUSD: providerTotal.hasUnpricedTokens
                        ? nil
                        : Double(providerTotal.costNanos) / Self.costScale)
            }.sorted { $0.modelProvider < $1.modelProvider }
            return CostUsageHourlyEntry(
                startDate: hour,
                totalTokens: total.tokens,
                costUSD: total.hasUnpricedTokens ? nil : Double(total.costNanos) / Self.costScale,
                modelProviderBreakdowns: breakdowns)
        }
    }

    static func buildCodexHourly24HourEntriesFromCache(
        cache: CostUsageCache,
        now: Date,
        calendar: Calendar,
        sessionRoots: [URL]? = nil) -> [CostUsageHourlyEntry]
    {
        guard !cache.files.isEmpty else { return [] }
        var latestFileBySessionID: [String: (path: String, usage: CostUsageFileUsage)] = [:]
        for (filePath, usage) in cache.files {
            if let sessionRoots,
               !Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: sessionRoots)
            {
                continue
            }
            let sessionID = usage.sessionId ?? filePath
            if let existing = latestFileBySessionID[sessionID], existing.usage.mtimeUnixMs >= usage.mtimeUnixMs {
                continue
            }
            latestFileBySessionID[sessionID] = (filePath, usage)
        }

        var events: [CodexHourlyUsageEvent] = []
        for file in latestFileBySessionID.values {
            guard let rows = file.usage.codexRows,
                  rows.allSatisfy({ $0.eventIndex != nil && $0.timestampUnixMs != nil })
            else { return [] }
            let rawProvider = file.usage.codexSession?.modelProvider?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = rawProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            events.append(contentsOf: rows.compactMap { row in
                guard let timestampUnixMs = row.timestampUnixMs else { return nil }
                let totalTokens = max(0, row.input) + max(0, row.output)
                return CodexHourlyUsageEvent(
                    timestampUnixMs: timestampUnixMs,
                    modelProvider: provider,
                    totalTokens: totalTokens,
                    knownCostNanos: row.knownCostNanos,
                    hasUnpricedTokens: row.knownCostNanos == nil && totalTokens > 0)
            })
        }
        return self.buildCodexHourly24HourEntries(events: events, now: now, calendar: calendar)
    }

    static func buildCodexRolling24HourSummaryFromCache(
        cache: CostUsageCache,
        now: Date,
        sessionRoots: [URL]? = nil) -> CostUsageRolling24HourSummary?
    {
        guard !cache.files.isEmpty else { return nil }
        let cutoffUnixMs = Int64(((now.timeIntervalSince1970 - 24 * 60 * 60) * 1000).rounded())
        let nowUnixMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var latestFileBySessionID: [String: (path: String, usage: CostUsageFileUsage)] = [:]

        for (filePath, usage) in cache.files {
            if let sessionRoots,
               !Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: sessionRoots)
            {
                continue
            }
            let sessionID = usage.sessionId ?? filePath
            if let existing = latestFileBySessionID[sessionID], existing.usage.mtimeUnixMs >= usage.mtimeUnixMs {
                continue
            }
            latestFileBySessionID[sessionID] = (filePath, usage)
        }

        var totalTokens = 0
        var totalCostNanos: Int64 = 0
        var hasUnpricedTokens = false
        var providerTotals: [String: (tokens: Int, costNanos: Int64, hasUnpricedTokens: Bool)] = [:]
        for file in latestFileBySessionID.values {
            let latestActivityUnixMs = file.usage.codexSession?.latestActivityUnixMs ?? file.usage.mtimeUnixMs
            guard latestActivityUnixMs >= cutoffUnixMs else { continue }
            guard let rows = file.usage.codexRows,
                  rows.allSatisfy({ $0.eventIndex != nil && $0.timestampUnixMs != nil })
            else {
                return nil
            }
            for row in rows {
                guard let timestampUnixMs = row.timestampUnixMs,
                      timestampUnixMs >= cutoffUnixMs,
                      timestampUnixMs <= nowUnixMs
                else { continue }
                let rowTokens = max(0, row.input) + max(0, row.output)
                totalTokens += rowTokens
                let modelProvider = file.usage.codexSession?.modelProvider?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let providerKey = modelProvider.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                var providerTotal = providerTotals[providerKey] ?? (0, 0, false)
                providerTotal.tokens += rowTokens
                if let knownCostNanos = row.knownCostNanos {
                    totalCostNanos += knownCostNanos
                    providerTotal.costNanos += knownCostNanos
                } else if rowTokens > 0 {
                    hasUnpricedTokens = true
                    providerTotal.hasUnpricedTokens = true
                }
                providerTotals[providerKey] = providerTotal
            }
        }

        return CostUsageRolling24HourSummary(
            totalTokens: totalTokens,
            costUSD: hasUnpricedTokens ? nil : Double(totalCostNanos) / Self.costScale,
            modelProviderBreakdowns: providerTotals.map { modelProvider, totals in
                CostUsageModelProviderBreakdown(
                    modelProvider: modelProvider,
                    totalTokens: totals.tokens,
                    costUSD: totals.hasUnpricedTokens ? nil : Double(totals.costNanos) / Self.costScale)
            }.sorted { $0.modelProvider < $1.modelProvider })
    }

    static func codexCache(
        _ cache: CostUsageCache,
        scopedTo roots: [URL],
        identity: UsageIdentity? = nil,
        attributionRevision: String? = nil) -> CostUsageCache
    {
        var scoped = cache
        scoped.files = cache.files.filter { filePath, usage in
            Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: roots)
                && Self.codexCacheIdentityMatches(
                    usage,
                    identity: identity,
                    attributionRevision: attributionRevision)
        }
        scoped.days = [:]
        for usage in scoped.files.values {
            Self.applyFileDays(cache: &scoped, fileDays: usage.days, sign: 1)
        }
        return scoped
    }

    static func buildCodexSessionBreakdownsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        sessionRoots: [URL]? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> [CostUsageSessionBreakdown]
    {
        let resolvedModelsDevCatalog = modelsDevCatalog
            ?? modelsDevCatalogLoader(modelsDevCacheRoot)
            ?? ModelsDevCatalog(providers: [:])
        var latestFileBySessionID: [String: (path: String, usage: CostUsageFileUsage)] = [:]

        for (filePath, usage) in cache.files {
            if let sessionRoots,
               !Self.isWithinCodexRoots(fileURL: URL(fileURLWithPath: filePath), roots: sessionRoots)
            {
                continue
            }
            guard usage.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) else {
                continue
            }
            let sessionID = usage.sessionId ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
            guard !sessionID.isEmpty else { continue }
            if let existing = latestFileBySessionID[sessionID], existing.usage.mtimeUnixMs >= usage.mtimeUnixMs {
                continue
            }
            latestFileBySessionID[sessionID] = (filePath, usage)
        }

        return latestFileBySessionID.compactMap { sessionID, file in
            var fileCache = CostUsageCache()
            fileCache.files[file.path] = file.usage
            fileCache.days = file.usage.days
            let report = Self.buildCodexReportFromCache(
                cache: fileCache,
                range: range,
                modelsDevCatalog: resolvedModelsDevCatalog,
                priorityTurns: priorityTurns)
            guard !report.data.isEmpty else { return nil }

            let summary = report.summary
            let requestCounts = report.data.compactMap(\.requestCount)
            return CostUsageSessionBreakdown(
                sessionID: sessionID,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(file.usage.mtimeUnixMs) / 1000),
                inputTokens: summary?.totalInputTokens,
                cachedInputTokens: summary?.cacheReadTokens,
                outputTokens: summary?.totalOutputTokens,
                totalTokens: summary?.totalTokens,
                requestCount: requestCounts.isEmpty ? nil : requestCounts.reduce(0, +),
                costUSD: summary?.totalCostUSD,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: report.data) ?? [])
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID > rhs.sessionID
        }
    }

    static func buildCodexProjectBreakdownsFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> [CostUsageProjectBreakdown]
    {
        // Project rollups build one report per cached session file. Resolve pricing once so every
        // row does not fall back through ModelsDevCache.load and repeat filesystem metadata reads.
        let resolvedModelsDevCatalog = modelsDevCatalog
            ?? modelsDevCatalogLoader(modelsDevCacheRoot)
            ?? ModelsDevCatalog(providers: [:])
        let projectPathResolver = CodexCanonicalProjectPathResolver()
        var accumulatorsByProjectPath: [String: CodexProjectBreakdownAccumulator] = [:]
        for (filePath, usage) in cache.files {
            guard usage.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey) else {
                continue
            }
            var fileCache = CostUsageCache()
            fileCache.files[filePath] = usage
            fileCache.days = usage.days
            let report = Self.buildCodexReportFromCache(
                cache: fileCache,
                range: range,
                modelsDevCatalog: resolvedModelsDevCatalog,
                priorityTurns: priorityTurns)
            guard !report.data.isEmpty else { continue }
            let projectKey = usage.canonicalProjectPath
                ?? projectPathResolver.canonicalProjectPath(for: usage.projectPath)
                ?? ""
            let sourceKey = usage.projectPath ?? ""
            var accumulator = accumulatorsByProjectPath[projectKey] ?? CodexProjectBreakdownAccumulator()
            accumulator.add(report: report, sourcePath: sourceKey)
            accumulatorsByProjectPath[projectKey] = accumulator
        }

        return accumulatorsByProjectPath.map { projectPath, accumulator in
            let merged = CostUsageDailyReport.merged(accumulator.reports)
            let resolvedPath = projectPath.isEmpty ? nil : projectPath
            return CostUsageProjectBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: merged.data),
                sources: Self.codexProjectSourceBreakdowns(from: accumulator.reportsBySourcePath))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func codexProjectName(path: String?) -> String {
        guard let path, !path.isEmpty else { return CostUsageProjectBreakdown.unknownProjectName }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private struct CodexProjectBreakdownAccumulator {
        var reports: [CostUsageDailyReport] = []
        var reportsBySourcePath: [String: [CostUsageDailyReport]] = [:]

        mutating func add(report: CostUsageDailyReport, sourcePath: String) {
            self.reports.append(report)
            self.reportsBySourcePath[sourcePath, default: []].append(report)
        }
    }

    private static func codexProjectSourceBreakdowns(
        from reportsBySourcePath: [String: [CostUsageDailyReport]]) -> [CostUsageProjectSourceBreakdown]
    {
        reportsBySourcePath.map { sourcePath, reports in
            let merged = CostUsageDailyReport.merged(reports)
            let resolvedPath = sourcePath.isEmpty ? nil : sourcePath
            return CostUsageProjectSourceBreakdown(
                name: Self.codexProjectName(path: resolvedPath),
                path: resolvedPath,
                totalTokens: merged.summary?.totalTokens,
                totalCostUSD: merged.summary?.totalCostUSD,
                daily: merged.data,
                modelBreakdowns: Self.codexProjectModelBreakdowns(from: merged.data))
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.totalCostUSD ?? -1
            let rhsCost = rhs.totalCostUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }
            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct ProjectBreakdownAccumulator {
        var totalTokens = 0
        var sawTotalTokens = false
        var costUSD: Double = 0
        var sawCost = false
        var standardCostUSD: Double = 0
        var sawStandardCost = false
        var priorityCostUSD: Double = 0
        var sawPriorityCost = false
        var standardTokens = 0
        var sawStandardTokens = false
        var priorityTokens = 0
        var sawPriorityTokens = false
        var splitEstimateNormalized = false

        mutating func add(_ breakdown: CostUsageDailyReport.ModelBreakdown) {
            if let totalTokens = breakdown.totalTokens {
                self.totalTokens += totalTokens
                self.sawTotalTokens = true
            }
            if let costUSD = breakdown.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
            if let standardCostUSD = breakdown.standardCostUSD {
                self.standardCostUSD += standardCostUSD
                self.sawStandardCost = true
            }
            if let priorityCostUSD = breakdown.priorityCostUSD {
                self.priorityCostUSD += priorityCostUSD
                self.sawPriorityCost = true
            }
            if let standardTokens = breakdown.standardTokens {
                self.standardTokens += standardTokens
                self.sawStandardTokens = true
            }
            if let priorityTokens = breakdown.priorityTokens {
                self.priorityTokens += priorityTokens
                self.sawPriorityTokens = true
            }
            self.splitEstimateNormalized = self.splitEstimateNormalized || breakdown.splitEstimateNormalized
        }

        func build(modelName: String) -> CostUsageDailyReport.ModelBreakdown {
            CostUsageDailyReport.ModelBreakdown(
                modelName: modelName,
                costUSD: self.sawCost ? self.costUSD : nil,
                totalTokens: self.sawTotalTokens ? self.totalTokens : nil,
                standardCostUSD: self.sawStandardCost ? self.standardCostUSD : nil,
                priorityCostUSD: self.sawPriorityCost ? self.priorityCostUSD : nil,
                standardTokens: self.sawStandardTokens ? self.standardTokens : nil,
                priorityTokens: self.sawPriorityTokens ? self.priorityTokens : nil,
                splitEstimateNormalized: self.splitEstimateNormalized)
        }
    }

    private static func codexProjectModelBreakdowns(
        from entries: [CostUsageDailyReport.Entry]) -> [CostUsageDailyReport.ModelBreakdown]?
    {
        var accumulators: [String: ProjectBreakdownAccumulator] = [:]
        for entry in entries {
            for breakdown in entry.modelBreakdowns ?? [] {
                var accumulator = accumulators[breakdown.modelName] ?? ProjectBreakdownAccumulator()
                accumulator.add(breakdown)
                accumulators[breakdown.modelName] = accumulator
            }
        }
        guard !accumulators.isEmpty else { return nil }
        return Self.sortedModelBreakdowns(accumulators.map { modelName, accumulator in
            accumulator.build(modelName: modelName)
        })
    }
}
