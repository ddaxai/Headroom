import AppKit
import CodexBarCore

struct CodexStackedMenuPresentation {
    let hasRelay: Bool
    let relayUsageProfileCount: Int

    var supplementaryItemIDs: [String] {
        ["codexCardGroupStatus"] + (self.hasRelay ? ["codexRelaySummary"] : []) + ["codexStackedTotal"]
    }

    var relayCardShowsProviderSwitcher: Bool {
        self.relayUsageProfileCount >= 2
    }

    let relayCardProviderSwitcherAffectsHeight = false

    init(hasRelay: Bool, relayUsageProfileCount: Int = 0) {
        self.hasRelay = hasRelay
        self.relayUsageProfileCount = relayUsageProfileCount
    }
}

private struct CodexRelayUsageCardSelection {
    let option: RelayQuickSwitchOption?
    let options: [RelayQuickSwitchOption]
    let activeProfileID: UUID?
    let selectedProfileID: UUID?
}

struct CodexRelayMenuLocalUsage {
    let line: String
    let snapshot: CostUsageTokenSnapshot?

    static func resolve(
        snapshot: CostUsageTokenSnapshot?,
        preferredCurrencyCode: String) -> Self
    {
        guard let snapshot else {
            return Self(line: L("codex_local_usage_empty"), snapshot: nil)
        }
        guard let rolling = CodexStackedUsageSummary.rolling24Hours(from: snapshot) else {
            let hasHistory = (snapshot.last30DaysTokens ?? 0) > 0
                || snapshot.daily.contains { ($0.totalTokens ?? 0) > 0 }
            return hasHistory
                ? Self(line: L("codex_local_usage_empty"), snapshot: snapshot)
                : Self(line: L("codex_local_usage_empty"), snapshot: nil)
        }
        let line = CodexStackedUsageSummary.line(
            rolling,
            preferredCurrencyCode: preferredCurrencyCode,
            emptyText: L("codex_local_usage_empty"),
            estimateSnapshot: snapshot)
        return Self(
            line: L("codex_relay_local_usage_format", line),
            snapshot: snapshot)
    }
}

