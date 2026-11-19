import CodexBarCore
import SwiftUI

struct UsageBarChart: View {
    static let chartHeight: CGFloat = 56
    static let emptyStateHeight = Self.chartHeight

    let snapshot: CostUsageTokenSnapshot?
    let unavailableText: String?

    @AppStorage("headroomUsageChartRange") private var rangeRaw = UsageWindow.hours24.rawValue
    @State private var hoveredIndex: Int?

    private var selectedRange: UsageWindow {
        UsageWindow(rawValue: self.rangeRaw) ?? .hours24
    }

    var body: some View {
        if let snapshot {
            let slots = self.slots(for: snapshot)
            VStack(alignment: .leading, spacing: 4) {
                self.controls(slots: slots, snapshot: snapshot)
                if slots.allSatisfy({ $0.totalTokens == 0 }) {
                    self.placeholder(L("No usage in this range"))
                        .accessibilityLabel(L("No usage in this range"))
                } else {
                    self.chart(slots: slots, snapshot: snapshot)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 6)
        } else {
            self.placeholder(self.unavailableText ?? L("Relay hourly usage unavailable"))
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack(alignment: .center) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(ConsoleDesign.track)
                    .frame(height: 1)
            }
            Text(text)
                .font(ConsoleDesign.mono(10))
                .foregroundStyle(ConsoleDesign.secondaryText)
                .lineLimit(1)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: Self.emptyStateHeight,
            maxHeight: Self.emptyStateHeight,
            alignment: .center)
    }

    private func controls(slots: [CodexUsageChartSlot], snapshot: CostUsageTokenSnapshot) -> some View {
        HStack(spacing: 4) {
            ForEach(UsageWindow.allCases) { range in
                Button {
                    self.rangeRaw = range.rawValue
                    self.hoveredIndex = nil
                } label: {
                    Text(range.rawValue)
                        .font(ConsoleDesign.mono(9.5, weight: .medium))
                        .foregroundStyle(
                            self.selectedRange == range
                                ? ConsoleDesign.primaryText
                                : ConsoleDesign.secondaryText)
                        .frame(width: 38, height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                                .fill(self.selectedRange == range ? ConsoleDesign.surface2 : .clear)
                                .overlay {
                                    RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                                        .stroke(
                                            self.selectedRange == range
                                                ? ConsoleDesign.accent
                                                : ConsoleDesign.border,
                                            lineWidth: 1)
                                }
                        }
                }
                .buttonStyle(.plain)
                .menuCardInteractiveControl()
                .accessibilityLabel(self.accessibilityLabel(for: range))
            }

            Spacer(minLength: 6)
            if let hoveredIndex, slots.indices.contains(hoveredIndex) {
                Text(self.detailText(for: slots[hoveredIndex], snapshot: snapshot))
                    .foregroundStyle(ConsoleDesign.primaryText)
            } else {
                Text(self.totalText(slots: slots, snapshot: snapshot))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }
        }
        .font(ConsoleDesign.mono(10))
        .frame(height: 24, alignment: .center)
        .animation(nil, value: self.hoveredIndex)
    }

    private func chart(slots: [CodexUsageChartSlot], snapshot: CostUsageTokenSnapshot) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let width = max(
                1,
                (geometry.size.width - gap * CGFloat(max(slots.count - 1, 0)))
                    / CGFloat(max(slots.count, 1)))
            let maximum = max(1, slots.map(\.totalTokens).max() ?? 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    Rectangle()
                        .fill(
                            slot.totalTokens > 0
                                ? (self.hoveredIndex == index ? ConsoleDesign.primaryText : ConsoleDesign.accent)
                                : ConsoleDesign.track)
                        .frame(
                            width: width,
                            height: slot.totalTokens > 0
                                ? max(2, Self.chartHeight * CGFloat(slot.totalTokens) / CGFloat(maximum))
                                : 1)
                        .frame(height: Self.chartHeight, alignment: .bottom)
                        .contentShape(Rectangle())
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    let index = Int((location.x / max(geometry.size.width, 1)) * CGFloat(slots.count))
                    self.hoveredIndex = min(max(index, 0), max(slots.count - 1, 0))
                case .ended:
                    self.hoveredIndex = nil
                }
            }
        }
        .frame(height: Self.chartHeight)
    }

    private func slots(for snapshot: CostUsageTokenSnapshot) -> [CodexUsageChartSlot] {
        CodexUsageChartProjection.slots(for: self.selectedRange, snapshot: snapshot, now: Date())
    }

    private func detailText(for slot: CodexUsageChartSlot, snapshot: CostUsageTokenSnapshot) -> String {
        var parts = [self.label(for: slot.startDate), self.tokenText(slot.totalTokens)]
        if let cost = slot.costUSD {
            parts.append(UsageFormatter.convertedCostString(cost, targetCurrency: snapshot.currencyCode))
        }
        return parts.joined(separator: " · ")
    }

    private func label(for date: Date) -> String {
        switch self.selectedRange {
        case .hours24:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        case .days7, .days30:
            date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
    }

    private func accessibilityLabel(for range: UsageWindow) -> String {
        switch range {
        case .hours24: L("Past 24 hours")
        case .days7: L("Past 7 days")
        case .days30: L("Past 30 days")
        }
    }

    private func tokenText(_ tokens: Int) -> String {
        UsageFormatter.tokenCountString(tokens)
    }

    private func totalText(slots: [CodexUsageChartSlot], snapshot: CostUsageTokenSnapshot) -> String {
        var parts = [
            L("Total"),
            self.tokenText(slots.reduce(0) { $0 + $1.totalTokens }),
        ]
        let cost = slots.compactMap(\.costUSD).reduce(0, +)
        if !slots.compactMap(\.costUSD).isEmpty {
            parts.append(UsageFormatter.convertedCostString(cost, targetCurrency: snapshot.currencyCode))
        }
        return parts.joined(separator: " · ")
    }
}

