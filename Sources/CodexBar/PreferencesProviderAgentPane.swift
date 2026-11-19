import CodexBarCore
import SwiftUI

enum ProviderAgentEntryID: Hashable {
    case provider(UsageProvider)
    case piAgent
}

enum ProviderAgentEntryCatalog {
    static let providerIDs = HeadroomProviderRegistry.providerIDs
    static let allIDs = providerIDs.map(ProviderAgentEntryID.provider) + [.piAgent]
}

@MainActor
struct ProviderAgentPane: View {
    @Bindable var settings: SettingsStore
    var store: UsageDomain?
    var onConfigureProvider: ((UsageProvider) -> Void)?
    @State private var piProbeResult: PiAgentProbe.Result?

    var body: some View {
        Form {
            Section {
                let accounts = self.settings.codexVisibleAccountProjection.visibleAccounts
                if accounts.isEmpty {
                    Text(L("settings_official_accounts_empty"))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                } else {
                    ForEach(accounts) { account in
                        HStack(spacing: 8) {
                            Text(account.displayName)
                            if account.isLive {
                                Text(L("System"))
                                    .font(ConsoleDesign.text(10.5))
                                    .foregroundStyle(ConsoleDesign.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L("Accounts"))
                    Spacer()
                    if let onConfigureProvider {
                        Button(L("provider_agent_manage_accounts")) {
                            onConfigureProvider(.codex)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(ConsoleDesign.text(11, weight: .medium))
                    }
                }
            } footer: {
                SettingsSectionFooter(L("settings_official_accounts_menu_hint"))
            }

            Section {
                ForEach(ProviderAgentEntryCatalog.providerIDs, id: \.self) { provider in
                    let descriptor = HeadroomProviderRegistry.descriptor(for: provider)!
                    ProviderAgentRow(
                        name: descriptor.metadata.displayName,
                        provider: provider,
                        capabilities: descriptor.capabilities,
                        statusText: self.providerStatus(provider, descriptor: descriptor),
                        statusIsError: self.providerHasError(provider, descriptor: descriptor),
                        isEnabled: self.providerBinding(provider, descriptor: descriptor),
                        onConfigure: self.onConfigureProvider.map { action in
                            { action(provider) }
                        })
                }

                PiAgentEntryRow(
                    capabilities: [.localUsage, .cost],
                    statusText: self.piStatusText,
                    isLoading: self.piProbeResult?.state == .loading,
                    isEnabled: self.piEnabledBinding,
                    onRefresh: {
                        Task { await self.refreshPiProbe() }
                    })
            } header: {
                Text(L("provider_agent_section_title"))
            } footer: {
                SettingsSectionFooter(L("provider_agent_section_footer"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(ConsoleDesign.background)
        .task(id: self.settings.piAgentUsageEnabled) {
            await self.refreshPiProbe()
        }
    }

    private func providerBinding(
        _ provider: UsageProvider,
        descriptor: ProviderDescriptor) -> Binding<Bool>
    {
        Binding(
            get: {
                self.settings.isProviderEnabled(provider: provider, metadata: descriptor.metadata)
            },
            set: {
                self.settings.setProviderEnabled(provider: provider, metadata: descriptor.metadata, enabled: $0)
            })
    }

    private func providerStatus(
        _ provider: UsageProvider,
        descriptor: ProviderDescriptor) -> String
    {
        guard self.settings.isProviderEnabled(provider: provider, metadata: descriptor.metadata) else {
            return L("provider_agent_status_disabled")
        }
        guard let store = self.store else {
            return L("provider_agent_status_detected")
        }
        if let error = store.error(for: provider), !error.isEmpty {
            return error
        }
        if store.refreshingProviders.contains(provider) {
            return L("provider_agent_status_loading")
        }
        if let sourceLabel = store.lastSourceLabels[provider], !sourceLabel.isEmpty {
            return "\(L("provider_agent_status_detected")) · \(sourceLabel)"
        }
        return L("provider_agent_status_detected")
    }

    private func providerHasError(
        _ provider: UsageProvider,
        descriptor: ProviderDescriptor) -> Bool
    {
        guard self.settings.isProviderEnabled(provider: provider, metadata: descriptor.metadata),
              let error = self.store?.error(for: provider)
        else { return false }
        return !error.isEmpty
    }

    private var piEnabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.piAgentUsageEnabled },
            set: { self.settings.piAgentUsageEnabled = $0 })
    }

    private var piStatusText: String {
        guard self.settings.piAgentUsageEnabled else {
            return L("provider_agent_status_disabled")
        }
        guard let result = self.piProbeResult else {
            return L("provider_agent_status_loading")
        }
        switch result.state {
        case .loading:
            return L("provider_agent_status_loading")
        case .available:
            return L("pi_agent_status_sessions", result.parseableSessionCount)
        case .empty:
            return L("pi_agent_status_no_sessions")
        case .unavailable:
            switch result.reason {
            case .commandMissing:
                return L("pi_agent_status_command_missing")
            case .sessionsDirectoryMissing:
                return L("pi_agent_status_directory_missing")
            case .noSessions, nil:
                return L("pi_agent_status_unavailable")
            }
        }
    }

    private func refreshPiProbe() async {
        guard self.settings.piAgentUsageEnabled else {
            self.piProbeResult = nil
            return
        }
        self.piProbeResult = .loading
        let result = await Task.detached(priority: .utility) {
            PiAgentProbe.inspectDefault()
        }.value
        guard !Task.isCancelled, self.settings.piAgentUsageEnabled else { return }
        self.piProbeResult = result
    }
}

@MainActor
private struct ProviderAgentRow: View {
    let name: String
    let provider: UsageProvider
    let capabilities: ProviderCapabilities
    let statusText: String
    var statusIsError = false
    @Binding var isEnabled: Bool
    var onConfigure: (() -> Void)?

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

            ProviderAgentRowContent(
                name: self.name,
                capabilities: self.capabilities,
                statusText: self.statusText,
                statusIsError: self.statusIsError)

            // Fixed slot: rows with and without a trailing action keep their toggles aligned.
            Group {
                if let onConfigure {
                    Button(action: onConfigure) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Settings..."))
                    .accessibilityLabel(L("Settings..."))
                }
            }
            .frame(width: ProviderAgentRowMetrics.actionSlotSide, height: ProviderAgentRowMetrics.actionSlotSide)

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct PiAgentEntryRow: View {
    let capabilities: ProviderCapabilities
    let statusText: String
    let isLoading: Bool
    @Binding var isEnabled: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(HeadroomTypography.text(14, weight: .semibold))
                .foregroundStyle(self.isEnabled ? ConsoleDesign.accentForeground : ConsoleDesign.tertiaryText)
                .frame(width: 18, height: 18)

            ProviderAgentRowContent(
                name: L("pi_agent"),
                capabilities: self.capabilities,
                statusText: self.statusText)

            // Same fixed slot as provider rows so the toggle column never shifts when the
            // refresh button appears, disappears or turns into a spinner.
            Group {
                if self.isEnabled {
                    Button(action: self.onRefresh) {
                        if self.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .help(L("provider_agent_refresh_probe"))
                    .accessibilityLabel(L("provider_agent_refresh_probe"))
                    .disabled(self.isLoading)
                }
            }
            .frame(width: ProviderAgentRowMetrics.actionSlotSide, height: ProviderAgentRowMetrics.actionSlotSide)

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

private enum ProviderAgentRowMetrics {
    static let actionSlotSide: CGFloat = 24
}

private struct ProviderAgentRowContent: View {
    let name: String
    let capabilities: ProviderCapabilities
    let statusText: String
    var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(self.name)
                    .font(ConsoleDesign.text(13, weight: .medium))
                    .foregroundStyle(ConsoleDesign.primaryText)
                ForEach(self.capabilityLabels, id: \.self) { label in
                    Text(label)
                        .font(ConsoleDesign.mono(9.5, weight: .medium))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                                .fill(ConsoleDesign.surface2))
                }
            }
            Text(self.statusText)
                .font(ConsoleDesign.text(10.5))
                .foregroundStyle(self.statusIsError ? ConsoleDesign.criticalForeground : ConsoleDesign.secondaryText)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(self.statusIsError ? self.statusText : "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capabilityLabels: [String] {
        [
            (ProviderCapabilities.quota, L("provider_capability_quota")),
            (.localUsage, L("provider_capability_local_usage")),
            (.relaySwitch, L("provider_capability_relay_switch")),
            (.login, L("provider_capability_login")),
            (.cost, L("provider_capability_cost")),
        ].compactMap { capability, label in
            self.capabilities.contains(capability) ? label : nil
        }
    }
}
