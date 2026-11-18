import AppKit
import CoreServices
import Foundation
import Testing
@testable import CodexBar

struct RelaySprayAnimationTests {
    @Test
    func `spray frames advance at a bounded cadence`() {
        #expect(RelaySprayAnimation.framesPerSecond == 4)
        #expect((0..<12).map(RelaySprayAnimation.frame(forTick:)) == [0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5])
        #expect(RelaySprayAnimation.frame(forTick: -1) == 0)
    }

    @Test
    func `spray pauses for power and thermal pressure`() {
        #expect(RelaySprayAnimation.shouldAnimate(
            isLowPowerModeEnabled: false,
            thermalState: .nominal))
        #expect(RelaySprayAnimation.shouldAnimate(
            isLowPowerModeEnabled: false,
            thermalState: .fair))
        #expect(!RelaySprayAnimation.shouldAnimate(
            isLowPowerModeEnabled: true,
            thermalState: .nominal))
        #expect(!RelaySprayAnimation.shouldAnimate(
            isLowPowerModeEnabled: false,
            thermalState: .serious))
    }

    @Test
    func `activity monitor accepts only rollout writes`() {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)

        #expect(CodexActivityPulseMonitor.isRelevantRolloutEvent(
            path: "/tmp/.codex/sessions/rollout.jsonl",
            flags: modified))
        #expect(!CodexActivityPulseMonitor.isRelevantRolloutEvent(
            path: "/tmp/.codex/sessions/rollout.jsonl",
            flags: removed))
        #expect(!CodexActivityPulseMonitor.isRelevantRolloutEvent(
            path: "/tmp/.codex/log/codex.log",
            flags: modified))
    }

    @MainActor
    @Test
    func `relay percentage title sits one point below the default baseline`() throws {
        let title = StatusItemController.relayButtonTitle(" 34%")
        let offset = try #require(title.attribute(
            .baselineOffset,
            at: 0,
            effectiveRange: nil) as? NSNumber)
        #expect(offset.doubleValue == -1)
        #expect(title.attribute(.font, at: 0, effectiveRange: nil) is NSFont)
    }

    @MainActor
    @Test
    func `menu bar spray frames are cached and non-template`() throws {
        let first = try #require(RelayVisualIdentity.menuBarImage(sprayFrame: 2))
        let repeated = try #require(RelayVisualIdentity.menuBarImage(sprayFrame: 2))
        #expect(first === repeated)
        #expect(first.size == NSSize(width: 18, height: 18))
        #expect(!first.isTemplate)
    }

    @MainActor
    @Test
    func `menu bar sprinkler renders all visible layers in white`() throws {
        let image = try #require(RelayVisualIdentity.menuBarImage())
        let representation = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        var whitePixels = 0
        var bluePixels = 0
        for x in 0..<representation.pixelsWide {
            for y in 0..<representation.pixelsHigh {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1
                else { continue }
                if color.redComponent > 0.72,
                   color.greenComponent > 0.72,
                   color.blueComponent > 0.72
                {
                    whitePixels += 1
                }
                if color.blueComponent > 0.55,
                   color.blueComponent > color.redComponent + 0.2,
                   color.blueComponent > color.greenComponent + 0.1
                {
                    bluePixels += 1
                }
            }
        }

        #expect(whitePixels > 0)
        #expect(bluePixels == 0)
    }
}
