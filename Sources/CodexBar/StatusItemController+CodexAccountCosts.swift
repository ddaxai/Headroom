import CodexBarCore
import Foundation

extension StatusItemController {
    private func loadPiAgentUsageCardSnapshot(
        now: Date,
        forceRefresh: Bool) async -> PiAgentUsageCardSnapshot?
    {
        let refreshInterval: TimeInterval = forceRefresh
            ? 0
            : PiAgentUsageRefreshCadence.interval(for: self.settings.refreshFrequency) ?? 60
        return await Task.detached(priority: .utility) {
            PiAgentUsageCardLoader.load(
                now: now,
                options: .init(refreshMinIntervalSeconds: refreshInterval))
        }.value
    }

    func refreshPiAgentUsageCardAfterExplicitRefresh(now: Date = Date()) async {
        #if DEBUG
        if SettingsStore.isRunningTests { return }
        #endif
        guard self.settings.piAgentUsageEnabled else {
            self.piAgentUsageRefreshTask?.cancel()
            self.piAgentUsageRefreshTask = nil
            self.piAgentUsageCardSnapshot = nil
            self.piAgentUsageUpdatedAt = nil
            return
        }

        self.piAgentUsageRefreshTask?.cancel()
        self.piAgentUsageRefreshTask = nil
        let snapshot = await self.loadPiAgentUsageCardSnapshot(now: now, forceRefresh: true)
        guard !Task.isCancelled,
              !self.hasPreparedForAppShutdown,
              self.settings.piAgentUsageEnabled
        else {
            return
        }
        self.piAgentUsageCardSnapshot = snapshot
        self.piAgentUsageUpdatedAt = now
    }

