import AppKit
import CodexBarCore
import Observation
import SwiftUI

extension StatusItemController {
    func switcherWeeklyRemaining(for provider: UsageProvider) -> Double? {
        let snapshot = self.store.snapshot(for: provider)
        return Self.switcherWeeklyMetricPercent(
            for: provider,
            snapshot: snapshot,
            showUsed: self.settings.usageBarsShowUsed,
            preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot))
    }
}

@MainActor
protocol MenuCardHighlighting: AnyObject {
    var allowsMenuHighlight: Bool { get }
    func setHighlighted(_ highlighted: Bool)
}

extension MenuCardHighlighting {
    var allowsMenuHighlight: Bool {
        true
    }
}

@MainActor
protocol MenuCardMeasuring: AnyObject {
    func measuredHeight(width: CGFloat) -> CGFloat
}

@MainActor
protocol MenuCardInteractiveHitTesting: AnyObject {
    func hitsInteractiveControl(at point: NSPoint) -> Bool
    func hitsPrimaryAction(at point: NSPoint) -> Bool
}

@MainActor
protocol MenuCardDynamicHeightAdjusting: AnyObject {
    func remeasureMenuCardHeight(width: CGFloat)
}

@MainActor
@Observable
final class MenuCardHighlightState {
    var isHighlighted = false
}

final class MenuHostingView<Content: View>: NSHostingView<Content> {
    /// The height AppKit should give this item's menu row. NSMenu reads `intrinsicContentSize`
    /// (not the explicit `frame`) when it lays out custom-view rows, so a measured height that
    /// only lives in `frame` is silently reverted to the open-time row height — leaving the
    /// SwiftUI content centered in a stale, oversized row. Routing the height through the
    /// intrinsic size is the channel the menu actually honors.
    private var measuredHeight: CGFloat?

    override var allowsVibrancy: Bool {
        false
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.applyConsoleAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.applyConsoleAppearance()
    }

    private func applyConsoleAppearance() {
        self.applyConsoleAppearance(palette: ConsoleDesign.palette)
    }

