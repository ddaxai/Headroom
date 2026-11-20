import AppKit
import SwiftUI

enum HeadroomPopupPresentationState: Equatable {
    case closed
    case popup
    case pinned
}

enum HeadroomPopupPlacement {
    static let screenEdgeInset: CGFloat = 8

    static func frame(
        contentSize: NSSize,
        anchorFrame: NSRect,
        visibleFrames: [NSRect]) -> NSRect
    {
        guard let visibleFrame = self.visibleFrame(for: anchorFrame, candidates: visibleFrames) else {
            return NSRect(origin: anchorFrame.origin, size: contentSize)
        }

        let safeFrame = visibleFrame.insetBy(dx: self.screenEdgeInset, dy: self.screenEdgeInset)
        let size = NSSize(
            width: min(contentSize.width, safeFrame.width),
            height: min(contentSize.height, safeFrame.height))
        let preferredX = anchorFrame.maxX - size.width
        let x = min(max(preferredX, safeFrame.minX), safeFrame.maxX - size.width)
        let belowY = anchorFrame.minY - size.height
        let aboveY = anchorFrame.maxY
        let y: CGFloat = if belowY >= safeFrame.minY {
            min(belowY, safeFrame.maxY - size.height)
        } else if aboveY + size.height <= safeFrame.maxY {
            max(aboveY, safeFrame.minY)
        } else {
            min(max(belowY, safeFrame.minY), safeFrame.maxY - size.height)
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func clampedPinnedFrame(
        currentFrame: NSRect,
        preferredViewportSize: NSSize,
        visibleFrames: [NSRect]) -> NSRect
    {
        let topY = currentFrame.maxY
        guard let visibleFrame = self.visibleFrame(for: currentFrame, candidates: visibleFrames) else {
            return NSRect(
                origin: NSPoint(x: currentFrame.minX, y: topY - preferredViewportSize.height),
                size: preferredViewportSize)
        }

        let safeFrame = visibleFrame.insetBy(dx: self.screenEdgeInset, dy: self.screenEdgeInset)
        let size = NSSize(
            width: min(preferredViewportSize.width, safeFrame.width),
            height: min(preferredViewportSize.height, safeFrame.height))
        let x = min(max(currentFrame.minX, safeFrame.minX), safeFrame.maxX - size.width)
        let y = min(max(topY - size.height, safeFrame.minY), safeFrame.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func visibleFrame(for anchorFrame: NSRect, candidates: [NSRect]) -> NSRect? {
        let anchorCenter = NSPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        if let containingFrame = candidates.first(where: { $0.contains(anchorCenter) }) {
            return containingFrame
        }
        let intersecting = candidates.filter { self.area($0.intersection(anchorFrame)) > 0 }
        if let bestIntersecting = intersecting.max(by: {
            self.area($0.intersection(anchorFrame)) < self.area($1.intersection(anchorFrame))
        }) {
            return bestIntersecting
        }
        return candidates.max { lhs, rhs in
            let lhsOverlap = self.horizontalOverlap(lhs, anchorFrame)
            let rhsOverlap = self.horizontalOverlap(rhs, anchorFrame)
            if lhsOverlap != rhsOverlap {
                return lhsOverlap < rhsOverlap
            }
            return self.verticalDistance(from: anchorFrame, to: lhs)
                > self.verticalDistance(from: anchorFrame, to: rhs)
        }
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        guard !rect.isNull else { return 0 }
        return rect.width * rect.height
    }

    private static func horizontalOverlap(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    private static func verticalDistance(from anchor: NSRect, to candidate: NSRect) -> CGFloat {
        if anchor.minY >= candidate.maxY {
            return anchor.minY - candidate.maxY
        }
        if anchor.maxY <= candidate.minY {
            return candidate.minY - anchor.maxY
        }
        return 0
    }
}

@MainActor
enum HeadroomPopupScrollRouting {
    static let pointsPerScrollLine: CGFloat = 16

    @discardableResult
    static func scroll(_ event: NSEvent, in scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maximumOriginY = max(0, documentHeight - clipView.bounds.height)
        guard maximumOriginY > 0 else { return false }
        let deltaY = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * Self.pointsPerScrollLine
        let proposedOriginY = clipView.bounds.origin.y - deltaY
        let originY = min(max(proposedOriginY, 0), maximumOriginY)
        guard originY != clipView.bounds.origin.y else { return false }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: originY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

@MainActor
final class HeadroomPopupMenuRowView: NSView {
    private static let submenuHoverDelay = Duration.milliseconds(150)

    private weak var contentView: NSView?
    private let submenu: NSMenu?
    private let isRowEnabled: Bool
    private var submenuHoverTask: Task<Void, Never>?
    private var isHovering = false
    private var isPresentingSubmenu = false
    private var isPressingSubmenu = false
    private var didCancelPresentedSubmenu = false

    var onSubmenuWillPresent: ((HeadroomPopupMenuRowView, NSMenu) -> Bool)?
    var onSubmenuDidDismiss: ((HeadroomPopupMenuRowView, NSMenu) -> Void)?

    init(contentView: NSView, submenu: NSMenu?, isEnabled: Bool) {
        self.contentView = contentView
        self.submenu = submenu
        self.isRowEnabled = isEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.cancelPendingSubmenuOpen()
            self.cancelPresentedSubmenuIfNeeded()
        }
    }

    private var submenuHoverSuppressedUntil: TimeInterval = 0

    func suppressHoverSubmenu(until deadline: TimeInterval) {
        self.submenuHoverSuppressedUntil = deadline
        self.cancelPendingSubmenuOpen()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let descendant = super.hitTest(point)
        guard self.submenu != nil, let descendant else {
            return descendant
        }
        // AppKit supplies the point in the superview's coordinate system. A hosting view
        // can initially return the row itself, so consult its semantic hit regions before
        // giving the row's submenu ownership of a button or primary card action.
        let localPoint = self.convert(point, from: self.superview)
        if self.isInteractiveHit(descendant, at: localPoint) {
            return descendant === self ? self.contentView : descendant
        }
        if self.bounds.contains(localPoint) {
            return self
        }
        return descendant
    }

    override func mouseDown(with event: NSEvent) {
        self.isPressingSubmenu = self.isRowEnabled && self.submenu != nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.isPressingSubmenu = false }
        let location = self.convert(event.locationInWindow, from: nil)
        guard self.isPressingSubmenu, self.bounds.contains(location) else { return }
        self.openSubmenu()
    }

    override func mouseEntered(with event: NSEvent) {
        self.beginHoverIfNeeded()
    }

    override func mouseMoved(with event: NSEvent) {
        self.beginHoverIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        self.cancelPendingSubmenuOpen()
    }

    /// Cards are hosted inside an AppKit row, while the row itself lives in the outer
    /// SwiftUI `ScrollView`.  Some hosted views consume wheel events instead of allowing
    /// them to bubble through the responder chain, so forward the event explicitly to the
    /// nearest scroll view whenever the pointer is over a card.
    override func scrollWheel(with event: NSEvent) {
        guard let scrollView = self.enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }

        // Hosted SwiftUI descendants can receive the wheel event without an AppKit tracking
        // transaction.  In that case forwarding to NSScrollView's responder implementation is a
        // no-op (the clip view never gets a new origin).  Apply the bounded vertical delta directly
        // and reflect it through the scroll view so both real events and synthetic/test events use
        // the same path.
        guard HeadroomPopupScrollRouting.scroll(event, in: scrollView) else {
            super.scrollWheel(with: event)
            return
        }
    }

    @objc func openSubmenu() {
        self.submenuHoverTask?.cancel()
        self.submenuHoverTask = nil
        guard self.isRowEnabled, let submenu, !self.isPresentingSubmenu,
              ProcessInfo.processInfo.systemUptime >= self.submenuHoverSuppressedUntil
        else { return }
        guard self.onSubmenuWillPresent?(self, submenu) ?? true else {
            self.scheduleSubmenuOpen()
            return
        }
        self.isPresentingSubmenu = true
        self.didCancelPresentedSubmenu = false
        defer { self.isPresentingSubmenu = false }
        defer { self.didCancelPresentedSubmenu = false }
        defer { self.onSubmenuDidDismiss?(self, submenu) }
        submenu.popUp(
            positioning: nil,
            at: NSPoint(x: self.bounds.maxX, y: self.bounds.maxY),
            in: self)
    }

    private func scheduleSubmenuOpen() {
        guard self.submenu != nil else { return }
        self.submenuHoverTask?.cancel()
        self.submenuHoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.submenuHoverDelay)
            guard !Task.isCancelled else { return }
            self?.openSubmenu()
        }
    }

    func cancelPendingSubmenuOpen() {
        self.submenuHoverTask?.cancel()
        self.submenuHoverTask = nil
        self.isHovering = false
        self.isPressingSubmenu = false
        (self.contentView as? MenuCardHighlighting)?.setHighlighted(false)
    }

    func cancelPresentedSubmenuIfNeeded() {
        guard self.isPresentingSubmenu, !self.didCancelPresentedSubmenu else { return }
        self.didCancelPresentedSubmenu = true
        self.submenu?.cancelTrackingWithoutAnimation()
    }

    var isHoveringForSubmenuPresentation: Bool {
        self.isHovering
    }

    func updateHover(isInside: Bool) {
        if isInside {
            self.beginHoverIfNeeded()
        } else if self.isHovering {
            self.cancelPendingSubmenuOpen()
        }
    }

    private func beginHoverIfNeeded() {
        guard ProcessInfo.processInfo.systemUptime >= self.submenuHoverSuppressedUntil else { return }
        guard self.isRowEnabled, !self.isHovering else { return }
        self.isHovering = true
        (self.contentView as? MenuCardHighlighting)?.setHighlighted(true)
        self.scheduleSubmenuOpen()
    }

    private func isInteractiveHit(_ descendant: NSView, at point: NSPoint) -> Bool {
        var current: NSView? = descendant
        while let view = current, view !== self {
            if view is NSControl {
                return true
            }
            current = view.superview
        }
        guard let contentView = self.contentView,
              let interactiveHitTesting = contentView as? MenuCardInteractiveHitTesting
        else {
            return false
        }
        let contentPoint = contentView.convert(point, from: self)
        return interactiveHitTesting.hitsInteractiveControl(at: contentPoint) ||
            interactiveHitTesting.hitsPrimaryAction(at: contentPoint)
    }
}

@MainActor
final class HeadroomPopupMenuStackView: NSView {
    private static let submenuWindowHandoffGrace: TimeInterval = 0.15
    private static let submenuWindowHandoffInset: CGFloat = 40
    private static let submenuWindowContainmentInset: CGFloat = 2
    private static let projectedSubmenuContainmentInset: CGFloat = 8

    private struct Row {
        let sourceItem: NSMenuItem
        let container: HeadroomPopupMenuRowView
        let contentView: NSView
        let height: CGFloat
        let restoresSourceItemView: Bool
    }

    private var rows: [Row] = []
    private(set) var contentSize: NSSize = .zero
    private var installedMenu: NSMenu
    private var installedMenuRevision: Int
    private weak var activeSubmenuRow: HeadroomPopupMenuRowView?
    private weak var activeSubmenu: NSMenu?
    private weak var pendingSubmenuRow: HeadroomPopupMenuRowView?
    private weak var hoveredRow: HeadroomPopupMenuRowView?
    private weak var activeSubmenuWindow: NSWindow?
    private var activeSubmenuPresentedAt: TimeInterval?
    private var submenuDismissalTimer: Timer?
    private var pendingSubmenuPresentationTask: Task<Void, Never>?
    private var submenuTransitionGeneration = 0

    var rowViews: [NSView] {
        self.rows.map(\.container)
    }

    var hasActivePresentedSubmenu: Bool {
        self.activeSubmenuRow != nil
    }

    var onSubmenuDidDismiss: (() -> Void)?

    override var isFlipped: Bool {
        true
    }

    init(menu: NSMenu, detachesSourceMenuItemViews: Bool = false, revision: Int = 0) {
        self.installedMenu = menu
        self.installedMenuRevision = revision
        super.init(frame: .zero)
        self.install(menu: menu, detachesSourceMenuItemViews: detachesSourceMenuItemViews)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.layoutRows()
    }

    func restoreSourceMenuItemViews() {
        self.cancelHoverAndPresentedSubmenus()
        for row in self.rows
            where row.restoresSourceItemView && row.sourceItem.menu != nil && row.sourceItem.view == nil
        {
            row.sourceItem.view = row.contentView
        }
    }

    func update(menu: NSMenu, detachesSourceMenuItemViews: Bool, revision: Int = 0) {
        guard self.installedMenu !== menu || self.installedMenuRevision != revision else { return }
        self.restoreSourceMenuItemViews()
        for row in self.rows {
            row.contentView.removeFromSuperview()
            row.container.removeFromSuperview()
        }
        self.rows.removeAll(keepingCapacity: true)
        self.installedMenu = menu
        self.installedMenuRevision = revision
        self.install(menu: menu, detachesSourceMenuItemViews: detachesSourceMenuItemViews)
    }

    func updateHover(at point: NSPoint) {
        let rowAtPoint = self.rows.first { row in
            let location = row.container.convert(point, from: self)
            return row.container.bounds.contains(location)
        }?.container
        if self.hoveredRow !== rowAtPoint {
            self.invalidatePendingSubmenuPresentation()
        }
        if self.activeSubmenuRow !== rowAtPoint {
            self.pendingSubmenuRow = rowAtPoint
            self.activeSubmenuRow?.cancelPresentedSubmenuIfNeeded()
        }
        self.hoveredRow = rowAtPoint
        if rowAtPoint != nil {
            self.cancelSubmenuDismissal()
        }
        for row in self.rows {
            row.container.updateHover(isInside: row.container === rowAtPoint)
        }
    }

    func cancelHover() {
        self.invalidatePendingSubmenuPresentation()
        self.pendingSubmenuRow = nil
        for row in self.rows {
            row.container.cancelPendingSubmenuOpen()
        }
        self.hoveredRow = nil
    }

    func cancelScheduledPresentedSubmenuDismissal() {
        self.cancelSubmenuDismissal()
    }

    func schedulePresentedSubmenuDismissal() {
        guard self.activeSubmenuRow != nil, self.submenuDismissalTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.12,
            target: self,
            selector: #selector(self.presentedSubmenuDismissalTimerFired(_:)),
            userInfo: nil,
            repeats: false)
        self.submenuDismissalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func presentedSubmenuDismissalTimerFired(_ timer: Timer) {
        guard timer === self.submenuDismissalTimer else { return }
        self.submenuDismissalTimer = nil
        self.cancelHoverAndPresentedSubmenus()
    }

    func cancelHoverAndPresentedSubmenus() {
        self.cancelSubmenuDismissal()
        self.invalidatePendingSubmenuPresentation()
        self.pendingSubmenuRow = nil
        self.cancelHover()
        let activeSubmenuRow = self.activeSubmenuRow
        self.activeSubmenuRow = nil
        self.activeSubmenu = nil
        self.activeSubmenuWindow = nil
        self.activeSubmenuPresentedAt = nil
        activeSubmenuRow?.cancelPresentedSubmenuIfNeeded()
    }

    func suppressHoverSubmenus(until deadline: TimeInterval) {
        self.cancelHoverAndPresentedSubmenus()
        for row in self.rows {
            row.container.suppressHoverSubmenu(until: deadline)
        }
    }

    func acceptsPresentedSubmenuWindow(_ window: NSWindow?, at point: NSPoint) -> Bool {
        guard let window,
              window !== self.window,
              !(window is HeadroomPopupPanel),
              window.level == .popUpMenu,
              Self.isMenuTrackingWindow(window),
              self.activeSubmenuRow != nil
        else {
            return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isInWindow = window.frame
            .insetBy(
                dx: -Self.submenuWindowContainmentInset,
                dy: -Self.submenuWindowContainmentInset)
            .contains(point)
        let isInHandoffRange = window.frame
            .insetBy(
                dx: -Self.submenuWindowHandoffInset,
                dy: -Self.submenuWindowHandoffInset)
            .contains(point)
        let isInHandoffGrace = self.activeSubmenuPresentedAt.map {
            now - $0 <= Self.submenuWindowHandoffGrace
        } ?? false
        guard isInWindow || (isInHandoffGrace && isInHandoffRange) else {
            return false
        }
        guard let activeSubmenuWindow = self.activeSubmenuWindow else {
            self.activeSubmenuWindow = window
            return true
        }
        if activeSubmenuWindow === window {
            return true
        }
        let handoffFrame = activeSubmenuWindow.frame.insetBy(
            dx: -Self.submenuWindowHandoffInset,
            dy: -Self.submenuWindowHandoffInset)
        guard handoffFrame.intersects(window.frame) || handoffFrame.contains(point) else {
            return false
        }
        self.activeSubmenuWindow = window
        self.activeSubmenuPresentedAt = now
        return true
    }

    func acceptsProjectedSubmenuRegion(at point: NSPoint) -> Bool {
        guard let activeSubmenuRow,
              let activeSubmenu,
              let window = activeSubmenuRow.window
        else {
            return false
        }
        activeSubmenu.update()
        let submenuSize = activeSubmenu.size
        guard submenuSize.width > 0, submenuSize.height > 0 else { return false }
        let rowFrame = window.convertToScreen(activeSubmenuRow.convert(activeSubmenuRow.bounds, to: nil))
        return Self.projectedSubmenuFrames(
            rowFrame: rowFrame,
            submenuSize: submenuSize,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)).contains { frame in
            frame.insetBy(
                dx: -Self.projectedSubmenuContainmentInset,
                dy: -Self.projectedSubmenuContainmentInset)
                .contains(point)
        }
    }

    static func projectedSubmenuFrames(
        rowFrame: NSRect,
        submenuSize: NSSize,
        visibleFrames: [NSRect]) -> [NSRect]
    {
        guard submenuSize.width > 0, submenuSize.height > 0 else { return [] }
        let naturalY = rowFrame.maxY - submenuSize.height
        guard let visibleFrame = self.visibleFrame(for: rowFrame, candidates: visibleFrames),
              visibleFrame.width > 0,
              visibleFrame.height > 0
        else {
            return [
                NSRect(
                    x: rowFrame.maxX,
                    y: naturalY,
                    width: submenuSize.width,
                    height: submenuSize.height),
                NSRect(
                    x: rowFrame.minX - submenuSize.width,
                    y: naturalY,
                    width: submenuSize.width,
                    height: submenuSize.height),
            ]
        }

        let size = NSSize(
            width: min(submenuSize.width, visibleFrame.width),
            height: min(submenuSize.height, visibleFrame.height))
        let y = min(
            max(naturalY, visibleFrame.minY),
            visibleFrame.maxY - size.height)
        func clampedX(_ preferredX: CGFloat) -> CGFloat {
            min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - size.width)
        }
        return [
            NSRect(origin: NSPoint(x: clampedX(rowFrame.maxX), y: y), size: size),
            NSRect(origin: NSPoint(x: clampedX(rowFrame.minX - size.width), y: y), size: size),
        ]
    }

    private static func visibleFrame(for rowFrame: NSRect, candidates: [NSRect]) -> NSRect? {
        HeadroomPopupPlacement.visibleFrame(for: rowFrame, candidates: candidates)
    }

    private static func isMenuTrackingWindow(_ window: NSWindow) -> Bool {
        if let popupMenuWindowClass = NSClassFromString("NSPopupMenuWindow"),
           window.isKind(of: popupMenuWindowClass)
        {
            return true
        }
        return NSStringFromClass(type(of: window)).hasSuffix("MenuWindow")
    }

    private func cancelSubmenuDismissal() {
        self.submenuDismissalTimer?.invalidate()
        self.submenuDismissalTimer = nil
    }

    private func submenuWillPresent(
        row: HeadroomPopupMenuRowView,
        submenu: NSMenu) -> Bool
    {
        self.cancelSubmenuDismissal()
        if let activeSubmenuRow = self.activeSubmenuRow, activeSubmenuRow !== row {
            self.pendingSubmenuRow = row
            activeSubmenuRow.cancelPresentedSubmenuIfNeeded()
            return false
        }
        self.activeSubmenuRow = row
        self.activeSubmenu = submenu
        self.activeSubmenuWindow = nil
        self.activeSubmenuPresentedAt = ProcessInfo.processInfo.systemUptime
        self.pendingSubmenuRow = nil
        return true
    }

    private func submenuDidDismiss(
        row: HeadroomPopupMenuRowView,
        submenu: NSMenu)
    {
        guard self.activeSubmenuRow === row, self.activeSubmenu === submenu else { return }
        self.activeSubmenuRow = nil
        self.activeSubmenu = nil
        self.activeSubmenuWindow = nil
        self.activeSubmenuPresentedAt = nil
        guard let pendingSubmenuRow = self.pendingSubmenuRow,
              pendingSubmenuRow === self.hoveredRow,
              pendingSubmenuRow.isHoveringForSubmenuPresentation,
              self.rows.contains(where: { $0.container === pendingSubmenuRow })
        else {
            self.pendingSubmenuRow = nil
            self.onSubmenuDidDismiss?()
            return
        }
        let generation = self.submenuTransitionGeneration
        self.pendingSubmenuPresentationTask?.cancel()
        self.pendingSubmenuPresentationTask = Task { @MainActor [weak self, weak pendingSubmenuRow] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.submenuTransitionGeneration == generation,
                  self.activeSubmenuRow == nil,
                  let pendingSubmenuRow,
                  self.pendingSubmenuRow === pendingSubmenuRow,
                  self.hoveredRow === pendingSubmenuRow,
                  pendingSubmenuRow.isHoveringForSubmenuPresentation,
                  self.rows.contains(where: { $0.container === pendingSubmenuRow })
            else {
                return
            }
            self.pendingSubmenuPresentationTask = nil
            self.pendingSubmenuRow = nil
            pendingSubmenuRow.openSubmenu()
        }
    }

    private func invalidatePendingSubmenuPresentation() {
        self.submenuTransitionGeneration &+= 1
        self.pendingSubmenuPresentationTask?.cancel()
        self.pendingSubmenuPresentationTask = nil
    }

    private func layoutRows() {
        var y = CGFloat.zero
        for row in self.rows {
            row.container.frame = NSRect(x: 0, y: y, width: self.bounds.width, height: row.height)
            row.contentView.frame = row.container.bounds
            y += row.height
        }
    }

    private func install(menu: NSMenu, detachesSourceMenuItemViews: Bool) {
        let rowViews = menu.items.map { item in
            item.view ?? Self.fallbackView(for: item, width: StatusItemController.menuCardBaseWidth)
        }
        let rowSizes = rowViews.map { view -> NSSize in
            let width = max(view.frame.width, view.fittingSize.width)
            let height = max(max(view.frame.height, view.fittingSize.height), 1)
            return NSSize(width: width, height: height)
        }
        let width = max(rowSizes.map(\.width).max() ?? 0, StatusItemController.menuCardBaseWidth)
        let height = rowSizes.reduce(CGFloat.zero) { $0 + $1.height }
        self.contentSize = NSSize(width: width, height: height)
        self.frame.size = self.contentSize

        for (index, item) in menu.items.enumerated() {
            let rowHeight = rowSizes[index].height
            let view = rowViews[index]
            let restoresSourceItemView = detachesSourceMenuItemViews && item.view === view
            if restoresSourceItemView {
                item.view = nil
            }
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            let container = HeadroomPopupMenuRowView(
                contentView: view,
                submenu: item.submenu,
                isEnabled: item.isEnabled)
            container.onSubmenuWillPresent = { [weak self] row, submenu in
                self?.submenuWillPresent(row: row, submenu: submenu) ?? true
            }
            container.onSubmenuDidDismiss = { [weak self] row, submenu in
                self?.submenuDidDismiss(row: row, submenu: submenu)
            }
            container.addSubview(view)
            self.addSubview(container)
            self.rows.append(Row(
                sourceItem: item,
                container: container,
                contentView: view,
                height: rowHeight,
                restoresSourceItemView: restoresSourceItemView))
        }
        self.layoutRows()
    }

    private static func fallbackView(for item: NSMenuItem, width: CGFloat) -> NSView {
        let view = ConsoleMenuRowView(
            title: item.title,
            subtitle: nil,
            systemImageName: nil,
            shortcutText: nil,
            showsChevron: item.submenu != nil,
            isHeadline: false,
            isEnabled: item.isEnabled,
            onClick: { [weak item] in
                guard let item, let action = item.action else { return }
                _ = NSApp.sendAction(action, to: item.target, from: item)
            })
        view.applySize(width: width)
        return view
    }

    static func measuredContentSize(menu: NSMenu) -> NSSize {
        let rowSizes = menu.items.map { item -> NSSize in
            let view = item.view ?? Self.fallbackView(for: item, width: StatusItemController.menuCardBaseWidth)
            return NSSize(
                width: max(view.frame.width, view.fittingSize.width),
                height: max(max(view.frame.height, view.fittingSize.height), 1))
        }
        return NSSize(
            width: max(rowSizes.map(\.width).max() ?? 0, StatusItemController.menuCardBaseWidth),
            height: rowSizes.reduce(CGFloat.zero) { $0 + $1.height })
    }
}

@MainActor
final class HeadroomPopupPointerTrackingView: NSView {
    var onWindowPointChanged: ((NSPoint?) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            window.acceptsMouseMovedEvents = true
            self.updateTrackingAreas()
        } else {
            self.onWindowPointChanged?(nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func mouseEntered(with event: NSEvent) {
        self.onWindowPointChanged?(event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        self.onWindowPointChanged?(event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        self.onWindowPointChanged?(nil)
    }
}

@MainActor
final class HeadroomPopupPointerMonitor {
    private static let pollingInterval: TimeInterval = 1.0 / 30.0

    private let onPointerMove: @MainActor (NSPoint, NSWindow?) -> Void
    private var timer: Timer?

    var isRunning: Bool {
        self.timer != nil
    }

    init(onPointerMove: @escaping @MainActor (NSPoint, NSWindow?) -> Void) {
        self.onPointerMove = onPointerMove
    }

    func start() {
        guard self.timer == nil else { return }
        let timer = Timer(
            timeInterval: Self.pollingInterval,
            target: self,
            selector: #selector(self.timerFired(_:)),
            userInfo: nil,
            repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }

    @objc private func timerFired(_ timer: Timer) {
        guard timer === self.timer else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowNumber = NSWindow.windowNumber(
            at: screenPoint,
            belowWindowWithWindowNumber: 0)
        let window = windowNumber == 0 ? nil : NSApp.window(withWindowNumber: windowNumber)
        self.onPointerMove(screenPoint, window)
    }
}

#if DEBUG
extension HeadroomPopupPointerMonitor {
    func _test_isPollingTimerRegistered(in mode: RunLoop.Mode) -> Bool {
        guard let timer else { return false }
        return CFRunLoopContainsTimer(
            CFRunLoopGetMain(),
            timer as CFRunLoopTimer,
            CFRunLoopMode(mode.rawValue as CFString))
    }
}

extension HeadroomPopupMenuStackView {
    func _test_openSubmenuForTesting(at index: Int) {
        guard self.rows.indices.contains(index) else { return }
        self.rows[index].container.openSubmenu()
    }
}
#endif

@MainActor
@Observable
final class HeadroomPopupPresentationModel {
    private(set) var state: HeadroomPopupPresentationState = .closed
    @ObservationIgnored var onTogglePin: (() -> Void)?
    @ObservationIgnored var onSubmenuDidDismiss: (() -> Void)?
    /// The hosted toolbar follows the state directly. SwiftUI refreshes its representable only on
    /// the next update pass, which left the pin icon, tooltip and VoiceOver label one state behind.
    @ObservationIgnored weak var toolbar: HeadroomPopupToolbarView?

    func update(state: HeadroomPopupPresentationState) {
        self.state = state
        self.toolbar?.updatePresentation(state: state)
    }

    func togglePin() {
        self.onTogglePin?()
    }
}

@MainActor
final class HeadroomPopupToolbarView: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let buttonSize = NSSize(width: 24, height: 22)

    let pinButton: NSButton
    private let presentation: HeadroomPopupPresentationModel

    override var isFlipped: Bool {
        true
    }

    init(presentation: HeadroomPopupPresentationModel) {
        self.presentation = presentation
        self.pinButton = NSButton()
        super.init(frame: .zero)
        self.pinButton.isBordered = false
        self.pinButton.imagePosition = .imageOnly
        self.pinButton.imageScaling = .scaleProportionallyDown
        self.pinButton.focusRingType = .none
        self.pinButton.target = self
        self.pinButton.action = #selector(self.togglePin)
        self.addSubview(self.pinButton)
        self.updatePresentation(state: presentation.state)
        presentation.toolbar = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        self.pinButton.frame = NSRect(
            x: max(0, self.bounds.maxX - Self.horizontalInset - Self.buttonSize.width),
            y: max(0, (self.bounds.height - Self.buttonSize.height) / 2),
            width: Self.buttonSize.width,
            height: Self.buttonSize.height)
    }

    func updatePresentation(state: HeadroomPopupPresentationState) {
        let isPinned = state == .pinned
        let title = L(isPinned ? "headroom_popup_unpin" : "headroom_popup_pin")
        self.pinButton.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: title)
        self.pinButton.contentTintColor = isPinned ? ConsoleDesign.nsAccent : ConsoleDesign.nsSecondaryText
        self.pinButton.toolTip = title
        self.pinButton.setAccessibilityLabel(title)
    }

    @objc private func togglePin() {
        self.presentation.togglePin()
    }
}

@MainActor
private struct HeadroomPopupToolbarRepresentable: NSViewRepresentable {
    let presentation: HeadroomPopupPresentationModel
    let state: HeadroomPopupPresentationState

    func makeNSView(context: Context) -> HeadroomPopupToolbarView {
        HeadroomPopupToolbarView(presentation: self.presentation)
    }

    func updateNSView(_ nsView: HeadroomPopupToolbarView, context: Context) {
        nsView.updatePresentation(state: self.state)
    }
}

@MainActor
private struct HeadroomPopupMenuStackRepresentable: NSViewRepresentable {
    let menu: NSMenu
    let revision: Int
    let onSubmenuDidDismiss: (() -> Void)?

    func makeNSView(context: Context) -> HeadroomPopupMenuStackView {
        let stack = HeadroomPopupMenuStackView(
            menu: self.menu,
            detachesSourceMenuItemViews: true,
            revision: self.revision)
        stack.onSubmenuDidDismiss = self.onSubmenuDidDismiss
        return stack
    }

    func updateNSView(_ nsView: HeadroomPopupMenuStackView, context: Context) {
        nsView.onSubmenuDidDismiss = self.onSubmenuDidDismiss
        nsView.update(
            menu: self.menu,
            detachesSourceMenuItemViews: true,
            revision: self.revision)
    }
}

@MainActor
struct HeadroomPopupCardStack: View {
    static let toolbarHeight: CGFloat = 30

    let menu: NSMenu
    let contentSize: NSSize
    let viewportSize: NSSize
    let revision: Int
    let presentation: HeadroomPopupPresentationModel

    var body: some View {
        VStack(spacing: 0) {
            HeadroomPopupToolbarRepresentable(
                presentation: self.presentation,
                state: self.presentation.state)
                .frame(height: Self.toolbarHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ConsoleDesign.border)
                        .frame(height: 1)
                }

            ScrollView(.vertical) {
                HeadroomPopupMenuStackRepresentable(
                    menu: self.menu,
                    revision: self.revision,
                    onSubmenuDidDismiss: self.presentation.onSubmenuDidDismiss)
                    .frame(width: self.contentSize.width, height: self.contentSize.height)
            }
            .frame(
                width: self.viewportSize.width,
                height: max(0, self.viewportSize.height - Self.toolbarHeight))
        }
        .frame(width: self.viewportSize.width, height: self.viewportSize.height)
        .background(ConsoleDesign.background)
        .preferredColorScheme(ConsoleDesign.preferredColorScheme)
    }
}

@MainActor
final class HeadroomPopupPanel: NSPanel {
    private(set) var sourceMenu: NSMenu
    private(set) var contentSize: NSSize
    private(set) var presentationState: HeadroomPopupPresentationState = .closed
    private var menuRevision = 0
    let presentationModel: HeadroomPopupPresentationModel
    let hostingController: NSHostingController<HeadroomPopupCardStack>
    let pointerTrackingView: HeadroomPopupPointerTrackingView
    var onRequestClose: (() -> Void)?
    var onSubmenuDidDismiss: (() -> Void)?

    var hasActivePresentedSubmenu: Bool {
        self.menuStacks(in: self.hostingController.view).contains(where: \.hasActivePresentedSubmenu)
    }

    private weak var anchorView: NSView?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localScrollMonitor: Any?
    private var lastPointerScreenPoint: NSPoint?
    private lazy var pointerMonitor = HeadroomPopupPointerMonitor { [weak self] screenPoint, window in
        self?.handlePointerMove(screenPoint: screenPoint, eventWindow: window)
    }

    #if DEBUG
    private var pointerMonitoringSuppressedForTesting = false
    #endif

    #if DEBUG
    var isPointerMonitoringForTesting: Bool {
        self.pointerMonitor.isRunning
    }

    func _test_disablePointerMonitoring() {
        self.pointerMonitoringSuppressedForTesting = true
        self.stopPointerMonitoring()
    }

    var isScrollMonitoringForTesting: Bool {
        self.localScrollMonitor != nil
    }
    #endif

    init(menu: NSMenu) {
        let contentSize = HeadroomPopupPanel.measuredContentSize(menu: menu)
        let viewportSize = HeadroomPopupPanel.preferredViewportSize(for: contentSize)
        let presentationModel = HeadroomPopupPresentationModel()
        self.sourceMenu = menu
        self.contentSize = contentSize
        self.presentationModel = presentationModel
        self.pointerTrackingView = HeadroomPopupPointerTrackingView(frame: .zero)
        self.hostingController = NSHostingController(rootView: HeadroomPopupCardStack(
            menu: menu,
            contentSize: contentSize,
            viewportSize: viewportSize,
            revision: self.menuRevision,
            presentation: presentationModel))
        super.init(
            contentRect: NSRect(origin: .zero, size: viewportSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        self.contentViewController = self.hostingController
        self.collectionBehavior = [.transient]
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.hasShadow = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.isReleasedWhenClosed = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.applyConsoleAppearance()
        self.hostingController.view.frame = NSRect(origin: .zero, size: viewportSize)
        self.pointerTrackingView.frame = self.hostingController.view.bounds
        self.pointerTrackingView.autoresizingMask = [.width, .height]
        self.hostingController.view.addSubview(self.pointerTrackingView, positioned: .above, relativeTo: nil)
        self.hostingController.view.layoutSubtreeIfNeeded()
        self.presentationModel.onTogglePin = { [weak self] in
            self?.togglePinned()
        }
        self.presentationModel.onSubmenuDidDismiss = { [weak self] in
            self?.onSubmenuDidDismiss?()
        }
    }

    func update(menu: NSMenu, screens: [NSScreen] = NSScreen.screens) {
        let previousScrollOriginY = self.popupScrollView(in: self.hostingController.view)?
            .contentView.bounds.origin.y
        self.lastPointerScreenPoint = nil
        self.restoreSourceMenuItemViews()
        self.sourceMenu = menu
        self.contentSize = Self.measuredContentSize(menu: menu)
        let preferredViewportSize = Self.preferredViewportSize(for: self.contentSize)
        let visibleFrames = screens.map(\.visibleFrame)
        let targetFrame: NSRect?
        let viewportSize: NSSize
        switch self.presentationState {
        case .closed:
            targetFrame = nil
            viewportSize = preferredViewportSize
        case .popup:
            if let anchorFrame = self.anchorFrameInScreen(), !visibleFrames.isEmpty {
                let frame = HeadroomPopupPlacement.frame(
                    contentSize: preferredViewportSize,
                    anchorFrame: anchorFrame,
                    visibleFrames: visibleFrames)
                targetFrame = frame
                viewportSize = frame.size
            } else if !visibleFrames.isEmpty {
                let frame = HeadroomPopupPlacement.clampedPinnedFrame(
                    currentFrame: self.frame,
                    preferredViewportSize: preferredViewportSize,
                    visibleFrames: visibleFrames)
                targetFrame = frame
                viewportSize = frame.size
            } else {
                targetFrame = nil
                viewportSize = preferredViewportSize
            }
        case .pinned:
            let frame = HeadroomPopupPlacement.clampedPinnedFrame(
                currentFrame: self.frame,
                preferredViewportSize: preferredViewportSize,
                visibleFrames: visibleFrames)
            targetFrame = frame
            viewportSize = frame.size
        }
        self.menuRevision += 1
        self.hostingController.rootView = HeadroomPopupCardStack(
            menu: menu,
            contentSize: self.contentSize,
            viewportSize: viewportSize,
            revision: self.menuRevision,
            presentation: self.presentationModel)
        self.applyConsoleAppearance()
        if let targetFrame {
            self.setFrame(targetFrame, display: self.isVisible)
        } else {
            self.setContentSize(viewportSize)
        }
        self.pointerTrackingView.frame = self.hostingController.view.bounds
        self.hostingController.view.addSubview(self.pointerTrackingView, positioned: .above, relativeTo: nil)
        self.hostingController.view.layoutSubtreeIfNeeded()
        if let previousScrollOriginY,
           previousScrollOriginY > 0,
           let scrollView = self.popupScrollView(in: self.hostingController.view)
        {
            let clipView = scrollView.contentView
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maximumOriginY = max(0, documentHeight - clipView.bounds.height)
            let restoredOriginY = min(max(previousScrollOriginY, 0), maximumOriginY)
            if restoredOriginY > 0 {
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: restoredOriginY))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    private func applyConsoleAppearance() {
        self.appearance = ConsoleDesign.nsAppearance
        let view = self.hostingController.view
        view.appearance = ConsoleDesign.nsAppearance
        view.wantsLayer = true
        view.layer?.backgroundColor = ConsoleDesign.nsBackground.cgColor
    }

    func prepareForSourceMenuMutation() {
        self.restoreSourceMenuItemViews()
    }

    func show(relativeTo anchorView: NSView, screens: [NSScreen] = NSScreen.screens) {
        self.anchorView = anchorView
        guard self.position(relativeTo: anchorView, screens: screens) else { return }
        self.transition(to: .popup)
        self.orderFront(nil)
    }

    func transition(to state: HeadroomPopupPresentationState) {
        switch state {
        case .closed:
            self.stopPointerMonitoring()
            self.stopOutsideClickMonitoring()
            self.stopScrollMonitoring()
            self.restoreSourceMenuItemViews()
            self.collectionBehavior = []
            self.isMovable = false
            self.isMovableByWindowBackground = false
            self.orderOut(nil)
        case .popup:
            self.level = .popUpMenu
            self.collectionBehavior = [.transient]
            self.isMovable = false
            self.isMovableByWindowBackground = false
            self.startOutsideClickMonitoring()
            self.startScrollMonitoring()
            self.startPointerMonitoring()
        case .pinned:
            self.stopOutsideClickMonitoring()
            self.level = .floating
            self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.isMovable = true
            self.isMovableByWindowBackground = true
            if self.presentationState != .pinned {
                if let anchorView, anchorView.window != nil {
                    _ = self.position(relativeTo: anchorView, screens: NSScreen.screens, updatesRootView: true)
                } else if !NSScreen.screens.isEmpty {
                    let frame = HeadroomPopupPlacement.clampedPinnedFrame(
                        currentFrame: self.frame,
                        preferredViewportSize: Self.preferredViewportSize(for: self.contentSize),
                        visibleFrames: NSScreen.screens.map(\.visibleFrame))
                    self.updateRootViewportIfNeeded(frame.size)
                    self.setFrame(frame, display: self.isVisible)
                }
            }
            self.startScrollMonitoring()
            self.startPointerMonitoring()
        }

        self.presentationState = state
        self.presentationModel.update(state: state)
    }

    func togglePinned() {
        switch self.presentationState {
        case .closed:
            break
        case .popup:
            self.transition(to: .pinned)
        case .pinned:
            self.transition(to: .popup)
            if let anchorView {
                _ = self.position(relativeTo: anchorView, screens: NSScreen.screens, updatesRootView: true)
            }
        }
    }

    func shouldDismissPopup(forScreenPoint point: NSPoint) -> Bool {
        guard self.presentationState == .popup, !self.frame.contains(point) else { return false }
        return self.anchorFrameInScreen()?.contains(point) != true
    }

    override func close() {
        self.transition(to: .closed)
        super.close()
    }

    private func position(
        relativeTo anchorView: NSView,
        screens: [NSScreen],
        updatesRootView: Bool = true) -> Bool
    {
        guard let anchorWindow = anchorView.window else { return false }
        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrame = anchorWindow.convertToScreen(anchorFrameInWindow)
        let viewportSize = updatesRootView ? Self.preferredViewportSize(for: self.contentSize) : self.frame.size
        let frame = HeadroomPopupPlacement.frame(
            contentSize: viewportSize,
            anchorFrame: anchorFrame,
            visibleFrames: screens.map(\.visibleFrame))
        if updatesRootView {
            self.updateRootViewportIfNeeded(frame.size)
        }
        self.setFrame(frame, display: true)
        return true
    }

    private func updateRootViewportIfNeeded(_ size: NSSize) {
        guard self.hostingController.rootView.viewportSize != size else { return }
        self.hostingController.rootView = HeadroomPopupCardStack(
            menu: self.sourceMenu,
            contentSize: self.contentSize,
            viewportSize: size,
            revision: self.menuRevision,
            presentation: self.presentationModel)
    }

    private func startOutsideClickMonitoring() {
        guard self.localClickMonitor == nil, self.globalClickMonitor == nil else { return }
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        self.localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            guard let self else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self.requestCloseIfNeeded(forScreenPoint: point)
            return event
        }
        self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.requestCloseIfNeeded(forScreenPoint: point)
            }
        }
    }

    private func startPointerMonitoring() {
        #if DEBUG
        guard !self.pointerMonitoringSuppressedForTesting else { return }
        #endif
        self.lastPointerScreenPoint = nil
        self.pointerMonitor.start()
    }

    private func startScrollMonitoring() {
        guard self.localScrollMonitor == nil else { return }
        self.localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            guard self.shouldRouteScrollWheel(from: event.window, at: point) else { return event }
            return self.routeScrollWheel(event) ? nil : event
        }
    }

    private func stopScrollMonitoring() {
        guard let localScrollMonitor else { return }
        NSEvent.removeMonitor(localScrollMonitor)
        self.localScrollMonitor = nil
    }

    func shouldRouteScrollWheel(from window: NSWindow?, at screenPoint: NSPoint) -> Bool {
        guard self.presentationState != .closed else { return false }
        if window === self { return true }
        // Native NSMenu tracking creates a separate menu window. Accept only a window owned
        // by this popup's active submenu; unrelated windows keep their normal scroll behavior.
        return self.menuStacks(in: self.hostingController.view).contains {
            $0.acceptsPresentedSubmenuWindow(window, at: screenPoint)
        }
    }

    @discardableResult
    func routeScrollWheel(_ event: NSEvent) -> Bool {
        guard self.presentationState != .closed,
              let scrollView = self.popupScrollView(in: self.hostingController.view)
        else {
            return false
        }
        // Extend on each gesture/momentum event. The final phase can arrive outside
        // this popup, so an infinite deadline would leave hover permanently disabled.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        for stack in self.menuStacks(in: self.hostingController.view) {
            stack.suppressHoverSubmenus(until: deadline)
        }
        return HeadroomPopupScrollRouting.scroll(event, in: scrollView)
    }

