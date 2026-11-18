import AppKit
import CodexBarCore

extension StatusItemController {
    @discardableResult
    func addStorageMenuCardSection(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let storageText = self.store.storageFootprintText(for: provider) else { return false }
        let storageSubmenu = self.makeStorageBreakdownSubmenu(provider: provider, width: width)
        let item = self.makeConsoleMenuRowItem(
            title: L("Storage"),
            shortcutText: storageText,
            showsChevron: storageSubmenu != nil,
            isEnabled: storageSubmenu != nil,
            width: width)
        item.representedObject = "menuCardStorage"
        item.submenu = storageSubmenu
        menu.addItem(item)
        return true
    }
}
