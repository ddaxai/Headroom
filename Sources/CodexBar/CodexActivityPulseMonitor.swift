import CoreServices
import Foundation

/// Watches Codex rollout files without polling. FSEvents sleeps while the sessions tree is idle and
/// reports file writes in batches, which makes it a substantially cheaper activity signal than
/// repeatedly scanning processes and session directories.
final class CodexActivityPulseMonitor: @unchecked Sendable {
    typealias ActivityHandler = @MainActor @Sendable () -> Void

    private let path: String
    private let callbackQueue = DispatchQueue(
        label: "com.codexbar.relay.codex-activity",
        qos: .utility)
    private let onActivity: ActivityHandler
    private var stream: FSEventStreamRef?

    init(path: String, onActivity: @escaping ActivityHandler) {
        self.path = path
        self.onActivity = onActivity
    }

    @discardableResult
    func start() -> Bool {
        guard self.stream == nil,
              FileManager.default.fileExists(atPath: self.path)
        else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            [self.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            flags)
        else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, self.callbackQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        return true
    }

    func stop() {
        guard let stream = self.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        self.stop()
    }

    private static let handleEvents: FSEventStreamCallback = { _, context, eventCount, eventPaths, eventFlags, _ in
        guard let context else { return }
        let monitor = Unmanaged<CodexActivityPulseMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        guard monitor.containsRolloutWrite(
            paths: paths,
            eventCount: eventCount,
            flags: eventFlags)
        else { return }

        let handler = monitor.onActivity
        Task { @MainActor in
            handler()
        }
    }

    private func containsRolloutWrite(
        paths: [String],
        eventCount: Int,
        flags: UnsafePointer<FSEventStreamEventFlags>) -> Bool
    {
        let relevantFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemRenamed)
        let count = min(paths.count, eventCount)
        for index in 0..<count where Self.isRelevantRolloutEvent(
            path: paths[index],
            flags: flags[index],
            relevantFlags: relevantFlags)
        {
            return true
        }
        return false
    }

    static func isRelevantRolloutEvent(
        path: String,
        flags: FSEventStreamEventFlags,
        relevantFlags: FSEventStreamEventFlags? = nil) -> Bool
    {
        let writeFlags = relevantFlags ?? FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemRenamed)
        return path.hasSuffix(".jsonl") && flags & writeFlags != 0
    }
}