    private func stopPointerMonitoring() {
        self.pointerMonitor.stop()
        self.lastPointerScreenPoint = nil
    }

    func handlePointerMove(screenPoint: NSPoint, eventWindow: NSWindow?) {
        guard self.presentationState != .closed else { return }
        let stacks = self.menuStacks(in: self.hostingController.view)
        guard !stacks.isEmpty else {
            self.lastPointerScreenPoint = nil
            return
        }
        let hasActiveSubmenu = stacks.contains(where: \.hasActivePresentedSubmenu)
        guard self.lastPointerScreenPoint != screenPoint || hasActiveSubmenu else { return }
        self.lastPointerScreenPoint = screenPoint
        if self.frame.contains(screenPoint) {
            self.keepPresentedSubmenuOpen()
            self.updateHover(at: self.convertPoint(fromScreen: screenPoint))
        } else if self.acceptsPresentedSubmenuWindow(
            preferredWindow: eventWindow,
            at: screenPoint,
            stacks: stacks)
            || self.acceptsUnresolvedPresentedSubmenuWindow(
                at: screenPoint,
                hasActiveSubmenu: hasActiveSubmenu)
            || stacks.contains(where: { $0.acceptsProjectedSubmenuRegion(at: screenPoint) })
        {
            self.keepPresentedSubmenuOpen()
            self.updateHover(at: nil)
        } else {
            self.handlePanelPointerExit()
        }
    }