/// A fixed-size child-menu drawer for the per-card usage history. Keeping this in a submenu
/// means hovering a card never changes the parent menu's height or causes AppKit to rebuild the
/// menu under the pointer.
struct UsageDetail: View {
    static var tableColumns: [String] {
        [L("usage.column.time"), L("usage.column.total"), L("usage.column.cost")]
    }

    let title: String
    let snapshot: CostUsageTokenSnapshot?
    let width: CGFloat
    let unavailableText: String?

    @AppStorage("headroomUsageChartRange") private var rangeRaw = UsageWindow.hours24.rawValue

    private var selectedRange: UsageWindow {
        UsageWindow(rawValue: self.rangeRaw) ?? .hours24
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(ConsoleDesign.accent)
                Text(self.title)
                    .font(ConsoleDesign.text(12, weight: .semibold))
                Spacer(minLength: 0)
                Text(self.selectedRange.rawValue)
                    .font(ConsoleDesign.mono(10))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }
            ConsoleDivider()
            UsageBarChart(snapshot: self.snapshot, unavailableText: self.unavailableText)
                .frame(height: 92, alignment: .top)
            self.table
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button(L("chart_reset_filter")) { self.rangeRaw = UsageWindow.hours24.rawValue }
                    .buttonStyle(.borderless)
                    .font(ConsoleDesign.text(10))
                    .foregroundStyle(ConsoleDesign.secondaryText)
            }
        }
        .padding(12)
        .frame(width: max(300, self.width), height: 330, alignment: .topLeading)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    @ViewBuilder
    private var table: some View {
        if let snapshot = self.snapshot {
            let slots = self.slots(for: snapshot)
            let columns = Self.tableColumns
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(columns[0]).frame(width: 64, alignment: .leading)
                    Text(columns[1]).frame(width: 72, alignment: .trailing)
                    Text(columns[2]).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .foregroundStyle(ConsoleDesign.secondaryText)
                ForEach(Array(self.fixedRows(slots: slots, snapshot: snapshot).enumerated()), id: \.offset) { _, slot in
                    HStack(spacing: 6) {
                        Text(slot.label).frame(width: 64, alignment: .leading)
                        Text(slot.tokens.map(UsageFormatter.tokenCountString) ?? "—")
                            .frame(width: 72, alignment: .trailing)
                        Text(slot.cost.map { UsageFormatter.convertedCostString(
                            $0,
                            targetCurrency: snapshot.currencyCode) } ?? "—")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .foregroundStyle(slot.tokens == nil ? ConsoleDesign.secondaryText : ConsoleDesign.primaryText)
                }
            }
            .font(ConsoleDesign.mono(9))
            .monospacedDigit()
        } else {
            Text(self.unavailableText ?? L("Relay hourly usage unavailable"))
                .font(ConsoleDesign.mono(10))
                .foregroundStyle(ConsoleDesign.secondaryText)
        }
    }

    private struct Row {
        let label: String
        let tokens: Int?
        let cost: Double?
    }

    private func fixedRows(slots: [CodexUsageChartSlot], snapshot: CostUsageTokenSnapshot) -> [Row] {
        var rows = slots.suffix(8).map {
            Row(
                label: self.label(for: $0.startDate),
                tokens: $0.totalTokens > 0 ? $0.totalTokens : nil,
                cost: $0.costUSD)
        }
        if rows.allSatisfy({ $0.tokens == nil && $0.cost == nil }),
           self.selectedRange == .hours24,
           let aggregate = snapshot.rolling24Hours
        {
            rows = [Row(
                label: snapshot.historyLabel ?? "24h",
                tokens: aggregate.totalTokens,
                cost: aggregate.costUSD)]
        }
        return Array(repeating: Row(label: "—", tokens: nil, cost: nil), count: max(0, 8 - rows.count)) + rows
    }

    private func slots(for snapshot: CostUsageTokenSnapshot) -> [CodexUsageChartSlot] {
        CodexUsageChartProjection.slots(for: self.selectedRange, snapshot: snapshot, now: Date())
    }

    private func label(for date: Date) -> String {
        switch self.selectedRange {
        case .hours24:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        case .days7, .days30:
            date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
    }
}

typealias CodexInlineUsageChartView = UsageBarChart
typealias CodexUsageDetailsDrawerView = UsageDetail
