import AppKit
import CodexBarCore
import SwiftUI

enum RelayUsageCardSelectorPresentation {
    static let labelWidth: CGFloat = 104
    static let lineLimit = 1
    static let helpKey = "relay_usage_card_selector_help"
}

struct CodexRelaySummaryCardModel {
    let name: String
    let isActive: Bool
    let isReady: Bool
    let blocker: String?
    let usageLine: String
    let usageSummary: RelayUsageSummary?
    let usageTriad: RelayUsageTriadPresentation?
    let profileOptions: [RelayQuickSwitchOption]
    let selectedProfileID: UUID?
    let apiFormat: RelayAPIFormat
    let speedLine: String?
    let speedTooltip: String?

    init(
        name: String,
        isActive: Bool,
        isReady: Bool,
        blocker: String?,
        usageLine: String,
        usageSummary: RelayUsageSummary?,
        usageTriad: RelayUsageTriadPresentation? = nil,
        profileOptions: [RelayQuickSwitchOption] = [],
        selectedProfileID: UUID? = nil,
        apiFormat: RelayAPIFormat = .openAIResponses,
        speedLine: String? = nil,
        speedTooltip: String? = nil)
    {
        self.name = name
        self.isActive = isActive
        self.isReady = isReady
        self.blocker = blocker
        self.usageLine = usageLine
        self.usageSummary = usageSummary
        self.usageTriad = usageTriad
        self.profileOptions = profileOptions
        self.selectedProfileID = selectedProfileID
        self.apiFormat = apiFormat
        self.speedLine = speedLine
        self.speedTooltip = speedTooltip
    }

    static func remainingPercent(for summary: RelayUsageSummary) -> Double? {
        guard let remaining = summary.remaining, let total = summary.total, total > 0 else { return nil }
        return min(100, max(0, remaining / total * 100))
    }

    var inlineUnavailableUsageLine: String? {
        if self.localMeterProtocolStatus == .unsupported {
            return L("local_meter_protocol_unsupported")
        }
        return self.usageSummary == nil ? self.usageLine : nil
    }

    var footerUsageLine: String? {
        if self.localMeterProtocolStatus == .unsupported {
            return self.usageSummary == nil ? nil : L("local_meter_protocol_unsupported")
        }
        return self.usageSummary == nil ? nil : self.usageLine
    }

    var subtitleLine: String {
        if let blocker { return blocker }
        if self.localMeterProtocolStatus == .unsupported {
            return L("local_meter_protocol_unsupported")
        }
        return "自定义 API"
    }

    private var localMeterProtocolStatus: LocalMeterProtocolStatus {
        self.usageTriad?.localMeterStatus
            ?? LocalMeterProtocolSupport.status(for: self.apiFormat)
    }
}

