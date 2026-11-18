import AppKit
import CodexBarCore

extension StatusItemController {
    func attachMenuPresentation(_ menu: NSMenu, to statusItem: NSStatusItem) {
        guard self.popupPanelEnabled else {
            statusItem.button?.target = nil
            statusItem.button?.action = nil
            if statusItem.menu !== menu {
                statusItem.menu = menu
            }
            return
        }

        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(self.toggleHeadroomPopupPanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp])
    }

    @objc func toggleHeadroomPopupPanel(_ sender: NSStatusBarButton) {
        if self.headroomPopupPanel?.isVisible == true {
            self.dismissHeadroomPopupPanel()
            return
        }
        guard let (menu, provider) = self.popupMenuAndProvider(for: sender) else { return }
        self.menuWillOpen(menu)
        if menu.items.isEmpty {
            self.populateMenu(menu, provider: provider)
        }
        self.refreshMenuCardHeights(in: menu)

        if let panel = self.headroomPopupPanel {
            panel.update(menu: menu)
        } else {
            let panel = HeadroomPopupPanel(menu: menu)
            panel.onRequestClose = { [weak self] in
                self?.dismissHeadroomPopupPanel()
            }
            panel.onSubmenuDidDismiss = { [weak self] in
                self?.refreshOpenMenusAfterHostedSubviewClose()
            }
            self.headroomPopupPanel = panel
        }
        self.headroomPopupMenu = menu
        self.headroomPopupPanel?.show(relativeTo: sender)
    }

    func dismissHeadroomPopupPanel() {
        guard let panel = self.headroomPopupPanel, panel.isVisible else { return }
        panel.transition(to: .closed)
        if let menu = self.headroomPopupMenu {
            self.menuDidClose(menu)
        }
        self.headroomPopupMenu = nil
    }

    func populateMenu(_ menu: NSMenu, provider: UsageProvider?) {
        let panel = self.prepareHeadroomPopupPanelForMenuMutation(menu)
        self.populateMenuContents(menu, provider: provider)
        self.refreshHeadroomPopupPanelAfterMenuMutation(menu, panel: panel)
    }

    func prepareHeadroomPopupPanelForMenuMutation(_ menu: NSMenu) -> HeadroomPopupPanel? {
        guard let panel = self.headroomPopupPanel,
              panel.presentationState != .closed,
              self.headroomPopupMenu === menu
        else {
            return nil
        }
        panel.prepareForSourceMenuMutation()
        return panel
    }

    func refreshHeadroomPopupPanelAfterMenuMutation(_ menu: NSMenu, panel: HeadroomPopupPanel?) {
        guard let panel,
              panel.presentationState != .closed,
              self.headroomPopupMenu === menu
        else {
            return
        }
        panel.update(menu: menu)
    }

    private func popupMenuAndProvider(for button: NSStatusBarButton) -> (NSMenu, UsageProvider?)? {
        if button === self.statusItem.button {
            if self.mergedMenu == nil {
                self.mergedMenu = self.makeMenu()
            }
            return self.mergedMenu.map { ($0, self.shouldMergeIcons ? self.resolvedMenuProvider() : nil) }
        }

        guard let provider = self.statusItems.first(where: { $0.value.button === button })?.key else {
            return nil
        }
        if self.isEnabled(provider) {
            if self.providerMenus[provider] == nil {
                self.providerMenus[provider] = self.makeMenu(for: provider)
            }
            return self.providerMenus[provider].map { ($0, provider) }
        }
        if self.fallbackProvider == provider {
            if self.fallbackMenu == nil {
                self.fallbackMenu = self.makeMenu(for: nil)
            }
            return self.fallbackMenu.map { ($0, nil) }
        }
        return nil
    }
}