    private func applyConsoleAppearance(palette: ConsolePalette) {
        let appearance = ConsoleDesign.nsAppearance(for: palette)
        self.appearance = appearance
        self.layer?.backgroundColor = palette.tokens.background.nsColor.cgColor
        if let window = self.window {
            StatusMenuAppearance.pin(
                window,
                to: appearance,
                backgroundColor: palette.tokens.background.nsColor)
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let measuredHeight else { return super.intrinsicContentSize }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    func applyMeasuredHeight(width: CGFloat, height: CGFloat) {
        let resolvedHeight = max(1, ceil(height))
        guard self.measuredHeight != resolvedHeight || self.frame.height != resolvedHeight else { return }

        self.measuredHeight = resolvedHeight
        self.frame = NSRect(
            origin: self.frame.origin,
            size: NSSize(width: width, height: resolvedHeight))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        self.superview?.layoutSubtreeIfNeeded()
    }

    /// Measures the true SwiftUI content height at `width`. The cached `measuredHeight` is routed
    /// through `intrinsicContentSize`, so `fittingSize` would otherwise echo the stale cached value;
    /// clearing it for the measurement lets the live content size drive the result. Used to resize
    /// the row exactly when expandable content (e.g. status groups) toggles.
    func measuredFittingHeight(width: CGFloat) -> CGFloat {
        let saved = self.measuredHeight
        self.measuredHeight = nil
        self.frame = NSRect(origin: self.frame.origin, size: NSSize(width: width, height: 1))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        let height = self.fittingSize.height
        self.measuredHeight = saved
        return height
    }
}

@MainActor
final class MenuCardItemHostingView<Content: View>: NSHostingView<Content>, MenuCardHighlighting, MenuCardMeasuring,
    MenuCardDynamicHeightAdjusting, MenuCardInteractiveHitTesting
{
    let highlightState: MenuCardHighlightState
    private(set) var allowsMenuHighlight: Bool
    private var onClick: (() -> Void)?
    private var containsInteractiveControls: Bool
    private var measuredMenuCardHeight: CGFloat?
    let interactiveRegionStore: MenuCardInteractiveRegionStore?
    private var isPressed = false
    private var isForwardingHostedControlPress = false
    #if DEBUG
    private var testForwardedHostedControlMouseDown = false
    private var testForwardedHostedControlMouseUp = false
    #endif

    override var allowsVibrancy: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.applyConsoleAppearance()
    }

    override var intrinsicContentSize: NSSize {
        if let measuredMenuCardHeight {
            return NSSize(
                width: self.frame.width > 0 ? self.frame.width : NSView.noIntrinsicMetric,
                height: measuredMenuCardHeight)
        }
        let size = super.intrinsicContentSize
        guard self.frame.width > 0 else { return size }
        return NSSize(width: self.frame.width, height: size.height)
    }

    init(
        rootView: Content,
        highlightState: MenuCardHighlightState,
        allowsMenuHighlight: Bool,
        containsInteractiveControls: Bool = false,
        interactiveRegionStore: MenuCardInteractiveRegionStore? = nil,
        onClick: (() -> Void)? = nil)
    {
        self.highlightState = highlightState
        self.allowsMenuHighlight = allowsMenuHighlight
        self.containsInteractiveControls = containsInteractiveControls
        self.interactiveRegionStore = interactiveRegionStore
        self.onClick = onClick
        self.measuredMenuCardHeight = nil
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.applyConsoleAppearance()
    }

    /// Reuses this hosting view for a rebuilt card with the same identity: the replaced
    /// `rootView` is diffed in place by SwiftUI instead of tearing down and recreating the
    /// hosting view and its graph. Callers must construct `rootView` around this view's own
    /// `highlightState` so menu hover highlighting keeps driving the rendered content.
    func prepareForReuse(
        rootView: Content,
        allowsMenuHighlight: Bool,
        containsInteractiveControls: Bool = false,
        onClick: (() -> Void)?,
        palette: ConsolePalette = ConsoleDesign.palette)
    {
        self.rootView = rootView
        self.allowsMenuHighlight = allowsMenuHighlight
        self.containsInteractiveControls = containsInteractiveControls
        self.onClick = onClick
        self.isPressed = false
        self.isForwardingHostedControlPress = false
        self.measuredMenuCardHeight = nil
        self.applyConsoleAppearance(palette: palette)
        self.invalidateIntrinsicContentSize()
    }

    /// `NSMenu` tracking consumes keyboard events before they reach a menu item's custom view, so
    /// the pointer `onClick` path has no native counterpart for assistive tech. Expose the row as an
    /// accessibility button whose press mirrors a click, giving VoiceOver an activation path that runs
    /// `onClick` (and therefore keeps the menu open) instead of regressing to mouse-only.
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

    required init(rootView: Content) {
        self.highlightState = MenuCardHighlightState()
        self.allowsMenuHighlight = false
        self.containsInteractiveControls = false
        self.interactiveRegionStore = nil
        self.onClick = nil
        self.measuredMenuCardHeight = nil
        super.init(rootView: rootView)
        self.wantsLayer = true
        self.applyConsoleAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
        let localPoint = self.locationInView(for: event)
        if self.beginPrimaryPress(at: localPoint) {
            #if DEBUG
            self.testForwardedHostedControlMouseDown = true
            #endif
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp, self.onClick != nil else {
            super.mouseUp(with: event)
            return
        }
        let result = self.endPrimaryPress(at: self.locationInView(for: event))
        if result.forwardToHostedControl {
            #if DEBUG
            self.testForwardedHostedControlMouseUp = true
            #endif
            super.mouseUp(with: event)
            return
        }
        if result.invokeRowAction {
            self.onClick?()
        }
    }

    /// Returns whether AppKit should forward the press into a nested SwiftUI control.
    private func beginPrimaryPress(at point: NSPoint) -> Bool {
        if self.hitsHostedInteractiveControl(at: point) {
            self.isForwardingHostedControlPress = true
            return true
        }
        self.isPressed = self.bounds.contains(point)
        return false
    }

    private func endPrimaryPress(at point: NSPoint) -> (forwardToHostedControl: Bool, invokeRowAction: Bool) {
        if self.isForwardingHostedControlPress {
            self.isForwardingHostedControlPress = false
            return (true, false)
        }
        defer { self.isPressed = false }
        return (false, self.isPressed && self.bounds.contains(point))
    }

    private func hitsHostedInteractiveControl(at point: NSPoint) -> Bool {
        // SwiftUI preference regions use a top-origin coordinate space, while a standard
        // NSHostingView receives AppKit points in a bottom-origin coordinate space. The GPU
        // hosting path converts through its child hosting view, so only this path needs the flip.
        let hostedPoint = NSPoint(x: point.x, y: self.bounds.maxY - point.y)
        return self.containsInteractiveControls &&
            (self.interactiveRegionStore?.contains(
                hostedPoint,
                hostingBounds: self.bounds,
                fittedSize: self.fittingSize) == true)
    }

    func hitsInteractiveControl(at point: NSPoint) -> Bool {
        self.hitsHostedInteractiveControl(at: point)
    }

    func hitsPrimaryAction(at point: NSPoint) -> Bool {
        self.onClick != nil && self.bounds.contains(point)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let saved = self.measuredMenuCardHeight
        self.measuredMenuCardHeight = nil
        self.frame = NSRect(origin: self.frame.origin, size: NSSize(width: width, height: 1))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        let result = self.fittingSize.height
        self.measuredMenuCardHeight = saved
        self.invalidateIntrinsicContentSize()
        return result
    }

    func remeasureMenuCardHeight(width: CGFloat) {
        let contentHeight = self.measuredHeight(width: width)
        let resolvedHeight = max(1, ceil(contentHeight + 7))
        self.measuredMenuCardHeight = resolvedHeight
        self.frame = NSRect(
            origin: self.frame.origin,
            size: NSSize(width: width, height: resolvedHeight))
        self.invalidateIntrinsicContentSize()
        self.layoutSubtreeIfNeeded()
        self.superview?.layoutSubtreeIfNeeded()
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.highlightState.isHighlighted != highlighted else { return }
        self.highlightState.isHighlighted = highlighted
    }

    private func applyConsoleAppearance(palette: ConsolePalette = ConsoleDesign.palette) {
        let appearance = ConsoleDesign.nsAppearance(for: palette)
        self.appearance = appearance
        self.layer?.backgroundColor = palette.tokens.background.nsColor.cgColor
        if let window = self.window {
            StatusMenuAppearance.pin(
                window,
                to: appearance,
                backgroundColor: palette.tokens.background.nsColor)
        }
        self.needsDisplay = true
    }
}

@MainActor
final class PersistentRefreshMenuView: NSView, MenuCardHighlighting {
    private static let minimumShortcutColumnWidth: CGFloat = 44
    private static let titleShortcutGap = ConsoleDesign.menuRowTitleShortcutGap
    private static let shortcutReferenceText = "⌘ R"

    private let selectionView = NSView()
    private let selectionAccentView = NSView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let shortcutField: NSTextField?
    private var isRowHighlighted = false
    private var isRowEnabled = true
    private var rowHeight = PersistentRefreshRowMetrics.defaults.rowHeight
    private var onClick: (() -> Void)?

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: self.rowHeight)
    }

