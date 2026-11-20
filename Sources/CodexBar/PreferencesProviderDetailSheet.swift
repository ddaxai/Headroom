import CodexBarCore
import SwiftUI

/// The macOS `.sheet` presentation is intentionally modal: clicking the dimmed area does not dismiss it.
/// Keep that native presentation (it preserves focus, keyboard navigation, and accessibility), but provide
/// an explicit in-surface close affordance so the detail page is never a dead end. Escape and ⌘W use the same
/// dismissal path through the cancel keyboard shortcut.
@MainActor
struct ProviderDetailSheet: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let icon = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Text(self.store.metadata(for: self.provider).displayName)
                    .font(ConsoleDesign.text(14, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                Spacer(minLength: 12)
                Button(L("Close")) {
                    self.dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ConsoleDesign.secondaryText)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L("Close"))
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(ConsoleDesign.background)

            Rectangle()
                .fill(ConsoleDesign.border)
                .frame(height: 1)

            ProvidersPane(
                provider: self.provider,
                settings: self.settings,
                store: self.store,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: self.runProviderLoginFlow)
        }
        .background(ConsoleDesign.background)
        .onExitCommand {
            self.dismiss()
        }
    }
}
