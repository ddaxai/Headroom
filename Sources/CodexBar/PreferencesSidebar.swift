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
