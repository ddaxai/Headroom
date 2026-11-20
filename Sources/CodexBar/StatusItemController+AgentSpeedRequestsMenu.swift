import AppKit
import CodexBarCore

extension AgentSpeedRequestRow {
    /// Time, model, output tokens, speed, first token, cache hit rate. Missing values are dashes.
    func columns(calendar: Calendar = .current, now: Date = Date()) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(self.timestamp, inSameDayAs: now) ? "HH:mm:ss" : "MM-dd HH:mm"
        return [
            formatter.string(from: self.timestamp),
            Self.truncatedModel(self.model),
            UsageFormatter.tokenCountString(self.outputTokens),
            self.speedText ?? Self.placeholder,
            self.firstTokenText ?? Self.placeholder,
            self.cacheHitText ?? Self.placeholder,
        ]
    }

    static let modelColumnCharacterLimit = 24

    static func truncatedModel(_ model: String?) -> String {
        guard let model else { return self.placeholder }
        guard model.count > self.modelColumnCharacterLimit else { return model }
        return String(model.prefix(self.modelColumnCharacterLimit - 1)) + "…"
    }

    static var columnTitles: [String] {
        [
            L("agent_speed_requests_column_time"),
            L("agent_speed_requests_column_model"),
            L("agent_speed_requests_column_output"),
            L("agent_speed_requests_column_speed"),
            L("agent_speed_requests_column_first_token"),
            L("agent_speed_requests_column_cache"),
        ]
    }
}

extension StatusItemController {
    private static let agentSpeedRequestColumnStops: [CGFloat] = [84, 262, 322, 420, 476]
    private static let agentSpeedRequestMenuWidth: CGFloat = 540

    /// A native submenu listing recent replies, so hovering a speed card shows where its figure came from.
    func makeAgentSpeedRequestsSubmenu(_ presentation: AgentSpeedPresentation?) -> NSMenu? {
        guard let presentation, !presentation.requests.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
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
        menu.addItem(Self.agentSpeedRequestInfoItem(L("agent_speed_requests_legend")))
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
            if emphasizesSpeed, index == 3 {
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
