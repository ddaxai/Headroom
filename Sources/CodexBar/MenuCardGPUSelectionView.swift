import AppKit
import SwiftUI

/// Hosts a menu-card SwiftUI row whose selection highlight is rendered entirely by AppKit/Core
/// Animation instead of SwiftUI, so moving the highlight while scrolling costs no SwiftUI body
/// re-evaluation or content re-rasterization.
///
/// The reported Overview scroll stutter comes from driving the native selection look through SwiftUI:
/// each scroll step flips `menuItemHighlighted`, which re-renders the entire rich row subtree
/// (header, usage bars, storage line). A headless benchmark measured ~3–10 ms per toggle with
/// spikes past one 120 Hz frame, matching the dropped frames in the bug report.
///
/// This view keeps the SwiftUI content pinned to its normal (unselected) appearance and recreates
/// the selected look with a console-colored, GPU-composited selection plate drawn behind the
/// content. The content keeps its normal palette so charts, quota bars, and text retain their
/// visual hierarchy while highlighted.
/// Toggling selection then costs a layer property change (~0.05 ms) rather than a SwiftUI pass.
@MainActor
final class GPUSelectionHostingView<Content: View>: NSView, MenuCardHighlighting, MenuCardMeasuring,
    MenuCardInteractiveHitTesting
{
    private let hosting: NSHostingView<MenuCardSectionContainerView<Content>>
    private let selectionView = NSView()
    private let selectionAccentView = NSView()
    private var isRowHighlighted = false
    private var onClick: (() -> Void)?
    private let containsInteractiveControls: Bool
    private let interactiveRegionStore: MenuCardInteractiveRegionStore?

    private(set) var allowsMenuHighlight: Bool

    /// Selection inset/radius mirror the SwiftUI `MenuCardSectionContainerView` highlight
    /// (`.padding(.horizontal, 6).padding(.vertical, 2)` with a 6 pt corner radius) so the AppKit
    /// background lands in the same place the SwiftUI one used to.
    private static var selectionHorizontalInset: CGFloat {
        6
    }

    private static var selectionVerticalInset: CGFloat {
        2
    }

    private static var selectionCornerRadius: CGFloat {
        6
    }

    /// Short enough that a fast flick still looks crisp, long enough to read as a glide rather than
    /// a hard cut. Tunable from real-device recordings.
    private static var selectionFadeDuration: CFTimeInterval {
        0.06
    }

    init(
        rootView: MenuCardSectionContainerView<Content>,
        allowsMenuHighlight: Bool,
        containsInteractiveControls: Bool = false,
        interactiveRegionStore: MenuCardInteractiveRegionStore? = nil,
        onClick: (() -> Void)?)
    {
        var rootView = rootView
        // Keep the opaque console background outside the hosted SwiftUI layer so the AppKit
        // selection plate can crossfade behind it without invalidating the SwiftUI graph.
        rootView.showsBackground = false
        self.hosting = NSHostingView(rootView: rootView)
        self.allowsMenuHighlight = allowsMenuHighlight
        self.containsInteractiveControls = containsInteractiveControls
        self.interactiveRegionStore = interactiveRegionStore
        self.onClick = onClick
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor
        self.setupSelectionView()
        self.setupHosting()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: self.hosting.intrinsicContentSize.height)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// Forward accessibility activation to the click handler, mirroring `MenuCardItemHostingView`.
    override func accessibilityRole() -> NSAccessibility.Role? {
        self.onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick = self.onClick else {
            return super.accessibilityPerformPress()
        }
        onClick()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let descendant = super.hitTest(point)
        if let descendant {
            var current: NSView? = descendant
            while let view = current, view !== self {
                if view is NSButton || view is NSControl {
                    return descendant
                }
                current = view.superview
            }
            if self.hitsHostedInteractiveControl(at: point) {
                return descendant
            }
            if descendant !== self, self.onClick != nil {
                return self
            }
        }
        return descendant
    }

    private func hitsHostedInteractiveControl(at point: NSPoint) -> Bool {
        guard self.containsInteractiveControls else { return false }
        let hostedPoint = self.hosting.convert(point, from: self)
        return self.interactiveRegionStore?.contains(
            hostedPoint,
            hostingBounds: self.hosting.bounds,
            fittedSize: self.hosting.fittingSize) == true
    }

    func hitsInteractiveControl(at point: NSPoint) -> Bool {
        self.hitsHostedInteractiveControl(at: point)
    }

    func hitsPrimaryAction(at point: NSPoint) -> Bool {
        self.onClick != nil && self.bounds.contains(point)
    }

    private func locationInView(for event: NSEvent) -> NSPoint {
        guard self.window != nil else {
            return event.locationInWindow
        }
        return self.convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, self.onClick != nil else {
            super.mouseDown(with: event)
            return
        }
        guard self.bounds.contains(self.locationInView(for: event)), let window = self.window else { return }

        // A submenu-backed NSMenuItem consumes mouseUp in its nested tracking loop before a custom
        // view receives it. Track the drag/up sequence directly so release-inside cancellation stays
        // native while the menu never gets a chance to close before the row action runs.
        var shouldInvoke = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking)
        { [weak self] trackedEvent, stop in
            guard let self, let trackedEvent else {
                stop.pointee = true
                return
            }
            if self.primaryPressShouldYieldToMenu(for: trackedEvent) {
                // We dequeued this drag from the window; put it back so NSMenu's tracking loop can
                // continue native drag-to-submenu selection from the same event.
                window.postEvent(trackedEvent, atStart: true)
                stop.pointee = true
                return
            }
            guard let decision = self.primaryPressDecision(for: trackedEvent) else { return }
            shouldInvoke = decision
            stop.pointee = true
        }
        if shouldInvoke {
            self.onClick?()
        }
    }

    private func primaryPressDecision(for event: NSEvent) -> Bool? {
        guard event.type == .leftMouseUp else { return nil }
        return self.bounds.contains(self.locationInView(for: event))
    }

    private func primaryPressShouldYieldToMenu(for event: NSEvent) -> Bool {
        event.type == .leftMouseDragged && !self.bounds.contains(self.locationInView(for: event))
    }

    override func layout() {
        super.layout()
        self.selectionView.frame = self.bounds.insetBy(
            dx: Self.selectionHorizontalInset,
            dy: Self.selectionVerticalInset)
        self.selectionView.layer?.cornerRadius = Self.selectionCornerRadius
        self.selectionAccentView.frame = NSRect(
            x: self.selectionView.frame.minX,
            y: self.selectionView.frame.minY,
            width: 2,
            height: self.selectionView.frame.height)
        self.hosting.frame = self.bounds
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        // Crossfade the selection background instead of hard-cutting it. As the wheel moves the
        // highlight, the leaving row fades out while the arriving row fades in, which reads as the
        // selection gliding between rows rather than teleporting. The fade is short so fast flicks
        // still resolve crisply. Runs entirely on the GPU via Core Animation.
        let layer = self.selectionView.layer
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer?.presentation()?.opacity ?? (highlighted ? 0 : 1)
        fade.toValue = highlighted ? 1 : 0
        fade.duration = Self.selectionFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "selectionFade")
        layer?.opacity = highlighted ? 1 : 0
        self.selectionAccentView.layer?.opacity = highlighted ? 1 : 0
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        self.hosting.frame = NSRect(origin: self.hosting.frame.origin, size: NSSize(width: width, height: 1))
        self.hosting.layoutSubtreeIfNeeded()
        return self.hosting.fittingSize.height
    }

    #if DEBUG
    /// True once the menu marks this row highlighted via `setHighlighted`.
    var isHighlightedForTesting: Bool {
        self.isRowHighlighted
    }

    /// The hosted SwiftUI highlight state, which must stay `false` for GPU-selected rows — proving
    /// selection never re-invalidates the SwiftUI graph while scrolling.
    var swiftUIHighlightStateIsHighlightedForTesting: Bool {
        self.hosting.rootView.highlightState.isHighlighted
    }

    /// The console background is supplied by this AppKit host, not the SwiftUI root.
    var hostedRootShowsBackgroundForTesting: Bool {
        self.hosting.rootView.showsBackground
    }

    /// The hosted layer stays transparent so the AppKit selection plate remains visible behind it.
    var hostingLayerBackgroundColorForTesting: CGColor? {
        self.hosting.layer?.backgroundColor
    }

    var hostingLayerFilterCountForTesting: Int {
        self.hosting.layer?.filters?.count ?? 0
    }

    /// The outer host owns the normal console background.
    var hostLayerBackgroundColorForTesting: CGColor? {
        self.layer?.backgroundColor
    }
    #endif

    private func setupSelectionView() {
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.masksToBounds = true
        self.selectionView.layer?.backgroundColor = ConsoleDesign.nsSurface2.cgColor
        // Visibility is driven by layer opacity (crossfaded in `setHighlighted`) rather than
        // `isHidden`, so the selection can glide in and out instead of hard-cutting.
        self.selectionView.layer?.opacity = 0
        self.selectionView.autoresizingMask = [.width, .height]
        self.addSubview(self.selectionView)

        self.selectionAccentView.wantsLayer = true
        self.selectionAccentView.layer?.backgroundColor = ConsoleDesign.nsAccent.cgColor
        self.selectionAccentView.layer?.opacity = 0
        self.addSubview(self.selectionAccentView)
    }

    private func setupHosting() {
        self.hosting.wantsLayer = true
        self.hosting.layer?.backgroundColor = nil
        self.hosting.autoresizingMask = [.width, .height]
        self.addSubview(self.hosting)
        self.addSubview(self.selectionAccentView, positioned: .above, relativeTo: self.hosting)
    }
}

#if DEBUG
extension GPUSelectionHostingView {
    func _test_hitsHostedInteractiveControl(at point: NSPoint) -> Bool {
        self.hitsHostedInteractiveControl(at: point)
    }

    func _test_simulateRuntimeClick(at point: NSPoint? = nil) -> Bool {
        let clickPoint = point ?? NSPoint(x: self.bounds.midX, y: self.bounds.midY)
        guard let onClick = self.onClick, self.hitTest(clickPoint) === self else { return false }
        guard self.bounds.contains(clickPoint) else { return false }
        onClick()
        return true
    }

    func _test_primaryPressDecision(for event: NSEvent) -> Bool? {
        self.primaryPressDecision(for: event)
    }

    func _test_primaryPressShouldYieldToMenu(for event: NSEvent) -> Bool {
        self.primaryPressShouldYieldToMenu(for: event)
    }
}
#endif