    init(
        title: String,
        systemImageName: String?,
        shortcutText: String?,
        onClick: (() -> Void)? = nil)
    {
        self.titleField = NSTextField(labelWithString: title)
        self.shortcutField = shortcutText.map(NSTextField.init(labelWithString:))
        self.onClick = onClick
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor
        self.setupSelectionView()
        self.setupIconView(systemImageName: systemImageName)
        self.setupTextFields()
        if onClick != nil {
            self.installClickRecognizer()
        }
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        self.onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityLabel() -> String? {
        self.titleField.stringValue
    }

    override func isAccessibilityEnabled() -> Bool {
        self.isRowEnabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.isRowEnabled else { return false }
        guard let onClick = self.onClick else {
            return super.accessibilityPerformPress()
        }
        onClick()
        return true
    }

    func applySize(width: CGFloat, height: CGFloat) {
        self.rowHeight = max(1, ceil(height))
        self.frame = NSRect(origin: .zero, size: NSSize(width: width, height: self.rowHeight))
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        self.selectionView.isHidden = !highlighted
        self.selectionAccentView.isHidden = !highlighted
        self.updateColors()
    }

    func setEnabled(_ enabled: Bool) {
        guard self.isRowEnabled != enabled else { return }
        self.isRowEnabled = enabled
        if !enabled {
            self.isRowHighlighted = false
            self.selectionView.isHidden = true
            self.selectionAccentView.isHidden = true
        }
        self.updateColors()
    }

    override func layout() {
        super.layout()

        let metrics = PersistentRefreshRowMetrics.defaults
        self.selectionView.frame = self.bounds.insetBy(
            dx: metrics.selectionHorizontalInset,
            dy: metrics.selectionVerticalInset)
        self.selectionView.layer?.cornerRadius = metrics.selectionCornerRadius
        self.selectionAccentView.frame = NSRect(
            x: self.selectionView.frame.minX,
            y: self.selectionView.frame.minY,
            width: 2,
            height: self.selectionView.frame.height)

        var leadingX = metrics.leadingPadding
        if self.iconView.image != nil {
            let iconSide = metrics.iconWidth
            self.iconView.symbolConfiguration = Self.iconConfiguration(for: metrics)
            self.iconView.frame = NSRect(
                x: leadingX,
                y: floor((self.bounds.height - iconSide) / 2),
                width: iconSide,
                height: iconSide)
            leadingX += metrics.iconWidth + metrics.iconTitleSpacing
        }

        var titleMaxX = self.bounds.maxX - metrics.trailingPadding
        if let shortcutField {
            shortcutField.font = Self.shortcutFont(for: metrics)
            let shortcutSize = shortcutField.intrinsicContentSize
            let referenceWidth = Self.shortcutReferenceWidth(for: metrics)
            let shortcutColumnWidth = max(Self.minimumShortcutColumnWidth, referenceWidth, shortcutSize.width)
            let shortcutX = self.bounds.maxX
                - metrics.trailingPadding
                + metrics.shortcutXOffset
                - referenceWidth
            shortcutField.frame = NSRect(
                x: shortcutX,
                y: floor((self.bounds.height - shortcutSize.height) / 2) + metrics.shortcutYOffset,
                width: shortcutColumnWidth,
                height: shortcutSize.height)
            titleMaxX = shortcutX - Self.titleShortcutGap
        }

        let titleSize = self.titleField.intrinsicContentSize
        self.titleField.frame = NSRect(
            x: leadingX,
            y: floor((self.bounds.height - titleSize.height) / 2),
            width: max(0, titleMaxX - leadingX),
            height: titleSize.height)
    }

    private func setupSelectionView() {
        self.selectionView.isHidden = true
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.masksToBounds = true
        self.selectionView.layer?.backgroundColor = ConsoleDesign.nsSurface2.cgColor
        self.selectionView.layer?.cornerRadius = ConsoleDesign.radiusControl
        self.addSubview(self.selectionView)

        self.selectionAccentView.wantsLayer = true
        self.selectionAccentView.layer?.backgroundColor = ConsoleDesign.nsAccent.cgColor
        self.selectionAccentView.isHidden = true
        self.addSubview(self.selectionAccentView)
    }

    private func setupIconView(systemImageName: String?) {
        guard let systemImageName,
              let baseImage = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        else {
            self.iconView.isHidden = true
            return
        }

        baseImage.isTemplate = true
        self.iconView.image = baseImage
        self.iconView.symbolConfiguration = Self.iconConfiguration(for: PersistentRefreshRowMetrics.defaults)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.contentTintColor = ConsoleDesign.nsPrimaryText
        self.addSubview(self.iconView)
    }

    private func setupTextFields() {
        // Title truncates, shortcut clips; configuring them separately keeps the shortcut column stable.
        self.titleField.font = NSFont.menuFont(ofSize: 0)
        self.configureTitleField(self.titleField)

        if let shortcutField {
            shortcutField.font = Self.shortcutFont(for: PersistentRefreshRowMetrics.defaults)
            self.configureShortcutField(shortcutField)
        }
    }

    private func configureTitleField(_ field: NSTextField) {
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = true
        field.backgroundColor = .clear
        self.addSubview(field)
    }

    private func configureShortcutField(_ field: NSTextField) {
        field.alignment = .left
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = false
        field.backgroundColor = .clear
        self.addSubview(field)
    }

    private func installClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
    }

