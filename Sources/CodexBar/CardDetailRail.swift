import SwiftUI

struct CardDetailRail: View {
    nonisolated static let width: CGFloat = 30
    static let borderWidth: CGFloat = 1
    nonisolated static let renderingFingerprint = "detailRail=plain-v1"

    @Environment(\.menuItemHighlighted) private var isHighlighted
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(self.backgroundColor)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(ConsoleDesign.border)
                    .frame(width: Self.borderWidth)
            }
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { self.isHovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("usage.rail.caption"))
    }

    private var backgroundColor: Color {
        self.isHovered || self.isHighlighted ? ConsoleDesign.accentSoft : .clear
    }
}
