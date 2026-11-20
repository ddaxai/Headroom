import AppKit
import SwiftUI

enum RelaySprayAnimation {
    static let framesPerSecond = 4
    static let frameCount = 6
    static let activeTail: TimeInterval = 2.5

    static func frame(forTick tick: Int) -> Int {
        guard tick >= 0 else { return 0 }
        return tick % self.frameCount
    }

    static func shouldAnimate(
        isLowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> Bool
    {
        guard !isLowPowerModeEnabled else { return false }
        return switch thermalState {
        case .nominal, .fair:
            true
        case .serious, .critical:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
enum RelayVisualIdentity {
    static let preferredSymbolName = "sprinkler.and.droplets.fill"
    static let fallbackSymbolName = "arrow.triangle.branch"

    static var symbolName: String {
        NSImage(systemSymbolName: self.preferredSymbolName, accessibilityDescription: nil) == nil
            ? self.fallbackSymbolName
            : self.preferredSymbolName
    }

    private static let menuBarCanvasSize = NSSize(width: 18, height: 18)

    private static let restingMenuBarImage = Self.makeMenuBarImage(sprayFrame: nil)
    private static let sprayMenuBarImages: [NSImage] = (0..<RelaySprayAnimation.frameCount)
        .compactMap { Self.makeMenuBarImage(sprayFrame: $0) }

    /// AppKit status items do not support SwiftUI's `symbolEffect`. The body and water layers are
    /// rendered separately, then cached spray frames scale/fade only the water away from the head.
    static func menuBarImage(sprayFrame: Int? = nil) -> NSImage? {
        guard let sprayFrame else { return self.restingMenuBarImage }
        guard !self.sprayMenuBarImages.isEmpty else { return self.restingMenuBarImage }
        return self.sprayMenuBarImages[sprayFrame % self.sprayMenuBarImages.count]
    }

    private static func makeMenuBarImage(sprayFrame: Int?) -> NSImage? {
        guard let base = NSImage(
            systemSymbolName: self.symbolName,
            accessibilityDescription: "Headroom Relay")
        else { return nil }

        let size = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let bodyPalette = NSImage.SymbolConfiguration(paletteColors: [.white, .clear, .clear])
        let waterPalette = NSImage.SymbolConfiguration(paletteColors: [.clear, .white, .clear])
        guard let body = base.withSymbolConfiguration(size.applying(bodyPalette)),
              let water = base.withSymbolConfiguration(size.applying(waterPalette))
        else {
            let fallbackPalette = NSImage.SymbolConfiguration(paletteColors: [.white, .white])
            let fallback = base.withSymbolConfiguration(size.applying(fallbackPalette)) ?? base
            fallback.size = self.menuBarCanvasSize
            fallback.isTemplate = true
            return fallback
        }

        body.size = self.menuBarCanvasSize
        water.size = self.menuBarCanvasSize
        let image = NSImage(size: self.menuBarCanvasSize)
        image.lockFocus()
        let canvas = NSRect(origin: .zero, size: self.menuBarCanvasSize)
        body.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)

        let frame = sprayFrame.map(Self.sprayFrameParameters) ?? (scale: 1.0, opacity: 1.0)
        let waterSize = NSSize(
            width: canvas.width * frame.scale,
            height: canvas.height * frame.scale)
        let waterRect = NSRect(
            x: (canvas.width - waterSize.width) / 2,
            y: (canvas.height - waterSize.height) / 2,
            width: waterSize.width,
            height: waterSize.height)
        water.draw(in: waterRect, from: .zero, operation: .sourceOver, fraction: frame.opacity)
        image.unlockFocus()
        // Drawn in white, used as a mask: the menu bar picks black or white to suit the wallpaper behind it.
        image.isTemplate = true
        return image
    }

    private static func sprayFrameParameters(_ frame: Int) -> (scale: CGFloat, opacity: CGFloat) {
        switch RelaySprayAnimation.frame(forTick: frame) {
        case 0: (0.72, 0.50)
        case 1: (0.80, 0.68)
        case 2: (0.88, 0.82)
        case 3: (0.96, 1.00)
        case 4: (1.04, 0.78)
        default: (1.10, 0.42)
        }
    }
}

struct RelaySprinklerSymbol: View {
    let isAnimated: Bool
    let primaryColor: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: RelayVisualIdentity.symbolName)
            .font(.system(size: self.size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(self.primaryColor, Color.blue)
            .symbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating,
                isActive: self.isAnimated)
            .accessibilityHidden(true)
    }
}