    private func updateColors() {
        guard self.isRowEnabled else {
            self.titleField.textColor = ConsoleDesign.nsTertiaryForeground
            self.shortcutField?.textColor = ConsoleDesign.nsTertiaryForeground
            self.iconView.contentTintColor = ConsoleDesign.nsTertiaryForeground
            return
        }

        if self.isRowHighlighted {
            self.titleField.textColor = ConsoleDesign.nsPrimaryText
            self.shortcutField?.textColor = ConsoleDesign.nsPrimaryText
            self.iconView.contentTintColor = ConsoleDesign.nsPrimaryText
            return
        }

        self.titleField.textColor = ConsoleDesign.nsPrimaryText
        self.shortcutField?.textColor = ConsoleDesign.nsTertiaryForeground
        self.iconView.contentTintColor = ConsoleDesign.nsPrimaryText
    }

    private static func iconConfiguration(for metrics: PersistentRefreshRowMetrics) -> NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(pointSize: metrics.iconSymbolPointSize, weight: metrics.iconSymbolWeight)
    }

    private static func shortcutFont(for metrics: PersistentRefreshRowMetrics) -> NSFont {
        ConsoleDesign.nsMono(metrics.shortcutFontSize, weight: .regular)
    }

    private static func shortcutReferenceWidth(for metrics: PersistentRefreshRowMetrics) -> CGFloat {
        (self.shortcutReferenceText as NSString).size(withAttributes: [
            .font: self.shortcutFont(for: metrics),
        ]).width
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard self.isRowEnabled else { return }
        self.onClick?()
    }
}

