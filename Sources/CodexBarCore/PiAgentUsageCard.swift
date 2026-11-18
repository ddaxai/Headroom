import Foundation

/// Local usage projected from Pi / OMP session transcripts.
///
/// This is deliberately not a `UsageProvider`: it has no remote quota endpoint,
/// account identity, or relay route. It is a local agent source only.
public struct PiAgentUsageCardSnapshot: Sendable, Equatable {
    public enum WindowKind: String, CaseIterable, Sendable {
        case rolling24Hours = "24h"
        case last7Days = "7d"
        case last30Days = "30d"
    }

    public struct Window: Sendable, Equatable, Identifiable {
        public let kind: WindowKind
        public let totalTokens: Int
        public let totalCostUSD: Double

        public var id: WindowKind { self.kind }

        public init(kind: WindowKind, totalTokens: Int, totalCostUSD: Double) {
            self.kind = kind
            self.totalTokens = max(0, totalTokens)
            self.totalCostUSD = max(0, totalCostUSD)
        }
    }

    public struct ProfileSection: Sendable, Equatable, Identifiable {
        public let providerKey: String
        public let windows: [Window]
        public let totalTokens: Int
        public let totalCostUSD: Double
        public let models: [String]
        public let daily: [CostUsageDailyReport.Entry]
        public let summary: CostUsageDailyReport.Summary?
        public let rolling24Hours: CostUsageRolling24HourSummary?

        public var id: String { self.providerKey }
        public var isUnassigned: Bool { self.providerKey == PiSessionCostScanner.unassignedProfileKey }

        fileprivate init(providerKey: String, reports: [WindowKind: CostUsageDailyReport]) {
            self.providerKey = providerKey
            self.windows = WindowKind.allCases.compactMap { kind in
                guard let report = reports[kind] else { return nil }
                return Window(kind: kind, totalTokens: Self.totalTokens(in: report), totalCostUSD: Self.totalCostUSD(in: report))
            }
            let totalReport = reports[.last30Days] ?? reports[.last7Days] ?? reports[.rolling24Hours]
                ?? CostUsageDailyReport(data: [], summary: nil)
            self.totalTokens = Self.totalTokens(in: totalReport)
            self.totalCostUSD = Self.totalCostUSD(in: totalReport)
            self.models = Self.models(in: CostUsageDailyReport.merged(Array(reports.values)))
            self.daily = totalReport.data
            self.summary = totalReport.summary
            if let report = reports[.rolling24Hours] {
                self.rolling24Hours = CostUsageRolling24HourSummary(
                    totalTokens: Self.totalTokens(in: report),
                    costUSD: Self.totalCostUSD(in: report),
                    modelProviderBreakdowns: [])
            } else {
                self.rolling24Hours = nil
            }
        }

        public func tokenSnapshot(now: Date, historyDays: Int = 30) -> CostUsageTokenSnapshot {
            CostUsageFetcher.tokenSnapshot(
                from: CostUsageDailyReport(data: self.daily, summary: self.summary),
                now: now,
                historyDays: historyDays,
                rolling24Hours: self.rolling24Hours)
        }

        private static func totalTokens(in report: CostUsageDailyReport) -> Int {
            report.summary?.totalTokens ?? report.data.compactMap(\.totalTokens).reduce(0, +)
        }

        private static func totalCostUSD(in report: CostUsageDailyReport) -> Double {
            report.summary?.totalCostUSD ?? report.data.compactMap(\.costUSD).reduce(0, +)
        }

        private static func models(in report: CostUsageDailyReport) -> [String] {
            Array(Set(report.data.flatMap { ($0.modelsUsed ?? []) + ($0.modelBreakdowns ?? []).map(\.modelName) })).sorted()
        }
    }

    public let windows: [Window]
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let models: [String]
    public let sections: [ProfileSection]

    public var hasUsage: Bool { self.totalTokens > 0 || self.totalCostUSD > 0 }

    /// Convenience initializer used when a single report is already scoped to one card window.
    public init(codexReport: CostUsageDailyReport, claudeReport: CostUsageDailyReport) {
        let aggregate = Self.aggregateReport(codexReport, claudeReport)
        let window = Self.window(kind: .last30Days, report: aggregate)
        self.init(windows: [window], totalReport: aggregate, modelsReport: aggregate)
    }

    public init(profileReports: [String: [WindowKind: CostUsageDailyReport]]) {
        let sections = profileReports.keys.sorted().compactMap { key -> ProfileSection? in
            let section = ProfileSection(providerKey: key, reports: profileReports[key] ?? [:])
            return section.windows.isEmpty ? nil : section
        }
        // The windows overlap by design. Use one widest report per profile for the aggregate
        // card; merging 24H + 7D + 30D would count the same sessions up to three times.
        let totalReport = CostUsageDailyReport.merged(
            sections.compactMap { section in
                let reports = profileReports[section.providerKey] ?? [:]
                return reports[.last30Days] ?? reports[.last7Days] ?? reports[.rolling24Hours]
            })
        self.sections = sections
        self.windows = WindowKind.allCases.compactMap { kind in
            let report = CostUsageDailyReport.merged(
                sections.compactMap { profileReports[$0.providerKey]?[kind] })
            return report.data.isEmpty ? nil : Self.window(kind: kind, report: report)
        }
        self.totalTokens = Self.totalTokens(in: totalReport)
        self.totalCostUSD = Self.totalCostUSD(in: totalReport)
        self.models = Self.models(in: totalReport)
    }

