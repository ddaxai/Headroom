import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexUsageChartTests {
    @Test
    func `all usage windows share one detail and bar chart implementation`() throws {
        #expect(UsageWindow.allCases.map(\.rawValue) == ["24H", "7D", "30D"])

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources/CodexBar", isDirectory: true)
        let swiftFiles = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
            .filter { $0.pathExtension == "swift" }
        let sources = try swiftFiles.map { try String(contentsOf: $0, encoding: .utf8) }

        #expect(sources.reduce(0) { $0 + $1.components(separatedBy: "struct UsageDetail: View").count - 1 } == 1)
        #expect(sources.reduce(0) { $0 + $1.components(separatedBy: "struct UsageBarChart: View").count - 1 } == 1)
        #expect(sources.allSatisfy { !$0.contains("struct CodexInlineUsageChartView: View") })
        #expect(sources.allSatisfy { !$0.contains("struct CodexHourlyUsageChartMenuView: View") })
        #expect(sources.allSatisfy { !$0.contains("struct CodexUsageDetailsDrawerView: View") })
    }

    @Test
    @MainActor
    func `empty and populated usage charts reserve the same plot height`() {
        #expect(CodexInlineUsageChartView.chartHeight == 56)
        #expect(CodexInlineUsageChartView.emptyStateHeight == CodexInlineUsageChartView.chartHeight)
    }

    @Test
    @MainActor
    func `usage drawer only advertises columns backed by its data source`() {
        #expect(CodexUsageDetailsDrawerView.tableColumns == ["Time", "Total", "Cost"])
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            #expect(CodexUsageDetailsDrawerView.tableColumns == ["时间", "总计", "费用"])
        }
    }

    @Test
    func `24 hour projection always has one slot per local hour`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 3,
            hour: 12)))
        let previous = try #require(calendar.date(byAdding: .hour, value: -23, to: now))
        let entries = try [
            CostUsageHourlyEntry(startDate: previous, totalTokens: 5, costUSD: 0.1),
            CostUsageHourlyEntry(startDate: now, totalTokens: 7, costUSD: 0.2),
            CostUsageHourlyEntry(
                startDate: #require(calendar.date(byAdding: .hour, value: -25, to: now)),
                totalTokens: 99,
                costUSD: 9),
        ]

        let slots = CodexUsageChartProjection.hours24(entries: entries, now: now, calendar: calendar)
        #expect(slots.count == 24)
        #expect(slots.first?.totalTokens == 5)
        #expect(slots.last?.totalTokens == 7)
        #expect(slots.first?.costUSD == 0.1)
        #expect(slots.last?.costUSD == 0.2)
        #expect(slots.map(\.totalTokens).reduce(0, +) == 12)
    }

    @Test
    func `30 day projection preserves empty days and aggregates duplicate dates`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 3,
            hour: 12)))
        let entries = [
            CostUsageDailyReport.Entry(
                date: "2026-08-03",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 10,
                costUSD: 0.1,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-08-03",
                inputTokens: 1,
                outputTokens: 1,
                totalTokens: 5,
                costUSD: 0.05,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]

        let slots = CodexUsageChartProjection.days30(entries: entries, now: now, calendar: calendar)
        #expect(slots.count == 30)
        #expect(slots.last?.totalTokens == 15)
        #expect(abs((slots.last?.costUSD ?? -1) - 0.15) < 0.0001)
        #expect(slots.dropLast().allSatisfy { $0.totalTokens == 0 })
    }

    @Test
    func `seven day window is a parameter of the shared projection`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 8,
            day: 7,
            hour: 12)))
        let today = CostUsageDailyReport.Entry(
            date: "2026-08-07",
            inputTokens: 4,
            outputTokens: 6,
            totalTokens: 10,
            costUSD: 0.1,
            modelsUsed: nil,
            modelBreakdowns: nil)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 0.1,
            hourly24Hours: [],
            daily: [today],
            updatedAt: now)

        let slots = CodexUsageChartProjection.slots(
            for: .days7,
            snapshot: snapshot,
            now: now,
            calendar: calendar)
        #expect(slots.count == 7)
        #expect(slots.last?.totalTokens == 10)
        #expect(slots.dropLast().allSatisfy { $0.totalTokens == 0 })
    }

    @Test
    func `hover state machine keeps only one expanded card`() {
        var state = CodexUsageChartHoverState()
        state.entered(cardID: "account-a")
        let expandedAccountA = state.commitExpansion(for: "account-a")
        #expect(expandedAccountA)
        #expect(state.expandedCardID == "account-a")
        state.entered(cardID: "account-b")
        let expandedAccountB = state.commitExpansion(for: "account-b")
        #expect(expandedAccountB)
        #expect(state.expandedCardID == "account-b")
        state.exited(cardID: "account-a")
        let collapsedAccountA = state.commitCollapse(for: "account-a")
        #expect(!collapsedAccountA)
        state.exited(cardID: "account-b")
        let collapsedAccountB = state.commitCollapse(for: "account-b")
        #expect(collapsedAccountB)
        #expect(state.expandedCardID == nil)
    }
}
