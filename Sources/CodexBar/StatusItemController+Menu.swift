// swiftlint:disable file_length

import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - NSMenu construction

extension StatusItemController {
    static let menuCardBaseWidth: CGFloat = 360
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit
    static let overviewRowIdentifierPrefix = "overviewRow-"
    static let persistentRefreshMenuItemID = "persistentRefreshAction"
    private static let defaultMenuOpenRefreshDelay: Duration = .seconds(1.2)
    #if DEBUG
    private static var menuOpenRefreshDelayForTesting: Duration = .seconds(1.2)
    static func setMenuOpenRefreshDelayForTesting(_ delay: Duration) {
        self.menuOpenRefreshDelayForTesting = delay
    }

    static func resetMenuOpenRefreshDelayForTesting() {
        self.menuOpenRefreshDelayForTesting = self.defaultMenuOpenRefreshDelay
    }
    #endif

    private static var menuOpenRefreshDelay: Duration {
        #if DEBUG
        menuOpenRefreshDelayForTesting
        #else
        defaultMenuOpenRefreshDelay
        #endif
    }

    static let usageBreakdownChartID = "usageBreakdownChart"
    static let creditsHistoryChartID = "creditsHistoryChart"
    static let costHistoryChartID = "costHistoryChart"
    static let usageHistoryChartID = "usageHistoryChart"
    static let storageBreakdownID = "storageBreakdown"
    static let statusComponentsID = "statusComponents"

