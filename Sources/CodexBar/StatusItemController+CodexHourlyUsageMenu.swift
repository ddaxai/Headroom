import AppKit
import CodexBarCore

extension StatusItemController {
    func makeCodexUsageDetailsSubmenu(
        snapshot: CostUsageTokenSnapshot?,
        title: String,
        width: CGFloat,
        unavailableText: String? = nil,
        agentSpeed: AgentSpeedPresentation? = nil) -> NSMenu
    {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // The request list below sets the menu's width; a narrower hosted view would leave bare menu beside it.
        let width = max(300, width, self.agentSpeedRequestListWidth(agentSpeed) ?? 0)
        submenu.minimumWidth = width
        // Recent responses go below the usage details, in either rendering mode.
        defer { self.appendAgentSpeedRequestItems(to: submenu, presentation: agentSpeed) }
        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }
        let view = UsageDetail(
            title: title,
            snapshot: snapshot,
            width: width,
            unavailableText: unavailableText)
        let hosting = MenuHostingView(rootView: view)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: 330))
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        submenu.addItem(item)
        return submenu
    }

    func makeCodexHourlyUsageSubmenu(
        snapshot: CostUsageTokenSnapshot,
        width: CGFloat) -> NSMenu?
    {
        guard !snapshot.hourly24Hours.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.minimumWidth = width

        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem(title: L("codex_hourly_usage_menu_title"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return submenu
        }

        let view = UsageDetail(
            title: L("codex_usage_details_title", L("codex_usage_total")),
            snapshot: snapshot,
            width: max(300, width),
            unavailableText: nil)
        let hosting = MenuHostingView(rootView: view)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: max(300, width), height: 330))
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        submenu.addItem(item)
        return submenu
    }
}
