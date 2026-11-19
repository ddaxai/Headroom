import AppKit

@MainActor
enum HeadroomGeometryAssertions {
    struct Target {
        let name: String
        let view: NSView
    }

    enum Failure: Equatable {
        case emptyRootBounds
        case outsideRoot(String)
        case hitTargetTooSmall(String, width: CGFloat, height: CGFloat)
        case overlap(String, String)
    }

    static func failures(
        root: NSView,
        targets: [Target],
        minimumHitTarget: NSSize = NSSize(width: 22, height: 22),
        usesAlignmentRects: Bool = false) -> [Failure]
    {
        var failures: [Failure] = []
        if root.bounds.width <= 0 || root.bounds.height <= 0 {
            failures.append(.emptyRootBounds)
        }

        let frames = targets.map { target in
            (target, Self.frame(of: target.view, in: root, usesAlignmentRect: usesAlignmentRects))
        }
        for (target, frame) in frames {
            if !root.bounds.contains(frame) {
                failures.append(.outsideRoot(target.name))
            }
            if frame.width < minimumHitTarget.width || frame.height < minimumHitTarget.height {
                failures.append(.hitTargetTooSmall(target.name, width: frame.width, height: frame.height))
            }
        }

        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                let first = frames[firstIndex]
                let second = frames[secondIndex]
                let intersection = first.1.intersection(second.1)
                if intersection.width > 0, intersection.height > 0 {
                    failures.append(.overlap(first.0.name, second.0.name))
                }
            }
        }
        return failures
    }

    /// Auto Layout sizes a control's alignment rect; its frame can extend past it by the bezel insets.
    static func frame(of view: NSView, in root: NSView, usesAlignmentRect: Bool) -> NSRect {
        guard usesAlignmentRect, let superview = view.superview else {
            return view.convert(view.bounds, to: root)
        }
        return superview.convert(view.alignmentRect(forFrame: view.frame), to: root)
    }
}
