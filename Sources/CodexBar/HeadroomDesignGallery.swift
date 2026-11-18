#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

enum HeadroomDesignGalleryState: String, CaseIterable, Hashable {
    case empty
    case loading
    case error
    case longCopy
    case multiAccount

    var title: String {
        switch self {
        case .empty: L("design_gallery_state_empty")
        case .loading: L("design_gallery_state_loading")
        case .error: L("design_gallery_state_error")
        case .longCopy: L("design_gallery_state_long_copy")
        case .multiAccount: L("design_gallery_state_multi_account")
        }
    }
}

enum HeadroomDesignGalleryCardKind: String, CaseIterable, Hashable {
    case provider
    case officialAccount
    case relay

    var title: String {
        switch self {
        case .provider: L("design_gallery_card_provider")
        case .officialAccount: L("Official Accounts")
        case .relay: L("API / Relay")
        }
    }
}

struct HeadroomDesignGalleryEntry: Identifiable, Equatable {
    let kind: HeadroomDesignGalleryCardKind
    let state: HeadroomDesignGalleryState

    var id: String {
        "\(self.kind.rawValue)-\(self.state.rawValue)"
    }
}

enum HeadroomDesignGalleryResetCreditsState: String, CaseIterable, Hashable {
    case available
    case unavailable

    var title: String {
        switch self {
        case .available: L("Available")
        case .unavailable: L("Unavailable")
        }
    }
}

struct HeadroomDesignGalleryResetCreditsEntry: Identifiable, Equatable {
    let state: HeadroomDesignGalleryResetCreditsState

    var id: String {
        "officialAccount-resetCredits-\(self.state.rawValue)"
    }
}

enum HeadroomDesignGalleryCatalog {
    static let entries = HeadroomDesignGalleryCardKind.allCases.flatMap { kind in
        HeadroomDesignGalleryState.allCases.map { state in
            HeadroomDesignGalleryEntry(kind: kind, state: state)
        }
    }

    static let resetCreditEntries = HeadroomDesignGalleryResetCreditsState.allCases.map {
        HeadroomDesignGalleryResetCreditsEntry(state: $0)
    }
}

struct HeadroomDesignGalleryBaseline: Decodable, Equatable {
    enum Period: String, CaseIterable, Decodable, Hashable {
        case rolling24Hours = "24h"
        case last7Days = "7d"
        case last30Days = "30d"

        var title: String {
            switch self {
            case .rolling24Hours: L("relay_local_usage_24h")
            case .last7Days: L("relay_local_usage_7d")
            case .last30Days: L("30d")
            }
        }
    }

    struct ResetCredits: Decodable, Equatable {
        let count: Int
        let expiresAt: Date
    }

    struct Window: Decodable, Equatable {
        let period: Period
        let localTokens: Int?
        let reportedTokens: Int?
    }

    struct OfficialAccount: Decodable, Equatable {
        let id: String
        let isActive: Bool
        let resetCredits: ResetCredits?
        let windows: [Window]

        func window(for period: Period) -> Window? {
            self.windows.first { $0.period == period }
        }
    }

    struct Relay: Decodable, Equatable {
        let id: String
        let multiplier: Double?
        let reportsUsage: Bool
        let windows: [Window]

        func window(for period: Period) -> Window? {
            self.windows.first { $0.period == period }
        }
    }

    struct Unassigned: Decodable, Equatable {
        let id: String
        let windows: [Window]
    }

    struct Total: Decodable, Equatable {
        let period: Period
        let localTokens: Int
    }

    let schemaVersion: Int
    let officialAccounts: [OfficialAccount]
    let relays: [Relay]
    let unassigned: Unassigned
    let totals: [Total]

    static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/CodexBarTests/Fixtures/usage_baseline.json")
    }

    static func load(from url: URL = Self.sourceURL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let baseline = try decoder.decode(Self.self, from: Data(contentsOf: url))
        try baseline.validate()
        return baseline
    }

    func total(for period: Period) -> Int {
        self.totals.first { $0.period == period }?.localTokens ?? 0
    }

    private func validate() throws {
        guard self.schemaVersion == 1 else { throw ValidationError.unsupportedSchema }
        guard self.officialAccounts.count >= 2, self.relays.count >= 2 else {
            throw ValidationError.missingRequiredSources
        }
        let expectedPeriods = Set(Period.allCases)
        let allWindows = self.officialAccounts.map(\.windows) + self.relays.map(\.windows) + [self.unassigned.windows]
        guard allWindows.allSatisfy({ Set($0.map(\.period)) == expectedPeriods }) else {
            throw ValidationError.missingRequiredPeriods
        }
    }

    enum ValidationError: Error {
        case unsupportedSchema
        case missingRequiredSources
        case missingRequiredPeriods
    }
}

