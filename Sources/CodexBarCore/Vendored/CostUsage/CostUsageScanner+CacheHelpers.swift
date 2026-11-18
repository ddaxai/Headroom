// swiftlint:disable file_length

import Foundation
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

extension CostUsageScanner {
    private final class CodexModelsDevCatalogResolver {
        private var catalog: ModelsDevCatalog?
        private let cacheRoot: URL?

        init(catalog: ModelsDevCatalog?, cacheRoot: URL?) {
            self.catalog = catalog
            self.cacheRoot = cacheRoot
        }

        func load(_ loader: (URL?) -> ModelsDevCatalog?) -> ModelsDevCatalog {
            if let catalog {
                return catalog
            }
            let loaded = loader(self.cacheRoot) ?? ModelsDevCatalog(providers: [:])
            self.catalog = loaded
            return loaded
        }
    }

    static func codexRowsByDayModel(
        rows: [CodexUsageRow],
        range: CostUsageDayRange) -> [String: [String: [CodexUsageRow]]]
    {
        var rowsByDayModel: [String: [String: [CodexUsageRow]]] = [:]
        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }
            rowsByDayModel[row.day, default: [:]][row.model, default: []].append(row)
        }
        return rowsByDayModel
    }

    static func codexCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexCostNanos }
    }

    static func codexPrioritySurchargeNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPrioritySurchargeNanos }
    }

    static func codexStandardCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexStandardCostNanos }
    }

    static func codexPriorityCostNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int64]]
    {
        self.codexNanosByDayModel(cache: cache, range: range) { $0.codexPriorityCostNanos }
    }

    static func codexStandardTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexStandardTokens }
    }

    static func codexPriorityTokensByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange) -> [String: [String: Int]]
    {
        self.codexIntByDayModel(cache: cache, range: range) { $0.codexPriorityTokens }
    }

    static func codexReportDayKeys(cache: CostUsageCache, range: CostUsageDayRange) -> [String] {
        cache.days.keys.sorted().filter {
            CostUsageDayRange.isInRange(dayKey: $0, since: range.sinceKey, until: range.untilKey)
        }
    }

    static func codexNanosByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int64]]?) -> [String: [String: Int64]]
    {
        var out: [String: [String: Int64]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    let current = out[day, default: [:]][model, default: 0]
                    let (sum, overflow) = current.addingReportingOverflow(value)
                    out[day, default: [:]][model] = overflow
                        ? (value >= 0 ? Int64.max : Int64.min)
                        : sum
                }
            }
        }
        return out
    }

    static func codexIntByDayModel(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        keyPath: (CostUsageFileUsage) -> [String: [String: Int]]?) -> [String: [String: Int]]
    {
        var out: [String: [String: Int]] = [:]
        for usage in cache.files.values {
            for (day, models) in keyPath(usage) ?? [:] {
                guard CostUsageDayRange.isInRange(dayKey: day, since: range.sinceKey, until: range.untilKey)
                else { continue }
                for (model, value) in models {
                    let current = out[day, default: [:]][model, default: 0]
                    let (sum, overflow) = current.addingReportingOverflow(value)
                    out[day, default: [:]][model] = overflow
                        ? (value >= 0 ? Int.max : Int.min)
                        : sum
                }
            }
        }
        return out
    }

    static func codexRowsCostUSD(
        rows: [CodexUsageRow],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            if row.preservesSavedPricing == true {
                if let cost = row.knownCostNanos, row.unpricedTokens == nil || row.unpricedTokens == 0 {
                    total += Double(cost) / Self.costScale
                    seen = true
                }
                continue
            }
            guard let cost = CostUsagePricing.codexCostUSD(
                model: row.model,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            else { continue }
            total += cost
            seen = true
        }
        return seen ? total : nil
    }

    static func codexPrioritySurchargeUSD(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> Double?
    {
        var total: Double = 0
        var seen = false
        for row in rows {
            // Preserved costs already include their original service tier.
            guard row.preservesSavedPricing != true,
                  let turnID = row.turnID, let priorityMetadata = priorityTurns[turnID] else { continue }
            let pricedModel = Self.codexPriorityPricingModel(for: row, priorityMetadata: priorityMetadata)
            guard let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot),
                let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                    model: pricedModel,
                    inputTokens: row.input,
                    cachedInputTokens: row.cached,
                    outputTokens: row.output,
                    pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            else { continue }
            total += max(priorityCost - baseCost, 0)
            seen = true
        }
        return seen ? total : nil
    }

    private static func codexPriorityPricingModel(
        for row: CodexUsageRow,
        priorityMetadata: CodexPriorityTurnMetadata) -> String
    {
        guard let model = priorityMetadata.model,
              CostUsagePricing.codexPriorityCostUSD(
                  model: model,
                  inputTokens: row.input,
                  cachedInputTokens: row.cached,
                  outputTokens: row.output,
                  pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }) != nil
        else { return row.model }
        return model
    }

    struct CodexRowCostBreakdown {
        var standardCostUSD: Double = 0
        var priorityCostUSD: Double = 0
        var standardTokens: Int = 0
        var priorityTokens: Int = 0
        var sawStandardCost = false
        var sawPriorityCost = false

        var optionalStandardCostUSD: Double? {
            self.sawStandardCost ? self.standardCostUSD : nil
        }

        var optionalPriorityCostUSD: Double? {
            self.sawPriorityCost ? self.priorityCostUSD : nil
        }

        var optionalStandardTokens: Int? {
            self.standardTokens > 0 ? self.standardTokens : nil
        }

        var optionalPriorityTokens: Int? {
            self.priorityTokens > 0 ? self.priorityTokens : nil
        }

        var totalCostUSD: Double? {
            guard self.sawStandardCost || self.sawPriorityCost else { return nil }
            return self.standardCostUSD + self.priorityCostUSD
        }

        var hasModeSplit: Bool {
            self.sawPriorityCost || self.priorityTokens > 0
        }
    }

    struct CodexNormalizedModeSplit {
        let standardTokens: Int?
        let priorityTokens: Int?
        let standardCostUSD: Double?
        let priorityCostUSD: Double?
        let wasNormalized: Bool
    }

    static func normalizedCodexModeSplit(
        canonicalTotalTokens: Int,
        standardTokens: Int?,
        priorityTokens: Int?,
        standardCostUSD: Double?,
        priorityCostUSD: Double?) -> CodexNormalizedModeSplit
    {
        let rawStandard = standardTokens ?? 0
        let rawPriority = priorityTokens ?? 0
        let standard = max(rawStandard, 0)
        let priority = max(rawPriority, 0)
        let (splitTotal, overflow) = standard.addingReportingOverflow(priority)
        let canonical = max(canonicalTotalTokens, 0)
        let needsScaling = overflow || splitTotal > canonical
        let needsNormalization = needsScaling || rawStandard < 0 || rawPriority < 0
        guard needsNormalization else {
            return CodexNormalizedModeSplit(
                standardTokens: standardTokens,
                priorityTokens: priorityTokens,
                standardCostUSD: standardCostUSD,
                priorityCostUSD: priorityCostUSD,
                wasNormalized: false)
        }
        guard needsScaling else {
            return CodexNormalizedModeSplit(
                standardTokens: standardTokens == nil ? nil : standard,
                priorityTokens: priorityTokens == nil ? nil : priority,
                standardCostUSD: standardCostUSD,
                priorityCostUSD: priorityCostUSD,
                wasNormalized: true)
        }
        let denominator = Double(standard) + Double(priority)
        let standardRatio = denominator > 0 ? Double(standard) / denominator : 0
        let projectedStandard = Double(canonical) * standardRatio
        let normalizedStandard: Int = if projectedStandard >= Double(Int.max) {
            canonical
        } else {
            min(canonical, max(0, Int(projectedStandard.rounded())))
        }
        let normalizedPriority = canonical - normalizedStandard
        let scale = denominator > 0 ? Double(canonical) / denominator : 0
        return CodexNormalizedModeSplit(
            standardTokens: standardTokens == nil ? nil : normalizedStandard,
            priorityTokens: priorityTokens == nil ? nil : normalizedPriority,
            standardCostUSD: standardCostUSD.map { $0 * scale },
            priorityCostUSD: priorityCostUSD.map { $0 * scale },
            wasNormalized: true)
    }

    static func codexRowCostBreakdown(
        rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CodexRowCostBreakdown
    {
        var breakdown = CodexRowCostBreakdown()
        for row in rows {
            let tokenCount = row.input + row.output
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let isPriority = priorityMetadata != nil
            if isPriority {
                breakdown.priorityTokens += tokenCount
            } else {
                breakdown.standardTokens += tokenCount
            }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            {
                breakdown.priorityCostUSD += max(priorityCost, baseCost ?? priorityCost)
                breakdown.sawPriorityCost = true
            } else if isPriority, let baseCost {
                breakdown.priorityCostUSD += baseCost
                breakdown.sawPriorityCost = true
            } else if let baseCost {
                breakdown.standardCostUSD += baseCost
                breakdown.sawStandardCost = true
            }
        }
        return breakdown
    }

    // MARK: - File cache construction

    static func makeFileUsage(
        mtimeUnixMs: Int64,
        size: Int64,
        days: [String: [String: [Int]]],
        parsedBytes: Int64?,
        lastModel: String? = nil,
        lastTotals: CostUsageCodexTotals? = nil,
        lastCountedTotals: CostUsageCodexTotals? = nil,
        lastRawTotalsBaseline: CostUsageCodexTotals? = nil,
        lastRawTotalsWatermark: CostUsageCodexTotals? = nil,
        seenRawTotals: [CostUsageCodexTotals]? = nil,
        hasDivergentTotals: Bool? = nil,
        hasInterleavedTotals: Bool? = nil,
        lastCodexTurnID: String? = nil,
        sessionId: String? = nil,
        forkedFromId: String? = nil,
        forkBaselineDependencyKey: String? = nil,
        projectPath: String? = nil,
        canonicalProjectPath: String? = nil,
        codexCostCacheComplete: Bool? = true,
        codexSession: CostUsageCodexSessionMetadata? = nil,
        codexCostNanos: [String: [String: Int64]]? = nil,
        codexPrioritySurchargeNanos: [String: [String: Int64]]? = nil,
        codexStandardCostNanos: [String: [String: Int64]]? = nil,
        codexPriorityCostNanos: [String: [String: Int64]]? = nil,
        codexStandardTokens: [String: [String: Int]]? = nil,
        codexPriorityTokens: [String: [String: Int]]? = nil,
        codexTurnIDs: [String]? = nil,
        codexRows: [CodexUsageRow]? = nil,
        claudeRows: [ClaudeUsageRow]? = nil,
        codexScanFileId: String? = nil,
        codexScanTargetSize: Int64? = nil,
        codexScanComplete: Bool? = nil,
        codexJSONLResumeState: CostUsageJsonl.ResumeState? = nil,
        codexBufferedSubagentLines: [CodexBufferedFastLine]? = nil,
        codexParserRevision: Int? = CostUsageFileUsage.currentCodexParserRevision,
        codexRequestLedgerState: CodexRequestLedgerState? = nil,
        codexLedgerMigrationRows: [CodexUsageRow]? = nil) -> CostUsageFileUsage
    {
        CostUsageFileUsage(
            codexParserRevision: codexParserRevision,
            codexRequestLedgerState: codexRequestLedgerState,
            codexLedgerMigrationRows: codexLedgerMigrationRows,
            mtimeUnixMs: mtimeUnixMs,
            size: size,
            days: days,
            parsedBytes: parsedBytes,
            lastModel: lastModel,
            lastTotals: lastTotals,
            lastCountedTotals: lastCountedTotals,
            lastRawTotalsBaseline: lastRawTotalsBaseline,
            lastRawTotalsWatermark: lastRawTotalsWatermark,
            seenRawTotals: seenRawTotals,
            hasDivergentTotals: hasDivergentTotals,
            hasInterleavedTotals: hasInterleavedTotals,
            lastCodexTurnID: lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexCostCacheComplete: codexCostCacheComplete,
            codexSession: codexSession,
            codexCostNanos: codexCostNanos,
            codexPrioritySurchargeNanos: codexPrioritySurchargeNanos,
            codexStandardCostNanos: codexStandardCostNanos,
            codexPriorityCostNanos: codexPriorityCostNanos,
            codexStandardTokens: codexStandardTokens,
            codexPriorityTokens: codexPriorityTokens,
            codexTurnIDs: codexTurnIDs,
            codexRows: codexRows,
            claudeRows: claudeRows,
            codexScanFileId: codexScanFileId,
            codexScanTargetSize: codexScanTargetSize,
            codexScanComplete: codexScanComplete,
            codexJSONLResumeState: codexJSONLResumeState,
            codexBufferedSubagentLines: codexBufferedSubagentLines)
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage) -> Bool {
        !(usage.codexRows?.isEmpty ?? true)
            && (usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage))
    }

    static func needsCodexCostCache(_ usage: CostUsageFileUsage, range: CostUsageDayRange) -> Bool {
        guard usage.codexCostCacheComplete != true || self.needsCodexModeSplitCache(usage) else {
            return false
        }
        guard let rows = usage.codexRows, !rows.isEmpty else { return false }
        return rows.contains {
            CostUsageDayRange.isInRange(dayKey: $0.day, since: range.sinceKey, until: range.untilKey)
        }
    }

    static func needsCodexModeSplitCache(_ usage: CostUsageFileUsage) -> Bool {
        let hasStandardCost = !(usage.codexStandardCostNanos?.isEmpty ?? true)
        let hasPriorityCost = !(usage.codexPriorityCostNanos?.isEmpty ?? true)
        let hasStandardTokens = !(usage.codexStandardTokens?.isEmpty ?? true)
        let hasPriorityTokens = !(usage.codexPriorityTokens?.isEmpty ?? true)

        // Token maps are also the completion marker for models with no known pricing.
        guard hasStandardTokens || hasPriorityTokens else { return true }
        return (hasStandardCost && !hasStandardTokens) || (hasPriorityCost && !hasPriorityTokens)
    }

    static func codexFileUsageWithCostCache(
        _ usage: CostUsageFileUsage,
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        self.codexFileUsageWithCostCache(
            usage,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
    }

    static func codexFileUsageWithCostCache(
        _ usage: CostUsageFileUsage,
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> CostUsageFileUsage
    {
        guard let rows = usage.codexRows, !rows.isEmpty else { return usage }
        var migratedRows: [CodexUsageRow] = []
        for row in rows where CostUsageDayRange.isInRange(
            dayKey: row.day,
            since: range.scanSinceKey,
            until: range.scanUntilKey)
        {
            migratedRows.append(row)
        }
        guard !migratedRows.isEmpty else { return usage }

        let splitMaps = Self.codexModeSplitMaps(
            rows: migratedRows,
            range: range,
            priorityTurns: priorityTurns,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        var updated = usage
        updated.codexCostNanos = Self.mergeMissingCostMaps(
            usage.codexCostNanos,
            Self.codexCostNanos(
                rows: migratedRows,
                range: range,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot))
        updated.codexPrioritySurchargeNanos = Self.mergeMissingCostMaps(
            usage.codexPrioritySurchargeNanos,
            Self.codexPrioritySurchargeNanos(
                rows: migratedRows,
                range: range,
                priorityTurns: priorityTurns,
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot))
        updated.codexStandardCostNanos = Self.mergeMissingCostMaps(
            usage.codexStandardCostNanos,
            splitMaps.standardCostNanos)
        updated.codexPriorityCostNanos = Self.mergeMissingCostMaps(
            usage.codexPriorityCostNanos,
            splitMaps.priorityCostNanos)
        updated.codexStandardTokens = Self.mergeMissingIntMaps(
            usage.codexStandardTokens,
            splitMaps.standardTokens)
        updated.codexPriorityTokens = Self.mergeMissingIntMaps(
            usage.codexPriorityTokens,
            splitMaps.priorityTokens)
        updated.codexCostCacheComplete = true
        updated.codexTurnIDs = Self.mergeCodexTurnIDs(usage.codexTurnIDs, rows: migratedRows)
        updated.codexRows = Self.codexRowsWithPricingAudit(
            rows,
            priorityTurns: priorityTurns,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        return updated.refreshingCodexWorkspaceUsageFingerprint()
    }

    static func codexRowsWithPricingAudit(
        _ rows: [CodexUsageRow],
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [CodexUsageRow]
    {
        rows.map { row in
            if row.preservesSavedPricing == true { return row }
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model
            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)
            let exactCost: Double? = if priorityMetadata != nil,
                                        let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                                            model: pricedModel,
                                            inputTokens: row.input,
                                            cachedInputTokens: row.cached,
                                            outputTokens: row.output,
                                            pricingDate: row.timestampUnixMs
                                                .map { Date(timeIntervalSince1970: Double($0) / 1000) })
            {
                max(priorityCost, baseCost ?? priorityCost)
            } else {
                baseCost
            }
            let totalTokens = max(0, row.input) + max(0, row.output)
            return CodexUsageRow(
                day: row.day,
                model: row.model,
                rawModel: row.rawModel,
                turnID: row.turnID,
                eventIndex: row.eventIndex,
                timestampUnixMs: row.timestampUnixMs,
                input: row.input,
                cached: row.cached,
                output: row.output,
                reasoning: row.reasoning,
                knownCostNanos: exactCost.map { Int64(($0 * Self.costScale).rounded()) },
                unpricedTokens: exactCost == nil ? totalTokens : 0,
                pricingModel: pricedModel,
                pricingMode: priorityMetadata == nil ? "standard" : "priority",
                responseID: row.responseID,
                requestMirrorKeys: row.requestMirrorKeys,
                preservesSavedPricing: row.preservesSavedPricing)
        }
    }

    static func codexMergedCostMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexCostNanos(
                rows: deltaRows,
                range: context.range,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexMergedPrioritySurchargeMap(
        _ existing: [String: [String: Int64]]?,
        deltaRows: [CodexUsageRow],
        context: CodexFileScanContext) -> [String: [String: Int64]]?
    {
        self.mergeCostMaps(
            existing,
            self.codexPrioritySurchargeNanos(
                rows: deltaRows,
                range: context.range,
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot))
    }

    static func codexCostNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let cost = Self.codexRowsCostUSD(
                    rows: rows,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((cost * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexPrioritySurchargeNanos(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> [String: [String: Int64]]?
    {
        guard !priorityTurns.isEmpty else { return nil }
        let rowsByDayModel = Self.codexRowsByDayModel(rows: rows, range: range)
        var out: [String: [String: Int64]] = [:]
        for (day, models) in rowsByDayModel {
            for (model, rows) in models {
                guard let surcharge = Self.codexPrioritySurchargeUSD(
                    rows: rows,
                    priorityTurns: priorityTurns,
                    modelsDevCatalog: modelsDevCatalog,
                    modelsDevCacheRoot: modelsDevCacheRoot)
                else { continue }
                out[day, default: [:]][model] = Int64((surcharge * Self.costScale).rounded())
            }
        }
        return out.isEmpty ? nil : out
    }

    static func codexModeSplitMaps(
        rows: [CodexUsageRow],
        range: CostUsageDayRange,
        priorityTurns: [String: CodexPriorityTurnMetadata],
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL?) -> (
        standardCostNanos: [String: [String: Int64]]?,
        priorityCostNanos: [String: [String: Int64]]?,
        standardTokens: [String: [String: Int]]?,
        priorityTokens: [String: [String: Int]]?)
    {
        var standardCostNanos: [String: [String: Int64]] = [:]
        var priorityCostNanos: [String: [String: Int64]] = [:]
        var standardTokens: [String: [String: Int]] = [:]
        var priorityTokens: [String: [String: Int]] = [:]

        for row in rows {
            guard CostUsageDayRange.isInRange(dayKey: row.day, since: range.sinceKey, until: range.untilKey)
            else { continue }

            let tokenCount = row.input + row.output
            if row.preservesSavedPricing == true {
                if row.pricingMode == "priority" {
                    priorityTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
                    if let cost = row.knownCostNanos {
                        priorityCostNanos[row.day, default: [:]][row.model, default: 0] += cost
                    }
                } else {
                    standardTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
                    if let cost = row.knownCostNanos {
                        standardCostNanos[row.day, default: [:]][row.model, default: 0] += cost
                    }
                }
                continue
            }
            let priorityMetadata = row.turnID.flatMap { priorityTurns[$0] }
            let pricedModel = priorityMetadata.map { Self.codexPriorityPricingModel(for: row, priorityMetadata: $0) }
                ?? row.model
            let isPriority = priorityMetadata != nil

            if isPriority {
                priorityTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            } else {
                standardTokens[row.day, default: [:]][row.model, default: 0] += tokenCount
            }

            let baseCost = CostUsagePricing.codexCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                modelsDevCatalog: modelsDevCatalog,
                modelsDevCacheRoot: modelsDevCacheRoot)

            if isPriority, let priorityCost = CostUsagePricing.codexPriorityCostUSD(
                model: pricedModel,
                inputTokens: row.input,
                cachedInputTokens: row.cached,
                outputTokens: row.output,
                pricingDate: row.timestampUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
            {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (max(priorityCost, baseCost ?? priorityCost) * Self.costScale).rounded())
            } else if isPriority, let baseCost {
                priorityCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            } else if let baseCost {
                standardCostNanos[row.day, default: [:]][row.model, default: 0] += Int64(
                    (baseCost * Self.costScale).rounded())
            }
        }

        return (
            standardCostNanos.isEmpty ? nil : standardCostNanos,
            priorityCostNanos.isEmpty ? nil : priorityCostNanos,
            standardTokens.isEmpty ? nil : standardTokens,
            priorityTokens.isEmpty ? nil : priorityTokens)
    }

    static func codexTurnIDs(rows: [CodexUsageRow]) -> [String]? {
        let ids = Set(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCodexTurnIDs(_ existing: [String]?, rows: [CodexUsageRow]) -> [String]? {
        var ids = Set(existing ?? [])
        ids.formUnion(rows.compactMap(\.turnID))
        return ids.sorted()
    }

    static func mergeCodexRows(
        _ existing: [CodexUsageRow]?,
        rows: [CodexUsageRow],
        sessionId: String?) -> [CodexUsageRow]?
    {
        var merged = (existing ?? []).filter { self.hasStableCodexRowIdentity($0) }
        let existingKeys = Set(merged.map { Self.codexUsageRowKey(sessionId: sessionId, row: $0) })
        for row in rows where !existingKeys.contains(Self.codexUsageRowKey(sessionId: sessionId, row: row)) {
            merged.append(row)
        }
        return merged.isEmpty ? nil : merged
    }

    static func hasStableCodexRowIdentity(_ row: CodexUsageRow) -> Bool {
        row.eventIndex != nil
    }

    static func codexRowsNeedIdentityRescan(_ rows: [CodexUsageRow]) -> Bool {
        rows.contains { !Self.hasStableCodexRowIdentity($0) }
    }

    static func cachedCodexRowsNeedIdentityRescan(_ usage: CostUsageFileUsage) -> Bool {
        let rows = usage.codexRows ?? []
        return (!usage.days.isEmpty && rows.isEmpty) || Self.codexRowsNeedIdentityRescan(rows)
    }

    static func nextCodexUsageRowIndex(_ rows: [CodexUsageRow]?) -> Int {
        guard let rows, !rows.isEmpty else { return 0 }
        if let maxIndex = rows.compactMap(\.eventIndex).max() {
            return maxIndex + 1
        }
        return rows.count
    }

    static func codexFileDays(rows: [CodexUsageRow]) -> [String: [String: [Int]]] {
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            let packed = days[row.day]?[row.model] ?? []
            days[row.day, default: [:]][row.model] = Self.addPacked(
                a: packed,
                b: [row.input, row.cached, row.output],
                sign: 1)
        }
        return days
    }

    static func codexFileUsageByFilteringRows(
        _ usage: CostUsageFileUsage,
        rows: [CodexUsageRow],
        context: CodexFileScanContext) -> CostUsageFileUsage
    {
        var days = Self.fileDaysOutsideScanWindow(usage.days, range: context.range)
        let rowsInScanWindow = rows.filter {
            CostUsageDayRange.isInRange(
                dayKey: $0.day,
                since: context.range.scanSinceKey,
                until: context.range.scanUntilKey)
        }
        Self.mergeFileDays(existing: &days, delta: Self.codexFileDays(rows: rowsInScanWindow))
        let splitMaps = Self.codexModeSplitMaps(
            rows: rows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)

        return Self.makeFileUsage(
            mtimeUnixMs: usage.mtimeUnixMs,
            size: usage.size,
            days: days,
            parsedBytes: usage.parsedBytes,
            lastModel: usage.lastModel,
            lastTotals: usage.lastTotals,
            lastCountedTotals: usage.lastCountedTotals,
            lastRawTotalsBaseline: usage.lastRawTotalsBaseline,
            lastRawTotalsWatermark: usage.lastRawTotalsWatermark,
            seenRawTotals: usage.seenRawTotals,
            hasDivergentTotals: usage.hasDivergentTotals,
            hasInterleavedTotals: usage.hasInterleavedTotals,
            lastCodexTurnID: usage.lastCodexTurnID,
            sessionId: usage.sessionId,
            forkedFromId: usage.forkedFromId,
            forkBaselineDependencyKey: usage.forkBaselineDependencyKey,
            projectPath: usage.projectPath,
            canonicalProjectPath: usage.canonicalProjectPath,
            codexCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexCostNanos, range: context.range),
                Self.codexCostNanos(
                    rows: rows,
                    range: context.range,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexPrioritySurchargeNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexPrioritySurchargeNanos, range: context.range),
                Self.codexPrioritySurchargeNanos(
                    rows: rows,
                    range: context.range,
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexStandardCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexStandardCostNanos, range: context.range),
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                Self.costMapOutsideScanWindow(usage.codexPriorityCostNanos, range: context.range),
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexStandardTokens, range: context.range),
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                Self.intMapOutsideScanWindow(usage.codexPriorityTokens, range: context.range),
                splitMaps.priorityTokens),
            codexTurnIDs: Self.mergeCodexTurnIDs(nil, rows: rows),
            codexRows: rows,
            codexParserRevision: usage.codexParserRevision,
            codexRequestLedgerState: usage.codexRequestLedgerState,
            codexLedgerMigrationRows: usage.codexLedgerMigrationRows)
            .refreshingCodexWorkspaceUsageFingerprint(
                identity: context.usageIdentity,
                attributionRevision: context.attributionRevision)
    }

    static func mergeCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingCostMaps(
        _ existing: [String: [String: Int64]]?,
        _ delta: [String: [String: Int64]]?) -> [String: [String: Int64]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models {
                out[day, default: [:]][model, default: 0] += value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func mergeMissingIntMaps(
        _ existing: [String: [String: Int]]?,
        _ delta: [String: [String: Int]]?) -> [String: [String: Int]]?
    {
        var out = existing ?? [:]
        for (day, models) in delta ?? [:] {
            for (model, value) in models where out[day]?[model] == nil {
                out[day, default: [:]][model] = value
            }
        }
        return out.isEmpty ? nil : out
    }

    static func costMapOutsideScanWindow(
        _ map: [String: [String: Int64]]?,
        range: CostUsageDayRange) -> [String: [String: Int64]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    static func intMapOutsideScanWindow(
        _ map: [String: [String: Int]]?,
        range: CostUsageDayRange) -> [String: [String: Int]]?
    {
        let filtered = (map ?? [:]).filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
        return filtered.isEmpty ? nil : filtered
    }

    // MARK: - File scan orchestration

    struct CodexFileMetadata {
        let path: String
        let mtimeUnixMs: Int64
        let size: Int64
        let fileId: String?
    }

    struct CodexFileScanInput {
        let fileURL: URL
        let metadata: CodexFileMetadata
        let cached: CostUsageFileUsage?
    }

    static func codexFileMetadata(fileURL: URL) -> CodexFileMetadata {
        let path = fileURL.path
        var info = stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            return CodexFileMetadata(path: path, mtimeUnixMs: 0, size: 0, fileId: nil)
        }
        #if os(Linux)
        let modifiedSeconds = Int64(info.st_mtim.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtim.tv_nsec)
        #else
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        #endif
        return CodexFileMetadata(
            path: path,
            mtimeUnixMs: modifiedSeconds * 1000 + modifiedNanoseconds / 1_000_000,
            size: Int64(info.st_size),
            fileId: "\(info.st_dev):\(info.st_ino)")
    }

    static func dropCachedCodexFile(
        path: String,
        cached: CostUsageFileUsage?,
        cache: inout CostUsageCache)
    {
        if let cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        cache.files.removeValue(forKey: path)
    }

    static func rememberScannedCodexFile(
        input: CodexFileScanInput,
        session: CodexScannedSession,
        rows: [CodexUsageRow],
        context: CodexFileScanContext,
        state: inout CodexScanState)
    {
        if let sessionId = session.id {
            context.resources.fileIndex.remember(fileURL: input.fileURL, sessionId: sessionId)
            if session.contributedUsage {
                state.contributingSessionIds.insert(sessionId)
            }
        }
        Self.rememberCodexRows(
            rows,
            sessionId: session.id,
            fileIdentity: input.metadata.path,
            state: &state)
        if let fileId = input.metadata.fileId {
            state.seenFileIds.insert(fileId)
        }
    }

    static func keepCachedCodexFileIfFresh(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState) throws -> Bool
    {
        guard let cached = input.cached, cached.hasCurrentCodexParser else { return false }
        let needsSessionId = cached.sessionId == nil
        guard cached.mtimeUnixMs == input.metadata.mtimeUnixMs,
              cached.size == input.metadata.size,
              cached.codexScanComplete != false,
              !needsSessionId,
              !context.forceFullScan
        else { return false }

        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }

        let sessionAlreadyContributed = cached.sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let cachedRows = cached.codexRows ?? []
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        if let parentSessionId = cached.forkedFromId {
            guard let cachedDependencyKey = cached.forkBaselineDependencyKey else { return false }
            if cachedDependencyKey != Self.codexForkDependencyNotRequiredKey {
                let currentDependencyKey = try context.resources.inheritedResolver
                    .currentDependencyKey(for: parentSessionId)
                guard cachedDependencyKey == currentDependencyKey else { return false }
            }
        }

        if sessionAlreadyContributed {
            guard !cachedRows.isEmpty || cached.codexRequestLedgerState?.hasMirrorEvidence == true else { return false }
            let uniqueRows = Self.uniqueCodexRows(
                rows: cachedRows,
                sessionId: cached.sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
            guard !uniqueRows.isEmpty || cached.codexRequestLedgerState?.hasMirrorEvidence == true else {
                Self.dropCachedCodexFile(path: input.metadata.path, cached: cached, cache: &cache)
                return true
            }
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            let filtered = Self.codexFileUsageByFilteringRows(cached, rows: uniqueRows, context: context)
            cache.files[input.metadata.path] = filtered
            Self.applyFileDays(cache: &cache, fileDays: filtered.days, sign: 1)
            Self.rememberScannedCodexFile(
                input: input,
                session: CodexScannedSession(id: cached.sessionId, days: filtered.days),
                rows: uniqueRows,
                context: context,
                state: &state)
            return true
        }

        // A page previously deduplicated to evidence alone must contribute again if
        // no earlier page owns its response on this scan (for example after deletion).
        if cachedRows.isEmpty, cached.codexRequestLedgerState?.hasMirrorEvidence == true { return false }

        let current = if Self.needsCodexCostCache(cached, range: context.range) {
            Self.codexFileUsageWithCostCache(cached, context: context)
        } else {
            cached
        }
        cache.files[input.metadata.path] = current
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: current.sessionId, days: current.days),
            rows: cachedRows,
            context: context,
            state: &state)
        return true
    }

    static func cachedCodexFileNeedsPriorityRescan(
        _ cached: CostUsageFileUsage,
        context: CodexFileScanContext) -> Bool
    {
        if cached.codexTurnIDs == nil {
            return context.requiresTurnIDCache
        }
        guard !context.changedPriorityTurnIDs.isEmpty else { return false }
        return !(Set(cached.codexTurnIDs ?? []).isDisjoint(with: context.changedPriorityTurnIDs))
    }

    // swiftlint:disable:next function_body_length
    static func appendCodexFileIncrementIfPossible(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws -> Bool
    {
        try context.checkCancellation?()
        guard let cached = input.cached, cached.hasCurrentCodexParser, cached.sessionId != nil,
              !context.forceFullScan else { return false }
        guard !Self.cachedCodexFileNeedsPriorityRescan(cached, context: context) else { return false }
        if Self.cachedCodexRowsNeedIdentityRescan(cached) {
            return false
        }
        // Subagent shape depends on the complete lineage prefix. Appended metadata can change an
        // independent counter into a copied-prefix rollout, so a tail-only parse is not sound.
        let startOffset = cached.parsedBytes ?? cached.size
        let hasMatchingResumeOffset = cached.codexJSONLResumeState?.offset == nil
            || cached.codexJSONLResumeState?.offset == startOffset
        let isResumablePartial = cached.codexScanComplete == false
            && cached.codexScanFileId != nil
            && cached.codexScanFileId == input.metadata.fileId
            && cached.codexScanTargetSize == input.metadata.size
            && cached.mtimeUnixMs == input.metadata.mtimeUnixMs
            && hasMatchingResumeOffset
        if cached.codexScanComplete == false, !isResumablePartial {
            return false
        }
        if !isResumablePartial, try Self.codexFileIsSubagentThread(
            fileURL: input.fileURL,
            checkCancellation: context.checkCancellation)
        {
            return false
        }
        let initialCountedTotals = cached.lastCountedTotals ?? cached.lastTotals
        let initialRawTotalsBaseline = cached.lastRawTotalsBaseline ?? cached.lastTotals
        let initialHasDivergentTotals = cached.hasDivergentTotals ?? (cached.lastTotals == nil)
        // Correctness-critical interleave state is watermark + interleaved flag (+ counted/raw).
        // `seenRawTotals` is optional precision only and must not gate incremental resume (#2037).
        let hasIncompleteInterleaveState =
            (cached.hasInterleavedTotals == true && cached.lastRawTotalsWatermark == nil)
            || (cached.lastRawTotalsWatermark != nil && cached.hasInterleavedTotals == nil)
            || (initialHasDivergentTotals && cached.lastRawTotalsWatermark == nil)
        let canIncremental = startOffset > 0
            && startOffset <= input.metadata.size
            && (isResumablePartial
                || (input.metadata.size > cached.size
                    && (initialCountedTotals != nil || cached.codexRequestLedgerState?.responseIDs.isEmpty == false)
                    && cached.forkedFromId == nil
                    && !hasIncompleteInterleaveState))
        guard canIncremental else { return false }

        let delta = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            startOffset: startOffset,
            initialModel: cached.lastModel,
            initialTotals: initialCountedTotals,
            initialRawTotalsBaseline: initialRawTotalsBaseline,
            initialRawTotalsWatermark: cached.lastRawTotalsWatermark,
            initialSeenRawTotals: cached.seenRawTotals ?? [],
            initialHasDivergentTotals: initialHasDivergentTotals,
            initialHasInterleavedTotals: cached.hasInterleavedTotals ?? false,
            initialCodexTurnID: cached.lastCodexTurnID,
            initialCodexUsageRowIndex: Self.nextCodexUsageRowIndex(cached.codexRows),
            initialBufferedSubagentLines: cached.codexBufferedSubagentLines,
            initialJSONLResumeState: cached.codexJSONLResumeState,
            initialSessionID: cached.sessionId,
            initialRequestLedgerState: cached.codexRequestLedgerState,
            initialRequestLedgerRows: cached.codexRows ?? [],
            maxBytesToRead: maxBytesToRead,
            checkCancellation: context.checkCancellation)
        if delta.forkedFromId != nil, !isResumablePartial {
            return false
        }
        let migrated = Self.codexFileUsageWithCostCache(cached, context: context)
        let cachedSessionMetadata = migrated.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: migrated.sessionId,
            forkedFromId: migrated.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let codexSession = cachedSessionMetadata.merging(delta.codexSession)
        let sessionId = codexSession.sessionId ?? delta.sessionId ?? cached.sessionId
        let projectPath = delta.projectPath ?? cached.projectPath
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: delta.forkedFromId,
            dependsOnParentTotals: delta.dependsOnParentTotals,
            inheritedResolver: context.resources.inheritedResolver)
        let canonicalProjectPath = delta.projectPath.map {
            context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? cached.canonicalProjectPath ?? context.resources.projectPathResolver.canonicalProjectPath(for: projectPath)
        let sessionAlreadyContributed = sessionId.map { state.contributingSessionIds.contains($0) } ?? false
        let cachedRows = (cached.codexRows ?? []).filter {
            $0.eventIndex.map { !delta.replacedLegacyRowIndices.contains($0) } ?? true
        }
        let retainedCachedRows: [CodexUsageRow]
        if sessionAlreadyContributed {
            retainedCachedRows = Self.uniqueCodexRows(
                rows: cachedRows,
                sessionId: sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
        } else {
            Self.rememberCodexRows(
                cachedRows,
                sessionId: sessionId,
                fileIdentity: input.metadata.path,
                state: &state)
            retainedCachedRows = cachedRows
        }
        let recoveredRows = Self.codexRowsRecoveringSavedPricing(
            delta.rows, saved: cached.codexLedgerMigrationRows ?? [])
        let attributedRows = context.usageRowFilter.map { filter in
            recoveredRows.filter { filter($0, codexSession.modelProvider) }
        } ?? recoveredRows
        let uniqueRows = Self.uniqueCodexRows(
            rows: attributedRows,
            sessionId: sessionId,
            fileIdentity: input.metadata.path,
            state: &state)

        let migratedCached = sessionAlreadyContributed || !delta.replacedLegacyRowIndices.isEmpty
            ? Self.codexFileUsageByFilteringRows(migrated, rows: retainedCachedRows, context: context)
            : migrated
        if sessionAlreadyContributed, migratedCached.days.isEmpty, uniqueRows.isEmpty,
           delta.requestLedgerState?.hasMirrorEvidence != true
        {
            Self.dropCachedCodexFile(path: input.metadata.path, cached: cached, cache: &cache)
            return true
        }
        let uniqueDays = Self.codexFileDays(rows: uniqueRows)

        if sessionAlreadyContributed || !delta.replacedLegacyRowIndices.isEmpty {
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
            Self.applyFileDays(cache: &cache, fileDays: migratedCached.days, sign: 1)
        }
        if !uniqueDays.isEmpty {
            Self.applyFileDays(cache: &cache, fileDays: uniqueDays, sign: 1)
        }

        var mergedDays = migratedCached.days
        Self.mergeFileDays(existing: &mergedDays, delta: uniqueDays)
        let splitMaps = Self.codexModeSplitMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)
        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: mergedDays,
            parsedBytes: delta.parsedBytes,
            lastModel: delta.lastModel,
            lastTotals: delta.lastTotals,
            lastCountedTotals: delta.lastCountedTotals,
            lastRawTotalsBaseline: delta.lastRawTotalsBaseline,
            lastRawTotalsWatermark: delta.lastRawTotalsWatermark,
            seenRawTotals: delta.seenRawTotals,
            hasDivergentTotals: delta.hasDivergentTotals,
            hasInterleavedTotals: delta.hasInterleavedTotals,
            lastCodexTurnID: delta.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: codexSession.forkedFromId ?? delta.forkedFromId ?? migratedCached.forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey ?? migratedCached.forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexSession: codexSession.isEmpty ? nil : codexSession,
            codexCostNanos: Self.codexMergedCostMap(
                migratedCached.codexCostNanos,
                deltaRows: uniqueRows,
                context: context),
            codexPrioritySurchargeNanos: Self.codexMergedPrioritySurchargeMap(
                migratedCached.codexPrioritySurchargeNanos,
                deltaRows: uniqueRows,
                context: context),
            codexStandardCostNanos: Self.mergeCostMaps(
                migratedCached.codexStandardCostNanos,
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                migratedCached.codexPriorityCostNanos,
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                migratedCached.codexStandardTokens,
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                migratedCached.codexPriorityTokens,
                splitMaps.priorityTokens),
            codexTurnIDs: Self.mergeCodexTurnIDs(migratedCached.codexTurnIDs, rows: uniqueRows),
            codexRows: Self.codexRowsWithPricingAudit(
                Self.mergeCodexRows(retainedCachedRows, rows: uniqueRows, sessionId: sessionId) ?? [],
                priorityTurns: context.resources.priorityTurns,
                modelsDevCatalog: context.resources.modelsDevCatalog,
                modelsDevCacheRoot: context.resources.modelsDevCacheRoot),
            codexScanFileId: input.metadata.fileId,
            codexScanTargetSize: input.metadata.size,
            codexScanComplete: delta.parsedBytes >= input.metadata.size && delta.jsonlResumeState == nil,
            codexJSONLResumeState: delta.jsonlResumeState,
            codexBufferedSubagentLines: delta.bufferedSubagentLines,
            codexRequestLedgerState: delta.requestLedgerState,
            codexLedgerMigrationRows: delta.parsedBytes >= input.metadata.size && delta.jsonlResumeState == nil
                ? nil : cached.codexLedgerMigrationRows)
            .refreshingCodexWorkspaceUsageFingerprint(
                identity: context.usageIdentity,
                attributionRevision: context.attributionRevision)
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: sessionId, days: mergedDays),
            rows: uniqueRows,
            context: context,
            state: &state)
        return true
    }

    private static func codexRescanIsEmptyDuplicate(
        sessionId: String?,
        rows: [CodexUsageRow],
        days: [String: [String: [Int]]],
        parsed: CodexParseResult,
        state: CodexScanState) -> Bool
    {
        guard let sessionId else { return false }
        return state.contributingSessionIds.contains(sessionId) && rows.isEmpty && days.isEmpty
            && parsed.bufferedSubagentLines == nil && parsed.requestLedgerState?.hasMirrorEvidence != true
    }

    private static func codexRescanRows(
        parsed: CodexParseResult,
        cached: CostUsageFileUsage?,
        migrated: CostUsageFileUsage?,
        session: CostUsageCodexSessionMetadata,
        context: CodexFileScanContext) -> [CodexUsageRow]
    {
        let migrationPrices = cached?.codexLedgerMigrationRows
            ?? (cached?.hasCurrentCodexParser == false ? cached?.codexRows : nil)
        let savedPrices = migrationPrices ?? (context.forceFullScan ? [] : migrated?.codexRows ?? [])
        let recovered = Self.codexRowsRecoveringSavedPricing(parsed.rows, saved: savedPrices)
        return context.usageRowFilter.map { filter in
            recovered.filter { filter($0, session.modelProvider) }
        } ?? recovered
    }

    static func rescanCodexFile(
        input: CodexFileScanInput,
        context: CodexFileScanContext,
        cache: inout CostUsageCache,
        state: inout CodexScanState,
        maxBytesToRead: Int64? = nil) throws
    {
        try context.checkCancellation?()
        if let cached = input.cached {
            self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }
        let migratedCached = input.cached.map { Self.codexFileUsageWithCostCache($0, context: context) }
        var usageDays = context.dropDeferredCodexRows
            ? [:]
            : Self.fileDaysOutsideScanWindow(migratedCached?.days ?? [:], range: context.range)

        let parsed = try Self.parseCodexFileCancellable(
            fileURL: input.fileURL,
            range: context.range,
            maxBytesToRead: maxBytesToRead,
            inheritedTotalsResolver: context.resources.inheritedResolver.inheritedTotals(for:atOrBefore:),
            checkCancellation: context.checkCancellation)
        let forkBaselineDependencyKey = Self.codexForkBaselineDependencyKey(
            parentSessionId: parsed.forkedFromId,
            dependsOnParentTotals: parsed.dependsOnParentTotals,
            inheritedResolver: context.resources.inheritedResolver)
        let cachedSessionMetadata = input.cached?.codexSession ?? CostUsageCodexSessionMetadata(
            sessionId: input.cached?.sessionId,
            forkedFromId: input.cached?.forkedFromId,
            cwd: nil,
            title: nil,
            startedAtUnixMs: nil,
            latestActivityUnixMs: nil)
        let parsedCodexSession = cachedSessionMetadata.merging(parsed.codexSession)
        let sessionId = parsedCodexSession.sessionId ?? parsed.sessionId ?? input.cached?.sessionId
        let projectPath = parsed.projectPath ?? input.cached?.projectPath
        let canonicalProjectPath = parsed.projectPath.map {
            context.resources.projectPathResolver.canonicalProjectPath(for: $0)
        } ?? input.cached?.canonicalProjectPath ?? context.resources.projectPathResolver
            .canonicalProjectPath(for: projectPath)
        let recoveredRows = Self.codexRescanRows(
            parsed: parsed,
            cached: input.cached,
            migrated: migratedCached,
            session: parsedCodexSession,
            context: context)
        let uniqueRows = Self.uniqueCodexRows(
            rows: recoveredRows,
            sessionId: sessionId,
            fileIdentity: input.metadata.path,
            state: &state)
        if Self.codexRescanIsEmptyDuplicate(
            sessionId: sessionId, rows: uniqueRows, days: usageDays, parsed: parsed, state: state)
        {
            cache.files.removeValue(forKey: input.metadata.path)
            return
        }
        let uniqueDays = Self.codexFileDays(rows: uniqueRows)
        Self.mergeFileDays(existing: &usageDays, delta: uniqueDays)
        let splitMaps = Self.codexModeSplitMaps(
            rows: uniqueRows,
            range: context.range,
            priorityTurns: context.resources.priorityTurns,
            modelsDevCatalog: context.resources.modelsDevCatalog,
            modelsDevCacheRoot: context.resources.modelsDevCacheRoot)

        cache.files[input.metadata.path] = Self.makeFileUsage(
            mtimeUnixMs: input.metadata.mtimeUnixMs,
            size: input.metadata.size,
            days: usageDays,
            parsedBytes: parsed.parsedBytes,
            lastModel: parsed.lastModel,
            lastTotals: parsed.lastTotals,
            lastCountedTotals: parsed.lastCountedTotals,
            lastRawTotalsBaseline: parsed.lastRawTotalsBaseline,
            lastRawTotalsWatermark: parsed.lastRawTotalsWatermark,
            seenRawTotals: parsed.seenRawTotals,
            hasDivergentTotals: parsed.hasDivergentTotals,
            hasInterleavedTotals: parsed.hasInterleavedTotals,
            lastCodexTurnID: parsed.lastCodexTurnID,
            sessionId: sessionId,
            forkedFromId: parsedCodexSession.forkedFromId ?? parsed.forkedFromId,
            forkBaselineDependencyKey: forkBaselineDependencyKey,
            projectPath: projectPath,
            canonicalProjectPath: canonicalProjectPath,
            codexSession: parsedCodexSession.isEmpty ? nil : parsedCodexSession,
            codexCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexCostNanos, range: context.range),
                Self.codexCostNanos(
                    rows: uniqueRows,
                    range: context.range,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexPrioritySurchargeNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPrioritySurchargeNanos, range: context.range),
                Self.codexPrioritySurchargeNanos(
                    rows: uniqueRows,
                    range: context.range,
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot)),
            codexStandardCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexStandardCostNanos, range: context.range),
                splitMaps.standardCostNanos),
            codexPriorityCostNanos: Self.mergeCostMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.costMapOutsideScanWindow(migratedCached?.codexPriorityCostNanos, range: context.range),
                splitMaps.priorityCostNanos),
            codexStandardTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexStandardTokens, range: context.range),
                splitMaps.standardTokens),
            codexPriorityTokens: Self.mergeIntMaps(
                context.dropDeferredCodexRows
                    ? nil
                    : Self.intMapOutsideScanWindow(migratedCached?.codexPriorityTokens, range: context.range),
                splitMaps.priorityTokens),
            codexTurnIDs: context.dropDeferredCodexRows
                ? Self.codexTurnIDs(rows: uniqueRows)
                : Self.mergeCodexTurnIDs(migratedCached?.codexTurnIDs, rows: uniqueRows),
            codexRows: context.dropDeferredCodexRows
                ? nil
                : Self.codexRowsWithPricingAudit(
                    Self.mergeCodexRows(
                        migratedCached?.codexRows?.filter {
                            !CostUsageDayRange.isInRange(
                                dayKey: $0.day, since: context.range.scanSinceKey, until: context.range.scanUntilKey)
                        },
                        rows: uniqueRows,
                        sessionId: sessionId) ?? [],
                    priorityTurns: context.resources.priorityTurns,
                    modelsDevCatalog: context.resources.modelsDevCatalog,
                    modelsDevCacheRoot: context.resources.modelsDevCacheRoot),
            codexScanFileId: input.metadata.fileId,
            codexScanTargetSize: input.metadata.size,
            codexScanComplete: parsed.parsedBytes >= input.metadata.size && parsed.jsonlResumeState == nil,
            codexJSONLResumeState: parsed.jsonlResumeState,
            codexBufferedSubagentLines: parsed.bufferedSubagentLines,
            codexRequestLedgerState: parsed.requestLedgerState,
            codexLedgerMigrationRows: parsed.parsedBytes >= input.metadata.size && parsed.jsonlResumeState == nil
                ? nil : input.cached?.codexLedgerMigrationRows ?? input.cached?.codexRows)
            .refreshingCodexWorkspaceUsageFingerprint(
                identity: context.usageIdentity,
                attributionRevision: context.attributionRevision)
        Self.applyFileDays(cache: &cache, fileDays: cache.files[input.metadata.path]?.days ?? [:], sign: 1)
        Self.rememberScannedCodexFile(
            input: input,
            session: CodexScannedSession(id: sessionId, days: usageDays),
            rows: uniqueRows,
            context: context,
            state: &state)
    }

    static func codexForkBaselineDependencyKey(
        parentSessionId: String?,
        dependsOnParentTotals: Bool,
        inheritedResolver: CodexInheritedTotalsResolver) -> String?
    {
        guard let parentSessionId else { return nil }
        guard dependsOnParentTotals else { return Self.codexForkDependencyNotRequiredKey }

        // A nil key means the parent changed while its snapshots were read (or no stable
        // snapshot was resolved). Preserve nil so the child cannot be reused on the next scan.
        return inheritedResolver.dependencyKeyUsed(for: parentSessionId)
    }

    static func mergeFileDays(
        existing: inout [String: [String: [Int]]],
        delta: [String: [String: [Int]]])
    {
        for (day, models) in delta {
            var dayModels = existing[day] ?? [:]
            for (model, packed) in models {
                let existingPacked = dayModels[model] ?? []
                let merged = self.addPacked(a: existingPacked, b: packed, sign: 1)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                existing.removeValue(forKey: day)
            } else {
                existing[day] = dayModels
            }
        }
    }

    static func fileDaysOutsideScanWindow(
        _ days: [String: [String: [Int]]],
        range: CostUsageDayRange) -> [String: [String: [Int]]]
    {
        days.filter {
            !CostUsageDayRange.isInRange(dayKey: $0.key, since: range.scanSinceKey, until: range.scanUntilKey)
        }
    }

    static func applyFileDays(cache: inout CostUsageCache, fileDays: [String: [String: [Int]]], sign: Int) {
        for (day, models) in fileDays {
            var dayModels = cache.days[day] ?? [:]
            for (model, packed) in models {
                let existing = dayModels[model] ?? []
                let merged = self.addPacked(a: existing, b: packed, sign: sign)
                if merged.allSatisfy({ $0 == 0 }) {
                    dayModels.removeValue(forKey: model)
                } else {
                    dayModels[model] = merged
                }
            }

            if dayModels.isEmpty {
                cache.days.removeValue(forKey: day)
            } else {
                cache.days[day] = dayModels
            }
        }
    }

    static func pruneDays(cache: inout CostUsageCache, sinceKey: String, untilKey: String) {
        for key in cache.days.keys where !CostUsageDayRange.isInRange(dayKey: key, since: sinceKey, until: untilKey) {
            cache.days.removeValue(forKey: key)
        }
    }

    static func hasCompressedCodexArchiveSibling(path: String, fileManager: FileManager = .default) -> Bool {
        guard path.lowercased().hasSuffix(".jsonl") else { return false }
        return fileManager.fileExists(atPath: path + ".zst")
    }

    static func pruneForceRescanFilesOutsideWindow(
        cache: inout CostUsageCache,
        range: CostUsageDayRange,
        isForceRescan: Bool)
    {
        guard isForceRescan else { return }
        for key in cache.files.keys {
            guard let old = cache.files[key] else { continue }
            guard !old.touchesCodexScanWindow(sinceKey: range.scanSinceKey, untilKey: range.scanUntilKey)
            else { continue }
            if Self.hasCompressedCodexArchiveSibling(path: key) { continue }
            Self.applyFileDays(cache: &cache, fileDays: old.days, sign: -1)
            cache.files.removeValue(forKey: key)
        }
    }

    static func requestedWindowExpandsCache(range: CostUsageDayRange, cache: CostUsageCache) -> Bool {
        guard let cachedSince = cache.scanSinceKey,
              let cachedUntil = cache.scanUntilKey
        else {
            return cache.lastScanUnixMs != 0 || !cache.files.isEmpty || !cache.days.isEmpty
        }
        return range.scanSinceKey < cachedSince || range.scanUntilKey > cachedUntil
    }

    static func addPacked(a: [Int], b: [Int], sign: Int) -> [Int] {
        let len = max(a.count, b.count)
        var out: [Int] = Array(repeating: 0, count: len)
        for idx in 0..<len {
            let next = (a[safe: idx] ?? 0) + sign * (b[safe: idx] ?? 0)
            out[idx] = max(0, next)
        }
        return out
    }

    // swiftlint:disable:next function_body_length
    static func buildCodexReportFromCache(
        cache: CostUsageCache,
        range: CostUsageDayRange,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil,
        priorityTurns: [String: CodexPriorityTurnMetadata] = [:],
        modelsDevCatalogLoader: (URL?) -> ModelsDevCatalog? = {
            CostUsagePricing.modelsDevCatalog(cacheRoot: $0)
        }) -> CostUsageDailyReport
    {
        let catalogResolver = CodexModelsDevCatalogResolver(
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        var reportCache = cache
        for (path, usage) in cache.files where self.needsCodexCostCache(usage, range: range) {
            reportCache.files[path] = self.codexFileUsageWithCostCache(
                usage,
                range: range,
                priorityTurns: priorityTurns,
                modelsDevCatalog: catalogResolver.load(modelsDevCatalogLoader),
                modelsDevCacheRoot: modelsDevCacheRoot)
        }
        var entries: [CostUsageDailyReport.Entry] = []
        var (totalInput, totalCacheRead, totalOutput, totalTokens) = (0, 0, 0, 0)
        var (totalCost, costSeen) = (0.0, false)

        let dayKeys = self.codexReportDayKeys(cache: reportCache, range: range)
        let costNanosByDayModel = self.codexCostNanosByDayModel(cache: reportCache, range: range)
        let prioritySurchargeNanosByDayModel = self.codexPrioritySurchargeNanosByDayModel(
            cache: reportCache,
            range: range)
        let standardCostNanosByDayModel = self.codexStandardCostNanosByDayModel(cache: reportCache, range: range)
        let priorityCostNanosByDayModel = self.codexPriorityCostNanosByDayModel(cache: reportCache, range: range)
        let standardTokensByDayModel = self.codexStandardTokensByDayModel(cache: reportCache, range: range)
        let priorityTokensByDayModel = self.codexPriorityTokensByDayModel(cache: reportCache, range: range)
        let savedUnpricedModels = Set(reportCache.files.values.flatMap { file in
            (file.codexRows ?? []).compactMap { row in
                row.preservesSavedPricing == true && (row.unpricedTokens ?? 0) > 0
                    ? row.day + "\u{1F}" + row.model : nil
            }
        })

        for day in dayKeys {
            guard let models = reportCache.days[day] else { continue }
            let modelNames = models.keys.sorted()

            var dayInput = 0
            var dayCacheRead = 0
            var dayOutput = 0
            var breakdown: [CostUsageDailyReport.ModelBreakdown] = []
            var dayCost: Double = 0
            var dayCostSeen = false

            for model in modelNames {
                let packed = models[model] ?? [0, 0, 0]
                let input = packed[safe: 0] ?? 0
                let cached = packed[safe: 1] ?? 0
                let output = packed[safe: 2] ?? 0
                let totalTokens = input + output

                dayInput += input
                dayCacheRead += cached
                dayOutput += output

                let cachedBaseCost = costNanosByDayModel[day]?[model].map { Double($0) / Self.costScale }
                let cachedStandardCost = standardCostNanosByDayModel[day]?[model].map {
                    Double($0) / Self.costScale
                }
                let cachedPriorityCost = priorityCostNanosByDayModel[day]?[model].map {
                    Double($0) / Self.costScale
                }
                let cachedStandardTokens = standardTokensByDayModel[day]?[model]
                let cachedPriorityTokens = priorityTokensByDayModel[day]?[model]
                let normalizedSplit = Self.normalizedCodexModeSplit(
                    canonicalTotalTokens: totalTokens,
                    standardTokens: cachedStandardTokens,
                    priorityTokens: cachedPriorityTokens,
                    standardCostUSD: cachedStandardCost,
                    priorityCostUSD: cachedPriorityCost)
                let hasSavedUnpricedUsage = savedUnpricedModels.contains(day + "\u{1F}" + model)
                func fallbackCost() -> Double? {
                    guard !hasSavedUnpricedUsage else { return nil }
                    return CostUsagePricing.codexCostUSD(
                        model: model,
                        inputTokens: input,
                        cachedInputTokens: cached,
                        outputTokens: output,
                        modelsDevCatalog: catalogResolver.load(modelsDevCatalogLoader),
                        modelsDevCacheRoot: modelsDevCacheRoot)
                }
                let canonicalCost: Double? = if normalizedSplit.wasNormalized {
                    cachedBaseCost
                        ?? fallbackCost()
                } else {
                    nil
                }
                let normalizedSplitCost: Double? = if normalizedSplit.standardCostUSD != nil
                    || normalizedSplit.priorityCostUSD != nil
                {
                    (normalizedSplit.standardCostUSD ?? 0) + (normalizedSplit.priorityCostUSD ?? 0)
                } else {
                    nil
                }
                let modeCostScale: Double? = if normalizedSplit.wasNormalized,
                                                let canonicalCost,
                                                let normalizedSplitCost,
                                                normalizedSplitCost > 0
                {
                    canonicalCost / normalizedSplitCost
                } else {
                    nil
                }
                let standardCost = normalizedSplit.standardCostUSD.map { $0 * (modeCostScale ?? 1) }
                let priorityCost = normalizedSplit.priorityCostUSD.map { $0 * (modeCostScale ?? 1) }
                let splitTotalCost: Double? = if standardCost != nil || priorityCost != nil {
                    (standardCost ?? 0) + (priorityCost ?? 0)
                } else {
                    nil
                }
                var cost = if normalizedSplit.wasNormalized {
                    canonicalCost ?? splitTotalCost
                } else {
                    splitTotalCost
                        ?? cachedBaseCost
                        ?? fallbackCost()
                }
                if splitTotalCost == nil,
                   let surchargeNanos = prioritySurchargeNanosByDayModel[day]?[model],
                   cachedBaseCost != nil
                {
                    cost = (cost ?? 0) + (Double(surchargeNanos) / Self.costScale)
                }
                let hasModeSplit = priorityCost != nil || cachedPriorityTokens != nil
                breakdown.append(
                    CostUsageDailyReport.ModelBreakdown(
                        modelName: model,
                        costUSD: cost,
                        totalTokens: totalTokens,
                        standardCostUSD: hasModeSplit ? standardCost : nil,
                        priorityCostUSD: hasModeSplit ? priorityCost : nil,
                        standardTokens: hasModeSplit ? normalizedSplit.standardTokens : nil,
                        priorityTokens: hasModeSplit ? normalizedSplit.priorityTokens : nil,
                        splitEstimateNormalized: normalizedSplit.wasNormalized))
                if let cost {
                    dayCost += cost
                    dayCostSeen = true
                }
            }

            let dayTotal = dayInput + dayOutput
            let entryCost = dayCostSeen ? dayCost : nil
            entries.append(CostUsageDailyReport.Entry(
                date: day,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead > 0 ? dayCacheRead : nil,
                totalTokens: dayTotal,
                costUSD: entryCost,
                modelsUsed: modelNames,
                modelBreakdowns: Self.sortedModelBreakdowns(breakdown)))

            totalInput += dayInput
            totalCacheRead += dayCacheRead
            totalOutput += dayOutput
            totalTokens += dayTotal
            if let entryCost {
                totalCost += entryCost
                costSeen = true
            }
        }

        let summary: CostUsageDailyReport.Summary? = entries.isEmpty
            ? nil
            : CostUsageDailyReport.Summary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                cacheReadTokens: totalCacheRead > 0 ? totalCacheRead : nil,
                totalTokens: totalTokens,
                totalCostUSD: costSeen ? totalCost : nil)

        return CostUsageDailyReport(data: entries, summary: summary)
    }

    static func sortedModelBreakdowns(_ breakdowns: [CostUsageDailyReport.ModelBreakdown])
        -> [CostUsageDailyReport.ModelBreakdown]
    {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }

        let calendar = CostUsageDayRange.localGregorianCalendar(matching: calendar)
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }
}

extension Data {
    func containsAscii(_ needle: String) -> Bool {
        guard let n = needle.data(using: .utf8) else { return false }
        return self.range(of: n) != nil
    }
}

extension [Int] {
    subscript(safe index: Int) -> Int? {
        if index < 0 {
            return nil
        }
        if index >= self.count {
            return nil
        }
        return self[index]
    }
}

extension [UInt8] {
    subscript(safe index: Int) -> UInt8? {
        if index < 0 {
            return nil
        }
        if index >= self.count {
            return nil
        }
        return self[index]
    }
}

extension CostUsageFileUsage {
    func touchesCodexScanWindow(sinceKey: String, untilKey: String) -> Bool {
        self.days.keys.contains {
            CostUsageScanner.CostUsageDayRange.isInRange(dayKey: $0, since: sinceKey, until: untilKey)
        }
    }
}