    public init(
        codexReports: [WindowKind: CostUsageDailyReport],
        claudeReports: [WindowKind: CostUsageDailyReport])
    {
        let allKinds = Set(codexReports.keys).union(claudeReports.keys)
        let windows = WindowKind.allCases.compactMap { kind -> Window? in
            guard allKinds.contains(kind) else { return nil }
            let report = Self.aggregateReport(codexReports[kind], claudeReports[kind])
            return Self.window(kind: kind, report: report)
        }
        let reportsByKind: [WindowKind: CostUsageDailyReport] = Dictionary(
            uniqueKeysWithValues: WindowKind.allCases.compactMap { kind -> (WindowKind, CostUsageDailyReport)? in
            guard allKinds.contains(kind) else { return nil }
            return (kind, Self.aggregateReport(codexReports[kind], claudeReports[kind]))
        })
        let modelsReport = Self.aggregateReports(Array(reportsByKind.values))
        let totalReport = reportsByKind[.last30Days]
            ?? reportsByKind[.last7Days]
            ?? reportsByKind[.rolling24Hours]
            ?? CostUsageDailyReport(data: [], summary: nil)
        self.init(windows: windows, totalReport: totalReport, modelsReport: modelsReport)
    }

    private init(
        windows: [Window],
        totalReport: CostUsageDailyReport,
        modelsReport: CostUsageDailyReport)
    {
        self.windows = windows
        self.totalTokens = Self.totalTokens(in: totalReport)
        self.totalCostUSD = Self.totalCostUSD(in: totalReport)
        self.models = Self.models(in: modelsReport)
        self.sections = []
    }

    private static func aggregateReport(
        _ codex: CostUsageDailyReport?,
        _ claude: CostUsageDailyReport?) -> CostUsageDailyReport
    {
        Self.aggregateReports([codex, claude].compactMap(\.self))
    }

    private static func aggregateReports(_ reports: [CostUsageDailyReport]) -> CostUsageDailyReport {
        CostUsageDailyReport.merged(reports)
    }

    private static func window(kind: WindowKind, report: CostUsageDailyReport) -> Window {
        Window(
            kind: kind,
            totalTokens: Self.totalTokens(in: report),
            totalCostUSD: Self.totalCostUSD(in: report))
    }

    private static func totalTokens(in report: CostUsageDailyReport) -> Int {
        report.summary?.totalTokens
            ?? report.data.compactMap(\.totalTokens).reduce(0, +)
    }

    private static func totalCostUSD(in report: CostUsageDailyReport) -> Double {
        report.summary?.totalCostUSD
            ?? report.data.compactMap(\.costUSD).reduce(0, +)
    }

    private static func models(in report: CostUsageDailyReport) -> [String] {
        let fromEntries = report.data.flatMap { entry in
            (entry.modelsUsed ?? []) + (entry.modelBreakdowns ?? []).map(\.modelName)
        }
        return Array(Set(fromEntries)).sorted()
    }
}

/// Builds the independent Pi Agent card without contacting a provider endpoint.
public enum PiAgentUsageCardLoader {
    static let scanOrder: [PiAgentUsageCardSnapshot.WindowKind] = [
        .last30Days,
        .last7Days,
        .rolling24Hours,
    ]

    public struct Options: Sendable {
        public var piSessionsRoot: URL?
        public var ompSessionsRoot: URL?
        public var cacheRoot: URL?
        public var calendar: Calendar
        public var refreshMinIntervalSeconds: TimeInterval

        public init(
            piSessionsRoot: URL? = nil,
            ompSessionsRoot: URL? = nil,
            cacheRoot: URL? = nil,
            calendar: Calendar = .current,
            refreshMinIntervalSeconds: TimeInterval = 60)
        {
            self.piSessionsRoot = piSessionsRoot
            self.ompSessionsRoot = ompSessionsRoot
            self.cacheRoot = cacheRoot
            self.calendar = calendar
            self.refreshMinIntervalSeconds = refreshMinIntervalSeconds
        }
    }

    public static func load(
        now: Date = Date(),
        options: Options = Options()) -> PiAgentUsageCardSnapshot?
    {
        var profileReports: [String: [PiAgentUsageCardSnapshot.WindowKind: CostUsageDailyReport]] = [:]
        for kind in self.scanOrder {
            let since = switch kind {
            case .rolling24Hours:
                now.addingTimeInterval(-24 * 60 * 60)
            case .last7Days:
                options.calendar.date(byAdding: .day, value: -6, to: now) ?? now
            case .last30Days:
                options.calendar.date(byAdding: .day, value: -29, to: now) ?? now
            }
            let scannerOptions = PiSessionCostScanner.Options(
                piSessionsRoot: options.piSessionsRoot,
                ompSessionsRoot: options.ompSessionsRoot,
                cacheRoot: options.cacheRoot,
                calendar: options.calendar,
                refreshMinIntervalSeconds: options.refreshMinIntervalSeconds)
            let reports = PiSessionCostScanner.loadProfileDailyReports(
                since: since,
                until: now,
                now: now,
                options: scannerOptions)
            for (providerKey, report) in reports {
                profileReports[providerKey, default: [:]][kind] = report
            }
        }
        let snapshot = PiAgentUsageCardSnapshot(profileReports: profileReports)
        guard snapshot.hasUsage else { return nil }
        return snapshot
    }
}
