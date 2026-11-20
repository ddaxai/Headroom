import SwiftUI

extension SettingsDestination {
    var systemImage: String {
        switch self {
        case .general: "square.grid.2x2.fill"
        case .accountsAndAPIs: "square.stack.3d.up.fill"
        case .usageAndCost: "chart.bar.fill"
        case .appearance: "menubar.rectangle"
        case .about: "info.circle.fill"
        }
    }
}

/// Top-level settings navigation: one row of tabs across the top of the window, which leaves the pane below
/// the full window width.
@MainActor
struct SettingsNavigationBar: View {
    static let height: CGFloat = 46

    @Binding var selection: SettingsPane
    var showsDiagnostics = false

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(SettingsDestination.allCases, id: \.self) { destination in
                SettingsNavigationTab(
                    title: destination.title,
                    systemImage: destination.systemImage,
                    isSelected: !self.selection.isOptionOnly && self.selection.destination == destination,
                    onSelect: { self.selection = destination.defaultPane })
            }
            if self.showsDiagnostics {
                SettingsNavigationTab(
                    title: L("settings_developer_diagnostics"),
                    systemImage: "stethoscope",
                    isSelected: self.selection.isOptionOnly,
                    onSelect: { self.selection = .advanced })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(ConsoleDesign.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ConsoleDesign.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("settings_navigation_accessibility"))
    }
}

@MainActor
private struct SettingsNavigationTab: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: self.onSelect) {
            HStack(spacing: 6) {
                Image(systemName: self.systemImage)
                    .font(ConsoleDesign.text(11, weight: .semibold))
                    .foregroundStyle(self.isSelected ? ConsoleDesign.accentForeground : ConsoleDesign.secondaryText)
                    .accessibilityHidden(true)
                Text(self.title)
                    .font(ConsoleDesign.text(12.5, weight: self.isSelected ? .semibold : .medium))
                    .foregroundStyle(self.isSelected ? ConsoleDesign.primaryText : ConsoleDesign.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                    .fill(self.fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                    .stroke(self.isSelected ? ConsoleDesign.accent : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityAddTraits(self.isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if self.isSelected { return ConsoleDesign.surface2 }
        return self.isHovered ? ConsoleDesign.surface : .clear
    }
}
