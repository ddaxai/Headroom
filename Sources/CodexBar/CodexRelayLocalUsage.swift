import CodexBarCore
import Foundation

struct CodexRelayLocalUsageWindow: Equatable, Sendable {
    let relayTokens: Int
    let corpusTokens: Int

    var percent: Double {
        Double(self.relayTokens) / Double(self.corpusTokens) * 100
    }
}

struct CodexRelayLocalUsagePresentation: Equatable, Sendable {
    let rolling24Hours: CodexRelayLocalUsageWindow?
    let last7Days: CodexRelayLocalUsageWindow?

    static func make(
        fullCorpus: CostUsageTokenSnapshot,
        relay: CostUsageTokenSnapshot,
        calendar: Calendar = .current) -> Self?
    {
        // A shared `now` is only a display boundary. The scanner-derived corpus revision proves
        // both partitions came from the same stable, fully parsed set of rollout files.
        guard CodexStackedUsageSummary.shareCorpusGeneration([fullCorpus, relay]) else { return nil }

        let rolling = Self.window(
            relayTokens: Self.exactRolling24HourTokens(relay) ?? 0,
            corpusTokens: Self.exactRolling24HourTokens(fullCorpus))

        let sevenDays: CodexRelayLocalUsageWindow? = if fullCorpus.historyDays >= 7,
                                                        relay.historyDays >= 7,
                                                        fullCorpus.historyCoverageIsEstablished,
                                                        relay.historyCoverageIsEstablished
        {
            Self.window(
                relayTokens: relay.summary(forLastDays: 7, calendar: calendar).totalTokens ?? 0,
                corpusTokens: fullCorpus.summary(forLastDays: 7, calendar: calendar).totalTokens)
        } else {
            nil
        }

        guard rolling != nil || sevenDays != nil else { return nil }
        return Self(rolling24Hours: rolling, last7Days: sevenDays)
    }

    private static func exactRolling24HourTokens(_ snapshot: CostUsageTokenSnapshot) -> Int? {
        if let rolling = snapshot.rolling24Hours { return rolling.totalTokens }
        guard !snapshot.hourly24Hours.isEmpty else { return nil }
        return snapshot.hourly24Hours.reduce(0) { $0 + $1.totalTokens }
    }

    private static func window(relayTokens: Int, corpusTokens: Int?) -> CodexRelayLocalUsageWindow? {
        guard let corpusTokens, corpusTokens > 0,
              relayTokens >= 0,
              relayTokens <= corpusTokens
        else { return nil }
        return CodexRelayLocalUsageWindow(relayTokens: relayTokens, corpusTokens: corpusTokens)
    }
}

enum CodexRelayLocalUsageSource {
    static func load(profileID: UUID, now: Date = Date()) async -> CodexRelayLocalUsagePresentation? {
        guard !Task.isCancelled,
              let timeline = try? FileCodexSessionOwnershipTimelineStore.default.load(),
              timeline.codexRelayProfileIDs.contains(profileID)
        else { return nil }
        let revision = timeline.revision
        let homePath = CodexHomeScope.ambientHomeURL(env: ProcessInfo.processInfo.environment).path
        let cacheRoot = UsageStore.costUsageCacheDirectory()
            .appendingPathComponent("relay-settings", isDirectory: true)

        do {
            let full = try await SpendDashboardSource.loadFullCorpusCodexSnapshot(
                sharedHomePath: homePath,
                now: now,
                forceRefresh: true,
                historyDays: SpendDashboardSource.scanDays,
                cacheRoot: cacheRoot.appendingPathComponent("full", isDirectory: true))
            guard !Task.isCancelled else { return nil }
            let relay = try await CostUsageFetcher(
                cacheRoot: cacheRoot.appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true))
                .loadRelaySharedCodexTokenSnapshot(
                    now: now,
                    sharedCodexHomePath: homePath,
                    profileID: profileID,
                    timeline: timeline,
                    historyDays: SpendDashboardSource.scanDays,
                    forceRefresh: true)
            guard !Task.isCancelled,
                  (try? FileCodexSessionOwnershipTimelineStore.default.load().revision) == revision
            else { return nil }
            return CodexRelayLocalUsagePresentation.make(fullCorpus: full, relay: relay)
        } catch {
            return nil
        }
    }
}
