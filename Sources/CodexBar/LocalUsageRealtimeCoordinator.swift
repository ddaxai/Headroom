import CodexBarCore
import Foundation

@MainActor
final class LocalUsageRealtimeCoordinator {
    typealias RefreshAction = @MainActor @Sendable (Set<LocalUsageRefreshSource>) async -> Void

    private let settings: SettingsStore
    private let roots: [LocalUsageWatchRoot]
    private let debouncer: LocalUsageRefreshDebouncer
    private var watcher: LocalUsageDirectoryWatcher?
    private var startupCatchUpTask: Task<Void, Never>?
    private var hasScheduledStartupCatchUp = false

    init(
        settings: SettingsStore,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheDirectory: URL = UsageStore.costUsageCacheDirectory(),
        debounceDelay: Duration = .seconds(2),
        refresh: @escaping RefreshAction)
    {
        self.settings = settings
        self.roots = LocalUsageWatchPlan.roots(
            environment: environment,
            homeDirectory: homeDirectory,
            cacheDirectory: cacheDirectory)
        self.debouncer = LocalUsageRefreshDebouncer(delay: debounceDelay, action: refresh)
    }

    func restart() {
        if self.settings.localUsageRefreshMode == .realtime, self.watcher != nil {
            return
        }
        self.watcher?.cancel()
        self.watcher = nil
        self.startupCatchUpTask?.cancel()
        self.startupCatchUpTask = nil
        Task { await self.debouncer.cancel() }

        guard self.settings.localUsageRefreshMode == .realtime else {
            self.hasScheduledStartupCatchUp = false
            self.settings.localUsageRealtimeStatus = .inactive
            return
        }

        let debouncer = self.debouncer
        do {
            let watcher = try LocalUsageDirectoryWatcher(roots: self.roots) { source in
                Task { await debouncer.submit(source) }
            }
            self.watcher = watcher
            self.settings.localUsageRealtimeStatus = .watching(directoryCount: watcher.watchedRoots.count)
            if !self.hasScheduledStartupCatchUp {
                self.hasScheduledStartupCatchUp = true
                let sources = Set(watcher.watchedRoots.map(\.source))
                let debouncer = self.debouncer
                self.startupCatchUpTask = Task {
                    for source in sources where !Task.isCancelled {
                        await debouncer.submit(source)
                    }
                }
            }
        } catch {
            self.settings.localUsageRealtimeStatus = .scheduledFallback
        }
    }

    func stop() {
        self.watcher?.cancel()
        self.watcher = nil
        self.startupCatchUpTask?.cancel()
        self.startupCatchUpTask = nil
        self.hasScheduledStartupCatchUp = false
        Task { await self.debouncer.cancel() }
        self.settings.localUsageRealtimeStatus = .inactive
    }
}

extension StatusItemController {
    func startLocalUsageRealtimeRefresh() {
        guard !SettingsStore.isRunningTests else { return }
        if self.localUsageRealtimeCoordinator == nil {
            self.localUsageRealtimeCoordinator = LocalUsageRealtimeCoordinator(settings: self.settings) {
                [weak self] sources in
                guard let self, !self.hasPreparedForAppShutdown else { return }
                if sources.contains(.codex) {
                    await LocalUsageCatchUpRunner.run {
                        await self.store.refreshTokenUsageNow(for: .codex, force: true)
                        let needsCatchUp = await self.refreshCodexMenuCostSnapshotsAfterExplicitRefresh()
                        self.invalidateMenus(
                            refreshOpenMenus: true,
                            deferOpenParentMenuRebuild: true,
                            allowStaleContentDuringDataRefresh: true)
                        return needsCatchUp
                    }
                }
                if sources.contains(.openCode) {
                    await self.store.refreshTokenUsageNow(for: .opencode, force: true)
                }
                if sources.contains(.pi) {
                    await self.refreshPiAgentUsageCardAfterExplicitRefresh()
                }
                let speedSources = Set(sources.map { source -> LocalAgentSpeedSource in
                    switch source {
                    case .codex: .codex
                    case .claude: .claude
                    case .antigravity: .antigravity
                    case .pi: .pi
                    case .openCode: .openCode
                    }
                })
                if !speedSources.isEmpty {
                    await self.refreshLocalAgentSpeedReport(sources: speedSources)
                }
                self.invalidateMenus(
                    refreshOpenMenus: true,
                    deferOpenParentMenuRebuild: true,
                    allowStaleContentDuringDataRefresh: true)
            }
        }
        self.localUsageRealtimeCoordinator?.restart()
    }
}
