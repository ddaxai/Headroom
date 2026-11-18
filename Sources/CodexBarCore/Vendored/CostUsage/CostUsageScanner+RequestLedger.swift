import CoreFoundation
import Foundation

/// Adapted from steipete/CodexBar a555a82 (#4195); persistence uses Headroom JSON caches.
extension CostUsageScanner {
    struct CodexRequestLedgerState: Codable, Equatable {
        var responseIDs: Set<String> = []
        var mirroredResponses: [String: String]? = [:]
        var legacyRowIndices: [String: Int] = [:]
        var turnModels: [String: String] = [:]
        var activeTurnID: String?
        var sessionID: String?
        var pendingLedgerMirrors: Set<String>?
        var pendingLedgerResponseID: String?
        var pendingLegacyMirrors: Set<String>?
        var pendingLegacyRowIndex: Int?
        var countedUsage: CostUsageCodexTotals?

        var hasMirrorEvidence: Bool {
            !(self.mirroredResponses ?? [:]).isEmpty
        }

        mutating func clearPendingMirrors(when shouldClear: Bool = true) {
            guard shouldClear else { return }
            self.pendingLedgerMirrors = nil
            self.pendingLedgerResponseID = nil
            self.pendingLegacyMirrors = nil
            self.pendingLegacyRowIndex = nil
        }

        mutating func beginLegacyObservation(keys: Set<String>?, snapshot: String?) {
            defer { self.clearPendingMirrors() }
            guard let keys, let pending = self.pendingLedgerMirrors, !keys.isDisjoint(with: pending),
                  let snapshot, let responseID = self.pendingLedgerResponseID else { return }
            self.rememberMirrors([snapshot], responseID: responseID)
        }

        mutating func rememberMirrors(_ keys: [String], responseID: String) {
            if self.mirroredResponses == nil { self.mirroredResponses = [:] }
            for key in keys {
                self.mirroredResponses?[key] = responseID
            }
        }
    }

    struct CodexRequestUsageRecord: Codable, Equatable {
        let timestamp: String
        let threadID: String
        let sessionID: String?
        let responseID: String
        let turnID: String?
        let model: String?
        let usage: CostUsageCodexTotals
        let threadTotal: CostUsageCodexTotals
        let turnTotal: CostUsageCodexTotals?
    }

    static func codexRequestUsageRecord(from object: [String: Any]) -> CodexRequestUsageRecord? {
        guard let payload = object["payload"] as? [String: Any],
              let threadID = codexModelEvidence(payload["thread_id"] as? String),
              let responseID = codexModelEvidence(payload["response_id"] as? String),
              let timestamp = object["timestamp"] as? String,
              let usage = (payload["usage"] as? [String: Any]).flatMap(codexRequestUsage),
              let total = (payload["thread_token_usage"] as? [String: Any]).flatMap(codexRequestUsage),
              codexTotalsAtLeast(total, usage)
        else { return nil }
        let sessionID = Self.codexModelEvidence(payload["session_id"] as? String)
        guard payload["session_id"] == nil || sessionID != nil else { return nil }
        let turnTotal = (payload["turn_token_usage"] as? [String: Any]).flatMap(Self.codexRequestUsage)
        return CodexRequestUsageRecord(
            timestamp: timestamp,
            threadID: threadID,
            sessionID: sessionID,
            responseID: responseID,
            turnID: Self.codexTurnID(from: payload),
            model: Self.codexModelEvidence(payload["model"] as? String),
            usage: usage,
            threadTotal: total,
            turnTotal: turnTotal.flatMap { Self.codexTotalsAtLeast($0, usage) ? $0 : nil })
    }

    static func codexRequestUsage(_ usage: [String: Any]) -> CostUsageCodexTotals? {
        func integer(_ key: String, defaultValue: Int? = nil) -> Int? {
            guard let value = usage[key] else { return defaultValue }
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.intValue
        }
        guard let input = integer("input_tokens"), let output = integer("output_tokens"),
              let cached = integer("cached_input_tokens", defaultValue: 0), cached <= input,
              let reasoning = integer("reasoning_output_tokens", defaultValue: 0), reasoning <= output,
              !input.addingReportingOverflow(output).overflow
        else { return nil }
        return CostUsageCodexTotals(input: input, cached: cached, output: output, reasoning: reasoning)
    }
}

extension CostUsageScanner {
    static func codexRowWithSavedPricing(_ row: CodexUsageRow, saved: CodexUsageRow) -> CodexUsageRow {
        CodexUsageRow(
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
            knownCostNanos: saved.knownCostNanos,
            unpricedTokens: saved.unpricedTokens,
            pricingModel: saved.pricingModel,
            pricingMode: saved.pricingMode,
            responseID: row.responseID,
            requestMirrorKeys: row.requestMirrorKeys,
            preservesSavedPricing: true)
    }

    /// A bounded parser upgrade changes row indices and identities, not a matched request's billing evidence.
    static func codexRowsRecoveringSavedPricing(_ rows: [CodexUsageRow], saved: [CodexUsageRow]) -> [CodexUsageRow] {
        func key(_ row: CodexUsageRow) -> String {
            [
                row.turnID ?? "",
                row.model,
                row.timestampUnixMs.map(String.init) ?? "",
                row.day,
                String(row.input),
                String(row.cached),
                String(row.output),
            ].joined(separator: "\u{1F}")
        }
        let prices = Dictionary(
            saved.filter { $0.timestampUnixMs != nil }.map { (key($0), $0) },
            uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            guard let previous = prices[key(row)] else { return row }
            return Self.codexRowWithSavedPricing(row, saved: previous)
        }
    }
}

extension CostUsageScanner.CodexFastLine {
    var boundaryTokenCount: CostUsageScanner.CodexTokenCountRecord? {
        switch self {
        case let .tokenCount(record): record
        case let .tokenUsageRecord(record):
            CostUsageScanner.CodexTokenCountRecord(
                timestamp: record.timestamp,
                model: record.model,
                turnID: record.turnID,
                last: record.usage,
                total: record.threadTotal)
        default: nil
        }
    }
}