    static func acceptsUnresolvedSubmenuWindow(
        windowNumber: Int,
        panelWindowNumber: Int,
        ownerPID: Int,
        currentPID: Int,
        hasActiveSubmenu: Bool) -> Bool
    {
        hasActiveSubmenu
            && windowNumber > 0
            && windowNumber != panelWindowNumber
            && ownerPID == currentPID
    }

    private func acceptsUnresolvedPresentedSubmenuWindow(
        at screenPoint: NSPoint,
        hasActiveSubmenu: Bool) -> Bool
    {
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard NSApp.window(withWindowNumber: windowNumber) == nil,
              let ownerPID = Self.ownerPID(forWindowNumber: windowNumber)
        else {
            return false
        }
        return Self.acceptsUnresolvedSubmenuWindow(
            windowNumber: windowNumber,
            panelWindowNumber: self.windowNumber,
            ownerPID: ownerPID,
            currentPID: Int(ProcessInfo.processInfo.processIdentifier),
            hasActiveSubmenu: hasActiveSubmenu)
    }

    private static func ownerPID(forWindowNumber windowNumber: Int) -> Int? {
        guard windowNumber > 0,
              let records = CGWindowListCopyWindowInfo(
                  .optionIncludingWindow,
                  CGWindowID(windowNumber)) as? [[String: Any]],
              let ownerPID = records.first?[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return nil
        }
        return ownerPID.intValue
    }

