import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    var includesPiAgentTab: Bool {
        self.settings.piAgentUsageEnabled
    }

    func shouldShowMergedProviderSwitcher(for enabledProviders: [UsageProvider]) -> Bool {
        self.shouldMergeIcons && (enabledProviders.count > 1 || self.includesPiAgentTab)
    }

    var fallbackProvider: UsageProvider? {
        // Intentionally uses availability-filtered list: fallback activates when no provider
        // can actually work, ensuring at least a codex icon is always visible.
        self.store.enabledProviders().isEmpty ? .codex : nil
    }
}

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(provider):
            provider
        case .piAgent:
            nil
        }
    }

    /// The relay switcher is scoped to the client represented by the selected provider tab.
    /// Overview intentionally keeps the complete multi-client switcher because it is the one
    /// place where cross-client state is useful.
    var relayVisibleTargets: [RelayTargetApp] {
        switch self {
        case .overview:
            RelayTargetApp.headroomManagedTargets
        case let .provider(provider):
            provider.relayTargetApp.map { [$0] } ?? []
        case .piAgent:
            [.piAgent]
        }
    }
}

extension UsageProvider {
    var relayTargetApp: RelayTargetApp? {
        switch self {
        case .codex:
            .codex
        case .opencode, .opencodego:
            .openCode
        case .claude:
            .claudeCode
        case .grok:
            .grokBuild
        default:
            nil
        }
    }
}

extension RelayTargetApp {
    static var headroomManagedTargets: [RelayTargetApp] {
        [.codex, .openCode, .claudeCode, .grokBuild, .piAgent]
    }
}

struct OverviewMenuCardRowView: View {
    static let showsSectionDividers = false

    let model: UsageMenuCardView.Model
    let storageText: String?
    var speedText: String? = nil
    var speedTooltip: String? = nil
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.model,
                showDivider: Self.showsSectionDividers && self.hasUsageBlock,
                width: self.width)
            if self.hasUsageBlock {
                UsageMenuCardUsageSectionView(
                    model: self.model,
                    showBottomDivider: false,
                    bottomPadding: 6,
                    width: self.width,
                    showsSectionDividers: Self.showsSectionDividers)
            }
            if self.speedText != nil || self.storageText != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let speedText = self.speedText {
                        Text(speedText)
                            .font(ConsoleDesign.mono(10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .lineLimit(1)
                            .help(self.speedTooltip ?? "")
                    }
                    if let storageText = self.storageText {
                        if self.speedText != nil {
                            Spacer(minLength: 6)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(L("Storage")):")
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            Text(storageText)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                    if self.storageText == nil {
                        Spacer(minLength: 4)
                    }
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.top, self.hasUsageBlock ? 0 : 8)
                .padding(.bottom, 6)
                .frame(width: self.width, alignment: .leading)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var hasUsageBlock: Bool {
        self.model.hasUsageContent
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay: Equatable {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: TokenAccountMenuDisplay, rhs: TokenAccountMenuDisplay) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.accountIdentity == rhs.accountIdentity &&
            lhs.activeIndex == rhs.activeIndex &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var accountIdentity: [AccountIdentity] {
        self.accounts.map { account in
            AccountIdentity(
                id: account.id,
                label: account.label,
                externalIdentifier: account.externalIdentifier,
                usageScope: account.usageScope,
                organizationID: account.organizationID,
                workspaceID: account.workspaceID)
        }
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct AccountIdentity: Equatable {
        let id: UUID
        let label: String
        let externalIdentifier: String?
        let usageScope: String?
        let organizationID: String?
        let workspaceID: String?
    }

    private struct SnapshotIdentity: Equatable {
        let id: UUID
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let snapshots: [CodexAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    var workspaceSections: [CodexAccountWorkspaceSection] {
        self.accounts.codexWorkspaceSections()
    }

    var showsWorkspaceGroups: Bool {
        Set(self.workspaceSections.map(\.title)).count > 1
    }

    static func == (lhs: CodexAccountMenuDisplay, rhs: CodexAccountMenuDisplay) -> Bool {
        lhs.accounts == rhs.accounts &&
            lhs.activeVisibleAccountID == rhs.activeVisibleAccountID &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct SnapshotIdentity: Equatable {
        let id: String
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}