@MainActor
final class ConsoleMenuDividerView: NSView {
    private let lineView = NSView()

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: 9)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor
        self.lineView.wantsLayer = true
        self.lineView.layer?.backgroundColor = ConsoleDesign.nsBorder.cgColor
        self.addSubview(self.lineView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.lineView.frame = NSRect(
            x: ConsoleDesign.menuHorizontalInset,
            y: floor((self.bounds.height - 1) / 2),
            width: max(0, self.bounds.width - ConsoleDesign.menuHorizontalInset * 2),
            height: 1)
    }
}

@MainActor
final class ConsoleMenuRowView: NSView, MenuCardHighlighting {
    private static let selectionHorizontalInset = ConsoleDesign.menuRowSelectionHorizontalInset
    private static let selectionVerticalInset = ConsoleDesign.menuRowSelectionVerticalInset
    private static let iconSize = ConsoleDesign.menuRowIconSize
    private static let leadingPadding = ConsoleDesign.menuRowLeadingPadding
    private static let trailingPadding = ConsoleDesign.menuRowTrailingPadding
    private static let iconTitleSpacing = ConsoleDesign.menuRowIconTitleSpacing
    private static let titleShortcutGap = ConsoleDesign.menuRowTitleShortcutGap

    private let selectionView = NSView()
    private let selectionAccentView = NSView()
    private let iconView = NSImageView()
    private let titleField: NSTextField
    private let subtitleField: NSTextField?
    private let shortcutField: NSTextField?
    private let chevronView = NSImageView()
    private let showsChevron: Bool
    private let isHeadline: Bool
    private let onClick: (() -> Void)?
    private var rowHeight: CGFloat
    private var isRowHighlighted = false
    private var isRowEnabled: Bool

    let allowsMenuHighlight: Bool