    private func acceptsPresentedSubmenuWindow(
        preferredWindow: NSWindow?,
        at screenPoint: NSPoint,
        stacks: [HeadroomPopupMenuStackView]) -> Bool
    {
        var candidates: [NSWindow] = []
        if let preferredWindow {
            candidates.append(preferredWindow)
        }
        for window in NSApp.windows
            where !candidates.contains(where: { $0 === window }) &&
            window !== self &&
            window.isVisible &&
            window.level == .popUpMenu
        {
            candidates.append(window)
        }
        for window in candidates
            where stacks.contains(where: { $0.acceptsPresentedSubmenuWindow(window, at: screenPoint) })
        {
            return true
        }
        return false
    }

    private func handlePanelPointerExit() {
        self.updateHover(at: nil)
        self.schedulePresentedSubmenuDismissal()
    }

    private func keepPresentedSubmenuOpen() {
        for stack in self.menuStacks(in: self.hostingController.view) {
            stack.cancelScheduledPresentedSubmenuDismissal()
        }
    }

    private func schedulePresentedSubmenuDismissal() {
        for stack in self.menuStacks(in: self.hostingController.view) {
            stack.schedulePresentedSubmenuDismissal()
        }
    }

    private func menuStacks(in view: NSView) -> [HeadroomPopupMenuStackView] {
        var result = [view as? HeadroomPopupMenuStackView].compactMap(\.self)
        for subview in view.subviews {
            result.append(contentsOf: self.menuStacks(in: subview))
        }
        return result
    }

