import Foundation

/// Converts the scanner's already delta-normalized Codex rows into ledger entries.
///
/// Codex reports cached input inside `input_tokens`, so the ledger stores
/// `input - cached` and `cached` as disjoint columns. `output_tokens` already
/// contains reasoning tokens; reasoning is therefore informational and is not
/// added again. Codex does not report cache creation separately, so that column
/// is zero. The scanner owns cumulative-total and fork replay deduplication;
/// this adapter keeps every distinct normalized row, including multiple rows
/// that share a turn identifier.
enum CodexUsageLedgerAdapter {
    static func entries(
        sessionID: String?,
        modelProvider: String?,
        rows: [CostUsageScanner.CodexUsageRow],
        timeline: CodexSessionOwnershipTimeline) -> [UsageLedgerEntry]
    {
        rows.enumerated().map { offset, row in
            let timestamp = self.timestamp(for: row)
            let provenance = CodexSessionProvenanceClassifier.classify(
                timestampUnixMs: row.timestampUnixMs,
                modelProvider: modelProvider,
                timeline: timeline)
            let identity = self.identity(for: provenance)
            let input = max(0, row.input)
            let cacheRead = min(input, max(0, row.cached))
            let output = max(0, row.output)
            return UsageLedgerEntry(
                key: UsageLedgerKey(
                    identityID: identity.id,
                    routeProfileID: identity.routeProfileID,
                    targetApp: .codex,
                    model: row.model,
                    requestID: self.requestID(for: row, fallbackOffset: offset),
                    sessionID: sessionID,
                    timestamp: timestamp),
                attribution: identity.attribution,
                amounts: UsageLedgerAmounts(
                    inputTokens: input - cacheRead,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheCreationTokens: 0,
                    totalTokens: input + output,
                    requestCount: 1,
                    costUSD: row.knownCostNanos.map { Double($0) / 1_000_000_000 }))
        }
    }

    private struct LedgerIdentity {
        let id: String
        let routeProfileID: UUID?
        let attribution: UsageLedgerAttribution
    }

    private static func identity(for provenance: CodexSessionProvenance) -> LedgerIdentity {
        switch provenance {
        case let .official(accountKey?) where !accountKey.isEmpty:
            LedgerIdentity(id: accountKey, routeProfileID: nil, attribution: .official)
        case let .relay(profileID?):
            LedgerIdentity(
                id: "relay:\(profileID.uuidString.lowercased()):codex",
                routeProfileID: profileID,
                attribution: .relay)
        case .relay(profileID: nil):
            LedgerIdentity(id: "relay:aggregate:codex", routeProfileID: nil, attribution: .relay)
        case .official, .unassigned:
            LedgerIdentity(id: "system-unassigned:codex", routeProfileID: nil, attribution: .unassigned)
        }
    }

    private static func requestID(for row: CostUsageScanner.CodexUsageRow, fallbackOffset: Int) -> String {
        let event = row.eventIndex ?? fallbackOffset
        if let turnID = row.turnID?.trimmingCharacters(in: .whitespacesAndNewlines), !turnID.isEmpty {
            return "\(turnID):\(event)"
        }
        return "event:\(event)"
    }

    private static func timestamp(for row: CostUsageScanner.CodexUsageRow) -> Date {
        if let timestampUnixMs = row.timestampUnixMs {
            return Date(timeIntervalSince1970: Double(timestampUnixMs) / 1000)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = row.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(
                  year: parts[0],
                  month: parts[1],
                  day: parts[2],
                  hour: 12))
        else { return Date(timeIntervalSince1970: 0) }
        return date
    }
}