enum HeadroomDesignGalleryLayout {
    static let cardWidth: CGFloat = 300
    static let rowLabelWidth: CGFloat = 104
    static let columnSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 14
    static let contentPadding: CGFloat = 18
    static let windowContentSize = NSSize(
        width: rowLabelWidth
            + cardWidth * CGFloat(HeadroomDesignGalleryState.allCases.count)
            + columnSpacing * CGFloat(HeadroomDesignGalleryState.allCases.count)
            + contentPadding * 2,
        height: 940)
}

enum HeadroomDesignGalleryModels {
    static func provider(
        state: HeadroomDesignGalleryState,
        baseline: HeadroomDesignGalleryBaseline) -> UsageMenuCardView.Model
    {
        self.baseUsageModel(state: state, baseline: baseline)
    }

    static func officialAccount(
        state: HeadroomDesignGalleryState,
        baseline: HeadroomDesignGalleryBaseline) -> CodexAccountSummaryCardModel
    {
        let account = self.account(for: state, baseline: baseline)
        let model = self.baseUsageModel(state: state, baseline: baseline)
        let hasLoadedUsage = state == .longCopy || state == .multiAccount
        let usageLine = hasLoadedUsage
            ? account.window(for: .rolling24Hours)?.localTokens.map(Self.tokenLine)
            : state == .loading ? L("codex_official_usage_scanning") : nil
        return CodexAccountSummaryCardModel(
            model: model,
            ordinal: state == .multiAccount ? 2 : 1,
            workspace: state == .longCopy ? L("design_gallery_long_workspace") : nil,
            isActive: account.isActive,
            usageLine: usageLine,
            usageEmptyText: state == .empty ? L("codex_account_usage_unassigned_explanation") : nil)
    }

    static func officialAccountResetCredits(
        state: HeadroomDesignGalleryResetCreditsState,
        baseline: HeadroomDesignGalleryBaseline) -> CodexAccountSummaryCardModel
    {
        let account = baseline.officialAccounts[0]
        let model = self.baseUsageModel(
            state: .longCopy,
            baseline: baseline,
            includesResetCredits: state == .available)
        return CodexAccountSummaryCardModel(
            model: model,
            ordinal: 1,
            workspace: nil,
            isActive: account.isActive,
            usageLine: account.window(for: .rolling24Hours)?.localTokens.map(Self.tokenLine))
    }

    static func relay(
        state: HeadroomDesignGalleryState,
        baseline: HeadroomDesignGalleryBaseline) -> CodexRelaySummaryCardModel
    {
        let primary = baseline.relays[0]
        let summary = state == .longCopy || state == .multiAccount
            ? self.relaySummary(primary, baseline: baseline)
            : nil
        let options = state == .multiAccount ? self.relayOptions(baseline) : []
        let blocker: String? = switch state {
        case .error: L("design_gallery_error_message")
        case .longCopy: L("design_gallery_long_relay_detail")
        default: nil
        }
        let usageLine = switch state {
        case .empty: L("codex_relay_usage_unavailable")
        case .loading: L("relay_usage_card_refreshing")
        case .error: L("design_gallery_error_message")
        case .longCopy, .multiAccount: self.relayUsageLine(primary)
        }
        return CodexRelaySummaryCardModel(
            name: state == .longCopy ? "\(primary.id) · \(L("design_gallery_long_profile"))" : primary.id,
            isActive: state == .multiAccount,
            isReady: state != .error,
            blocker: blocker,
            usageLine: usageLine,
            usageSummary: summary,
            profileOptions: options,
            selectedProfileID: options.first?.id)
    }