    override var allowsVibrancy: Bool {
        false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: self.frame.width, height: self.rowHeight)
    }

    init(
        title: String,
        subtitle: String? = nil,
        systemImageName: String? = nil,
        shortcutText: String? = nil,
        showsChevron: Bool = false,
        isHeadline: Bool = false,
        isEnabled: Bool = true,
        onClick: (() -> Void)? = nil)
    {
        self.titleField = NSTextField(labelWithString: title)
        self.subtitleField = subtitle.map(NSTextField.init(labelWithString:))
        self.shortcutField = shortcutText.map(NSTextField.init(labelWithString:))
        self.showsChevron = showsChevron
        self.isHeadline = isHeadline
        self.onClick = onClick
        self.rowHeight = subtitle == nil ? (isHeadline ? 30 : 28) : 42
        self.isRowEnabled = isEnabled
        self.allowsMenuHighlight = isEnabled && (onClick != nil || showsChevron)
        super.init(frame: .zero)

        self.wantsLayer = true
        self.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor
        self.setupSelectionView()
        self.setupIconView(systemImageName: systemImageName)
        self.setupTextFields()
        self.rowHeight = self.measuredRowHeight()
        if onClick != nil {
            self.installClickRecognizer()
        }
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        self.onClick == nil ? super.accessibilityRole() : .button
    }

    override func accessibilityLabel() -> String? {
        self.titleField.stringValue
    }

    override func isAccessibilityEnabled() -> Bool {
        self.isRowEnabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard self.isRowEnabled, let onClick = self.onClick else { return false }
        onClick()
        return true
    }

    func applySize(width: CGFloat, height: CGFloat? = nil) {
        if let height {
            self.rowHeight = max(1, ceil(height))
        }
        self.frame = NSRect(origin: .zero, size: NSSize(width: width, height: self.rowHeight))
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
    }

    func setHighlighted(_ highlighted: Bool) {
        guard self.isRowHighlighted != highlighted else { return }
        self.isRowHighlighted = highlighted
        self.selectionView.isHidden = !highlighted
        self.selectionAccentView.isHidden = !highlighted
        self.updateColors()
    }

    override func layout() {
        super.layout()
        let selectionFrame = self.bounds.insetBy(
            dx: Self.selectionHorizontalInset,
            dy: Self.selectionVerticalInset)
        self.selectionView.frame = selectionFrame
        self.selectionAccentView.frame = NSRect(
            x: selectionFrame.minX,
            y: selectionFrame.minY,
            width: 2,
            height: selectionFrame.height)

        var leadingX = Self.leadingPadding
        if self.iconView.image != nil {
            self.iconView.frame = NSRect(
                x: leadingX,
                y: floor((self.bounds.height - Self.iconSize) / 2),
                width: Self.iconSize,
                height: Self.iconSize)
            leadingX += Self.iconSize + Self.iconTitleSpacing
        }

        var trailingX = self.bounds.maxX - Self.trailingPadding
        if self.showsChevron {
            let chevronSize = self.chevronView.intrinsicContentSize
            self.chevronView.frame = NSRect(
                x: trailingX - chevronSize.width,
                y: floor((self.bounds.height - chevronSize.height) / 2),
                width: chevronSize.width,
                height: chevronSize.height)
            trailingX = self.chevronView.frame.minX - Self.titleShortcutGap
        }
        if let shortcutField {
            let shortcutSize = shortcutField.intrinsicContentSize
            shortcutField.frame = NSRect(
                x: trailingX - shortcutSize.width,
                y: floor((self.bounds.height - shortcutSize.height) / 2),
                width: shortcutSize.width,
                height: shortcutSize.height)
            trailingX = shortcutField.frame.minX - Self.titleShortcutGap
        }

        if let subtitleField {
            let titleHeight = self.titleField.intrinsicContentSize.height
            let subtitleHeight = subtitleField.intrinsicContentSize.height
            let stackHeight = titleHeight + 1 + subtitleHeight
            let top = floor((self.bounds.height - stackHeight) / 2)
            self.titleField.frame = NSRect(
                x: leadingX,
                y: top + subtitleHeight + 1,
                width: max(0, trailingX - leadingX),
                height: titleHeight)
            subtitleField.frame = NSRect(
                x: leadingX,
                y: top,
                width: max(0, trailingX - leadingX),
                height: subtitleHeight)
        } else {
            let titleSize = self.titleField.intrinsicContentSize
            self.titleField.frame = NSRect(
                x: leadingX,
                y: floor((self.bounds.height - titleSize.height) / 2),
                width: max(0, trailingX - leadingX),
                height: titleSize.height)
        }
    }

    private func setupSelectionView() {
        self.selectionView.wantsLayer = true
        self.selectionView.layer?.backgroundColor = ConsoleDesign.nsSurface2.cgColor
        self.selectionView.layer?.cornerRadius = ConsoleDesign.radiusControl
        self.selectionView.isHidden = true
        self.addSubview(self.selectionView)

        self.selectionAccentView.wantsLayer = true
        self.selectionAccentView.layer?.backgroundColor = ConsoleDesign.nsAccent.cgColor
        self.selectionAccentView.isHidden = true
        self.addSubview(self.selectionAccentView)
    }

    private func setupIconView(systemImageName: String?) {
        guard let systemImageName,
              let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
        else {
            self.iconView.isHidden = true
            return
        }
        image.isTemplate = true
        self.iconView.image = image
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: ConsoleDesign.menuRowIconSize,
            weight: .regular)
        self.addSubview(self.iconView)
    }

    private func setupTextFields() {
        self.titleField.font = self.isHeadline
            ? NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : NSFont.menuFont(ofSize: 0)
        self.titleField.lineBreakMode = .byTruncatingTail
        self.titleField.maximumNumberOfLines = 1
        self.titleField.backgroundColor = .clear
        self.addSubview(self.titleField)

        self.subtitleField?.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        self.subtitleField?.lineBreakMode = .byTruncatingTail
        self.subtitleField?.maximumNumberOfLines = 1
        self.subtitleField?.backgroundColor = .clear
        if let subtitleField = self.subtitleField {
            self.addSubview(subtitleField)
        }

        self.shortcutField?.font = ConsoleDesign.nsMono(NSFont.smallSystemFontSize, weight: .regular)
        self.shortcutField?.alignment = .right
        self.shortcutField?.backgroundColor = .clear
        if let shortcutField = self.shortcutField {
            self.addSubview(shortcutField)
        }

        if self.showsChevron,
           let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        {
            image.isTemplate = true
            self.chevronView.image = image
            self.chevronView.imageScaling = .scaleProportionallyDown
            self.chevronView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: ConsoleDesign.menuChevronPointSize,
                weight: .semibold)
            self.addSubview(self.chevronView)
        }
    }

    private func measuredRowHeight() -> CGFloat {
        let titleHeight = self.titleField.intrinsicContentSize.height
        let contentHeight: CGFloat
        let minimumHeight: CGFloat
        if let subtitleField {
            contentHeight = titleHeight + 1 + subtitleField.intrinsicContentSize.height
            minimumHeight = 42
        } else {
            contentHeight = titleHeight
            minimumHeight = self.isHeadline ? 30 : 28
        }
        // Keep the established console rhythm as a minimum, while allowing larger fonts or
        // accessibility settings to expand the row instead of clipping its text.
        return max(minimumHeight, ceil(contentHeight + 8))
    }

    private func installClickRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.handlePrimaryClick(_:)))
        recognizer.buttonMask = 0x1
        self.addGestureRecognizer(recognizer)
    }

    private func updateColors() {
        guard self.isRowEnabled else {
            self.titleField.textColor = ConsoleDesign.nsTertiaryForeground
            self.subtitleField?.textColor = ConsoleDesign.nsTertiaryForeground
            self.shortcutField?.textColor = ConsoleDesign.nsTertiaryForeground
            self.iconView.contentTintColor = ConsoleDesign.nsTertiaryForeground
            self.chevronView.contentTintColor = ConsoleDesign.nsTertiaryForeground
            return
        }

        self.titleField.textColor = ConsoleDesign.nsPrimaryText
        self.subtitleField?.textColor = self.isRowHighlighted
            ? ConsoleDesign.nsPrimaryText
            : ConsoleDesign.nsSecondaryText
        self.shortcutField?.textColor = self.isRowHighlighted
            ? ConsoleDesign.nsPrimaryText
            : ConsoleDesign.nsTertiaryForeground
        self.iconView.contentTintColor = ConsoleDesign.nsPrimaryText
        self.chevronView.contentTintColor = self.isRowHighlighted
            ? ConsoleDesign.nsPrimaryText
            : ConsoleDesign.nsSecondaryText
    }

    @objc private func handlePrimaryClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended, self.isRowEnabled else { return }
        self.onClick?()
    }
}