/// Compact presentation of the three accounting authorities. The local estimate, relay-reported
/// usage, and balance intentionally remain separate lanes so a missing or divergent source cannot
/// silently replace another source's value.
struct RelayUsageTriadView: View {
    let presentation: RelayUsageTriadPresentation
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: RelayUsageTriadLayout.multiplierSpacing) {
            if RelayUsageTriadLayout.mode(forCardWidth: self.width) == .columns {
                HStack(alignment: .top, spacing: RelayUsageTriadLayout.interitemSpacing) {
                    ForEach(self.presentation.metrics) { metric in
                        self.column(metric)
                            .frame(minHeight: RelayUsageTriadLayout.columnMetricHeight, alignment: .top)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: RelayUsageTriadLayout.rowSpacing) {
                    ForEach(self.presentation.metrics) { metric in
                        self.row(metric)
                            .frame(minHeight: RelayUsageTriadLayout.rowMetricHeight, alignment: .top)
                    }
                }
            }

            if let multiplierText = self.presentation.multiplierText {
                Text(L("relay_usage_triad_multiplier_format", multiplierText))
                    .font(ConsoleDesign.mono(9.5, weight: .medium))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func column(_ metric: RelayUsageTriadPresentation.Metric) -> some View {
        self.withTooltip(for: metric) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.id.localizedTitle)
                    .font(ConsoleDesign.text(9, weight: .medium))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(metric.valueText ?? L("relay_usage_triad_no_data"))
                    .font(ConsoleDesign.mono(12, weight: .semibold))
                    .foregroundStyle(self.valueColor(for: metric))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                self.detail(metric)
            }
        }
    }

    private func row(_ metric: RelayUsageTriadPresentation.Metric) -> some View {
        self.withTooltip(for: metric) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.id.localizedTitle)
                        .font(ConsoleDesign.text(10, weight: .medium))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(metric.valueText ?? L("relay_usage_triad_no_data"))
                        .font(ConsoleDesign.mono(11.5, weight: .semibold))
                        .foregroundStyle(self.valueColor(for: metric))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                self.detail(metric)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func withTooltip(
        for metric: RelayUsageTriadPresentation.Metric,
        @ViewBuilder content: () -> some View) -> some View
    {
        if let tooltip = metric.tooltipText {
            content().help(tooltip)
        } else {
            content()
        }
    }

    @ViewBuilder
    private func detail(_ metric: RelayUsageTriadPresentation.Metric) -> some View {
        if let detailText = metric.detailText {
            Text(detailText)
                .font(ConsoleDesign.mono(8.5))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            Text(metric.detail.localizedText)
                .font(ConsoleDesign.text(8.5, weight: .regular))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func valueColor(for metric: RelayUsageTriadPresentation.Metric) -> Color {
        metric.valueText == nil
            ? MenuHighlightStyle.secondary(self.isHighlighted)
            : MenuHighlightStyle.primary(self.isHighlighted)
    }
}

struct CodexRelaySummaryCardView: View {
    let model: CodexRelaySummaryCardModel
    let width: CGFloat
    let onSelectProfile: (UUID) -> Void
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @State private var profilePopupCoordinator = RelayUsageCardProfilePopupCoordinator()

    init(
        model: CodexRelaySummaryCardModel,
        width: CGFloat,
        onSelectProfile: @escaping (UUID) -> Void = { _ in })
    {
        self.model = model
        self.width = width
        self.onSelectProfile = onSelectProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if let icon = ProviderBrandIcon.image(for: .codex) {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "terminal.fill")
                    }
                }
                .frame(width: 18, height: 18)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("API · \(self.model.name)")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Text(self.statusText)
                            .font(ConsoleDesign.text(9.5, weight: .medium))
                            .foregroundStyle(self.statusForegroundColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                                    .stroke(self.statusBorderColor, lineWidth: 1)
                            }
                            .fixedSize()
                    }
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    Text(self.model.subtitleLine)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if self.model.profileOptions.count >= 2,
                   let selected = self.selectedProfile
                {
                    RelayUsageCardProfilePopupView(
                        coordinator: self.profilePopupCoordinator,
                        title: selected.name,
                        seriesIndex: self.selectedProfileIndex,
                        options: self.model.profileOptions,
                        selectedProfileID: self.model.selectedProfileID,
                        onSelectProfile: self.onSelectProfile)
                        .frame(width: RelayUsageCardSelectorPresentation.labelWidth)
                        .menuCardInteractiveControl()
                        .help(L(RelayUsageCardSelectorPresentation.helpKey))
                }
            }

            Group {
                if let usageTriad = self.model.usageTriad {
                    RelayUsageTriadView(
                        presentation: usageTriad,
                        width: self.width)
                } else {
                    self.legacyUsageSummary
                }
            }
            .frame(minHeight: self.model.usageTriad == nil ? 48 : nil, alignment: .top)

            if self.model.usageTriad == nil, let footerUsageLine = self.model.footerUsageLine {
                Text(footerUsageLine)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if let speedLine = self.model.speedLine {
                Text(speedLine)
                    .font(ConsoleDesign.mono(9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .help(self.model.speedTooltip ?? "")
            }
        }
        .padding(12)
        .padding(.trailing, CardDetailRail.width)
        .frame(width: self.width - 12, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .fill(self.model.isActive ? ConsoleDesign.surface2 : ConsoleDesign.surface)
        }
        .overlay(alignment: .trailing) {
            CardDetailRail()
        }
        .clipShape(RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                .stroke(
                    self.model.isActive ? ConsoleDesign.accent : ConsoleDesign.border,
                    lineWidth: self.model.isActive ? 1.5 : 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(ConsoleDesign.background)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    private var legacyUsageSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let summary = self.model.usageSummary {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.planTitle(for: summary))
                        .font(ConsoleDesign.text(11, weight: .medium))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Spacer(minLength: 8)
                    if let remainingPercent = CodexRelaySummaryCardModel.remainingPercent(for: summary) {
                        Text("\(Int(remainingPercent.rounded()))%")
                            .font(ConsoleDesign.mono(15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                remainingPercent <= 0
                                    ? ConsoleDesign.criticalForeground
                                    : ConsoleDesign.primaryText)
                    } else if let balance = RelayUsagePresentation.remainingLine(summary) {
                        Text(balance)
                            .font(ConsoleDesign.mono(11, weight: .medium))
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
                if let remainingPercent = CodexRelaySummaryCardModel.remainingPercent(for: summary) {
                    ConsoleSegmentedMeter(percent: remainingPercent)
                        .padding(.top, 2)
                }
                if let detail = RelayUsagePresentation.detailLine(summary) {
                    Text(detail)
                        .font(ConsoleDesign.mono(10))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            } else {
                Text(self.model.inlineUnavailableUsageLine ?? "")
                    .font(ConsoleDesign.mono(10))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: 48, alignment: .top)
    }

    private var statusText: String {
        if self.model.isActive { return "使用中" }
        return self.model.isReady ? "已保存" : "未就绪"
    }

    private var statusForegroundColor: Color {
        if self.model.isActive { return ConsoleDesign.accentForeground }
        return self.model.isReady ? ConsoleDesign.secondaryText : ConsoleDesign.criticalForeground
    }

    private var statusBorderColor: Color {
        if self.model.isActive { return ConsoleDesign.accent }
        return self.model.isReady ? ConsoleDesign.secondaryText : ConsoleDesign.critical
    }

    private func planTitle(for summary: RelayUsageSummary) -> String {
        guard let planName = summary.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planName.isEmpty
        else {
            return "额度"
        }
        return planName
    }

    private var selectedProfile: RelayQuickSwitchOption? {
        self.model.profileOptions.first(where: { $0.id == self.model.selectedProfileID })
            ?? self.model.profileOptions.first
    }

    private var selectedProfileIndex: Int {
        guard let selected = self.selectedProfile,
              let index = self.model.profileOptions.firstIndex(where: { $0.id == selected.id })
        else { return 0 }
        return index
    }
}

@MainActor
final class RelayUsageCardProfilePopupCoordinator: NSObject {
    typealias Popup = (NSMenu, NSMenuItem?, NSPoint, NSView) -> Bool

    private let popup: Popup
    private var options: [RelayQuickSwitchOption] = []
    private var selectedProfileID: UUID?
    private var onSelectProfile: (UUID) -> Void = { _ in }
    private var pendingProfileID: UUID?

    init(popup: @escaping Popup = { menu, item, point, view in
        menu.popUp(positioning: item, at: point, in: view)
    }) {
        self.popup = popup
        super.init()
    }

    func update(
        options: [RelayQuickSwitchOption],
        selectedProfileID: UUID?,
        onSelectProfile: @escaping (UUID) -> Void)
    {
        self.options = options
        self.selectedProfileID = selectedProfileID
        self.onSelectProfile = onSelectProfile
    }

    func present(relativeTo anchorView: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var positioningItem: NSMenuItem?
        for option in self.options {
            let item = NSMenuItem(title: option.name, action: #selector(self.captureSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.id
            item.state = option.id == self.selectedProfileID ? .on : .off
            item.isEnabled = true
            menu.addItem(item)
            if item.state == .on {
                positioningItem = item
            }
        }
        guard !menu.items.isEmpty else { return }

        self.pendingProfileID = nil
        let selected = self.popup(
            menu,
            positioningItem,
            NSPoint(x: anchorView.bounds.minX, y: anchorView.bounds.minY),
            anchorView)
        guard selected, let pendingProfileID = self.pendingProfileID else { return }
        self.onSelectProfile(pendingProfileID)
    }

    @objc func captureSelection(_ sender: NSMenuItem?) {
        self.pendingProfileID = sender?.representedObject as? UUID
    }
}

struct RelayUsageCardProfilePopupView: NSViewRepresentable {
    let coordinator: RelayUsageCardProfilePopupCoordinator
    let title: String
    let seriesIndex: Int
    let options: [RelayQuickSwitchOption]
    let selectedProfileID: UUID?
    let onSelectProfile: (UUID) -> Void

    func makeNSView(context: Context) -> RelayUsageCardProfilePopupControl {
        let view = RelayUsageCardProfilePopupControl(frame: .zero)
        self.configure(view)
        return view
    }

    func updateNSView(_ nsView: RelayUsageCardProfilePopupControl, context: Context) {
        self.configure(nsView)
    }

    private func configure(_ view: RelayUsageCardProfilePopupControl) {
        self.coordinator.update(
            options: self.options,
            selectedProfileID: self.selectedProfileID,
            onSelectProfile: self.onSelectProfile)
        let series = ConsoleDesign.tokens.series
        let color = series.isEmpty ? ConsoleDesign.nsAccent : series[self.seriesIndex % series.count].nsColor
        view.configure(coordinator: self.coordinator, title: self.title, dotColor: color)
    }
}

@MainActor
final class RelayUsageCardProfilePopupControl: NSControl {
    private weak var coordinator: RelayUsageCardProfilePopupCoordinator?
    private var displayTitle = ""
    private var dotColor = ConsoleDesign.nsAccent

    override var intrinsicContentSize: NSSize {
        NSSize(width: RelayUsageCardSelectorPresentation.labelWidth, height: 24)
    }

    override var allowsVibrancy: Bool {
        false
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    func configure(
        coordinator: RelayUsageCardProfilePopupCoordinator,
        title: String,
        dotColor: NSColor)
    {
        self.coordinator = coordinator
        self.displayTitle = title
        self.dotColor = dotColor
        self.toolTip = L(RelayUsageCardSelectorPresentation.helpKey)
        self.setAccessibilityLabel(L(RelayUsageCardSelectorPresentation.helpKey))
        self.setAccessibilityValue(title)
        self.needsDisplay = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .popUpButton
    }

    override func accessibilityPerformPress() -> Bool {
        self.coordinator?.present(relativeTo: self)
        return self.coordinator != nil
    }

    override func mouseDown(with event: NSEvent) {
        guard self.isEnabled, event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        self.coordinator?.present(relativeTo: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: ConsoleDesign.radiusControl,
            yRadius: ConsoleDesign.radiusControl)
        ConsoleDesign.nsSurface.setFill()
        path.fill()
        ConsoleDesign.nsBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        self.dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 7, y: floor((self.bounds.height - 5) / 2), width: 5, height: 5)).fill()

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
            .applying(.init(hierarchicalColor: ConsoleDesign.nsSecondaryText))
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration)
        let chevronSize = chevron?.size ?? NSSize(width: 8, height: 8)
        let chevronRect = NSRect(
            x: self.bounds.maxX - 7 - chevronSize.width,
            y: floor((self.bounds.height - chevronSize.height) / 2),
            width: chevronSize.width,
            height: chevronSize.height)
        chevron?.draw(
            in: chevronRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil)

        let titleRect = NSRect(
            x: 17,
            y: 0,
            width: max(0, chevronRect.minX - 21),
            height: self.bounds.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ConsoleDesign.nsMono(9.5, weight: .medium),
            .foregroundColor: ConsoleDesign.nsSecondaryText,
            .paragraphStyle: paragraph,
        ]
        let attributedTitle = NSAttributedString(string: self.displayTitle, attributes: attributes)
        let titleHeight = attributedTitle.size().height
        attributedTitle.draw(in: NSRect(
            x: titleRect.minX,
            y: floor((titleRect.height - titleHeight) / 2),
            width: titleRect.width,
            height: titleHeight))
    }
}

struct CodexStackedTotalUsageView: View {
    let label: String
    let value: String
    let secondaryValue: String?
    let width: CGFloat
    let showsDetailRail: Bool
    @Environment(\.menuItemHighlighted) private var isHighlighted

    init(
        label: String,
        value: String,
        secondaryValue: String? = nil,
        width: CGFloat,
        showsDetailRail: Bool)
    {
        self.label = label
        self.value = value
        self.secondaryValue = secondaryValue
        self.width = width
        self.showsDetailRail = showsDetailRail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.label)
                    .foregroundStyle(ConsoleDesign.tertiaryForeground)
                Spacer(minLength: 8)
                Text(self.value)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let secondaryValue {
                Text(secondaryValue)
                    .foregroundStyle(ConsoleDesign.tertiaryForeground)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .padding(.trailing, self.showsDetailRail ? CardDetailRail.width : 0)
        .frame(width: self.width, alignment: .leading)
        .overlay(alignment: .trailing) {
            if self.showsDetailRail {
                CardDetailRail()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