    private static func baseUsageModel(
        state: HeadroomDesignGalleryState,
        baseline: HeadroomDesignGalleryBaseline,
        includesResetCredits: Bool? = nil) -> UsageMenuCardView.Model
    {
        let account = self.account(for: state, baseline: baseline)
        let loaded = state == .longCopy || state == .multiAccount
        let metrics = loaded ? self.metrics(for: account, baseline: baseline) : []
        let resetCredits = if let includesResetCredits {
            includesResetCredits ? self.resetCredits(for: account) : nil
        } else {
            loaded ? self.resetCredits(for: account) : nil
        }
        let subtitleText = switch state {
        case .empty: L("Not fetched yet")
        case .loading: "\(L("Refreshing"))…"
        case .error: L("design_gallery_error_message")
        case .longCopy: L("design_gallery_long_subtitle")
        case .multiAccount: L("Active")
        }
        let subtitleStyle: UsageMenuCardView.Model.SubtitleStyle = switch state {
        case .loading: .loading
        case .error: .error
        default: .info
        }
        let planText: String? = switch state {
        case .empty, .loading, .error: nil
        case .longCopy: L("design_gallery_long_plan")
        case .multiAccount: "Pro"
        }
        let placeholder: String? = switch state {
        case .empty: L("No usage yet")
        case .loading: "\(L("Refreshing"))…"
        default: nil
        }
        return UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: self.email(for: account, state: state),
            subtitleText: subtitleText,
            subtitleStyle: subtitleStyle,
            usageIdentityKind: .subscription,
            planText: planText,
            metrics: metrics,
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            codexResetCredits: resetCredits,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: placeholder,
            progressColor: ConsoleDesign.accent)
    }

    private static func account(
        for state: HeadroomDesignGalleryState,
        baseline: HeadroomDesignGalleryBaseline) -> HeadroomDesignGalleryBaseline.OfficialAccount
    {
        state == .multiAccount ? baseline.officialAccounts[1] : baseline.officialAccounts[0]
    }

    private static func email(
        for account: HeadroomDesignGalleryBaseline.OfficialAccount,
        state: HeadroomDesignGalleryState) -> String
    {
        if state == .longCopy {
            return "\(account.id).workspace.with.an.intentionally.long.identity@headroom.invalid"
        }
        return "\(account.id)@headroom.invalid"
    }

    private static func metrics(
        for account: HeadroomDesignGalleryBaseline.OfficialAccount,
        baseline: HeadroomDesignGalleryBaseline) -> [UsageMenuCardView.Model.Metric]
    {
        HeadroomDesignGalleryBaseline.Period.allCases.compactMap { period in
            guard let tokens = account.window(for: period)?.localTokens else { return nil }
            let total = max(1, baseline.total(for: period))
            let remainingPercent = max(0, 100 - Double(tokens) / Double(total) * 100)
            return UsageMenuCardView.Model.Metric(
                id: period.rawValue,
                title: period.title,
                percent: remainingPercent,
                percentStyle: .left,
                resetText: nil,
                detailText: self.tokenLine(tokens),
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true)
        }
    }

    private static func resetCredits(
        for account: HeadroomDesignGalleryBaseline.OfficialAccount) -> CodexResetCreditsPresentation?
    {
        guard let credits = account.resetCredits else { return nil }
        let expiry = ISO8601DateFormatter().string(from: credits.expiresAt).prefix(10)
        let expiryText = String(format: L("Expires %@"), String(expiry))
        return CodexResetCreditsPresentation(
            text: String(format: L("%d available"), credits.count),
            items: (0..<credits.count).map { _ in
                CodexResetCreditPresentationItem(
                    expiryText: expiryText,
                    compactExpiryText: String(expiry))
            })
    }

    private static func relaySummary(
        _ relay: HeadroomDesignGalleryBaseline.Relay,
        baseline: HeadroomDesignGalleryBaseline) -> RelayUsageSummary?
    {
        guard let reported7d = relay.window(for: .last7Days)?.reportedTokens,
              let reported30d = relay.window(for: .last30Days)?.reportedTokens
        else { return nil }
        return RelayUsageSummary(
            remaining: Double(max(0, reported30d - reported7d)),
            used: Double(reported7d),
            total: Double(reported30d),
            unit: L("tokens"),
            planName: "Sub2API",
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private static func relayOptions(
        _ baseline: HeadroomDesignGalleryBaseline) -> [RelayQuickSwitchOption]
    {
        baseline.relays.enumerated().map { index, relay in
            RelayQuickSwitchOption(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1))),
                name: relay.id,
                isReady: relay.reportsUsage,
                blocker: relay.reportsUsage ? nil : L("codex_relay_usage_unavailable"),
                usageSummary: self.relaySummary(relay, baseline: baseline))
        }
    }

    private static func relayUsageLine(_ relay: HeadroomDesignGalleryBaseline.Relay) -> String {
        guard let window = relay.window(for: .rolling24Hours),
              let local = window.localTokens,
              let reported = window.reportedTokens
        else { return L("codex_relay_usage_unavailable") }
        return "\(L("relay_local_usage_24h")): \(self.tokenLine(local)) / \(self.tokenLine(reported))"
    }

    private static func tokenLine(_ tokens: Int) -> String {
        String(format: L("%@ tokens"), codexBarLocalizedInteger(tokens))
    }
}

