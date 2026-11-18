import AppKit
import CodexBarCore
import SwiftUI

/// Fixed Console-style settings navigation. Provider details live inside the Providers pane.
@MainActor
struct SettingsSidebarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @Binding var selection: SettingsPane
    var showsDiagnostics = false

    var body: some View {
        List {
            Section {
                SettingsSidebarDestinationRow(
                    destination: .general,
                    systemImage: "square.grid.2x2.fill",
                    color: ConsoleDesign.accent,
                    isSelected: self.selection.destination == .general,
                    onSelect: { self.selection = SettingsDestination.general.defaultPane })
                SettingsSidebarDestinationRow(
                    destination: .accountsAndAPIs,
                    systemImage: "square.stack.3d.up.fill",
                    color: ConsoleDesign.accent,
                    isSelected: self.selection.destination == .accountsAndAPIs,
                    onSelect: { self.selection = SettingsDestination.accountsAndAPIs.defaultPane })
                SettingsSidebarDestinationRow(
                    destination: .usageAndCost,
                    systemImage: "chart.bar.fill",
                    color: ConsoleDesign.accent,
                    isSelected: self.selection.destination == .usageAndCost,
                    onSelect: { self.selection = SettingsDestination.usageAndCost.defaultPane })
                SettingsSidebarDestinationRow(
                    destination: .appearance,
                    systemImage: "menubar.rectangle",
                    color: ConsoleDesign.accent,
                    isSelected: self.selection.destination == .appearance,
                    onSelect: { self.selection = SettingsDestination.appearance.defaultPane })
                SettingsSidebarDestinationRow(
                    destination: .about,
                    systemImage: "info.circle.fill",
                    color: ConsoleDesign.accent,
                    isSelected: self.selection.destination == .about,
                    onSelect: { self.selection = SettingsDestination.about.defaultPane })
                if self.showsDiagnostics {
                    SettingsSidebarDiagnosticsRow(
                        isSelected: self.selection.isOptionOnly,
                        onSelect: { self.selection = .advanced })
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .background(ConsoleDesign.background.opacity(0.94))
    }
}

@MainActor
private struct SettingsSidebarDiagnosticsRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconChip(systemImage: "stethoscope", color: ConsoleDesign.accent)
            Text(L("settings_developer_diagnostics"))
        }
        .sidebarSelectionRow(isSelected: self.isSelected, action: self.onSelect)
    }
}

@MainActor
private struct SettingsSidebarDestinationRow: View {
    let destination: SettingsDestination
    let systemImage: String
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconChip(systemImage: self.systemImage, color: self.color)
            Text(self.destination.title)
        }
        .sidebarSelectionRow(isSelected: self.isSelected, action: self.onSelect)
    }
}

@MainActor
private struct RelaySettingsSidebarRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RelaySprinklerSymbol(
                isAnimated: self.isSelected,
                primaryColor: .white,
                size: 11)
                .frame(width: SettingsIconChip.side, height: SettingsIconChip.side)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ConsoleDesign.accent))
            Text(SettingsPane.relay.title)
        }
        .sidebarSelectionRow(isSelected: self.isSelected, action: self.onSelect)
    }
}

@MainActor
private struct SettingsSidebarPaneRow: View {
    let pane: SettingsPane
    let systemImage: String
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconChip(systemImage: self.systemImage, color: self.color)
            Text(self.pane.title)
        }
        .sidebarSelectionRow(isSelected: self.isSelected, action: self.onSelect)
    }
}

@MainActor
private struct SettingsSidebarAboutRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsIconChip.side, height: SettingsIconChip.side)
                    .accessibilityHidden(true)
            } else {
                SettingsIconChip(systemImage: "info.circle.fill", color: ConsoleDesign.accent)
            }
            Text(SettingsPane.about.title)
        }
        .sidebarSelectionRow(isSelected: self.isSelected, action: self.onSelect)
    }
}

extension View {
    fileprivate func sidebarSelectionRow(isSelected: Bool, action: @escaping () -> Void) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                    .fill(isSelected ? ConsoleDesign.surface2 : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                            .stroke(isSelected ? ConsoleDesign.accent : .clear, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .listRowBackground(ConsoleDesign.background)
    }
}

@MainActor
private struct SettingsSidebarProviderRow: View {
    let provider: UsageProvider
    @Bindable var store: UsageDomain
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            SettingsSidebarBrandIcon(provider: self.provider, isEnabled: self.isEnabled)

            Text(self.store.metadata(for: self.provider).displayName)
                .foregroundStyle(self.isEnabled ? .primary : .secondary)

            Spacer(minLength: 4)

            if self.store.refreshingProviders.contains(self.provider) {
                ProgressView()
                    .controlSize(.mini)
            }

            if self.isEnabled, self.store.statusChecksEnabled {
                SettingsSidebarStatusDot(indicator: self.store.statusIndicator(for: self.provider))
            }
        }
        .opacity(self.isEnabled ? 1 : 0.62)
        .contextMenu {
            Button(self.isEnabled ? L("Disable") : L("Enable")) {
                self.isEnabled.toggle()
            }
        }
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let name = self.store.metadata(for: self.provider).displayName
        return self.isEnabled ? name : "\(name) — \(L("Disabled"))"
    }
}

@MainActor
private struct SettingsSidebarBrandIcon: View {
    let provider: UsageProvider
    let isEnabled: Bool

    var body: some View {
        Group {
            if let brand = ProviderBrandIcon.image(for: self.provider) {
                Image(nsImage: brand)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "circle.dotted")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(self.isEnabled ? .primary : .secondary)
        .accessibilityHidden(true)
    }
}

private struct SettingsSidebarStatusDot: View {
    let indicator: ProviderStatusIndicator

    var body: some View {
        Circle()
            .fill(self.statusColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch self.indicator {
        case .none: ConsoleDesign.accent
        case .minor: ConsoleDesign.secondaryText
        case .major, .critical: ConsoleDesign.critical
        case .maintenance, .unknown: ConsoleDesign.tertiaryText
        }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ConsoleDesign.secondaryText)
                .accessibilityHidden(true)

            TextField(L("Search providers"), text: self.$searchText)
                .textFieldStyle(.plain)

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ConsoleDesign.secondaryText)
                        .accessibilityLabel(L("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                .fill(ConsoleDesign.surface2))
        .overlay(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                .stroke(ConsoleDesign.border, lineWidth: 1))
    }
}

private struct SettingsSidebarSortToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            self.isOn.toggle()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.callout)
                .foregroundStyle(self.isOn ? ConsoleDesign.accent : ConsoleDesign.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.isOn
            ? L("Sorted alphabetically (enabled first) — click to use your custom order")
            : L("Sort providers alphabetically (enabled first)"))
        .accessibilityLabel(L("Sort providers alphabetically"))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}