    func schedulePiAgentUsageRefreshIfNeeded(now: Date = Date()) {
        guard self.settings.localUsageRefreshMode != .manual else { return }
        guard self.settings.piAgentUsageEnabled else {
            self.piAgentUsageRefreshTask?.cancel()
            self.piAgentUsageRefreshTask = nil
            self.piAgentUsageCardSnapshot = nil
            self.piAgentUsageUpdatedAt = nil
            return
        }
        guard self.piAgentUsageRefreshTask == nil else { return }
        guard PiAgentUsageRefreshCadence.interval(for: self.settings.refreshFrequency) != nil else { return }
        if let updatedAt = self.piAgentUsageUpdatedAt,
           now.timeIntervalSince(updatedAt) < (PiAgentUsageRefreshCadence.interval(
               for: self.settings.refreshFrequency) ?? .infinity)
        {
            return
        }

        self.piAgentUsageRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.loadPiAgentUsageCardSnapshot(now: now, forceRefresh: false)
            guard !Task.isCancelled,
                  !self.hasPreparedForAppShutdown,
                  self.settings.piAgentUsageEnabled
            else {
                self.piAgentUsageRefreshTask = nil
                return
            }
            self.piAgentUsageCardSnapshot = snapshot
            self.piAgentUsageUpdatedAt = now
            self.piAgentUsageRefreshTask = nil
            self.invalidateMenus(
                refreshOpenMenus: true,
                deferOpenParentMenuRebuild: true,
                allowStaleContentDuringDataRefresh: true)
        }
    }

    /// Returns true while the bounded Codex scan still has older rows to catch up.
    @discardableResult
    func refreshCodexMenuCostSnapshotsAfterExplicitRefresh(now: Date = Date()) async -> Bool {
        #if DEBUG
        if let override = self._test_codexMenuCostRefreshOverride {
            await override()
            return false
        }
        if SettingsStore.isRunningTests {
            return false
        }
        #endif

        guard self.settings.costUsageEnabled else { return false }
        // The cache-only menu path can start while startup catch-up is waiting on its first
        // scanner slice. Cancel it before reading the shared cache so one corpus never has two
        // competing menu projections in flight.
        self.codexMenuCostRefreshTask?.cancel()
        self.codexMenuCostRefreshTask = nil
        CodexSessionRouteBootstrap.reconcileCurrentRouteFromConfiguration(at: now)
        let request = SpendDashboardSource.makeCodexRefreshRequest(
            settings: self.settings,
            store: self.store,
            now: now)
        guard !request.codexRequests.isEmpty else { return false }
        let projectionSignature = CodexMenuSpendPlan.projectionSignature(
            self.settings.codexVisibleAccountProjection)
        let plan = CodexMenuSpendPlan(
            generation: 0,
            projectionSignature: projectionSignature,
            requests: request.codexRequests)
        let ownershipRevision = plan.ownershipRevision
            ?? (try? FileCodexSessionOwnershipTimelineStore.default.load().revision)
        let sharedHomePath = plan.sharedCorpusHomePath
        let ownershipTimeline = plan.requests.compactMap(\.sessionOwnershipTimeline).first
        var ledgerPartition: CodexUsageLedgerSnapshotPartition?
        if let sharedHomePath, let ownershipTimeline {
            ledgerPartition = await Task.detached(priority: .utility) {
                CodexUsageLedgerSnapshotPartition.load(
                    now: now,
                    sharedCodexHomePath: sharedHomePath,
                    timeline: ownershipTimeline,
                    historyDays: SpendDashboardSource.scanDays,
                    requireCurrentCorpus: true)
            }.value
        }
        var scannedFullCorpusSnapshot: CostUsageTokenSnapshot?
        if ledgerPartition == nil, let sharedHomePath, let ownershipTimeline {
            scannedFullCorpusSnapshot = try? await SpendDashboardSource.loadFullCorpusCodexSnapshot(
                sharedHomePath: sharedHomePath,
                now: now,
                forceRefresh: true,
                historyDays: SpendDashboardSource.scanDays)
            ledgerPartition = await Task.detached(priority: .utility) {
                CodexUsageLedgerSnapshotPartition.load(
                    now: now,
                    sharedCodexHomePath: sharedHomePath,
                    timeline: ownershipTimeline,
                    historyDays: SpendDashboardSource.scanDays,
                    requireCurrentCorpus: true)
            }.value
        }
        guard !Task.isCancelled,
              !self.hasPreparedForAppShutdown,
              CodexMenuSpendPlan.projectionSignature(self.settings.codexVisibleAccountProjection)
              == projectionSignature,
              (try? FileCodexSessionOwnershipTimelineStore.default.load().revision) == ownershipRevision
        else { return false }

        var snapshotsByAccountID: [String: CostUsageTokenSnapshot] = [:]
        var publishedAccountKeys: Set<String> = []
        for account in plan.requests where account.isHomeReadable {
            if account.usageIdentity.isSystemUnassigned {
                if let unassigned = ledgerPartition?.unassigned {
                    snapshotsByAccountID["system-unassigned:aggregate"] = unassigned
                }
            } else if publishedAccountKeys.insert(account.usageIdentity.accountKey).inserted,
                      let snapshot = ledgerPartition?.officialByAccountKey[account.usageIdentity.accountKey]
            {
                snapshotsByAccountID[account.id] = snapshot
            }
        }
        let relaySnapshots = CodexRelayMenuSnapshots(
            byProfileID: ledgerPartition?.relayByProfileID ?? [:],
            aggregate: ledgerPartition?.relayAggregate)
        let fullCorpusSnapshot = ledgerPartition?.fullCorpus ?? scannedFullCorpusSnapshot
        let completedAnyScan = fullCorpusSnapshot != nil || !snapshotsByAccountID.isEmpty
        guard completedAnyScan else { return false }

        self.codexMenuSpendPlanGeneration &+= 1
        let generation = self.codexMenuSpendPlanGeneration
        self.codexMenuSpendProjectionSignature = projectionSignature
        self.codexMenuSpendOwnershipRevision = ownershipRevision
        self.codexMenuSpendPlan = CodexMenuSpendPlan(
            generation: generation,
            projectionSignature: projectionSignature,
            requests: request.codexRequests)
        let sharedSnapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(
            snapshotsByAccountID.filter { $0.key.hasPrefix("system-unassigned") }.map(\.value))
        let partitionIsConserved = Self.codexMenuPartitionIsConserved(
            fullCorpusSnapshot: fullCorpusSnapshot,
            snapshotsByAccountID: snapshotsByAccountID,
            relayAggregateSnapshot: relaySnapshots.aggregate,
            sharedSnapshot: sharedSnapshot)
        self.codexMenuCostSnapshotsByAccountID = Self.codexMenuAccountSnapshotsAfterRefresh(
            candidates: snapshotsByAccountID,
            lastGood: self.codexMenuCostSnapshotsByAccountID,
            partitionIsConserved: partitionIsConserved)
        if partitionIsConserved {
            FileCodexMenuCostSnapshotStore().store(
                self.codexMenuCostSnapshotsByAccountID,
                for: self.settings.codexVisibleAccountProjection)
        }
        self.codexMenuFullCorpusCostSnapshot = fullCorpusSnapshot ?? self.codexMenuFullCorpusCostSnapshot
        self.codexMenuSharedCostSnapshot = partitionIsConserved ? sharedSnapshot : nil
        self.codexMenuRelayCostSnapshotsByProfileID = Self.relayProfileSnapshotsAfterRefresh(
            candidates: relaySnapshots.byProfileID,
            lastGood: self.codexMenuRelayCostSnapshotsByProfileID,
            partitionIsConserved: partitionIsConserved,
            fullCorpusSnapshot: fullCorpusSnapshot)
        self.codexMenuRelayAggregateCostSnapshot = partitionIsConserved
            ? relaySnapshots.aggregate
            : self.codexMenuRelayAggregateCostSnapshot
        if fullCorpusSnapshot != nil {
            FileCodexMenuCostSnapshotStore().storeRelay(self.codexMenuRelayCostSnapshotsByProfileID)
        }
        self.codexMenuCostUpdatedAt = ([fullCorpusSnapshot?.updatedAt].compactMap(\.self)
            + snapshotsByAccountID.values.map(\.updatedAt))
            .max() ?? now
        // A stale or incomplete partition can be nil even though the fallback full-corpus scan
        // produced a partial snapshot. Preserve the catch-up signal from either source so the
        // realtime runner keeps taking bounded slices until the menu can be partitioned.
        return ledgerPartition?.coverageIsComplete == false
            || scannedFullCorpusSnapshot?.codexCorpusCoverageIsComplete == false
    }

    func invalidateCodexMenuSpendPlanIfProjectionChanged(_ projection: CodexVisibleAccountProjection?) {
        let signature = projection.map(CodexMenuSpendPlan.projectionSignature)
        let ownershipRevision = try? FileCodexSessionOwnershipTimelineStore.default.load().revision
        guard signature != self.codexMenuSpendProjectionSignature ||
            ownershipRevision != self.codexMenuSpendOwnershipRevision
        else { return }

        let routeOnlyInvalidation = projection != nil && signature == self.codexMenuSpendProjectionSignature
        let retainedOfficialSnapshots = if routeOnlyInvalidation && self.codexMenuSpendPlan == nil {
            self.codexMenuCostSnapshotsByAccountID.filter { id, _ in
                !id.hasPrefix("system-unassigned")
            }
        } else {
            Self.retainedOfficialCostSnapshots(
                self.codexMenuCostSnapshotsByAccountID,
                previousPlan: self.codexMenuSpendPlan,
                projection: projection)
        }
        // Route changes invalidate attribution for the next scan, but they do not invalidate a
        // completed relay snapshot that was already published. Keep it visible while the new
        // route boundary is being scanned; otherwise switching API -> official briefly replaces
        // a valid card with "no local usage" even though no new data has been requested yet.
        let retainedRelaySnapshots = routeOnlyInvalidation
            ? self.codexMenuRelayCostSnapshotsByProfileID
            : [:]
        let retainedRelayAggregate = routeOnlyInvalidation
            ? self.codexMenuRelayAggregateCostSnapshot
            : nil
        self.codexMenuSpendPlanGeneration &+= 1
        self.codexMenuCostRefreshTask?.cancel()
        self.codexMenuCostRefreshTask = nil
        self.codexMenuSpendPlan = nil
        self.codexMenuSpendProjectionSignature = signature
        self.codexMenuSpendOwnershipRevision = ownershipRevision
        self.codexMenuCostSnapshotsByAccountID = retainedOfficialSnapshots
        // The full corpus is independent of account and route attribution. Keep it while
        // the official, relay, and unassigned partitions are rebuilt for the new revision.
        self.codexMenuSharedCostSnapshot = nil
        self.codexMenuRelayCostSnapshotsByProfileID = retainedRelaySnapshots
        self.codexMenuRelayAggregateCostSnapshot = retainedRelayAggregate
        self.codexMenuPersistedRelayCostSnapshotProfileIDs = []
        self.codexMenuCostUpdatedAt = nil
    }

    private static func retainedOfficialCostSnapshots(
        _ snapshots: [String: CostUsageTokenSnapshot],
        previousPlan: CodexMenuSpendPlan?,
        projection: CodexVisibleAccountProjection?) -> [String: CostUsageTokenSnapshot]
    {
        guard let previousPlan else { return [:] }
        let previousOwnerByID = Dictionary(
            previousPlan.requests.compactMap { request -> (String, String)? in
                guard !request.usageIdentity.isSystemUnassigned else { return nil }
                return (request.id, request.usageIdentity.accountKey)
            },
            uniquingKeysWith: { first, _ in first })
        let currentOwnerByID = projection.map { projection in
            Dictionary(
                projection.visibleAccounts.map { account in
                    (account.id, UsageIdentity.subscription(account: account).accountKey)
                },
                uniquingKeysWith: { first, _ in first })
        }

        return snapshots.filter { id, _ in
            guard !id.hasPrefix("system-unassigned"),
                  let previousOwner = previousOwnerByID[id]
            else { return false }
            guard let currentOwnerByID else { return true }
            return currentOwnerByID[id] == previousOwner
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func scheduleCodexMenuCostRefreshIfNeeded(renderedProviders: [UsageProvider]) {
        self.schedulePiAgentUsageRefreshIfNeeded()
        let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay
        self.invalidateCodexMenuSpendPlanIfProjectionChanged(projection)
        // Relay cards are keyed by their stable profile IDs and can hydrate independently of
        // the official-account projection. On startup that projection may still be awaiting
        // reconciliation, but persisted API/relay local usage should be visible immediately.
        let relayProfileIDs = Set(
            self.relayQuickSwitchCoordinator.usageCardProfileOptions().map(\.id))
        if self.hydratePersistedCodexRelayMenuCostSnapshotsIfNeeded(profileIDs: relayProfileIDs) {
            self.invalidateMenus()
        }
        guard renderedProviders.contains(.codex), self.settings.costUsageEnabled else { return }
        CodexSessionRouteBootstrap.reconcileCurrentRouteFromConfiguration()
        // A stale projection is revalidated independently. Do not synchronously
        // reconcile it from the cache-only menu path: that can both read a newer
        // identity than the displayed cards and block the projection refresh.
        guard !self.settings.codexAccountMenuProjectionNeedsRevalidation,
              let projection
        else { return }
        if self.hydratePersistedCodexMenuCostSnapshotsIfNeeded(for: projection) {
            self.invalidateMenus()
        }
        guard self.codexMenuCostRefreshTask == nil else { return }

        if let updatedAt = self.codexMenuCostUpdatedAt,
           Date().timeIntervalSince(updatedAt) < UsageDomain.minimumTokenFetchTTL
        {
            return
        }

        self.codexMenuSpendPlanGeneration &+= 1
        let generation = self.codexMenuSpendPlanGeneration
        self.codexMenuCostRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Every early-return path must release the in-flight marker. Otherwise one stale
            // ownership/projection check permanently blocks future menu refreshes until relaunch.
            // The generation guard prevents an older cancelled task from clearing a newer task.
            defer {
                if self.codexMenuSpendPlanGeneration == generation {
                    self.codexMenuCostRefreshTask = nil
                }
            }
            let now = Date()
            let requests = SpendDashboardSource.cachedCodexRequests(
                projection: projection,
                providerName: self.store.metadata(for: .codex).displayName)
            let plan = CodexMenuSpendPlan(
                generation: generation,
                projectionSignature: CodexMenuSpendPlan.projectionSignature(projection),
                requests: requests)
            let ownershipRevision = plan.ownershipRevision
                ?? (try? FileCodexSessionOwnershipTimelineStore.default.load().revision)
            self.codexMenuSpendPlan = plan
            let sharedCorpusHomePath = plan.sharedCorpusHomePath
            let ownershipTimeline = plan.requests.compactMap(\.sessionOwnershipTimeline).first
            // The automatic path must project every card from the same complete corpus as the
            // explicit Refresh path. A relay-only cache is merely a compatibility fallback; it
            // must not erase relay rows that are already present in the full corpus after launch.
            var ledgerPartition: CodexUsageLedgerSnapshotPartition?
            if let sharedCorpusHomePath, let ownershipTimeline {
                ledgerPartition = await Task.detached(priority: .utility) {
                    CodexUsageLedgerSnapshotPartition.load(
                        now: now,
                        sharedCodexHomePath: sharedCorpusHomePath,
                        timeline: ownershipTimeline,
                        historyDays: SpendDashboardSource.scanDays,
                        requireCurrentCorpus: true)
                }.value
            }
            var scannedFullCorpusSnapshot: CostUsageTokenSnapshot?
            if ledgerPartition == nil, let sharedCorpusHomePath, let ownershipTimeline {
                scannedFullCorpusSnapshot = try? await SpendDashboardSource.loadFullCorpusCodexSnapshot(
                    sharedHomePath: sharedCorpusHomePath,
                    now: now,
                    forceRefresh: true,
                    historyDays: SpendDashboardSource.scanDays)
                ledgerPartition = await Task.detached(priority: .utility) {
                    CodexUsageLedgerSnapshotPartition.load(
                        now: now,
                        sharedCodexHomePath: sharedCorpusHomePath,
                        timeline: ownershipTimeline,
                        historyDays: SpendDashboardSource.scanDays,
                        requireCurrentCorpus: true)
                }.value
            }
            let fullCorpusSnapshot = ledgerPartition?.fullCorpus ?? scannedFullCorpusSnapshot
            var snapshots: [String: CostUsageTokenSnapshot] = [:]
            if let ledgerPartition {
                var publishedAccountKeys: Set<String> = []
                for request in plan.requests where request.isHomeReadable {
                    if request.usageIdentity.isSystemUnassigned {
                        if let unassigned = ledgerPartition.unassigned {
                            snapshots["system-unassigned:aggregate"] = unassigned
                        }
                    } else if publishedAccountKeys.insert(request.usageIdentity.accountKey).inserted,
                              let snapshot = ledgerPartition.officialByAccountKey[request.usageIdentity.accountKey]
                    {
                        snapshots[request.id] = snapshot
                    }
                }
            } else {
                // Compatibility fallback for old caches that predate the shared ledger partition.
                for request in plan.requests where request.isHomeReadable {
                    let cacheRoot = UsageDomain.costUsageCacheDirectory()
                        .appendingPathComponent("accounts", isDirectory: true)
                        .appendingPathComponent(request.cacheIdentity, isDirectory: true)
                    let context = CodexSpendSnapshotLoadContext(
                        account: request,
                        cacheRoot: cacheRoot,
                        now: now,
                        force: true,
                        historyDays: SpendDashboardSource.scanDays,
                        refreshPricingInBackground: false,
                        includePiSessions: false)
                    let snapshot = await SpendDashboardSource.loadCachedOrScanFullCorpusSnapshot(
                        cachedLoader: {
                            if let sharedHomePath = request.sharedHomePath,
                               let timeline = request.sessionOwnershipTimeline
                            {
                                return await CostUsageFetcher(
                                    cacheRoot: cacheRoot.appendingPathComponent("shared", isDirectory: true))
                                    .loadCachedAttributedSharedCodexTokenSnapshot(
                                        now: now,
                                        sharedCodexHomePath: sharedHomePath,
                                        usageIdentity: request.usageIdentity,
                                        timeline: timeline,
                                        historyDays: SpendDashboardSource.scanDays)
                            }
                            return await CostUsageFetcher(cacheRoot: cacheRoot).loadCachedCodexTokenSnapshot(
                                now: now,
                                codexHomePath: request.homePath,
                                usageIdentity: request.usageIdentity,
                                historyDays: SpendDashboardSource.scanDays,
                                includePiSessions: false)
                        },
                        scanner: {
                            try await SpendDashboardSource.loadCodexMenuPartitionSnapshot(context)
                        })
                    let tracked = SpendDashboardSource.snapshotsWithTrackedUsage([snapshot].compactMap(\.self))
                    if let snapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(tracked) {
                        snapshots[request.id] = snapshot
                    }
                }
            }
            let legacyRelaySnapshots = if ledgerPartition == nil,
                                          let sharedCorpusHomePath,
                                          let ownershipTimeline
            {
                await self.loadCachedCodexRelayMenuSnapshots(
                    sharedHomePath: sharedCorpusHomePath,
                    timeline: ownershipTimeline,
                    now: now)
            } else {
                CodexRelayMenuSnapshots()
            }
            let relaySnapshots = CodexRelayMenuSnapshots.preferred(
                ledgerPartition: ledgerPartition,
                legacy: legacyRelaySnapshots)
            guard !Task.isCancelled,
                  self.codexMenuSpendPlanGeneration == generation,
                  self.codexMenuSpendPlan == plan,
                  plan.isCurrent(
                      generation: self.codexMenuSpendPlanGeneration,
                      projection: self.settings.codexVisibleAccountProjectionForMenuDisplay),
                  (try? FileCodexSessionOwnershipTimelineStore.default.load().revision) == ownershipRevision
            else { return }
            // Attribution scans above use the captured plan and publish only after the ownership
            // revision and projection generation are revalidated below.
            let sharedSnapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(
                snapshots.filter { $0.key.hasPrefix("system-unassigned:") }.map(\.value))
            let partitionIsConserved = Self.codexMenuPartitionIsConserved(
                fullCorpusSnapshot: fullCorpusSnapshot,
                snapshotsByAccountID: snapshots,
                relayAggregateSnapshot: relaySnapshots.aggregate,
                sharedSnapshot: sharedSnapshot)
            self.codexMenuCostSnapshotsByAccountID = Self.codexMenuAccountSnapshotsAfterRefresh(
                candidates: snapshots,
                lastGood: self.codexMenuCostSnapshotsByAccountID,
                partitionIsConserved: partitionIsConserved)
            if partitionIsConserved {
                FileCodexMenuCostSnapshotStore().store(
                    self.codexMenuCostSnapshotsByAccountID,
                    for: projection)
            }
            self.codexMenuFullCorpusCostSnapshot = fullCorpusSnapshot ?? self.codexMenuFullCorpusCostSnapshot
            self.codexMenuSharedCostSnapshot = partitionIsConserved ? sharedSnapshot : nil
            self.codexMenuRelayCostSnapshotsByProfileID = Self.relayProfileSnapshotsAfterRefresh(
                candidates: relaySnapshots.byProfileID,
                lastGood: self.codexMenuRelayCostSnapshotsByProfileID,
                partitionIsConserved: partitionIsConserved,
                fullCorpusSnapshot: fullCorpusSnapshot)
            self.codexMenuRelayAggregateCostSnapshot = partitionIsConserved
                ? relaySnapshots.aggregate
                : self.codexMenuRelayAggregateCostSnapshot
            if fullCorpusSnapshot != nil {
                FileCodexMenuCostSnapshotStore().storeRelay(self.codexMenuRelayCostSnapshotsByProfileID)
            }
            self.codexMenuSpendOwnershipRevision = ownershipRevision
            self.codexMenuCostUpdatedAt = now
            self.invalidateMenus(
                refreshOpenMenus: true,
                deferOpenParentMenuRebuild: true,
                allowStaleContentDuringDataRefresh: true)
        }
    }

    @discardableResult
    func hydratePersistedCodexMenuCostSnapshotsIfNeeded(
        for projection: CodexVisibleAccountProjection,
        store: FileCodexMenuCostSnapshotStore = FileCodexMenuCostSnapshotStore()) -> Bool
    {
        let signature = CodexMenuSpendPlan.projectionSignature(projection)
        guard signature != self.codexMenuPersistedCostSnapshotProjectionSignature else { return false }
        self.codexMenuPersistedCostSnapshotProjectionSignature = signature
        let persisted = store.load(for: projection)
        guard !persisted.isEmpty else { return false }
        var didHydrate = false
        for (accountID, snapshot) in persisted where self.codexMenuCostSnapshotsByAccountID[accountID] == nil {
            self.codexMenuCostSnapshotsByAccountID[accountID] = snapshot
            didHydrate = true
        }
        if didHydrate, self.codexMenuCostUpdatedAt == nil {
            self.codexMenuCostUpdatedAt = persisted.values.map(\.updatedAt).max()
        }
        return didHydrate
    }

    @discardableResult
    func hydratePersistedCodexRelayMenuCostSnapshotsIfNeeded(
        profileIDs: Set<UUID>,
        store: FileCodexMenuCostSnapshotStore = FileCodexMenuCostSnapshotStore()) -> Bool
    {
        guard !profileIDs.isEmpty,
              profileIDs != self.codexMenuPersistedRelayCostSnapshotProfileIDs
        else { return false }
        self.codexMenuPersistedRelayCostSnapshotProfileIDs = profileIDs
        let persisted = store.loadRelay(profileIDs: profileIDs)
        var didHydrate = false
        for (profileID, snapshot) in persisted
            where self.codexMenuRelayCostSnapshotsByProfileID[profileID] == nil
        {
            self.codexMenuRelayCostSnapshotsByProfileID[profileID] = snapshot
            didHydrate = true
        }
        if didHydrate, self.codexMenuCostUpdatedAt == nil {
            self.codexMenuCostUpdatedAt = persisted.values.map(\.updatedAt).max()
        }
        return didHydrate
    }

    private func loadCachedCodexRelayMenuSnapshots(
        sharedHomePath: String,
        timeline: CodexSessionOwnershipTimeline,
        now: Date) async -> CodexRelayMenuSnapshots
    {
        let cacheRoot = UsageDomain.costUsageCacheDirectory().appendingPathComponent("relay", isDirectory: true)
        return await CodexRelayMenuSnapshots.loadConcurrently(
            profileIDs: timeline.codexRelayProfileIDs,
            loadAggregate: {
                await CostUsageFetcher(
                    cacheRoot: cacheRoot.appendingPathComponent("aggregate", isDirectory: true))
                    .loadCachedRelaySharedCodexTokenSnapshot(
                        now: now,
                        sharedCodexHomePath: sharedHomePath,
                        profileID: nil,
                        timeline: timeline,
                        historyDays: SpendDashboardSource.scanDays)
            },
            loadProfile: { profileID in
                await CostUsageFetcher(
                    cacheRoot: cacheRoot.appendingPathComponent(
                        profileID.uuidString.lowercased(),
                        isDirectory: true))
                    .loadCachedRelaySharedCodexTokenSnapshot(
                        now: now,
                        sharedCodexHomePath: sharedHomePath,
                        profileID: profileID,
                        timeline: timeline,
                        historyDays: SpendDashboardSource.scanDays)
            })
    }

    private static func codexMenuPartitionIsConserved(
        fullCorpusSnapshot: CostUsageTokenSnapshot?,
        snapshotsByAccountID: [String: CostUsageTokenSnapshot],
        relayAggregateSnapshot: CostUsageTokenSnapshot?,
        sharedSnapshot: CostUsageTokenSnapshot?) -> Bool
    {
        guard let fullCorpusSnapshot else { return false }
        let officialSnapshots = snapshotsByAccountID.compactMap { element -> CostUsageTokenSnapshot? in
            let (key, snapshot) = element
            return key.hasPrefix("system-unassigned") ? nil : snapshot
        }
        return CodexStackedUsageSummary.isPublishableMenuPartition(
            fullCorpusSnapshot: fullCorpusSnapshot,
            officialSnapshots: officialSnapshots,
            relaySnapshot: relayAggregateSnapshot,
            unassignedSnapshot: sharedSnapshot)
    }

    static func codexMenuAccountSnapshotsAfterRefresh(
        candidates: [String: CostUsageTokenSnapshot],
        lastGood: [String: CostUsageTokenSnapshot],
        partitionIsConserved: Bool) -> [String: CostUsageTokenSnapshot]
    {
        partitionIsConserved ? candidates : lastGood
    }

    static func relayProfileSnapshotsAfterRefresh(
        candidates: [UUID: CostUsageTokenSnapshot],
        lastGood: [UUID: CostUsageTokenSnapshot],
        partitionIsConserved: Bool,
        fullCorpusSnapshot: CostUsageTokenSnapshot?) -> [UUID: CostUsageTokenSnapshot]
    {
        guard fullCorpusSnapshot != nil else { return lastGood }
        return partitionIsConserved || !candidates.isEmpty ? candidates : lastGood
    }

    static func currentRelayProfileSnapshots(
        _ snapshots: [UUID: CostUsageTokenSnapshot],
        fullCorpusSnapshot: CostUsageTokenSnapshot?) -> [UUID: CostUsageTokenSnapshot]
    {
        guard let fullCorpusSnapshot else { return [:] }
        // The caller has already proven that the full menu partition is conserved. A partial
        // corpus is a supported catch-up state, so do not apply the older complete-generation
        // gate to each profile and erase otherwise valid local history.
        _ = fullCorpusSnapshot
        return snapshots
    }
}