extension StatusItemController {
    static let consoleDividerIdentifier = "consoleDivider"

    func makeConsoleDividerItem(width: CGFloat? = nil) -> NSMenuItem {
        // Use a regular custom-view row rather than AppKit's native separator item. Native
        // separators ignore their custom views on some macOS releases and can re-enter menu
        // layout while a menu is tracking; this row keeps the divider fully under our console
        // palette and remains stable during reconciliation.
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = ConsoleMenuDividerView(frame: .zero)
        view.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width ?? Self.menuCardBaseWidth, height: 9))
        item.view = view
        item.representedObject = Self.consoleDividerIdentifier
        item.isEnabled = false
        return item
    }

    func addConsoleDivider(to menu: NSMenu, width: CGFloat? = nil) {
        menu.addItem(self.makeConsoleDividerItem(width: width ?? self.renderedMenuWidth(for: menu)))
    }

    func isConsoleDivider(_ item: NSMenuItem) -> Bool {
        #if DEBUG
        if item.isSeparatorItem {
            assertionFailure("Console menus must use represented custom divider rows")
        }
        #endif
        return item.representedObject as? String == Self.consoleDividerIdentifier
    }

    func makeConsoleMenuRowItem(
        title: String,
        subtitle: String? = nil,
        systemImageName: String? = nil,
        shortcutText: String? = nil,
        showsChevron: Bool = false,
        isHeadline: Bool = false,
        isEnabled: Bool = true,
        width: CGFloat,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        let view = ConsoleMenuRowView(
            title: title,
            subtitle: subtitle,
            systemImageName: systemImageName,
            shortcutText: shortcutText,
            showsChevron: showsChevron,
            isHeadline: isHeadline,
            isEnabled: isEnabled,
            onClick: onClick)
        view.applySize(width: width)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = view
        item.isEnabled = isEnabled
        return item
    }
}

#if DEBUG
extension MenuCardItemHostingView {
    var _test_forwardedHostedControlEvents: (mouseDown: Bool, mouseUp: Bool) {
        (self.testForwardedHostedControlMouseDown, self.testForwardedHostedControlMouseUp)
    }