extension StatusItemController {
    func addSegmentedCodexMenuCard(
        _ display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        context: MenuCardContext)
    {
        guard let account = display.accounts.first(where: { $0.id == display.activeVisibleAccountID }) ?? display
            .accounts.first
        else {
            return
        }
        let accountSnapshot = display.snapshots.first(where: { $0.account.id == account.id })
        let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
        guard var model = self.menuCardModel(
            for: .codex,
            snapshotOverride: accountSnapshot?.snapshot,
            errorOverride: health.label,
            forceOverrideCard: accountSnapshot == nil,
            accountOverride: self.accountInfo(for: account),
            historySelectionOverride: self.store.codexPlanUtilizationHistorySelection(
                forVisibleAccount: account),
            usageIdentityKindOverride: .subscription,
            tokenSnapshotOverride: self.codexMenuCostSnapshotsByAccountID[account.id])
        else {
            return
        }
        model.agentSpeed = self.codexAccountSpeedPresentation(for: account)

        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardView(model: model, width: context.menuWidth),
            id: "menuCard",
            width: context.menuWidth,
            heightCacheScope: account.id,
            heightCacheFingerprint: model.heightFingerprint(section: "card"),
            containsInteractiveControls: true))

        self.addConsoleDivider(to: menu)
    }

    func addStackedCodexMenuCards(
        _ display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        context: MenuCardContext)
    {
        let costSnapshotsByAccountID = self.codexMenuCostSnapshotsByAccountID
        let sharedCorpusHasUsage = (self.codexMenuFullCorpusCostSnapshot ?? self.codexMenuSharedCostSnapshot)
            .map(CodexStackedUsageSummary.hasTrackedUsage) == true
        let snapshotsByAccountID = Dictionary(uniqueKeysWithValues: display.snapshots.map {
            ($0.account.id, $0)
        })
        var cardIndex = 0
        let sections = display.showsWorkspaceGroups ? display.workspaceSections : [
            CodexAccountWorkspaceSection(title: "", accounts: display.accounts),
        ]
        let relayUsageCardSelection = self.codexRelayUsageCardSelection()
        let cardGroupUpdatedAt = CodexCardGroupStatusPresentation.latestUpdatedAt(
            fullCorpusUpdatedAt: self.codexMenuFullCorpusCostSnapshot?.updatedAt,
            accountUpdatedAts: display.snapshots.map { $0.snapshot?.updatedAt },
            relayUpdatedAt: relayUsageCardSelection.option?.usageSummary?.updatedAt)

        menu.addItem(self.makeMenuCardItem(
            CodexCardGroupStatusView(
                updatedAt: cardGroupUpdatedAt,
                width: context.menuWidth,
                onRefresh: { [weak self] in
                    await self?.refreshCodexCardGroup(relayUsageCardSelection)
                }),
            id: "codexCardGroupStatus",
            width: context.menuWidth,
            heightCacheScope: "codexCardGroupStatus",
            heightCacheFingerprint: MenuCardHeightFingerprint.codexCardGroupStatus(
                height: CodexCardGroupStatusPresentation.height,
                refreshButtonSize: CodexCardGroupStatusPresentation.refreshButtonSize),
            containsInteractiveControls: true))

        if !display.accounts.isEmpty {
            let submenu = self.makeCodexOfficialAccountsSubmenu(display: display)
            self.addCodexGroupHeader(
                title: L("Official Accounts"),
                count: display.accounts.count,
                id: "codexOfficialGroupHeader",
                submenu: submenu,
                to: menu,
                width: context.menuWidth)
        }

        for section in sections {
            for account in section.accounts {
                let accountSnapshot = snapshotsByAccountID[account.id]
                let tokenSnapshot = costSnapshotsByAccountID[account.id]
                let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
                let model = self.menuCardModel(
                    for: .codex,
                    snapshotOverride: accountSnapshot?.snapshot,
                    errorOverride: health.label,
                    forceOverrideCard: accountSnapshot == nil,
                    accountOverride: self.accountInfo(for: account),
                    historySelectionOverride: self.store.codexPlanUtilizationHistorySelection(
                        forVisibleAccount: account),
                    usageIdentityKindOverride: .subscription,
                    tokenSnapshotOverride: tokenSnapshot)
                guard let model else { continue }
                let scopedUsage = tokenSnapshot
                    .flatMap(CodexStackedUsageSummary.rolling24Hours(from:))
                    .flatMap { $0.totalTokens > 0 ? $0 : nil }
                let summaryLine = scopedUsage.map { summary in
                    CodexStackedUsageSummary.line(
                        summary,
                        preferredCurrencyCode: self.settings.preferredCurrencyCode,
                        emptyText: self.codexMenuCostRefreshTask == nil
                            ? L("codex_local_usage_empty")
                            : L("codex_local_usage_scanning"),
                        estimateSnapshot: tokenSnapshot)
                }
                let localUsage = CodexLocalUsagePresentation.resolve(
                    summaryLine: summaryLine,
                    refreshInFlight: self.codexMenuCostRefreshTask != nil,
                    coverageIsComplete: tokenSnapshot?.codexCorpusCoverageIsComplete,
                    sharedCorpusHasUsage: sharedCorpusHasUsage)
                let accountSpeed = self.codexAccountSpeedPresentation(for: account)
                let accountCardModel = CodexAccountSummaryCardModel(
                    model: model,
                    ordinal: cardIndex + 1,
                    workspace: display.showsWorkspaceGroups ? section.title : nil,
                    isActive: account.id == display.activeVisibleAccountID,
                    usageLine: localUsage.line,
                    usageEmptyText: localUsage.unassignedExplanation,
                    speedLine: accountSpeed?.inlineCompactLine,
                    speedTooltip: accountSpeed?.tooltipText)
                let baseHeightFingerprint = model.heightFingerprint(
                    section: "codexAccountCard",
                    additional: [
                        "ordinal=\(cardIndex + 1)",
                        "isActive=\(account.id == display.activeVisibleAccountID)",
                        UsageMenuCardView.Model.heightFingerprintField(
                            "resetCredits",
                            accountCardModel.resetCredits?.expirySummaryText),
                        UsageMenuCardView.Model.heightFingerprintField("workspace", section.title),
                        CardDetailRail.renderingFingerprint,
                    ])
                menu.addItem(self.makeMenuCardItem(
                    CodexAccountSummaryCardView(
                        model: accountCardModel,
                        width: context.menuWidth,
                        onViewUnassigned: { [weak self] in
                            self?.showUsageSpendSettingsFromMenu()
                        }),
                    id: "menuCard-\(cardIndex)",
                    width: context.menuWidth,
                    heightCacheScope: account.id,
                    heightCacheFingerprint: MenuCardHeightFingerprint.codexAccountCard(
                        baseFingerprint: baseHeightFingerprint,
                        usageLine: localUsage.line,
                        usageEmptyText: localUsage.unassignedExplanation,
                        speedLine: accountSpeed?.inlineCompactLine),
                    submenu: self.makeCodexUsageDetailsSubmenu(
                        snapshot: tokenSnapshot,
                        title: L("codex_usage_details_title", accountCardModel.email),
                        width: 300,
                        unavailableText: localUsage.unassignedExplanation
                            ?? L("codex_usage_details_unavailable_official")),
                    usesCardDetailRail: true,
                    containsInteractiveControls: true))
                cardIndex += 1
            }
        }

        if cardIndex == 0, let model = self.menuCardModel(for: context.selectedProvider) {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "card"),
                containsInteractiveControls: true))
        }

        self.addCodexRelayAndTotalCards(
            display: display,
            to: menu,
            context: context,
            relayUsageCardSelection: relayUsageCardSelection)
        self.addConsoleDivider(to: menu)
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            self.addConsoleDivider(to: menu)
        }
    }

    private func refreshCodexCardGroup(_ relayUsageCardSelection: CodexRelayUsageCardSelection) async {
        let relayProfileID: UUID? = relayUsageCardSelection.option.flatMap { option -> UUID? in
            guard option.isReady,
                  relayUsageCardSelection.options.contains(where: { $0.id == option.id })
            else { return nil }
            return option.id
        }
        await CodexCardGroupRefreshOrchestrator.run(
            relayProfileID: relayProfileID,
            refreshCodex: { [weak self] in
                guard let self else { return }
                await self.performStoreRefresh(
                    for: .codex,
                    refreshOpenMenusWhenComplete: false,
                    invalidateMenusWhenComplete: false,
                    interaction: .userInitiated)
                await self.refreshLocalAgentSpeedReport()
            },
            refreshRelay: { [weak self] profileID in
                guard let self else { return }
                _ = await self.relayQuickSwitchCoordinator.refreshUsage(profileID: profileID)
            },
            rebuildMenu: { [weak self] in
                self?.invalidateMenus(
                    refreshOpenMenus: true,
                    deferOpenParentMenuRebuild: false,
                    allowStaleContentDuringDataRefresh: true)
            })
    }

    private func addCodexRelayAndTotalCards(
        display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        context: MenuCardContext,
        relayUsageCardSelection: CodexRelayUsageCardSelection)
    {
        let costSnapshotsByAccountID = self.codexMenuCostSnapshotsByAccountID
        let accountSnapshots = display.accounts.compactMap { costSnapshotsByAccountID[$0.id] }
        let fullCorpusSnapshot = self.codexMenuFullCorpusCostSnapshot
        let unassignedSnapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(
            costSnapshotsByAccountID.filter { $0.key.hasPrefix("system-unassigned:") }.map(\.value))

        let activeProfileID = relayUsageCardSelection.activeProfileID
        let usageCardOptions = relayUsageCardSelection.options
        let selectedUsageProfileID = relayUsageCardSelection.selectedProfileID
        let option = relayUsageCardSelection.option
        if let option {
            self.addCodexGroupHeader(
                title: L("API / Relay"),
                id: "codexAPIGroupHeader",
                to: menu,
                width: context.menuWidth)
            let codexLocalSnapshot = self.codexMenuRelayCostSnapshotsByProfileID[option.id]
            let piLocalSnapshot = self.piAgentUsageCardSnapshot?.sections
                .first { !$0.isUnassigned && $0.providerKey == option.providerKey }?
                .tokenSnapshot(now: Date())
            let localRelaySnapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(
                [codexLocalSnapshot, piLocalSnapshot].compactMap(\.self))
            let localUsage = CodexRelayMenuLocalUsage.resolve(
                snapshot: localRelaySnapshot,
                preferredCurrencyCode: self.settings.preferredCurrencyCode)
            let unmeteredTargets = option.enabledTargets.subtracting([.codex, .piAgent, .claudeDesktop])
            let usageTriad = RelayUsageTriadPresentation.resolve(
                localSnapshot: localRelaySnapshot,
                providerSummary: option.usageSummary,
                apiFormat: option.apiFormat,
                preferredCurrencyCode: self.settings.preferredCurrencyCode,
                hasUnmeteredClientTargets: !unmeteredTargets.isEmpty)
            let relaySpeed = self.relaySpeedPresentation(
                profileID: option.id,
                providerKey: option.providerKey)
            let usageLine = localUsage.line
            menu.addItem(self.makeMenuCardItem(
                CodexRelaySummaryCardView(
                    model: CodexRelaySummaryCardModel(
                        name: option.name,
                        isActive: activeProfileID == option.id,
                        isReady: option.isReady,
                        blocker: option.blocker,
                        usageLine: usageLine,
                        usageSummary: option.usageSummary,
                        usageTriad: usageTriad,
                        profileOptions: usageCardOptions,
                        selectedProfileID: selectedUsageProfileID,
                        apiFormat: option.apiFormat,
                        speedLine: relaySpeed?.inlineCompactLine,
                        speedTooltip: relaySpeed?.tooltipText),
                    width: context.menuWidth,
                    onSelectProfile: { [weak self] profileID in
                        guard let self else { return }
                        self.settings.relayUsageCardProfileID = profileID
                        // The nested AppKit popup has returned, but the parent status menu is still
                        // unwinding its mouseDown tracking transaction. Replace its hosting view on
                        // the next main-loop turn instead of invalidating the view under the cursor.
                        DispatchQueue.main.async { [weak self] in
                            self?.invalidateMenus(
                                refreshOpenMenus: true,
                                deferOpenParentMenuRebuild: false,
                                allowStaleContentDuringDataRefresh: true)
                        }
                    }),
                id: "codexRelaySummary",
                width: context.menuWidth,
                heightCacheScope: "codexRelay",
                heightCacheFingerprint: [
                    option.id.uuidString,
                    String(activeProfileID == option.id),
                    usageCardOptions.map(\.id.uuidString).joined(separator: ","),
                    selectedUsageProfileID?.uuidString ?? "none",
                    option.apiFormat.rawValue,
                    usageLine,
                    relaySpeed?.inlineCompactLine ?? "no-speed",
                    String(describing: option.usageSummary),
                    usageTriad.heightFingerprint,
                    CardDetailRail.renderingFingerprint,
                ].joined(separator: "|"),
                submenu: self.makeCodexUsageDetailsSubmenu(
                    snapshot: localUsage.snapshot,
                    title: L("codex_relay_usage_details_title", option.name),
                    width: 300,
                    unavailableText: L("codex_local_usage_empty")),
                usesCardDetailRail: true,
                containsInteractiveControls: true))
        }

        let total = CodexStackedUsageSummary.menuTotal(
            accountSnapshots: accountSnapshots,
            expectedAccountCount: display.accounts.count,
            sharedSnapshot: unassignedSnapshot,
            fullCorpusSnapshot: fullCorpusSnapshot)
        let totalLine = CodexStackedUsageSummary.line(
            total,
            preferredCurrencyCode: self.settings.preferredCurrencyCode,
            emptyText: self.codexMenuCostRefreshTask == nil
                ? L("codex_local_usage_empty")
                : L("codex_local_usage_scanning"),
            estimateSnapshot: fullCorpusSnapshot ?? unassignedSnapshot)
        let hourlySubmenu = (fullCorpusSnapshot ?? unassignedSnapshot).flatMap {
            self.makeCodexHourlyUsageSubmenu(snapshot: $0, width: context.menuWidth)
        }
        menu.addItem(self.makeMenuCardItem(
            CodexStackedTotalUsageView(
                label: L("codex_usage_total"),
                value: totalLine,
                secondaryValue: nil,
                width: context.menuWidth,
                showsDetailRail: hourlySubmenu != nil),
            id: "codexStackedTotal",
            width: context.menuWidth,
            heightCacheScope: "codexTotal",
            heightCacheFingerprint: MenuCardHeightFingerprint.codexStackedTotal(
                totalLine: totalLine,
                unassignedLine: nil),
            submenu: hourlySubmenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            usesCardDetailRail: hourlySubmenu != nil,
            containsInteractiveControls: false))
    }

    private func codexRelayUsageCardSelection() -> CodexRelayUsageCardSelection {
        let relaySnapshot = self.relayQuickSwitchCoordinator.snapshot()
        let providerOptions = relaySnapshot.optionsByTarget[.codex] ?? []
        let activeProfileID = relaySnapshot.activeProfileIDsByTarget[.codex]
            ?? relaySnapshot.activeProfileIDsByTarget[.piAgent]
        let piProviderKeys = Set(
            (self.piAgentUsageCardSnapshot?.sections ?? [])
                .filter { !$0.isUnassigned }
                .map(\.providerKey))
        let meteredRelayIDs = Set(self.codexMenuRelayCostSnapshotsByProfileID.keys)
        var codexProviderKeys = Set(
            providerOptions
                .filter { meteredRelayIDs.contains($0.id) }
                .map(\.providerKey))
        for snapshot in [self.codexMenuFullCorpusCostSnapshot, self.codexMenuRelayAggregateCostSnapshot]
            .compactMap(\.self)
        {
            for breakdown in snapshot.rolling24Hours?.modelProviderBreakdowns ?? [] where breakdown.totalTokens > 0 {
                codexProviderKeys.insert(RelayProviderKey.slug(for: breakdown.modelProvider))
            }
            for profile in snapshot.profileBreakdowns where (profile.totalTokens ?? 0) > 0 {
                codexProviderKeys.insert(profile.providerKey)
            }
        }
        let usageCardOptions = self.relayQuickSwitchCoordinator.usageCardProfileOptions(
            localMeteredProviderKeys: piProviderKeys.union(codexProviderKeys))
        let persistedSelection = RelayUsageCardProfileSelection(
            options: usageCardOptions,
            activeProfileID: activeProfileID,
            defaults: self.settings.userDefaults)
        let selectedProfileID = persistedSelection.selectedProfileID
        let selectedOption = usageCardOptions.first { $0.id == selectedProfileID }
        let activeOption: RelayQuickSwitchOption? = if let activeProfileID {
            providerOptions.first { $0.id == activeProfileID }
        } else {
            nil
        }
        let option = selectedOption ?? activeOption ?? providerOptions.first
        return CodexRelayUsageCardSelection(
            option: option,
            options: usageCardOptions,
            activeProfileID: activeProfileID,
            selectedProfileID: selectedProfileID)
    }

    private func addCodexGroupHeader(
        title: String,
        count: Int? = nil,
        id: String,
        submenu: NSMenu? = nil,
        to menu: NSMenu,
        width: CGFloat)
    {
        let item = self.makeConsoleMenuRowItem(
            title: title,
            shortcutText: count.map { codexBarLocalizedInteger($0) },
            showsChevron: submenu != nil,
            isEnabled: submenu != nil,
            width: width)
        item.representedObject = id
        item.submenu = submenu
        menu.addItem(item)
    }

    func codexOfficialAccountSubmenuItems(
        display: CodexAccountMenuDisplay,
        relaySnapshot: RelayQuickSwitchSnapshot? = nil) -> [MenuDescriptor.SubmenuItem]
    {
        let relaySnapshot = relaySnapshot ?? self.relayQuickSwitchCoordinator.snapshot()
        let hasActiveRelay = relaySnapshot.activeProfileIDsByTarget[.codex] != nil
        let liveVisibleAccountID = self.settings.codexVisibleAccountProjection.liveVisibleAccountID
        let isInteractionBlocked = self.codexAccountPromotionCoordinator.isInteractionBlocked()
        return display.accounts.map { account in
            let isChecked = !hasActiveRelay && account.id == liveVisibleAccountID
            let action: MenuDescriptor.MenuAction? = if isChecked {
                nil
            } else if let storedAccountID = account.storedAccountID {
                .requestCodexSystemPromotion(storedAccountID)
            } else if hasActiveRelay {
                .restoreCodexOfficialConfiguration
            } else {
                nil
            }
            return MenuDescriptor.SubmenuItem(
                title: account.displayName,
                action: action,
                isEnabled: !isInteractionBlocked && action != nil,
                isChecked: isChecked)
        }
    }

    private func makeCodexOfficialAccountsSubmenu(display: CodexAccountMenuDisplay) -> NSMenu {
        let items = self.codexOfficialAccountSubmenuItems(display: display)
        let submenu = NSMenu(title: L("Official Accounts"))
        submenu.autoenablesItems = false
        submenu.delegate = self
        StatusMenuAppearance.pin(submenu)
        self.replaceNativeSubmenuItems(in: submenu, with: items)
        return submenu
    }

    func synchronizeCodexOfficialAccountsSubmenu(in rootMenu: NSMenu) {
        guard let submenu = rootMenu.items.first(where: {
            ($0.representedObject as? String) == "codexOfficialGroupHeader"
        })?.submenu else { return }
        let display = self.codexAccountMenuDisplay(for: .codex) ?? self.lastCodexAccountMenuDisplay
        guard let display else { return }
        self.replaceNativeSubmenuItems(
            in: submenu,
            with: self.codexOfficialAccountSubmenuItems(display: display))
    }
}