struct CodexRelayMenuSnapshots: Sendable, Equatable {
    var byProfileID: [UUID: CostUsageTokenSnapshot] = [:]
    var aggregate: CostUsageTokenSnapshot?

    static func preferred(
        ledgerPartition: CodexUsageLedgerSnapshotPartition?,
        legacy: Self) -> Self
    {
        guard let ledgerPartition else { return legacy }
        return Self(
            byProfileID: ledgerPartition.relayByProfileID,
            aggregate: ledgerPartition.relayAggregate)
    }

    static func loadConcurrently(
        profileIDs: Set<UUID>,
        loadAggregate: @escaping @Sendable () async -> CostUsageTokenSnapshot?,
        loadProfile: @escaping @Sendable (UUID) async -> CostUsageTokenSnapshot?) async -> Self
    {
        await withTaskGroup(of: (UUID?, CostUsageTokenSnapshot?).self) { group in
            group.addTask {
                await (nil, loadAggregate())
            }
            for profileID in profileIDs {
                group.addTask {
                    await (profileID, loadProfile(profileID))
                }
            }

            var aggregate: CostUsageTokenSnapshot?
            var byProfileID: [UUID: CostUsageTokenSnapshot] = [:]
            for await (profileID, snapshot) in group {
                guard let snapshot else { continue }
                if let profileID {
                    byProfileID[profileID] = snapshot
                } else {
                    aggregate = snapshot
                }
            }
            return Self(byProfileID: byProfileID, aggregate: aggregate)
        }
    }
}
