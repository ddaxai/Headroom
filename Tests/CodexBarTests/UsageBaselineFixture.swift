import Foundation

enum UsageBaselinePeriod: String, Codable, CaseIterable, Sendable {
    case rolling24Hours = "24h"
    case last7Days = "7d"
    case last30Days = "30d"
}

struct UsageBaselineFixture: Decodable, Equatable, Sendable {
    struct ResetCredits: Decodable, Equatable, Sendable {
        let count: Int
        let expiresAt: Date
    }

    struct Window: Decodable, Equatable, Sendable {
        let period: UsageBaselinePeriod
        let localTokens: Int?
        let reportedTokens: Int?
    }

    struct OfficialAccount: Decodable, Equatable, Sendable {
        let id: String
        let isActive: Bool
        let resetCredits: ResetCredits?
        let windows: [Window]

        func localTokens(for period: UsageBaselinePeriod) -> Int? {
            self.windows.first { $0.period == period }?.localTokens
        }
    }

    struct Relay: Decodable, Equatable, Sendable {
        let id: String
        let multiplier: Double?
        let reportsUsage: Bool
        let windows: [Window]

        func localTokens(for period: UsageBaselinePeriod) -> Int? {
            self.windows.first { $0.period == period }?.localTokens
        }

        func reportedTokens(for period: UsageBaselinePeriod) -> Int? {
            self.windows.first { $0.period == period }?.reportedTokens
        }
    }

    struct Unassigned: Decodable, Equatable, Sendable {
        let id: String
        let windows: [Window]

        func localTokens(for period: UsageBaselinePeriod) -> Int? {
            self.windows.first { $0.period == period }?.localTokens
        }
    }

    struct Total: Decodable, Equatable, Sendable {
        let period: UsageBaselinePeriod
        let localTokens: Int
    }

    struct Chart: Equatable, Sendable {
        struct Row: Equatable, Identifiable, Sendable {
            enum Kind: Equatable, Sendable {
                case official
                case relay
                case unassigned
            }

            let id: String
            let kind: Kind
            let localTokens: Int
        }

        let period: UsageBaselinePeriod
        let rows: [Row]
        let unavailableSourceIDs: [String]
        let totalLocalTokens: Int
    }

    let schemaVersion: Int
    let officialAccounts: [OfficialAccount]
    let relays: [Relay]
    let unassigned: Unassigned
    let totals: [Total]

    static func load() throws -> Self {
        guard let url = Bundle.module.url(
            forResource: "usage_baseline",
            withExtension: "json",
            subdirectory: "Fixtures")
        else {
            throw FixtureError.missingResource
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try fixture.validate()
        return fixture
    }

    func totalLocalTokens(for period: UsageBaselinePeriod) -> Int? {
        self.totals.first { $0.period == period }?.localTokens
    }

    func localSourceSum(for period: UsageBaselinePeriod) -> Int {
        let official = self.officialAccounts.compactMap { $0.localTokens(for: period) }.reduce(0, +)
        let relay = self.relays.compactMap { $0.localTokens(for: period) }.reduce(0, +)
        return official + relay + (self.unassigned.localTokens(for: period) ?? 0)
    }

    func chart(for period: UsageBaselinePeriod) -> Chart? {
        guard let total = self.totalLocalTokens(for: period), total > 0 else { return nil }
        let officialRows = self.officialAccounts.compactMap { account -> Chart.Row? in
            guard let tokens = account.localTokens(for: period) else { return nil }
            return Chart.Row(id: account.id, kind: .official, localTokens: tokens)
        }
        let relayRows = self.relays.compactMap { relay -> Chart.Row? in
            guard let tokens = relay.localTokens(for: period) else { return nil }
            return Chart.Row(id: relay.id, kind: .relay, localTokens: tokens)
        }
        let unassignedRows = self.unassigned.localTokens(for: period).map {
            [Chart.Row(id: self.unassigned.id, kind: .unassigned, localTokens: $0)]
        } ?? []
        return Chart(
            period: period,
            rows: officialRows + relayRows + unassignedRows,
            unavailableSourceIDs: self.relays.filter { $0.localTokens(for: period) == nil }.map(\.id),
            totalLocalTokens: total)
    }

    private func validate() throws {
        guard self.schemaVersion == 1 else {
            throw FixtureError.unsupportedSchema(self.schemaVersion)
        }

        let sourceIDs = self.officialAccounts.map(\.id) + self.relays.map(\.id) + [self.unassigned.id]
        guard sourceIDs.allSatisfy({ !$0.isEmpty }), Set(sourceIDs).count == sourceIDs.count else {
            throw FixtureError.invalidSourceIDs
        }

        for account in self.officialAccounts {
            try Self.validateWindows(account.windows, sourceID: account.id)
            if let credits = account.resetCredits, credits.count < 1 {
                throw FixtureError.invalidResetCredits(account.id)
            }
        }
        for relay in self.relays {
            try Self.validateWindows(relay.windows, sourceID: relay.id)
            if let multiplier = relay.multiplier, !multiplier.isFinite || multiplier <= 0 {
                throw FixtureError.invalidMultiplier(relay.id)
            }
            if !relay.reportsUsage,
               relay.windows.contains(where: { $0.localTokens != nil || $0.reportedTokens != nil })
            {
                throw FixtureError.unavailableRelayContainsUsage(relay.id)
            }
        }
        try Self.validateWindows(self.unassigned.windows, sourceID: self.unassigned.id)

        let totalPeriods = self.totals.map(\.period)
        guard totalPeriods.count == UsageBaselinePeriod.allCases.count,
              Set(totalPeriods) == Set(UsageBaselinePeriod.allCases),
              self.totals.allSatisfy({ $0.localTokens >= 0 })
        else {
            throw FixtureError.invalidTotals
        }

        for period in UsageBaselinePeriod.allCases {
            guard self.localSourceSum(for: period) == self.totalLocalTokens(for: period) else {
                throw FixtureError.nonConservingWindow(period)
            }
        }
    }

    private static func validateWindows(_ windows: [Window], sourceID: String) throws {
        let periods = windows.map(\.period)
        guard periods.count == UsageBaselinePeriod.allCases.count,
              Set(periods) == Set(UsageBaselinePeriod.allCases),
              windows.allSatisfy({ ($0.localTokens ?? 0) >= 0 && ($0.reportedTokens ?? 0) >= 0 })
        else {
            throw FixtureError.invalidWindows(sourceID)
        }
    }

    enum FixtureError: Error, Equatable {
        case missingResource
        case unsupportedSchema(Int)
        case invalidSourceIDs
        case invalidResetCredits(String)
        case invalidMultiplier(String)
        case unavailableRelayContainsUsage(String)
        case invalidWindows(String)
        case invalidTotals
        case nonConservingWindow(UsageBaselinePeriod)
    }
}
