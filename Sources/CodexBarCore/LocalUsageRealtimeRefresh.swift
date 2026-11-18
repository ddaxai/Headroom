import Dispatch
import Foundation
#if os(macOS)
import CoreServices
#endif

public enum LocalUsageRefreshSource: String, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case antigravity
    case pi
    case openCode
}

public struct LocalUsageWatchRoot: Equatable, Sendable {
    public let source: LocalUsageRefreshSource
    public let url: URL

    public init(source: LocalUsageRefreshSource, url: URL) {
        self.source = source
        self.url = url.standardizedFileURL
    }
}

public enum LocalUsageWatchPlan {
    public static func roots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheDirectory: URL) -> [LocalUsageWatchRoot]
    {
        let codexHome: URL = if let configured = self.nonEmpty(environment["CODEX_HOME"]) {
            URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        let claudeHome: URL = if let configured = self.nonEmpty(environment["CLAUDE_CONFIG_DIR"]) {
            URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        let candidates = [
            LocalUsageWatchRoot(
                source: .codex,
                url: codexHome.appendingPathComponent("sessions", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .codex,
                url: codexHome.appendingPathComponent("archived_sessions", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .claude,
                url: claudeHome.appendingPathComponent("projects", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .antigravity,
                url: homeDirectory.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .antigravity,
                url: homeDirectory.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .antigravity,
                url: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .antigravity,
                url: homeDirectory.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .pi,
                url: homeDirectory.appendingPathComponent(".pi/agent/sessions", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .pi,
                url: homeDirectory.appendingPathComponent(".omp/agent/sessions", isDirectory: true)),
            LocalUsageWatchRoot(
                source: .openCode,
                url: homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true)),
        ]
        let cachePath = cacheDirectory.standardizedFileURL.path
        return candidates.filter { root in
            let path = root.url.standardizedFileURL.path
            return !self.contains(path: path, within: cachePath)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func contains(path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

public enum LocalUsageCatchUpRunner {
    /// Repeats bounded scanner slices until the cache reports complete coverage.
    /// The operation returns true while another pass is required.
    @MainActor
    @discardableResult
    public static func run(
        maxPasses: Int = 12,
        operation: @MainActor @Sendable () async -> Bool) async -> Int
    {
        let limit = max(1, maxPasses)
        for pass in 1...limit {
            guard !Task.isCancelled else { return pass - 1 }
            let needsCatchUp = await operation()
            if !needsCatchUp { return pass }
            await Task.yield()
        }
        return limit
    }
}

public actor LocalUsageRefreshDebouncer {
    public typealias Action = @Sendable (Set<LocalUsageRefreshSource>) async -> Void

    private let delay: Duration
    private let action: Action
    private var pendingSources: Set<LocalUsageRefreshSource> = []
    private var debounceTask: Task<Void, Never>?
    private var activeActionTask: Task<Void, Never>?
    private var activeActionID: UUID?

    public init(delay: Duration = .seconds(2), action: @escaping Action) {
        self.delay = delay
        self.action = action
    }

    public func submit(_ source: LocalUsageRefreshSource) {
        self.pendingSources.insert(source)
        guard self.activeActionTask == nil else { return }
        self.scheduleFlush()
    }

    public func cancel() {
        self.debounceTask?.cancel()
        self.debounceTask = nil
        self.activeActionTask?.cancel()
        self.activeActionTask = nil
        self.activeActionID = nil
        self.pendingSources.removeAll()
    }

    private func scheduleFlush() {
        self.debounceTask?.cancel()
        let delay = self.delay
        self.debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.beginFlush()
        }
    }

    private func beginFlush() async {
        self.debounceTask = nil
        guard self.activeActionTask == nil else { return }
        let sources = self.pendingSources
        self.pendingSources.removeAll()
        guard !sources.isEmpty else { return }

        let action = self.action
        let actionID = UUID()
        let task = Task {
            await action(sources)
        }
        self.activeActionID = actionID
        self.activeActionTask = task
        await task.value

        guard self.activeActionID == actionID else { return }
        self.activeActionID = nil
        self.activeActionTask = nil
        if !self.pendingSources.isEmpty {
            self.scheduleFlush()
        }
    }
}

#if os(macOS)
public final class LocalUsageDirectoryWatcher: @unchecked Sendable {
    public enum WatchError: LocalizedError, Equatable {
        case noAvailableRoots
        case cannotOpen(String, Int32)
        case failedToStart

        public var errorDescription: String? {
            switch self {
            case .noAvailableRoots:
                "No local usage directories are available to watch."
            case let .cannotOpen(path, code):
                "Could not watch \(path) (errno \(code))."
            case .failedToStart:
                "The recursive local usage watcher could not start."
            }
        }
    }

    public let watchedRoots: [LocalUsageWatchRoot]

    private final class CallbackContext: @unchecked Sendable {
        let source: LocalUsageRefreshSource
        let onEvent: @Sendable (LocalUsageRefreshSource) -> Void

        init(
            source: LocalUsageRefreshSource,
            onEvent: @escaping @Sendable (LocalUsageRefreshSource) -> Void)
        {
            self.source = source
            self.onEvent = onEvent
        }

        func handle() {
            self.onEvent(self.source)
        }
    }

    private struct StreamRegistration {
        let stream: FSEventStreamRef
        let context: CallbackContext
    }

    private static let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, _, _ in
        guard eventCount > 0 else { return }
        guard let info else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        guard LocalUsageDirectoryWatcher.containsRelevantEvent(
            paths: paths,
            source: context.source,
            eventCount: eventCount)
        else {
            return
        }
        context.handle()
    }

    private static func containsRelevantEvent(
        paths: [String],
        source: LocalUsageRefreshSource,
        eventCount: Int) -> Bool
    {
        guard source == .openCode else { return true }
        // A read-only SQLite connection can create or update these sidecars while acquiring
        // its shared-memory read lock. They are not usage writes and must not retrigger a scan.
        let count = min(paths.count, eventCount)
        guard count > 0 else { return true }
        return paths.prefix(count).contains { path in
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return fileName == "opencode.db" || fileName == "opencode.db-wal"
        }
    }

    private let lock = NSLock()
    private var registrations: [StreamRegistration]

    public init(
        roots: [LocalUsageWatchRoot],
        fileManager: FileManager = .default,
        queue: DispatchQueue = DispatchQueue(label: "com.steipete.codexbar.local-usage-watch"),
        onEvent: @escaping @Sendable (LocalUsageRefreshSource) -> Void) throws
    {
        let available = roots.filter { root in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !available.isEmpty else { throw WatchError.noAvailableRoots }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot)
        var registrations: [StreamRegistration] = []
        do {
            for root in available {
                let callbackContext = CallbackContext(source: root.source, onEvent: onEvent)
                var context = FSEventStreamContext(
                    version: 0,
                    info: Unmanaged.passUnretained(callbackContext).toOpaque(),
                    retain: nil,
                    release: nil,
                    copyDescription: nil)
                guard let stream = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    Self.callback,
                    &context,
                    [root.url.resolvingSymlinksInPath().path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    0.1,
                    flags)
                else { throw WatchError.failedToStart }
                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else {
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    throw WatchError.failedToStart
                }
                registrations.append(StreamRegistration(stream: stream, context: callbackContext))
            }
        } catch {
            Self.stop(registrations)
            throw error
        }

        self.watchedRoots = available
        self.registrations = registrations
    }

    public func cancel() {
        self.lock.lock()
        let registrations = self.registrations
        self.registrations.removeAll()
        self.lock.unlock()
        Self.stop(registrations)
    }

    private static func stop(_ registrations: [StreamRegistration]) {
        for registration in registrations {
            withExtendedLifetime(registration.context) {
                FSEventStreamStop(registration.stream)
                FSEventStreamInvalidate(registration.stream)
                FSEventStreamRelease(registration.stream)
            }
        }
    }

    deinit {
        self.cancel()
    }
}
#endif