    func _test_hitsHostedInteractiveControl(at point: NSPoint) -> Bool {
        self.hitsHostedInteractiveControl(at: point)
    }

    func _test_simulateRuntimeClick(at point: NSPoint? = nil) -> Bool {
        let clickPoint = point ?? NSPoint(x: self.bounds.midX, y: self.bounds.midY)
        guard let onClick = self.onClick else { return false }
        guard !self.beginPrimaryPress(at: clickPoint) else {
            _ = self.endPrimaryPress(at: clickPoint)
            return false
        }
        let result = self.endPrimaryPress(at: clickPoint)
        guard result.invokeRowAction else { return false }
        onClick()
        return true
    }
}
#endif

struct MenuCardSectionContainerView<Content: View>: View {
    @Bindable var highlightState: MenuCardHighlightState
    let showsSubmenuIndicator: Bool
    let submenuIndicatorAlignment: Alignment
    let submenuIndicatorTopPadding: CGFloat
    var showsBackground: Bool
    var refreshMonitor: MenuCardRefreshMonitor?
    var interactiveRegionStore: MenuCardInteractiveRegionStore?
    @ViewBuilder let content: () -> Content

    init(
        highlightState: MenuCardHighlightState,
        showsSubmenuIndicator: Bool,
        submenuIndicatorAlignment: Alignment,
        submenuIndicatorTopPadding: CGFloat,
        refreshMonitor: MenuCardRefreshMonitor?,
        showsBackground: Bool = true,
        interactiveRegionStore: MenuCardInteractiveRegionStore? = nil,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.highlightState = highlightState
        self.showsSubmenuIndicator = showsSubmenuIndicator
        self.submenuIndicatorAlignment = submenuIndicatorAlignment
        self.submenuIndicatorTopPadding = submenuIndicatorTopPadding
        self.refreshMonitor = refreshMonitor
        self.showsBackground = showsBackground
        self.interactiveRegionStore = interactiveRegionStore
        self.content = content
    }

    var body: some View {
        self.content()
            .environment(\.menuItemHighlighted, self.highlightState.isHighlighted)
            .environment(\.menuCardRefreshMonitor, self.refreshMonitor)
            .coordinateSpace(name: MenuCardInteractiveRegionPreferenceKey.coordinateSpaceName)
            .onPreferenceChange(MenuCardInteractiveRegionPreferenceKey.self) { regions in
                self.interactiveRegionStore?.regions = regions
            }
            .foregroundStyle(MenuHighlightStyle.primary(self.highlightState.isHighlighted))
            .background(alignment: .topLeading) {
                if self.showsBackground {
                    Rectangle().fill(ConsoleDesign.background)
                }
            }
            .overlay(alignment: .leading) {
                if self.highlightState.isHighlighted {
                    Rectangle()
                        .fill(ConsoleDesign.accent)
                        .frame(width: 2)
                        .padding(.vertical, 2)
                }
            }
            .overlay(alignment: self.submenuIndicatorAlignment) {
                if self.showsSubmenuIndicator {
                    Image(systemName: "chevron.right")
                        .font(.system(size: ConsoleDesign.menuChevronPointSize, weight: .semibold))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.highlightState.isHighlighted))
                        .frame(width: ConsoleDesign.menuChevronHitSize, height: ConsoleDesign.menuChevronHitSize)
                        .contentShape(Rectangle())
                        .padding(.top, self.submenuIndicatorTopPadding)
                        .padding(.trailing, ConsoleDesign.menuChevronTrailingInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
@Observable
final class MenuCardInteractiveRegionStore {
    var regions: [CGRect] = []

    func contains(_ point: CGPoint, hostingBounds: CGRect, fittedSize: CGSize) -> Bool {
        // MenuCardSectionContainerView fills the hosting row and explicitly top-aligns its
        // content. Preference rectangles therefore already share the hosting coordinate space;
        // applying the old centering offset would move every interactive hitbox downward.
        _ = hostingBounds
        _ = fittedSize
        return self.regions.contains { $0.contains(point) }
    }
}

struct MenuCardInteractiveRegionPreferenceKey: PreferenceKey {
    static let coordinateSpaceName = "MenuCardInteractiveRegion"
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func menuCardInteractiveControl(isEnabled: Bool = true) -> some View {
        self.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MenuCardInteractiveRegionPreferenceKey.self,
                    value: isEnabled
                        ? [proxy.frame(in: .named(MenuCardInteractiveRegionPreferenceKey.coordinateSpaceName))]
                        : [])
            }
        }
    }
}
