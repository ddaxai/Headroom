import CodexBarCore
import SwiftUI

@MainActor
struct ProviderManagementPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void

    @State private var searchText = ""
    @State private var showsUnconfiguredProviders = false
    @State private var selectedProvider: UsageProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("服务商")
                    .font(ConsoleDesign.text(22, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("搜索服务商", text: self.$searchText)
                        .textFieldStyle(.roundedBorder)
                    Toggle("显示未配置", isOn: self.$showsUnconfiguredProviders)
                        .toggleStyle(.switch)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            List {
                ForEach(self.visibleProviders, id: \.self) { provider in
                    ProviderManagementRow(
                        provider: provider,
                        settings: self.settings,
                        store: self.store,
                        isEnabled: self.enabledBinding(for: provider),
                        onOpen: { self.selectedProvider = provider })
                        .moveDisabled(!self.canReorder)
                }
                .onMove { offsets, destination in
                    guard self.canReorder else { return }
                    self.settings.moveHeadroomProvider(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(ConsoleDesign.background)
        .onTapGesture {
            // macOS sheets normally keep the dimmed background modal. When the sheet opts
            // into background interaction, a click outside the detail surface becomes an
            // intuitive second close affordance; clicks inside the sheet never reach this view.
            if self.selectedProvider != nil {
                self.selectedProvider = nil
            }
        }
        .sheet(isPresented: self.detailIsPresented) {
            if let provider = self.selectedProvider {
                ProviderDetailSheet(
                    provider: provider,
                    settings: self.settings,
                    store: self.store,
                    managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                    codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                    runProviderLoginFlow: self.runProviderLoginFlow)
                    .frame(minWidth: 680, minHeight: 560)
                    .preferredColorScheme(ConsoleDesign.preferredColorScheme)
                    .presentationBackgroundInteraction(.enabled)
            }
        }
    }

    private var orderedProviders: [UsageProvider] {
        self.settings.headroomProviderOrder()
    }

    private var visibleProviders: [UsageProvider] {
        let providers = self.orderedProviders.filter { provider in
            self.showsUnconfiguredProviders || self.isEnabled(provider)
        }
        return ProvidersPane.filteredProviders(
            providers,
            query: self.searchText,
            displayName: { self.store.metadata(for: $0).displayName })
    }

    private var canReorder: Bool {
        self.showsUnconfiguredProviders
            && self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !self.settings.providersSortedAlphabetically
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { self.selectedProvider != nil },
            set: { if !$0 { self.selectedProvider = nil } })
    }

    private func isEnabled(_ provider: UsageProvider) -> Bool {
        self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
    }

    private func enabledBinding(for provider: UsageProvider) -> Binding<Bool> {
        let metadata = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: metadata) },
            set: { self.settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: $0) })
    }
}

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

@MainActor
private struct ProviderManagementRow: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @Binding var isEnabled: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "circle.dotted")
                }
            }
            .frame(width: 18, height: 18)
            .foregroundStyle(self.isEnabled ? ConsoleDesign.primaryText : ConsoleDesign.tertiaryText)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.store.metadata(for: self.provider).displayName)
                    .font(ConsoleDesign.text(13, weight: .medium))
                Text(self.sourceDescription)
                    .font(ConsoleDesign.mono(10))
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let remainingPercent = self.remainingPercent {
                Text("\(Int(remainingPercent.rounded()))%")
                    .font(ConsoleDesign.mono(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        remainingPercent <= 0
                            ? ConsoleDesign.criticalForeground
                            : ConsoleDesign.accentForeground)
                    .frame(minWidth: 38, alignment: .trailing)
            }

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

            Button(action: self.onOpen) {
                Image(systemName: "chevron.right")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("管理 \(self.store.metadata(for: self.provider).displayName)")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: self.onOpen)
    }

    private var sourceDescription: String {
        if let source = self.store.lastSourceLabels[self.provider], !source.isEmpty {
            return source
        }
        return self.isEnabled ? "已启用 · 等待刷新" : "未配置"
    }

    private var remainingPercent: Double? {
        self.store.presentationSnapshot(for: self.provider)?.primary?.remainingPercent
    }
}
