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
        minimumHitTarget: NSSize = NSSize(width: 22, height: 22)) -> [Failure]
    {
        var failures: [Failure] = []
        if root.bounds.width <= 0 || root.bounds.height <= 0 {
            failures.append(.emptyRootBounds)
        }

        let frames = targets.map { target in
            (target, target.view.convert(target.view.bounds, to: root))
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
}