struct HeadroomDesignGalleryView: View {
    let baseline: HeadroomDesignGalleryBaseline

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: HeadroomDesignGalleryLayout.rowSpacing) {
                Text(L("design_gallery_title"))
                    .font(HeadroomTypography.text(18, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)

                HStack(alignment: .top, spacing: HeadroomDesignGalleryLayout.columnSpacing) {
                    Color.clear
                        .frame(width: HeadroomDesignGalleryLayout.rowLabelWidth, height: 1)
                    ForEach(HeadroomDesignGalleryState.allCases, id: \.self) { state in
                        Text(state.title)
                            .font(HeadroomTypography.mono(11, weight: .semibold))
                            .foregroundStyle(ConsoleDesign.secondaryText)
                            .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .leading)
                    }
                }

                ForEach(HeadroomDesignGalleryCardKind.allCases, id: \.self) { kind in
                    HStack(alignment: .top, spacing: HeadroomDesignGalleryLayout.columnSpacing) {
                        Text(kind.title)
                            .font(HeadroomTypography.text(12, weight: .semibold))
                            .foregroundStyle(ConsoleDesign.secondaryText)
                            .frame(width: HeadroomDesignGalleryLayout.rowLabelWidth, alignment: .leading)
                        ForEach(HeadroomDesignGalleryState.allCases, id: \.self) { state in
                            self.card(kind: kind, state: state)
                                .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .top)
                        }
                    }
                }

                HStack(alignment: .top, spacing: HeadroomDesignGalleryLayout.columnSpacing) {
                    Text(L("Limit Reset Credits"))
                        .font(HeadroomTypography.text(12, weight: .semibold))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                        .frame(width: HeadroomDesignGalleryLayout.rowLabelWidth, alignment: .leading)
                    ForEach(HeadroomDesignGalleryCatalog.resetCreditEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.state.title)
                                .font(HeadroomTypography.mono(11, weight: .semibold))
                                .foregroundStyle(ConsoleDesign.secondaryText)
                            CodexAccountSummaryCardView(
                                model: HeadroomDesignGalleryModels.officialAccountResetCredits(
                                    state: entry.state,
                                    baseline: self.baseline),
                                width: HeadroomDesignGalleryLayout.cardWidth)
                        }
                        .frame(width: HeadroomDesignGalleryLayout.cardWidth, alignment: .topLeading)
                    }
                }
            }
            .padding(HeadroomDesignGalleryLayout.contentPadding)
        }
        .frame(
            width: HeadroomDesignGalleryLayout.windowContentSize.width,
            height: HeadroomDesignGalleryLayout.windowContentSize.height,
            alignment: .topLeading)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }

    @ViewBuilder
    private func card(kind: HeadroomDesignGalleryCardKind, state: HeadroomDesignGalleryState) -> some View {
        switch kind {
        case .provider:
            UsageMenuCardView(
                model: HeadroomDesignGalleryModels.provider(state: state, baseline: self.baseline),
                width: HeadroomDesignGalleryLayout.cardWidth)
        case .officialAccount:
            CodexAccountSummaryCardView(
                model: HeadroomDesignGalleryModels.officialAccount(state: state, baseline: self.baseline),
                width: HeadroomDesignGalleryLayout.cardWidth)
        case .relay:
            CodexRelaySummaryCardView(
                model: HeadroomDesignGalleryModels.relay(state: state, baseline: self.baseline),
                width: HeadroomDesignGalleryLayout.cardWidth)
        }
    }
}

@MainActor
final class HeadroomDesignGalleryWindowController: NSWindowController {
    init(baseline: HeadroomDesignGalleryBaseline) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: HeadroomDesignGalleryLayout.windowContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = L("design_gallery_title")
        window.contentMinSize = HeadroomDesignGalleryLayout.windowContentSize
        window.contentViewController = NSHostingController(rootView: HeadroomDesignGalleryView(baseline: baseline))
        super.init(window: window)
        self.shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func makeFromBaselineFixture() throws -> HeadroomDesignGalleryWindowController {
        try HeadroomDesignGalleryWindowController(baseline: .load())
    }

    func present() {
        self.window?.center()
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