    func shortcut(for action: MenuDescriptor.MenuAction) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch action {
        case .refresh:
            ("r", [.command])
        case .settings:
            (",", [.command])
        case .quit:
            ("q", [.command])
        default:
            nil
        }
    }

    func makeMenu() -> NSMenu {
        guard self.shouldMergeIcons else {
            return self.makeMenu(for: nil)
        }
        return self.makeBaseMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard self.shouldMergeIcons, menu === self.mergedMenu else { return }
        self.refreshMenuForOpenIfNeeded(menu, provider: self.resolvedMenuProvider())
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Records interaction and may bring an adaptive timer forward; never refreshes synchronously.
        self.store.noteMenuOpened()
        self.agentSessions.refreshOnMenuOpen()

        let trace = self.beginMenuOperationTrace("menuWillOpen", breadcrumb: "menuWillOpen")
        defer { self.endMenuOperationTrace(trace, menu: menu, provider: self.menuProvider(for: menu)) }

        // Keep the menu drawing in the current system appearance rather than the menu bar's
        // (possibly dark) vibrant appearance. Done before any early return so submenus match too.
        StatusMenuAppearance.pin(menu)
        // The menu window is created by AppKit as tracking begins. Pin it here, at the menu-open
        // boundary, instead of from child hosting views whose viewDidMoveToWindow timing is not
        // deterministic and can cause repeated appearance churn.
        StatusMenuAppearance.pinWindow(menu)

        self.cancelDeferredMenuInteractionRefreshTask()
        self.cancelClosedMenuRebuild(menu)

        self.beginMenuTrackingSession(for: menu)

        // Track whether this is the root menu opening (no menus were open). Only the root open rebuilds
        // all content from current data, so the readiness baseline is re-anchored only here — re-anchoring
        // on a nested submenu open could mask a pending refresh for the already-open parent menu.
        let menuTrackingWasIdle = self.openMenus.isEmpty

        if self.isHostedSubviewMenu(menu) {
            if !self.hydrateHostedSubviewMenuIfNeeded(menu) {
                self.refreshHostedSubviewMenu(menu)
            }
            if self.isMenuRefreshEnabled, self.isOpenAIWebSubviewMenu(menu) {
                self.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "submenu open")
            }
            if self.isMenuRefreshEnabled {
                // Intentionally skip open-menu tracking when refresh is disabled (tests).
                // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
                self.openMenus[ObjectIdentifier(menu)] = menu
                if menuTrackingWasIdle {
                    self.resyncMenuAdjunctReadinessBaseline()
                }
            }
            // Removed redundant async refresh - single pass is sufficient after initial layout
            return
        }

        // Child menus own their rows. Sending one through the root-content path below would call
        // populateMenu(), remove those rows, and replace them with a duplicate of the main menu.
        // Hosted SwiftUI submenus are handled above because they still need hydration/refresh.
        if menu.supermenu != nil {
            if self.isMenuRefreshEnabled {
                self.openMenus[ObjectIdentifier(menu)] = menu
                if menuTrackingWasIdle {
                    self.resyncMenuAdjunctReadinessBaseline()
                }
            }
            return
        }

        var provider: UsageProvider?
        if self.shouldMergeIcons {
            let resolvedProvider = self.resolvedMenuProvider()
            self.lastMenuProvider = resolvedProvider ?? .codex
            provider = resolvedProvider
        } else {
            if let menuProvider = self.menuProviders[ObjectIdentifier(menu)] {
                self.lastMenuProvider = menuProvider
                provider = menuProvider
            } else if menu === self.fallbackMenu {
                self.lastMenuProvider = self.store.enabledProvidersForDisplay().first ?? .codex
                provider = nil
            } else {
                let resolved = self.store.enabledProvidersForDisplay().first ?? .codex
                self.lastMenuProvider = resolved
                provider = resolved
            }
        }

        if self.isMenuRefreshEnabled, (provider ?? self.lastMenuProvider) == .codex {
            self.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "parent menu open")
        }
        if self.settings.providerStorageFootprintsEnabled {
            self.store.refreshStorageFootprintsForOverview()
        }

        let renderedProviders = self.renderedProviders(for: menu)
        self.scheduleCodexMenuCostRefreshIfNeeded(renderedProviders: renderedProviders)
        let menuWasFreshBeforeOpen = !self.menuNeedsRefresh(menu)
        self.refreshMenuForOpenIfNeeded(menu, provider: provider)
        self.scheduleCodexAccountMenuProjectionRevalidationIfNeeded(
            for: renderedProviders)
        if self.isMenuRefreshEnabled {
            // Intentionally skip open-menu tracking when refresh is disabled (tests).
            // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
            self.openMenus[ObjectIdentifier(menu)] = menu
            // Only re-anchor when the opened menu actually shows current data. During an in-flight provider
            // refresh `refreshMenuForOpenIfNeeded` can preserve stale content; resyncing the baseline to
            // live store data in that case would mask the refresh-completion update (#1351).
            if menuTrackingWasIdle, !self.menuNeedsRefresh(menu) {
                self.resyncMenuAdjunctReadinessBaselineForRootOpen(
                    menu,
                    provider: provider,
                    menuWasFreshBeforeOpen: menuWasFreshBeforeOpen)
            }
            self.installProviderSwitcherShortcutMonitorIfNeeded(for: menu)
            // Only schedule refresh after menu is registered as open - refreshNow is called async
            self.scheduleOpenMenuRefresh(for: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        let wasHostedSubviewMenu = self.isHostedSubviewMenu(menu)
        self.forgetClosedMenu(menu)
        if wasHostedSubviewMenu {
            self.refreshOpenMenusAfterHostedSubviewClose()
        }
    }

    func forgetClosedMenu(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        let wasMergedMenu = menu === self.mergedMenu

        self.endMenuTrackingSession(for: menu)

        if key == self.providerSwitcherShortcutMenuID {
            self.removeProviderSwitcherShortcutMonitor()
        }

        self.clearMergedSwitcherContentCache(for: menu)
        let wasTracked = self.openMenus.removeValue(forKey: key) != nil
        let menuTrackingEnded = wasTracked && self.openMenus.isEmpty
        if self.openMenus.isEmpty {
            self.parentMenuRebuildPendingAfterHostedSubviewClose = false
        }
        self.cancelMenuWork(key)
        self.clearMenuHighlight(key)

        let isPersistentMenu = menu === self.mergedMenu ||
            menu === self.fallbackMenu ||
            self.providerMenus.values.contains { $0 === menu }
        if !isPersistentMenu {
            self.removeMenuTrackingState(key)
        } else if self.menuNeedsRefresh(menu) {
            self.handleClosedPersistentMenuNeedingRefresh(menu)
        }
        self.menuSession.clearParentRebuildDeferral(key)
        self.scheduleDeferredMenuInteractionRefreshIfNeeded()
        if wasMergedMenu {
            self.applyDeferredMergedIconRenderAfterTrackingIfNeeded()
        }
        if menuTrackingEnded {
            self.prepareAttachedClosedMenusIfNeeded()
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let key = ObjectIdentifier(menu)
        let previous = self.highlightedMenuItems[key]
        guard previous !== item else { return }
        let previousWasNative = self.isNativeMenuItemHighlighted(in: menu)

        if let previous {
            (previous.view as? MenuCardHighlighting)?.setHighlighted(false)
        }

        if let item,
           item.isEnabled,
           (item.view as? MenuCardHighlighting)?.allowsMenuHighlight != false
        {
            self.highlightedMenuItems[key] = item
            (item.view as? MenuCardHighlighting)?.setHighlighted(true)
        } else {
            self.highlightedMenuItems.removeValue(forKey: key)
        }

        if previousWasNative, !self.isNativeMenuItemHighlighted(in: menu) {
            self.resumeMenuRebuildDeferredForNativeHighlightIfNeeded(menu)
        }
    }

    // swiftlint:disable:next function_body_length
    func populateMenuContents(_ menu: NSMenu, provider: UsageProvider?) {
        guard menu.supermenu == nil else {
            assertionFailure("populateMenu called on a child menu; root content would clobber its items")
            return
        }

        let trace = self.beginMenuOperationTrace(
            "populateMenu",
            breadcrumb: "populateMenu:\(provider?.rawValue ?? "merged")")
        defer { self.endMenuOperationTrace(trace, menu: menu, provider: provider) }
        defer { self.refreshMenuCardHeights(in: menu) }

        let enabledProviders = self.store.enabledProvidersForDisplay()
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        let showsMergedSwitcher = self.shouldShowMergedProviderSwitcher(for: enabledProviders)
        let switcherSelection = showsMergedSwitcher
            ? self.resolvedSwitcherSelection(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview)
            : nil
        let isOverviewSelected = switcherSelection == .overview
        let isPiAgentSelected = switcherSelection == .piAgent
        let selectedProvider = if isOverviewSelected {
            self.resolvedMenuProvider(enabledProviders: enabledProviders)
        } else {
            switcherSelection?.provider ?? provider
        }
        let currentProvider = selectedProvider ?? enabledProviders.first ?? .codex
        let rawCodexAccountDisplay = isOverviewSelected || isPiAgentSelected
            ? nil
            : self.codexAccountMenuDisplay(for: currentProvider)
        let codexAccountDisplay = isOverviewSelected
            || isPiAgentSelected
            ? nil
            : self.stableCodexAccountMenuDisplay(
                rawCodexAccountDisplay,
                menu: menu,
                provider: currentProvider)
        let tokenAccountDisplay = isOverviewSelected || isPiAgentSelected
            ? nil
            : self.tokenAccountMenuDisplay(for: currentProvider)
        let showAllAccounts = (tokenAccountDisplay?.showAll ?? false) || (codexAccountDisplay?.showAll ?? false)
        let openAIContext = self.openAIWebContext(
            currentProvider: currentProvider,
            showAllAccounts: showAllAccounts)
        let descriptor = self.makeMenuDescriptor(
            provider: selectedProvider,
            includeContextualActions: !isOverviewSelected && !isPiAgentSelected,
            showsCodexAccountAction: isOverviewSelected
                ? enabledProviders.contains(.codex)
                : currentProvider == .codex)
        let menuWidth = self.menuCardWidth(
            for: enabledProviders,
            selectedProvider: selectedProvider,
            descriptor: descriptor)

        let hasTokenSwitcher = menu.items.contains { $0.view is TokenAccountSwitcherView }
        let hasCodexSwitcher = menu.items.contains { $0.view is CodexAccountSwitcherView }
        let switcherProvidersMatch = enabledProviders == self.lastSwitcherProviders
        let switcherUsageBarsShowUsedMatch = self.settings.usageBarsShowUsed == self.lastSwitcherUsageBarsShowUsed
        let switcherSelectionMatches = switcherSelection == self.lastMergedSwitcherSelection
        let switcherOverviewAvailabilityMatches = includesOverview == self.lastSwitcherIncludesOverview
        let switcherPiAvailabilityMatches = self.includesPiAgentTab == self.lastSwitcherIncludesPiAgent
        let menuLocalizationMatches = self.menuLocalizationSignature() == self.lastMenuLocalizationSignature
        let tokenSwitcherCompatible = tokenAccountDisplay == self.lastTokenAccountMenuDisplay &&
            ((tokenAccountDisplay?.showSwitcher == true && hasTokenSwitcher) ||
                (tokenAccountDisplay?.showSwitcher != true && !hasTokenSwitcher))
        let codexSwitcherCompatible = codexAccountDisplay == self.lastCodexAccountMenuDisplay &&
            ((codexAccountDisplay?.showSwitcher == true && hasCodexSwitcher) ||
                (codexAccountDisplay?.showSwitcher != true && !hasCodexSwitcher))
        let reusableRowWidthsMatch = self.reusableFixedWidthRows(in: menu).allSatisfy { item in
            guard let view = item.view else { return false }
            return abs(view.frame.width - menuWidth) <= 0.5
        }
        let providerSwitcherWidthMatches = (menu.items.first?.view as? ProviderSwitcherView).map { view in
            abs(view.frame.width - menuWidth) <= 0.5
        } ?? false
        let canSmartUpdate = showsMergedSwitcher &&
            !isOverviewSelected &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherSelectionMatches &&
            switcherOverviewAvailabilityMatches &&
            switcherPiAvailabilityMatches &&
            menuLocalizationMatches &&
            tokenSwitcherCompatible &&
            codexSwitcherCompatible &&
            reusableRowWidthsMatch &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): provider=\(String(describing: provider)) " +
                    "display=\(enabledProviders.map(\.rawValue)) " +
                    "available=\(self.store.enabledProviders().map(\.rawValue)) " +
                    "selection=\(String(describing: switcherSelection)) " +
                    "last=\(String(describing: self.lastMergedSwitcherSelection)) " +
                    "smart=\(canSmartUpdate)")
        }
        #endif

        if canSmartUpdate {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider),
                    menuWidth: menuWidth,
                    codexAccountDisplay: codexAccountDisplay,
                    tokenAccountDisplay: tokenAccountDisplay,
                    openAIContext: openAIContext,
                    descriptor: descriptor))
            return
        }

        let canPreserveProviderSwitcher = showsMergedSwitcher &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherOverviewAvailabilityMatches &&
            switcherPiAvailabilityMatches &&
            menuLocalizationMatches &&
            providerSwitcherWidthMatches &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): preserveSwitcher=\(canPreserveProviderSwitcher) " +
                    "widthMatch=\(providerSwitcherWidthMatches)")
        }
        #endif

        if canPreserveProviderSwitcher {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider),
                    menuWidth: menuWidth,
                    codexAccountDisplay: codexAccountDisplay,
                    tokenAccountDisplay: tokenAccountDisplay,
                    openAIContext: openAIContext,
                    descriptor: descriptor))
            return
        }

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil, menu.items.first?.view is ProviderSwitcherView {
            self.menuLogger.debug("populateMenu(open): rebuilding whole menu and replacing provider switcher")
        }
        #endif
        self.rebuildMenuContent(
            menu,
            context: MenuRebuildContext(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview,
                switcherSelection: switcherSelection,
                currentProvider: currentProvider,
                selectedProvider: selectedProvider,
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                openAIContext: openAIContext,
                descriptor: descriptor))
    }

    private func reusableFixedWidthRows(in menu: NSMenu) -> [NSMenuItem] {
        guard !menu.items.isEmpty else { return [] }

        var reusableRows: [NSMenuItem] = []
        var index = self.providerSwitcherContentStartIndex(in: menu)
        if index > 0 {
            reusableRows.append(menu.items[0])
        }
        if menu.items.count > index,
           menu.items[index].representedObject as? String == "relayQuickSwitch"
        {
            reusableRows.append(menu.items[index])
            index += 2
        }
        if menu.items.count > index,
           menu.items[index].view is CodexAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
            index += 2
        }
        if menu.items.count > index,
           menu.items[index].view is TokenAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
        }
        return reusableRows
    }

    private func rebuildMenuContent(
        _ menu: NSMenu,
        context: MenuRebuildContext)
    {
        self.performMenuMutationWithoutAnimation {
            let displacedSelection = self.lastMergedMenuContentSelection
            self.lastMergedMenuContentSelection = nil
            self.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: displacedSelection)
            defer { self.clearMenuCardViewRecyclePool() }
            menu.removeAllItems()
            let contentSelection = context.switcherSelection ?? .provider(context.currentProvider)
            self.addProviderSwitcherIfNeeded(
                to: menu,
                enabledProviders: context.enabledProviders,
                includesOverview: context.includesOverview,
                selection: context.switcherSelection ?? .provider(context.currentProvider),
                width: context.menuWidth)
            // Track which providers the switcher was built with for smart update detection
            if self.shouldShowMergedProviderSwitcher(for: context.enabledProviders) {
                self.rememberMergedSwitcherState(
                    context.enabledProviders,
                    context.switcherSelection,
                    context.includesOverview,
                    self.includesPiAgentTab)
            }
            if self.shouldShowMergedProviderSwitcher(for: context.enabledProviders),
               self.addCachedMergedSwitcherContent(
                   for: contentSelection,
                   to: menu,
                   menuWidth: context.menuWidth,
                   codexAccountDisplay: context.codexAccountDisplay,
                   tokenAccountDisplay: context.tokenAccountDisplay)
            {
                return
            }
            self.addRelayQuickSwitch(
                to: menu,
                width: context.menuWidth,
                visibleTargets: contentSelection.relayVisibleTargets)
            self.addCodexAccountSwitcherIfNeeded(
                to: menu,
                display: context.codexAccountDisplay,
                width: context.menuWidth)
            self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
            self.addTokenAccountSwitcherIfNeeded(
                to: menu,
                display: context.tokenAccountDisplay,
                width: context.menuWidth)
            self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay
            let menuContext = MenuCardContext(
                currentProvider: context.currentProvider,
                selectedProvider: context.selectedProvider,
                menuWidth: context.menuWidth,
                codexAccountDisplay: context.codexAccountDisplay,
                tokenAccountDisplay: context.tokenAccountDisplay,
                openAIContext: context.openAIContext)
            self.addPrimaryMenuContent(
                to: menu,
                context: menuContext,
                switcherSelection: contentSelection)
            self.addActionableSections(context.descriptor.sections, to: menu, width: context.menuWidth)
            self.cacheVisibleMergedSwitcherContent(
                in: menu,
                selection: contentSelection,
                contentStartIndex: self.providerSwitcherContentStartIndex(in: menu),
                menuWidth: context.menuWidth,
                contentVersion: self.menuSession.contentVersion)
        }
    }

    private func openAIWebContext(
        currentProvider: UsageProvider,
        showAllAccounts: Bool) -> OpenAIWebContext
    {
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: currentProvider,
            surface: .liveCard)
        let hasCreditsHistory = ForkFeaturePolicy.showsOptionalCreditsAndExtraUsage(for: currentProvider) &&
            codexProjection?.hasCreditsHistory == true
        let hasUsageBreakdown = codexProjection?.hasUsageBreakdown == true
        // OpenCode local usage is a first-class inline card lane. Its optional hosted chart
        // would replace the 24h/7d/30d lines with an arrow, which is especially confusing for
        // API-only and free-model users who have no web quota to show beside it.
        let hasCostHistory = currentProvider != .opencode &&
            self.settings.costSummaryShowsSubmenu(for: currentProvider) &&
            (self.store.tokenSnapshot(for: currentProvider)?.daily.isEmpty == false)
        let canShowBuyCredits = ForkFeaturePolicy.showsBuyCredits(for: currentProvider) &&
            self.settings.showOptionalCreditsAndExtraUsage &&
            codexProjection?.canShowBuyCredits == true
        let hasOpenAIWebMenuItems = !showAllAccounts &&
            (hasCreditsHistory || hasUsageBreakdown || hasCostHistory)
        return OpenAIWebContext(
            hasUsageBreakdown: hasUsageBreakdown,
            hasCreditsHistory: hasCreditsHistory,
            hasCostHistory: hasCostHistory,
            canShowBuyCredits: canShowBuyCredits,
            hasOpenAIWebMenuItems: hasOpenAIWebMenuItems)
    }

    private func addProviderSwitcherIfNeeded(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        includesOverview: Bool,
        selection: ProviderSwitcherSelection,
        width: CGFloat)
    {
        guard self.shouldShowMergedProviderSwitcher(for: enabledProviders) else { return }
        let switcherItem = self.makeProviderSwitcherItem(
            providers: enabledProviders,
            includesOverview: includesOverview,
            selected: selection,
            menu: menu,
            width: width)
        menu.addItem(switcherItem)
        self.addConsoleDivider(to: menu)
    }

    func addTokenAccountSwitcherIfNeeded(
        to menu: NSMenu,
        display: TokenAccountMenuDisplay?,
        width: CGFloat,
        captureMenu: NSMenu? = nil)
    {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeTokenAccountSwitcherItem(
            display: display,
            menu: captureMenu ?? menu,
            width: width)
        menu.addItem(switcherItem)
        self.addConsoleDivider(to: menu)
    }

    func addCodexAccountSwitcherIfNeeded(
        to menu: NSMenu,
        display: CodexAccountMenuDisplay?,
        width: CGFloat,
        captureMenu: NSMenu? = nil)
    {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeCodexAccountSwitcherItem(
            display: display,
            menu: captureMenu ?? menu,
            width: width)
        menu.addItem(switcherItem)
        self.addConsoleDivider(to: menu)
    }

    @discardableResult
    private func addOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat,
        captureMenu: NSMenu? = nil) -> Bool
    {
        // Rows may be built into a detached scratch menu for in-place reconciliation;
        // interaction closures must always reference the live menu they end up serving.
        let interactionMenu = captureMenu ?? menu
        let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: enabledProviders)
        let rows: [(provider: UsageProvider, model: UsageMenuCardView.Model)] = overviewProviders
            .compactMap { provider in
                guard let model = self.menuCardModel(for: provider) else { return nil }
                guard !model.isOverviewErrorOnly else { return nil }
                return (provider: provider, model: model)
            }
        guard !rows.isEmpty else { return false }

        let t0 = CACurrentMediaTime()
        defer { self.logChartRenderDurationIfSlow("addOverviewRows(\(rows.count))", startedAt: t0) }

        for (index, row) in rows.enumerated() {
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            let storageText = self.store.storageFootprintText(for: row.provider)
            let speedPresentation = self.agentSpeedPresentation(for: row.provider)
            let submenu = self.makeOverviewRowSubmenu(
                provider: row.provider,
                model: row.model,
                width: menuWidth)
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(
                    model: row.model,
                    storageText: storageText,
                    speedText: speedPresentation?.badgeText,
                    speedTooltip: speedPresentation?.tooltipText,
                    width: menuWidth),
                id: identifier,
                width: menuWidth,
                heightCacheScope: row.provider.rawValue,
                heightCacheFingerprint: row.model.heightFingerprint(
                    section: "overview",
                    additional: [
                        UsageMenuCardView.Model.heightFingerprintField("storage", storageText),
                        UsageMenuCardView.Model.heightFingerprintField("speed", speedPresentation?.badgeText),
                    ]),
                submenu: submenu,
                containsInteractiveControls: row.model.subtitleStyle == .error || row.model.usesLiveSubtitle,
                usesGPUSelection: true,
                onClick: { [weak self, weak interactionMenu] in
                    guard let self, let interactionMenu else { return }
                    self.selectOverviewProvider(row.provider, menu: interactionMenu)
                })
            if submenu == nil {
                // Keep plain rows wired for keyboard activation and accessibility action paths.
                item.target = self
                item.action = #selector(self.selectOverviewProvider(_:))
            }
            menu.addItem(item)
            if index < rows.count - 1 {
                self.addConsoleDivider(to: menu)
            }
        }
        return true
    }

    private func addOverviewEmptyState(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders)
        let message = resolvedProviders.isEmpty
            ? L("No providers selected for Overview.")
            : L("No overview data available.")
        let item = self.makeConsoleMenuRowItem(
            title: message,
            isEnabled: false,
            width: self.renderedMenuWidth(for: menu))
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

    private func addMenuCards(to menu: NSMenu, context: MenuCardContext, captureMenu: NSMenu? = nil) -> Bool {
        if let codexAccountDisplay = context.codexAccountDisplay, codexAccountDisplay.showAll {
            self.addStackedCodexMenuCards(codexAccountDisplay, to: menu, context: context)
            return false
        }

        if let codexAccountDisplay = context.codexAccountDisplay,
           context.currentProvider == .codex,
           self.store.tokenCostScope(for: .codex).signature == "codex:ambient"
        {
            self.addSegmentedCodexMenuCard(
                codexAccountDisplay,
                to: menu,
                context: context)
            return false
        }

        // Eligible claude-swap rows take precedence over Claude token-account cards; otherwise
        // the stacked token-account branch below would return before rendering the adapter rows.
        if ClaudeSwapMenuPrecedence.prefersClaudeSwap(
            provider: context.currentProvider,
            accountCount: self.store.claudeSwapAccountSnapshots.count,
            showSingleAccount: self.settings.claudeSwapShowSingleAccount)
        {
            self.addClaudeSwapMenuCards(to: menu, captureMenu: captureMenu ?? menu, context: context)
            return false
        }

        if let tokenAccountDisplay = context.tokenAccountDisplay, tokenAccountDisplay.showAll {
            let accountSnapshots = tokenAccountDisplay.snapshots
            let cards = accountSnapshots.isEmpty
                ? []
                : accountSnapshots.compactMap { accountSnapshot in
                    self.tokenAccountMenuCardModel(
                        for: context.currentProvider,
                        accountSnapshot: accountSnapshot)
                }
            self.addStackedMenuCards(cards, to: menu, context: context)
            return false
        }

        if context.currentProvider == .kilo, self.store.kiloScopeSnapshots.count > 1 {
            let cards = self.store.kiloScopeSnapshots.compactMap { scope in
                self.menuCardModel(
                    for: .kilo,
                    snapshotOverride: scope.snapshot,
                    errorOverride: scope.errorMessage,
                    forceOverrideCard: scope.snapshot == nil)
            }
            self.addStackedMenuCards(cards, to: menu, context: context)
            return false
        }

        guard let model = self.menuCardModel(for: context.selectedProvider) else { return false }
        let renderedModel = self.menuCardRefreshMonitor.model(for: model.provider, fallback: model)
        if context.openAIContext.hasOpenAIWebMenuItems ||
            self.requiresSectionedMenuForProviderDerivedCost(provider: context.currentProvider)
        {
            let webItems = OpenAIWebMenuItems(
                hasUsageBreakdown: context.openAIContext.hasUsageBreakdown,
                hasCreditsHistory: context.openAIContext.hasCreditsHistory,
                hasCostHistory: context.openAIContext.hasCostHistory,
                canShowBuyCredits: context.openAIContext.canShowBuyCredits)
            self.addMenuCardSections(
                to: menu,
                model: model,
                layoutModel: renderedModel,
                width: context.menuWidth,
                webItems: webItems)
            return true
        }

        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardView(
                model: model,
                layoutModel: renderedModel,
                width: context.menuWidth,
                onRefresh: self.menuCardRefreshAction(for: model.provider)),
            id: "menuCard",
            width: context.menuWidth,
            heightCacheScope: context.currentProvider.rawValue,
            heightCacheFingerprint: renderedModel.heightFingerprint(
                section: "card",
                additional: [
                    UsageMenuCardView.Model.heightFingerprintField(
                        "refreshButton",
                        model.provider == .opencode
                            ? String(describing: UsageMenuCardView.RefreshPresentation.buttonSize)
                            : nil),
                ]),
            containsInteractiveControls: true))
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            self.addConsoleDivider(to: menu)
        }
        if context.openAIContext.canShowBuyCredits {
            menu.addItem(self.makeBuyCreditsItem())
        }
        self.addConsoleDivider(to: menu)
        return false
    }

    private func menuCardRefreshAction(
        for provider: UsageProvider) -> (@MainActor () async -> Void)?
    {
        guard provider == .opencode else { return nil }
        return { [weak self] in
            guard let self else { return }
            await self.performStoreRefresh(
                for: provider,
                refreshOpenMenusWhenComplete: true,
                interaction: .userInitiated)
        }
    }

    func addStackedMenuCards(
        _ cards: [UsageMenuCardView.Model],
        to menu: NSMenu,
        context: MenuCardContext,
        planAction: ((Int) -> (() -> Void)?)? = nil)
    {
        if cards.isEmpty, let model = self.menuCardModel(for: context.selectedProvider) {
            let renderedModel = self.menuCardRefreshMonitor.model(for: model.provider, fallback: model)
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, layoutModel: renderedModel, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: renderedModel.heightFingerprint(section: "card"),
                containsInteractiveControls: true))
            self.addConsoleDivider(to: menu)
        } else {
            for (index, model) in cards.enumerated() {
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(
                        model: model,
                        width: context.menuWidth,
                        planAction: planAction?(index)),
                    id: "menuCard-\(index)",
                    width: context.menuWidth,
                    heightCacheScope: "\(context.currentProvider.rawValue)-\(index)",
                    heightCacheFingerprint: model.heightFingerprint(section: "card"),
                    containsInteractiveControls: true))
                if index < cards.count - 1 {
                    self.addConsoleDivider(to: menu)
                }
            }
            if !cards.isEmpty {
                self.addConsoleDivider(to: menu)
            }
        }
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            self.addConsoleDivider(to: menu)
        }
    }

    private func addOpenAIWebItemsIfNeeded(
        to menu: NSMenu,
        currentProvider: UsageProvider,
        context: OpenAIWebContext,
        addedOpenAIWebItems: Bool)
    {
        guard context.hasOpenAIWebMenuItems else { return }
        if !addedOpenAIWebItems {
            // Only show these when we actually have additional data.
            if context.hasUsageBreakdown {
                _ = self.addUsageBreakdownSubmenu(to: menu)
            }
            if context.hasCreditsHistory {
                _ = self.addCreditsHistorySubmenu(to: menu)
            }
            if context.hasCostHistory {
                _ = self.addCostHistorySubmenu(to: menu, provider: currentProvider)
            }
        }
        if menu.items.last.map(self.isConsoleDivider) != true {
            self.addConsoleDivider(to: menu)
        }
    }

    func addPrimaryMenuContent(
        to menu: NSMenu,
        context: MenuCardContext,
        switcherSelection: ProviderSwitcherSelection,
        captureMenu: NSMenu? = nil)
    {
        if switcherSelection == .overview {
            let enabledProviders = self.store.enabledProvidersForDisplay()
            if self.addOverviewRows(
                to: menu,
                enabledProviders: enabledProviders,
                menuWidth: context.menuWidth,
                captureMenu: captureMenu)
            {
                self.addConsoleDivider(to: menu)
            } else {
                self.addOverviewEmptyState(to: menu, enabledProviders: enabledProviders)
                self.addConsoleDivider(to: menu)
            }
        } else if switcherSelection == .piAgent {
            self.addPiAgentMenuCard(to: menu, width: context.menuWidth)
        } else {
            let addedOpenAIWebItems = self.addMenuCards(to: menu, context: context, captureMenu: captureMenu)
            if context.currentProvider == .opencode {
                self.addOpenCodeProfileMenuCards(to: menu, width: context.menuWidth)
            }
            self.addOpenAIWebItemsIfNeeded(
                to: menu,
                currentProvider: context.currentProvider,
                context: context.openAIContext,
                addedOpenAIWebItems: addedOpenAIWebItems)
            self.addUsageHistoryClusterIfNeeded(to: menu, context: context)
            if self.addZaiHourlyUsageMenuItemIfNeeded(
                to: menu,
                provider: context.currentProvider,
                width: context.menuWidth)
            {
                self.addConsoleDivider(to: menu)
            }
        }
    }

    func addActionableSections(
        _ sections: [MenuDescriptor.Section],
        to menu: NSMenu,
        width: CGFloat,
        captureMenu: NSMenu? = nil)
    {
        let actionableSections = sections.filter { section in section.entries.contains(where: \ .isActionable) }
        for (index, section) in actionableSections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    if style == .secondary {
                        menu.addItem(self.makeWrappedSecondaryTextItem(text: text, width: width))
                        continue
                    }
                    let item = self.makeConsoleMenuRowItem(
                        title: text,
                        isHeadline: style == .headline,
                        isEnabled: false,
                        width: width)
                    menu.addItem(item)
                case let .action(title, action):
                    if action == .refresh {
                        let item = self.makePersistentRefreshItem(
                            title: L(title),
                            menu: captureMenu ?? menu,
                            width: width)
                        menu.addItem(item)
                        self.persistentRefreshItems.add(item)
                        continue
                    }
                    let localizedTitle = L(title)
                    let (selector, represented) = self.selector(for: action)
                    let shell = NSMenuItem(title: localizedTitle, action: selector, keyEquivalent: "")
                    shell.target = self
                    shell.representedObject = represented
                    self.attachStatusComponentsSubmenuIfNeeded(
                        to: shell,
                        action: action,
                        menu: captureMenu ?? menu,
                        width: width)

                    var subtitle: String?
                    var isEnabled = true
                    if case let .switchAccount(targetProvider) = action,
                       let value = self.switchAccountSubtitle(for: targetProvider)
                    {
                        isEnabled = false
                        subtitle = value
                    } else if case .addCodexAccount = action,
                              let value = self.codexAddAccountSubtitle()
                    {
                        isEnabled = false
                        subtitle = value
                    } else if case .checkForUpdates = action,
                              !self.updater.isAvailable
                    {
                        isEnabled = false
                        subtitle = self.updater.unavailableReason
                    }

                    var menuItem: NSMenuItem?
                    let row = self.makeConsoleMenuRowItem(
                        title: localizedTitle,
                        subtitle: subtitle,
                        systemImageName: action.systemImageName,
                        shortcutText: self.shortcut(for: action).map(Self.shortcutDisplayLabel),
                        showsChevron: shell.submenu != nil,
                        isEnabled: isEnabled,
                        width: width,
                        onClick: isEnabled && shell.submenu == nil
                            ? { [weak self, weak menu] in
                                guard let self, let menuItem else { return }
                                _ = NSApp.sendAction(selector, to: self, from: menuItem)
                                if let menu { self.advanceMenuInteraction(for: menu) }
                            }
                            : nil)
                    menuItem = row
                    row.action = selector
                    row.target = self
                    row.representedObject = represented
                    if let shortcut = self.shortcut(for: action) {
                        row.keyEquivalent = shortcut.key
                        row.keyEquivalentModifierMask = shortcut.modifiers
                    }
                    row.submenu = shell.submenu
                    menu.addItem(row)
                case let .unavailable(title, tooltip):
                    let item = self.makeConsoleMenuRowItem(
                        title: title,
                        subtitle: tooltip,
                        isEnabled: false,
                        width: width)
                    menu.addItem(item)
                case let .submenu(title, systemImageName, submenuItems):
                    let submenu = NSMenu(title: title)
                    submenu.autoenablesItems = false
                    submenu.delegate = self
                    StatusMenuAppearance.pin(submenu)
                    self.replaceNativeSubmenuItems(in: submenu, with: submenuItems)
                    let item = self.makeConsoleMenuRowItem(
                        title: title,
                        systemImageName: systemImageName,
                        showsChevron: true,
                        width: width)
                    item.submenu = submenu
                    menu.addItem(item)
                    self.updatePersistentRefreshItemsEnabled()
                case .divider:
                    self.addConsoleDivider(to: menu)
                }
            }
            if index < actionableSections.count - 1 {
                self.addConsoleDivider(to: menu)
            }
        }
    }

    private func makeWrappedSecondaryTextItem(text: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = self.makeWrappedSecondaryTextView(text: text)
        let height = self.menuTextItemHeight(for: view, width: width)
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        item.view = view
        item.isEnabled = false
        item.toolTip = text
        return item
    }

    private func makeWrappedSecondaryTextView(text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor

        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = ConsoleDesign.nsSecondaryText
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textField)
        // macos-smell:disable MACOS005
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }

    private func menuTextItemHeight(for view: NSView, width: CGFloat) -> CGFloat {
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        view.layoutSubtreeIfNeeded()
        return max(1, ceil(view.fittingSize.height))
    }

    func makeMenu(for provider: UsageProvider?) -> NSMenu {
        let menu = self.makeBaseMenu()
        if let provider {
            self.menuProviders[ObjectIdentifier(menu)] = provider
        }
        return menu
    }

    private func makeBaseMenu() -> NSMenu {
        let menu = StatusItemMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.persistentActionDelegate = self
        StatusMenuAppearance.pin(menu)
        return menu
    }

    private func makeProviderSwitcherItem(
        providers: [UsageProvider],
        includesOverview: Bool,
        selected: ProviderSwitcherSelection,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ProviderSwitcherView(
            providers: providers,
            selected: selected,
            includesOverview: includesOverview,
            includesPiAgent: self.includesPiAgentTab,
            width: width,
            showsIcons: self.settings.switcherShowsIcons,
            iconProvider: { [weak self] provider in
                self?.switcherIcon(for: provider) ?? NSImage()
            },
            weeklyRemainingProvider: { [weak self] provider in
                self?.switcherWeeklyRemaining(for: provider)
            },
            onSelect: { [weak self, weak menu] selection in
                guard let self, let menu else { return }
                var provider: UsageProvider?
                self.preservingMergedSwitcherContentCachesDuringInvalidation {
                    switch selection {
                    case .overview:
                        self.settings.mergedMenuLastSelectedWasOverview = true
                        self.settings.mergedMenuLastSelectedWasPiAgent = false
                        provider = self.resolvedMenuProvider()
                    case let .provider(selectedProvider):
                        self.settings.mergedMenuLastSelectedWasOverview = false
                        self.settings.mergedMenuLastSelectedWasPiAgent = false
                        self.selectedMenuProvider = selectedProvider
                        provider = selectedProvider
                    case .piAgent:
                        self.settings.mergedMenuLastSelectedWasOverview = false
                        self.settings.mergedMenuLastSelectedWasPiAgent = true
                        provider = nil
                    }
                    switch selection {
                    case .overview:
                        self.lastMenuProvider = provider ?? .codex
                    case let .provider(provider):
                        self.lastMenuProvider = provider
                    case .piAgent:
                        self.lastMenuProvider = .codex
                    }
                    self.lastMergedSwitcherSelection = selection
                    self.refreshProviderSelectionDependentUI(deferRendering: true)
                }
                self.requestProviderSwitcherMenuRebuild(menu, provider: provider)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeTokenAccountSwitcherItem(
        display: TokenAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = TokenAccountSwitcherView(
            accounts: display.accounts,
            selectedIndex: display.activeIndex,
            width: width,
            onSelect: { [weak self, weak menu] index -> Task<Void, Never>? in
                guard let self, let menu else { return nil }
                guard display.accounts.indices.contains(index) else { return nil }
                let selectedAccount = display.accounts[index]
                self.advanceMenuInteraction(for: menu)
                self.settings.setActiveTokenAccountIndex(index, for: display.provider)
                self.store.activateCachedTokenAccountSnapshot(
                    provider: display.provider,
                    accountID: selectedAccount.id)
                self.applyIcon(phase: nil)
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                return Task { @MainActor [weak self, weak menu] in
                    guard let self else { return }
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(display.provider)
                    }
                    guard let menu else { return }
                    self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                }
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeCodexAccountSwitcherItem(
        display: CodexAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = CodexAccountSwitcherView(
            accounts: display.accounts,
            selectedAccountID: display.activeVisibleAccountID,
            width: width,
            onSelect: { [weak self, weak menu] account in
                guard let self else { return }
                self.handleCodexVisibleAccountSelection(account, menu: menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleCodexVisibleAccountSelection(_ account: CodexVisibleAccount, menu: NSMenu?) -> Bool {
        let visibleAccountID = account.id
        self.advanceMenuInteraction(for: menu)
        self.accountsDomain.selectDisplayedAccount(account)
        if self.accountsDomain.prepareScopedRefreshIfNeeded(), let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        }
        let accountsDomain = self.accountsDomain
        Task { @MainActor [weak controller = self, weak menu, accountsDomain] in
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await accountsDomain.refreshScopedState(
                    allowDisabled: true,
                    phaseDidChange: { [weak controller, weak menu, accountsDomain] _ in
                        guard let controller, let menu else { return }
                        guard accountsDomain.visibleAccountProjection.activeVisibleAccountID == visibleAccountID
                        else {
                            return
                        }
                        controller.refreshOpenMenuIfStillVisible(menu, provider: .codex)
                    })
            }
        }
        return true
    }

    func resolvedMenuProvider(enabledProviders: [UsageProvider]? = nil) -> UsageProvider? {
        let enabled = enabledProviders ?? self.store.enabledProvidersForDisplay()
        if enabled.isEmpty {
            return .codex
        }
        if let selected = self.selectedMenuProvider, enabled.contains(selected) {
            return selected
        }
        // Prefer an available provider so the default menu content matches the status icon.
        // Falls back to first display provider when all lack credentials.
        return enabled.first(where: { self.store.isProviderAvailable($0) }) ?? enabled.first
    }

    private func includesOverviewTab(enabledProviders: [UsageProvider]) -> Bool {
        !self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders).isEmpty
    }

    private func resolvedSwitcherSelection(
        enabledProviders: [UsageProvider],
        includesOverview: Bool) -> ProviderSwitcherSelection
    {
        if self.includesPiAgentTab, self.settings.mergedMenuLastSelectedWasPiAgent {
            return .piAgent
        }
        if includesOverview, self.settings.mergedMenuLastSelectedWasOverview {
            return .overview
        }
        return .provider(self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex)
    }

    func menuProvider(for menu: NSMenu) -> UsageProvider? {
        let menu = self.rootMenu(for: menu)
        if self.shouldMergeIcons {
            return self.resolvedMenuProvider()
        }
        if let provider = self.menuProviders[ObjectIdentifier(menu)] {
            return provider
        }
        if menu === self.fallbackMenu {
            return nil
        }
        return self.store.enabledProvidersForDisplay().first ?? .codex
    }

    private func scheduleOpenMenuRefresh(for menu: NSMenu) {
        // Queue refresh work only when visible menu data is missing or stale. Here "stale" means the last
        // provider fetch failed and needs a retry; periodic freshness is handled by the refresh timer.
        // AppKit menu tracking is modal, so starting provider refreshes while it is active can make the menu
        // feel frozen and can block keyboard focus from returning.
        // Exception: when `refreshAllProvidersOnMenuOpen` is enabled, every enabled provider is refreshed on
        // open regardless of freshness — still after the delay below, and still via the light usage-only
        // primitive so the OpenAI dashboard scrape stays deferred until the menu closes.
        let providersNeedingRetryAtOpen = self.delayedRefreshRetryProviders(for: menu).filter {
            self.store.needsUsageRefreshRetry(for: $0)
        }
        if !providersNeedingRetryAtOpen.isEmpty {
            self.deferMenuInteractionRefreshIfNeeded(providers: providersNeedingRetryAtOpen)
        }
        let key = ObjectIdentifier(menu)
        self.menuRefreshTasks[key]?.cancel()
        self.menuRefreshTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            try? await Task.sleep(for: Self.menuOpenRefreshDelay)
            guard !Task.isCancelled else { return }
            guard self.isMenuRefreshEnabled else { return }
            #if DEBUG
            self.onDelayedMenuRefreshAttemptForTesting?()
            #endif
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            let refreshAllOnOpen = self.settings.refreshAllProvidersOnMenuOpen
            let enabledProviders = self.store.enabledProvidersForBackgroundWork()
            let visibleProviders = self.delayedRefreshRetryProviders(for: menu)
            let plan = MenuOpenRefreshPlan.resolve(.init(
                refreshAllOnOpen: refreshAllOnOpen,
                enabledProviders: enabledProviders,
                visibleProviders: visibleProviders,
                refreshingProviders: self.store.refreshingProviders,
                staleProviders: Set(visibleProviders.filter { self.store.isStale(provider: $0) }),
                missingProviders: Set(visibleProviders.filter { !self.store.hasSatisfiedUsageFetch(for: $0) })))
            if plan.refreshCodexDashboard {
                self.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "refresh all")
            }
            let retryProviders = plan.providers
            guard !retryProviders.isEmpty else {
                self.clearSatisfiedDeferredMenuInteractionRefreshes(
                    for: self.delayedRefreshRetryProviders(for: menu))
                // Ordinary store changes intentionally stay queued until the next open. Rebuilding here
                // made first-open work such as the storage scan flash the visible menu after 1.2 seconds.
                if !providersNeedingRetryAtOpen.isEmpty, self.menuNeedsRefresh(menu) {
                    self.scheduleOpenMenuRebuildIfStillVisible(
                        menu,
                        provider: self.menuProvider(for: menu),
                        resyncReadinessBaselineAfterRebuild: self.openMenus.count == 1)
                }
                return
            }
            self.deferMenuInteractionRefreshIfNeeded(providers: retryProviders)
            await ProviderInteractionContext.$current.withValue(.background) {
                if plan.scheduling == .concurrent {
                    // Refresh concurrently so one slow provider doesn't delay the rest, mirroring the
                    // periodic refresh in `UsageDomain.runRefresh`. `coalesceIfRefreshing` makes each call
                    // wait for any in-flight refresh (e.g. a manual refresh) instead of overriding it.
                    await withTaskGroup(of: Void.self) { group in
                        for provider in retryProviders {
                            group.addTask {
                                await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                            }
                        }
                    }
                } else {
                    for provider in retryProviders {
                        guard !Task.isCancelled else { return }
                        await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
                    }
                }
            }
            let stillNeedsRetry = retryProviders.contains {
                self.store.needsUsageRefreshRetry(for: $0)
            }
            if !stillNeedsRetry {
                self.clearSatisfiedDeferredMenuInteractionRefreshes(for: retryProviders)
            }
            guard !Task.isCancelled else { return }
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            self.invalidateMenus(
                refreshOpenMenus: true,
                deferOpenParentMenuRebuild: false,
                allowStaleContentDuringDataRefresh: true)
        }
    }

    private func menuNeedsDelayedRefreshRetry(for menu: NSMenu) -> Bool {
        let providersToCheck = self.delayedRefreshRetryProviders(for: menu)
        guard !providersToCheck.isEmpty else { return false }
        return providersToCheck.contains { provider in
            self.store.needsUsageRefreshRetry(for: provider)
        }
    }

    private func delayedRefreshRetryProviders(for menu: NSMenu) -> [UsageProvider] {
        self.renderedProviders(for: menu)
    }

    func renderedProviders(for menu: NSMenu) -> [UsageProvider] {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        guard !enabledProviders.isEmpty else { return [] }
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)

        if self.shouldShowMergedProviderSwitcher(for: enabledProviders),
           self.resolvedSwitcherSelection(
               enabledProviders: enabledProviders,
               includesOverview: includesOverview) == .overview
        {
            return self.settings.resolvedMergedOverviewProviders(
                activeProviders: enabledProviders,
                maxVisibleProviders: Self.maxOverviewProviders)
        }

        if self.shouldShowMergedProviderSwitcher(for: enabledProviders),
           self.resolvedSwitcherSelection(
               enabledProviders: enabledProviders,
               includesOverview: includesOverview) == .piAgent
        {
            return []
        }

        if let provider = self.menuProvider(for: menu)
            ?? self.resolvedMenuProvider(enabledProviders: enabledProviders)
        {
            return [provider]
        }
        return enabledProviders
    }

    private func addMenuCardSections(
        to menu: NSMenu,
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model,
        width: CGFloat,
        webItems: OpenAIWebMenuItems)
    {
        let provider = layoutModel.provider
        let hasCredits = layoutModel.creditsText != nil
        let hasExtraUsage = layoutModel.providerCost != nil
        let hasCost = layoutModel.tokenUsage != nil
        let bottomPadding = CGFloat(hasCredits ? 4 : 6)
        let sectionSpacing = CGFloat(6)
        let creditsBottomPadding = bottomPadding
        func addSectionSeparator() {
            guard menu.items.last.map(self.isConsoleDivider) != true else { return }
            self.addConsoleDivider(to: menu)
        }

        if layoutModel.hasUsageContent {
            let usageView = UsageMenuCardHeaderAndUsageSectionView(
                model: model,
                layoutModel: layoutModel,
                bottomPadding: bottomPadding,
                width: width,
                onRefresh: self.menuCardRefreshAction(for: provider))
            let usageSubmenu = self.makeUsageSubmenu(
                provider: provider,
                snapshot: self.store.snapshot(for: provider),
                webItems: webItems,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                usageView,
                id: "menuCardUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "usage"),
                submenu: usageSubmenu,
                containsInteractiveControls: true))
        } else {
            let headerView = UsageMenuCardHeaderSectionView(
                model: layoutModel,
                showDivider: false,
                width: width,
                onRefresh: self.menuCardRefreshAction(for: provider))
            menu.addItem(self.makeMenuCardItem(
                headerView,
                id: "menuCardHeader",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "header"),
                containsInteractiveControls: true))
        }

        if self.addStorageMenuCardSection(to: menu, provider: provider, width: width),
           hasCredits || hasExtraUsage
        {
            addSectionSeparator()
        }

        if hasCredits {
            if hasExtraUsage || hasCost {
                addSectionSeparator()
            }
            let creditsView = UsageMenuCardCreditsSectionView(
                model: model,
                showBottomDivider: false,
                topPadding: sectionSpacing,
                bottomPadding: creditsBottomPadding,
                width: width)
            let creditsSubmenu = webItems.hasCreditsHistory ? self.makeCreditsHistorySubmenu(width: width) : nil
            menu.addItem(self.makeMenuCardItem(
                creditsView,
                id: "menuCardCredits",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "credits"),
                submenu: creditsSubmenu))
            if webItems.canShowBuyCredits {
                menu.addItem(self.makeBuyCreditsItem())
            }
        }
        if hasExtraUsage {
            if hasCredits {
                addSectionSeparator()
            }
            let extraUsageSubmenu = self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
            let extraUsageView = UsageMenuCardExtraUsageSectionView(
                model: model,
                topPadding: sectionSpacing,
                bottomPadding: bottomPadding,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                extraUsageView,
                id: "menuCardExtraUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: layoutModel.heightFingerprint(section: "extraUsage"),
                submenu: extraUsageSubmenu))
        }
        if hasCost {
            if hasCredits || hasExtraUsage {
                addSectionSeparator()
            }
            let costSubmenu = webItems.hasCostHistory ? self
                .makeCostHistorySubmenu(provider: provider, width: width) : nil
            menu.addItem(self.makeCostMenuCardItem(
                model: model,
                submenu: costSubmenu,
                width: width))
        }
        if !hasCredits, webItems.hasCreditsHistory, self.settings.showOptionalCreditsAndExtraUsage {
            addSectionSeparator()
            _ = self.addCreditsHistorySubmenu(to: menu)
        }
        if !hasCredits, webItems.canShowBuyCredits {
            menu.addItem(self.makeBuyCreditsItem())
        }
    }

    private func switcherIcon(for provider: UsageProvider) -> NSImage {
        if let brand = ProviderBrandIcon.image(for: provider) {
            return brand
        }

        // Fallback to the dynamic icon renderer if resources are missing (e.g. dev bundle mismatch).
        let snapshot = self.store.snapshot(for: provider)
        let showUsed = self.settings.usageBarsShowUsed
        let style = self.store.style(for: provider)
        let now = Date()
        let resolved = snapshot.map {
            IconRemainingResolver.resolvedPercents(
                snapshot: $0,
                style: style,
                showUsed: showUsed,
                secondaryOverrideWindowID: self.settings.copilotIconSecondaryWindowOverrideID(snapshot: $0),
                now: now)
        }
        let primary = resolved?.primary
        let weekly = resolved?.secondary
        let creditsProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)
        let credits = creditsProjection?.menuBarFallback == .creditsBalance
            ? self.store.codexMenuBarCreditsRemaining(
                snapshotOverride: snapshot,
                now: now)
            : nil
        let stale = self.store.isStale(provider: provider)
        let indicator = self.store.statusIndicator(for: provider)
        let image = IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: credits,
            stale: stale,
            style: style,
            blink: 0,
            wiggle: 0,
            tilt: 0,
            statusIndicator: indicator,
            hideCritters: self.settings.menuBarHidesCritters)
        image.isTemplate = true
        return image
    }

    private func makeBuyCreditsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: L("Buy Credits..."),
            action: #selector(self.openCreditsPurchase),
            keyEquivalent: "")
        item.target = self
        if let image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }

    @discardableResult
    private func addCreditsHistorySubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeCreditsHistorySubmenu(width: self.renderedMenuWidth(for: menu))
        else { return false }
        let item = NSMenuItem(title: L("Credits history"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addUsageBreakdownSubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeUsageBreakdownSubmenu(width: self.renderedMenuWidth(for: menu))
        else { return false }
        let item = NSMenuItem(title: L("Usage breakdown"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeCostHistorySubmenu(provider: provider, width: self.renderedMenuWidth(for: menu))
        else { return false }
        let days = self.store.settings.costUsageHistoryDays
        let title = days == 1 ? L("Usage history (today)") : String(format: L("Usage history (%d days)"), days)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func makeUsageSubmenu(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        webItems: OpenAIWebMenuItems,
        width: CGFloat? = nil) -> NSMenu?
    {
        if webItems.hasUsageBreakdown {
            return self.makeUsageBreakdownSubmenu(width: width)
        }
        if provider == .openai {
            return self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
        }
        // Mistral's top usage pane has no rate-limit bars of its own, so its cost history hangs
        // off this row instead. Other `tokenCostRequiresProviderSnapshot` providers (e.g.
        // opencodego) show real rate-limit bars here and get their own "Cost" row instead
        // (see `makeCostMenuCardItem`), matching Codex/Claude's structure.
        if provider == .mistral {
            return self.makeCostHistorySubmenu(provider: provider, width: width)
        }
        if provider == .zai {
            return self.makeZaiUsageDetailsSubmenu(snapshot: snapshot)
        }
        return nil
    }

    func makeZaiUsageDetailsSubmenu(snapshot: UsageSnapshot?) -> NSMenu? {
        guard let timeLimit = snapshot?.zaiUsage?.timeLimit else { return nil }
        guard !timeLimit.usageDetails.isEmpty else { return nil }

        let submenu = NSMenu()
        submenu.delegate = self
        let titleItem = NSMenuItem(title: L("MCP details"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        submenu.addItem(titleItem)

        if let window = timeLimit.windowLabel {
            let item = NSMenuItem(title: String(format: L("mcp_window"), window), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if let resetTime = timeLimit.nextResetTime {
            let reset = self.settings.resetTimeDisplayStyle == .absolute
                ? UsageFormatter.resetDescription(from: resetTime)
                : UsageFormatter.resetCountdownDescription(from: resetTime)
            let item = NSMenuItem(title: String(format: L("mcp_resets"), reset), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        self.addConsoleDivider(to: submenu)

        let sortedDetails = timeLimit.usageDetails.sorted {
            $0.modelCode.localizedCaseInsensitiveCompare($1.modelCode) == .orderedAscending
        }
        for detail in sortedDetails {
            let usage = UsageFormatter.compactCountString(detail.usage)
            let item = NSMenuItem(
                title: String(format: L("mcp_model_usage"), detail.modelCode, usage),
                action: nil,
                keyEquivalent: "")
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeUsageBreakdownSubmenu(width: CGFloat? = nil) -> NSMenu? {
        let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: self.store.openAIDashboard?.usageBreakdown ?? [])
        guard !breakdown.isEmpty else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageBreakdownChartID, width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageBreakdownChartID)
    }

    private func makeCreditsHistorySubmenu(width: CGFloat? = nil) -> NSMenu? {
        guard !(self.store.openAIDashboard?.dailyBreakdown ?? []).isEmpty else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(chartID: Self.creditsHistoryChartID, width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.creditsHistoryChartID)
    }

    func makeCostHistorySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return nil }
        guard self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.costHistoryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.costHistoryChartID, provider: provider)
    }

    func tokenSnapshotForCostHistorySubmenu(provider: UsageProvider) -> CostUsageTokenSnapshot? {
        let projected = self.store.tokenSnapshot(
            fromProviderSnapshot: self.store.snapshot(for: provider),
            provider: provider)
        if UsageDomain.tokenCostRequiresProviderSnapshot(provider) {
            return projected
        }
        return projected ?? self.store.tokenSnapshot(for: provider)
    }

    func makeOpenAIAPIUsageSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.hasOpenAIAPIUsageSubmenu(provider: provider) else { return nil }
        return self.makeCostHistorySubmenu(provider: provider, width: width)
    }

    private func hasOpenAIAPIUsageSubmenu(provider: UsageProvider) -> Bool {
        provider == .openai && self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
    }

    /// Unlike `makeUsageSubmenu`'s and `tokenCostMenuSectionEnabled`'s provider checks, this one
    /// intentionally reuses `tokenCostRequiresProviderSnapshot`: any provider whose cost is
    /// sourced by projecting a snapshot field (rather than the CostUsageFetcher pipeline) can only
    /// render that cost through `addMenuCardSections`'s sectioned layout, so the two concepts are
    /// genuinely coupled here, not coincidentally aliased. The name is deliberately broader than
    /// "top-pane submenu" — opencodego satisfies this via its collapsible "Cost" row, not a
    /// provider-native top-pane submenu like openai/mistral.
    private func requiresSectionedMenuForProviderDerivedCost(provider: UsageProvider) -> Bool {
        UsageDomain.tokenCostRequiresProviderSnapshot(provider) &&
            self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
    }

    func makeStorageBreakdownSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.storageFootprint(for: provider)?.components.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.storageBreakdownID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.storageBreakdownID, provider: provider)
    }

    private func isOpenAIWebSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }

    @objc func menuCardNoOp(_ sender: NSMenuItem) {
        _ = sender
    }
}
