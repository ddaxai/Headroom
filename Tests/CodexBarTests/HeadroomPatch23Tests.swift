import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct HeadroomPatch23Tests {
    @Test
    func `interactive regions stay in the top aligned hosting coordinate space`() {
        let store = MenuCardInteractiveRegionStore()
        store.regions = [CGRect(x: 280, y: 39, width: 30, height: 10)]

        // A menu row may be seven points taller than its SwiftUI content. The hosted content is
        // top-aligned, so the refresh/control hitbox must remain at its original y coordinate.
        #expect(store.contains(
            CGPoint(x: 285, y: 39),
            hostingBounds: CGRect(x: 0, y: 0, width: 320, height: 51),
            fittedSize: CGSize(width: 320, height: 44)))
    }

    @Test
    func `swiftui and appkit console colors use the same sRGB channels`() throws {
        let swiftUIColor = try #require(NSColor(ConsoleDesign.background).usingColorSpace(.sRGB))
        let appKitColor = try #require(ConsoleDesign.nsBackground.usingColorSpace(.sRGB))
        let tolerance = 1.0 / 255.0

        #expect(abs(swiftUIColor.redComponent - appKitColor.redComponent) < tolerance)
        #expect(abs(swiftUIColor.greenComponent - appKitColor.greenComponent) < tolerance)
        #expect(abs(swiftUIColor.blueComponent - appKitColor.blueComponent) < tolerance)
        #expect(abs(swiftUIColor.alphaComponent - appKitColor.alphaComponent) < tolerance)
    }
}
