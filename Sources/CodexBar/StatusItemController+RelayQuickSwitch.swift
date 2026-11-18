import AppKit
import CodexBarCore

extension StatusItemController {
    func addRelayQuickSwitch(
        to menu: NSMenu,
        width: CGFloat,
        visibleTargets: [RelayTargetApp],
        captureMenu: NSMenu? = nil)
    {
        guard !visibleTargets.isEmpty else { return }
        let snapshot = self.relayQuickSwitchCoordinator.snapshot()
        let interactionMenu = captureMenu ?? menu
        let scopedSelectionFingerprint = visibleTargets.compactMap { target in
            snapshot.selectionByTarget[target]?.cacheDescription
        }.joined(separator: ",")
        let scopedOptionsFingerprint = visibleTargets.flatMap { target in
            snapshot.optionsByTarget[target] ?? []
        }.map(\.heightCacheDescription)
            .joined(separator: ",")
        let presentation = RelayQuickSwitchPresentation(visibleTargets: visibleTargets)
        let optionRowCounts = visibleTargets.enumerated().map { index, target in
            let externalTitles = snapshot.externalActiveByTarget[target].map { [$0.chipTitle] } ?? []
            let choices = [RelayQuickSwitchPresentation.officialChoiceLabel]
                + (snapshot.optionsByTarget[target] ?? []).map(\.name)
                + externalTitles
            let itemWidths = choices.enumerated().map { choiceIndex, choice in
                let textWidth = (choice as NSString).size(withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                ]).width
                return ceil(textWidth) + 18 + (choiceIndex == 0 ? 0 : 10)
            }
            let trailingSettingsWidth: CGFloat = index == 0 ? 26 : 0
            let targetSpacing = presentation.showsTargetLabels
                ? RelayQuickSwitchPresentation.interitemSpacing
                : 0
            let availableWidth = max(
                1,
                width - 24 - presentation.targetLabelWidth - targetSpacing - trailingSettingsWidth)
            return RelayQuickSwitchFlowLayout.rowCount(
                itemWidths: itemWidths,
                availableWidth: availableWidth,
                spacing: RelayQuickSwitchPresentation.interitemSpacing)
        }
        let baseFingerprint = [
            snapshot.currentLabel,
            scopedSelectionFingerprint,
            visibleTargets.map(\.rawValue).joined(separator: ","),
            scopedOptionsFingerprint,
        ].joined(separator: "|")
        let item = self.makeMenuCardItem(
            RelayQuickSwitchMenuView(
                snapshot: snapshot,
                width: width,
                visibleTargets: visibleTargets,
                onSelect: { [weak self, weak interactionMenu] selection, confirmed in
                    guard let self else {
                        return RelayQuickSwitchOutcome(
                            succeeded: false,
                            selection: .official(.codex),
                            message: "菜单已关闭。")
                    }
                    let outcome = self.relayQuickSwitchCoordinator.select(selection, confirmed: confirmed)
                    if outcome.succeeded {
                        self.applyIcon(phase: nil)
                        if let interactionMenu,
                           RelayQuickSwitchPresentation.shouldRebuildMenu(after: outcome)
                        {
                            self.rebuildMenuTree(
                                from: interactionMenu,
                                provider: self.resolvedMenuProvider())
                        } else if outcome.warning == nil {
                            self.invalidateMenus(refreshOpenMenus: false)
                        }
                    }
                    return outcome
                },
                onOpenSettings: { [weak self] in
                    self?.showRelaySettingsFromMenu()
                },
                codexSpeedActions: self.relayQuickSwitchCoordinator.codexSpeedActions,
                onFeedbackPresenceChange: { [weak self] in
                    self?.remeasureOpenMenuCardHeights()
                }),
            id: "relayQuickSwitch",
            width: width,
            heightCacheScope: "relay",
            heightCacheFingerprint: MenuCardHeightFingerprint.relayQuickSwitch(
                baseFingerprint: baseFingerprint,
                visibleTargetCount: visibleTargets.count,
                optionRowCounts: optionRowCounts,
                showsLoadError: snapshot.loadError != nil),
            containsInteractiveControls: true)
        menu.addItem(item)
        self.addConsoleDivider(to: menu)
    }
}

extension RelayQuickSwitchSelection {
    var cacheDescription: String {
        switch self {
        case let .official(target): "official:\(target.rawValue)"
        case let .profile(target, id): "profile:\(target.rawValue):\(id.uuidString)"
        case let .external(target, name): "external:\(target.rawValue):\(name)"
        case .mixed: "mixed"
        }
    }
}
