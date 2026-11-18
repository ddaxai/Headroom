import CodexBarCore
import SwiftUI

enum CodexCardGroupStatusPresentation {
    static let height: CGFloat = 30
    static let refreshButtonSize: CGFloat = 22

    static func height(isRefreshing _: Bool) -> CGFloat {
        self.height
    }

    static func latestUpdatedAt(
        fullCorpusUpdatedAt: Date?,
        accountUpdatedAts: [Date?],
        relayUpdatedAt: Date?) -> Date?
    {
        ([fullCorpusUpdatedAt, relayUpdatedAt] + accountUpdatedAts).compactMap(\.self).max()
    }

    @MainActor
    static func statusText(updatedAt: Date?, now: Date = .now) -> String {
        guard let updatedAt else { return L("codex_card_group_not_updated") }
        return UsageFormatter.updatedString(from: updatedAt, now: now)
    }
}

@MainActor
enum CodexCardGroupRefreshOrchestrator {
    static func run(
        relayProfileID: UUID?,
        refreshCodex: @MainActor () async -> Void,
        refreshRelay: @MainActor (UUID) async -> Void,
        rebuildMenu: @MainActor () -> Void) async
    {
        await refreshCodex()
        if let relayProfileID {
            await refreshRelay(relayProfileID)
        }
        rebuildMenu()
    }
}

struct CodexCardGroupStatusView: View {
    let updatedAt: Date?
    let width: CGFloat
    let onRefresh: @MainActor () async -> Void
    @State private var isRefreshing = false
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        HStack(spacing: 8) {
            Text(CodexCardGroupStatusPresentation.statusText(updatedAt: self.updatedAt))
                .font(ConsoleDesign.mono(10))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            CardGroupRefreshButton(isRefreshing: self.isRefreshing) {
                guard !self.isRefreshing else { return }
                self.isRefreshing = true
                await self.onRefresh()
                self.isRefreshing = false
            }
        }
        .padding(.horizontal, 12)
        .frame(
            width: self.width,
            height: CodexCardGroupStatusPresentation.height(isRefreshing: self.isRefreshing),
            alignment: .center)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }
}

private struct CardGroupRefreshButton: View {
    let isRefreshing: Bool
    let action: @MainActor () async -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            Task { await self.action() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(self.isRefreshing ? .degrees(360) : .zero)
                .animation(
                    self.isRefreshing
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: self.isRefreshing)
                .frame(
                    width: CodexCardGroupStatusPresentation.refreshButtonSize,
                    height: CodexCardGroupStatusPresentation.refreshButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(self.isHovered ? ConsoleDesign.surface2 : ConsoleDesign.surface)
                .overlay {
                    Circle().stroke(ConsoleDesign.border, lineWidth: 1)
                }
        }
        .onHover { self.isHovered = $0 }
        .menuCardInteractiveControl(isEnabled: !self.isRefreshing)
        .disabled(self.isRefreshing)
        .help(L("codex_card_group_refresh_help"))
        .accessibilityLabel(L("codex_card_group_refresh"))
    }
}
