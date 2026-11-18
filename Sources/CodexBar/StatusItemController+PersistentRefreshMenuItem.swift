import AppKit

extension StatusItemController {
    func isPersistentRefreshItem(_ item: NSMenuItem) -> Bool {
        item.representedObject as? String == Self.persistentRefreshMenuItemID
    }

    func menuTreeContainsPersistentRefreshItem(_ menu: NSMenu) -> Bool {
        var visitedMenus = Set<ObjectIdentifier>()

        func containsPersistentRefreshItem(_ candidate: NSMenu) -> Bool {
            guard visitedMenus.insert(ObjectIdentifier(candidate)).inserted else { return false }
            for item in candidate.items {
                if self.isPersistentRefreshItem(item) {
                    return true
                }
                if let submenu = item.submenu, containsPersistentRefreshItem(submenu) {
                    return true
                }
            }
            return false
        }

        return containsPersistentRefreshItem(menu)
    }

    func makePersistentRefreshItem(title: String, menu: NSMenu, width: CGFloat) -> NSMenuItem {
        let shortcutText = self.shortcut(for: .refresh).map(Self.shortcutDisplayLabel)
        let metrics = PersistentRefreshRowMetrics.defaults
        let view = PersistentRefreshMenuView(
            title: title,
            systemImageName: MenuDescriptor.MenuAction.refresh.systemImageName,
            shortcutText: shortcutText,
            onClick: { [weak self, weak menu] in
                guard let self, let menu else { return }
                if let menu = menu as? StatusItemMenu {
                    menu.requestPersistentRefreshAction()
                } else {
                    self.performPersistentRefreshAction(in: ObjectIdentifier(menu))
                }
            })
        let enabled = !self.isRefreshActionInFlight(for: menu)
        view.setEnabled(enabled)
        view.applySize(width: width, height: metrics.rowHeight)

        let item = NSMenuItem()
        item.title = title
        item.representedObject = Self.persistentRefreshMenuItemID
        item.view = view
        item.isEnabled = enabled
        item.keyEquivalentModifierMask = []
        item.toolTip = title
        return item
    }

    static func shortcutDisplayLabel(
        for shortcut: (key: String, modifiers: NSEvent.ModifierFlags)) -> String
    {
        var label = ""
        if shortcut.modifiers.contains(.control) {
            label += "^"
        }
        if shortcut.modifiers.contains(.option) {
            label += "⌥"
        }
        if shortcut.modifiers.contains(.shift) {
            label += "⇧"
        }
        if shortcut.modifiers.contains(.command) {
            label += "⌘"
        }
        if !label.isEmpty {
            label += " "
        }
        return label + shortcut.key.uppercased()
    }
}
