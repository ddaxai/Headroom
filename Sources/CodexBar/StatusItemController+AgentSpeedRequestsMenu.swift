import AppKit
import CodexBarCore

extension StatusItemController {
    private static let agentSpeedRequestColumnStops: [CGFloat] = [70, 190, 280, 352]
    /// Wide enough for the five columns. The legend wraps to it instead of stretching the menu.
    static let agentSpeedRequestMenuWidth: CGFloat = 410

    /// How wide a menu holding this list ends up, for content stacked above it that must span the same width.
    func agentSpeedRequestListWidth(_ presentation: AgentSpeedPresentation?) -> CGFloat? {
        guard let presentation, !presentation.requests.isEmpty else { return nil }
        let probe = NSMenu()
        self.appendAgentSpeedRequestItems(to: probe, presentation: presentation)
        return max(Self.agentSpeedRequestMenuWidth, ceil(probe.size.width))
    }

    /// A native submenu listing recent replies, so hovering a speed card shows where its figure came from.
    func makeAgentSpeedRequestsSubmenu(_ presentation: AgentSpeedPresentation?) -> NSMenu? {
        guard let presentation, !presentation.requests.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        StatusMenuAppearance.pin(submenu)
        self.appendAgentSpeedRequestItems(to: submenu, presentation: presentation)
        return submenu
    }

    func appendAgentSpeedRequestItems(
        to menu: NSMenu,
        presentation: AgentSpeedPresentation?,
        now: Date = Date())
    {
        guard let presentation, !presentation.requests.isEmpty else { return }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.minimumWidth = max(menu.minimumWidth, Self.agentSpeedRequestMenuWidth)

        menu.addItem(Self.agentSpeedRequestInfoItem(L("agent_speed_requests_title")))
        menu.addItem(Self.agentSpeedRequestColumnsItem(
            AgentSpeedRequestRow.columnTitles,
            color: .secondaryLabelColor,
            emphasizesSpeed: false,
            isEnabled: false))
        for row in presentation.requests {
            menu.addItem(Self.agentSpeedRequestColumnsItem(
                row.columns(now: now),
                color: row.countsAsRealUsage ? nil : .tertiaryLabelColor,
                emphasizesSpeed: row.countsAsRealUsage,
                isEnabled: true))
        }

        menu.addItem(.separator())
        let legend = self.makeWrappedSecondaryTextItem(
            text: L("agent_speed_requests_legend"),
            width: Self.agentSpeedRequestMenuWidth)
        legend.view?.autoresizingMask = [.width]
        // The rows around it are native items on the menu's own material.
        legend.view?.layer?.backgroundColor = NSColor.clear.cgColor
        menu.addItem(legend)
        if let expiry = presentation.cacheExpiresAt {
            let time = DateFormatter.localizedString(from: expiry, dateStyle: .none, timeStyle: .short)
            let key = expiry > now ? "agent_speed_cache_expires_format" : "agent_speed_cache_expired_format"
            menu.addItem(Self.agentSpeedRequestInfoItem(L(key, time)))
        }
    }

    private static func agentSpeedRequestInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func agentSpeedRequestColumnsItem(
        _ columns: [String],
        color: NSColor?,
        emphasizesSpeed: Bool,
        isEnabled: Bool) -> NSMenuItem
    {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = Self.agentSpeedRequestColumnStops.map { NSTextTab(textAlignment: .left, location: $0) }
        paragraph.lineBreakMode = .byTruncatingTail
        let size = NSFont.smallSystemFontSize
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .paragraphStyle: paragraph,
        ]
        if let color {
            attributes[.foregroundColor] = color
        }

        let title = NSMutableAttributedString()
        for (index, column) in columns.enumerated() {
            var columnAttributes = attributes
            if emphasizesSpeed, index == AgentSpeedRequestRow.speedColumnIndex {
                columnAttributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            }
            title.append(NSAttributedString(
                string: index == 0 ? column : "\t" + column,
                attributes: columnAttributes))
        }

        let item = NSMenuItem(title: columns.joined(separator: "  "), action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.isEnabled = isEnabled
        return item
    }
}
