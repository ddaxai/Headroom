import CodexBarCore
import Foundation
import Observation

enum UsageWindow: String, CaseIterable, Identifiable {
    case hours24 = "24H"
    case days7 = "7D"
    case days30 = "30D"

    var id: String { self.rawValue }
}

struct CodexUsageChartSlot: Equatable, Identifiable {
    let startDate: Date
    let totalTokens: Int
    let costUSD: Double?

    var id: Date {
        self.startDate
    }
}

enum CodexUsageChartProjection {
    static func slots(
        for window: UsageWindow,
        snapshot: CostUsageTokenSnapshot,
        now: Date,
        calendar: Calendar = .current) -> [CodexUsageChartSlot]
    {
        switch window {
        case .hours24:
            Self.hours(entries: snapshot.hourly24Hours, count: 24, now: now, calendar: calendar)
        case .days7:
            Self.days(entries: snapshot.daily, count: 7, now: now, calendar: calendar)
        case .days30:
            Self.days(entries: snapshot.daily, count: 30, now: now, calendar: calendar)
        }
    }

    static func hours24(
        entries: [CostUsageHourlyEntry],
        now: Date,
        calendar: Calendar = .current) -> [CodexUsageChartSlot]
    {
        Self.hours(entries: entries, count: 24, now: now, calendar: calendar)
    }

    private static func hours(
        entries: [CostUsageHourlyEntry],
        count: Int,
        now: Date,
        calendar: Calendar) -> [CodexUsageChartSlot]
    {
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        let starts = (0..<count).compactMap {
            calendar.date(byAdding: .hour, value: $0 - (count - 1), to: currentHour)
        }
        guard let first = starts.first, let last = starts.last else { return [] }
        var totals: [Date: Int] = [:]
        var costs: [Date: Double] = [:]
        for entry in entries {
            guard let hour = calendar.dateInterval(of: .hour, for: entry.startDate)?.start,
                  hour >= first,
                  hour <= last
            else { continue }
            totals[hour, default: 0] += max(0, entry.totalTokens)
            if let cost = entry.costUSD, cost >= 0 {
                costs[hour, default: 0] += cost
            }
        }
        return starts.map {
            CodexUsageChartSlot(startDate: $0, totalTokens: totals[$0, default: 0], costUSD: costs[$0])
        }
    }

    static func days30(
        entries: [CostUsageDailyReport.Entry],
        now: Date,
        calendar: Calendar = .current) -> [CodexUsageChartSlot]
    {
        Self.days(entries: entries, count: 30, now: now, calendar: calendar)
    }

    private static func days(
        entries: [CostUsageDailyReport.Entry],
        count: Int,
        now: Date,
        calendar: Calendar) -> [CodexUsageChartSlot]
    {
        let currentDay = calendar.startOfDay(for: now)
        let starts = (0..<count).compactMap {
            calendar.date(byAdding: .day, value: $0 - (count - 1), to: currentDay)
        }
        guard let first = starts.first, let last = starts.last else { return [] }
        var totals: [Date: Int] = [:]
        var costs: [Date: Double] = [:]
        for entry in entries {
            guard let date = Self.parseDailyDate(entry.date, calendar: calendar) else { continue }
            let day = calendar.startOfDay(for: date)
            guard day >= first, day <= last else { continue }
            totals[day, default: 0] += max(0, entry.totalTokens ?? 0)
            if let cost = entry.costUSD, cost >= 0 {
                costs[day, default: 0] += cost
            }
        }
        return starts.map {
            CodexUsageChartSlot(startDate: $0, totalTokens: totals[$0, default: 0], costUSD: costs[$0])
        }
    }

    static func hasData(
        snapshot: CostUsageTokenSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current) -> Bool
    {
        let hourly = Self.hours24(entries: snapshot.hourly24Hours, now: now, calendar: calendar)
        let daily = Self.days30(entries: snapshot.daily, now: now, calendar: calendar)
        return hourly.contains { $0.totalTokens > 0 } || daily.contains { $0.totalTokens > 0 }
    }

    private static func parseDailyDate(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter().date(from: trimmed) {
            return date
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }
}

struct CodexUsageChartHoverState: Equatable {
    private(set) var expandedCardID: String?
    private var pendingCardID: String?

    mutating func entered(cardID: String) {
        self.pendingCardID = cardID
    }

    mutating func exited(cardID: String) {
        if self.pendingCardID == cardID {
            self.pendingCardID = nil
        }
    }

    mutating func commitExpansion(for cardID: String) -> Bool {
        guard self.pendingCardID == cardID else { return false }
        self.pendingCardID = nil
        self.expandedCardID = cardID
        return true
    }

    mutating func commitCollapse(for cardID: String) -> Bool {
        guard self.expandedCardID == cardID else { return false }
        self.expandedCardID = nil
        return true
    }
}

@MainActor
@Observable
final class CodexUsageChartHoverCoordinator {
    private(set) var expandedCardID: String?
    var onExpansionChanged: (@MainActor () -> Void)?

    private var state = CodexUsageChartHoverState()
    private var expansionTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    init(onExpansionChanged: (@MainActor () -> Void)? = nil) {
        self.onExpansionChanged = onExpansionChanged
    }

    func pointerEntered(cardID: String) {
        self.collapseTask?.cancel()
        self.state.entered(cardID: cardID)
        self.expansionTask?.cancel()
        self.expansionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.state.commitExpansion(for: cardID) else { return }
            self.expandedCardID = self.state.expandedCardID
            self.onExpansionChanged?()
        }
    }

    func pointerExited(cardID: String) {
        self.expansionTask?.cancel()
        self.state.exited(cardID: cardID)
        self.collapseTask?.cancel()
        self.collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.state.commitCollapse(for: cardID) else { return }
            self.expandedCardID = self.state.expandedCardID
            self.onExpansionChanged?()
        }
    }
}