    private func popupScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           !self.menuStacks(in: scrollView).isEmpty
        {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = self.popupScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func stopOutsideClickMonitoring() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func requestCloseIfNeeded(forScreenPoint point: NSPoint) {
        guard self.shouldDismissPopup(forScreenPoint: point) else { return }
        self.onRequestClose?()
    }

    private func anchorFrameInScreen() -> NSRect? {
        guard let anchorView, let window = anchorView.window else { return nil }
        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        return window.convertToScreen(anchorFrameInWindow)
    }

    private func restoreSourceMenuItemViews() {
        self.restoreSourceMenuItemViews(in: self.hostingController.view)
    }

    private func updateHover(at pointInWindow: NSPoint?) {
        guard let stack = self.menuStacks(in: self.hostingController.view).first else { return }
        if let pointInWindow {
            stack.updateHover(at: stack.convert(pointInWindow, from: nil))
        } else {
            stack.cancelHover()
        }
    }

    private func restoreSourceMenuItemViews(in view: NSView) {
        if let stack = view as? HeadroomPopupMenuStackView {
            stack.restoreSourceMenuItemViews()
        }
        for subview in view.subviews {
            self.restoreSourceMenuItemViews(in: subview)
        }
    }

    private static func measuredContentSize(menu: NSMenu) -> NSSize {
        HeadroomPopupMenuStackView.measuredContentSize(menu: menu)
    }

    private static func preferredViewportSize(for contentSize: NSSize) -> NSSize {
        NSSize(width: contentSize.width, height: contentSize.height + HeadroomPopupCardStack.toolbarHeight)
    }
}
