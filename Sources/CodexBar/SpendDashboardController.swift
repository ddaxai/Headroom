import CodexBarCore
import CryptoKit
import Foundation
import Observation

struct SpendDashboardConfiguration: Equatable, Sendable {
    let costUsageEnabled: Bool
    let preferredCurrencyCode: String
    let providerIDs: [String]
    let codexAccountIdentities: [String]
    let codexAccountDisplayNames: [String: String]
    let sourceOwnershipFingerprints: [String]
    let sourceRevisions: [String]

    init(
        costUsageEnabled: Bool,
        preferredCurrencyCode: String = "auto",
        providerIDs: [String],
        codexAccountIdentities: [String],
        codexAccountDisplayNames: [String: String] = [:],
        sourceOwnershipFingerprints: [String] = [],
        sourceRevisions: [String] = [])
    {
        self.costUsageEnabled = costUsageEnabled
        self.preferredCurrencyCode = preferredCurrencyCode
        self.providerIDs = providerIDs
        self.codexAccountIdentities = codexAccountIdentities
        self.codexAccountDisplayNames = codexAccountDisplayNames
        self.sourceOwnershipFingerprints = sourceOwnershipFingerprints
        self.sourceRevisions = sourceRevisions
    }
}

enum SpendDashboardRequestBuildMode: Equatable, Sendable {
    case refreshMissing
    case forceRefresh
    case captureOnly

    var forcesLoader: Bool {
        self == .forceRefresh
    }

    func shouldRefresh(hasPublication: Bool) -> Bool {
        switch self {
        case .refreshMissing: !hasPublication
        case .forceRefresh: true
        case .captureOnly: false
        }
    }
}

struct SpendDashboardLoadRequest: Sendable {
    let configuration: SpendDashboardConfiguration
    let capturedInputs: [SpendDashboardModel.ProviderInput]
    let unavailableSourceIDs: Set<String>
    let confirmedEmptySourceIDs: Set<String>
    let codexRequests: [CodexSpendScanRequest]
    let now: Date
    let force: Bool

    init(
        configuration: SpendDashboardConfiguration,
        capturedInputs: [SpendDashboardModel.ProviderInput],
        unavailableSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String> = [],
        codexRequests: [CodexSpendScanRequest],
        now: Date,
        force: Bool)
    {
        self.configuration = configuration
        self.capturedInputs = capturedInputs
        self.unavailableSourceIDs = unavailableSourceIDs
        self.confirmedEmptySourceIDs = confirmedEmptySourceIDs
        self.codexRequests = codexRequests
        self.now = now
        self.force = force
    }
}

struct SpendDashboardLoadResult: Sendable {
    let inputs: [SpendDashboardModel.ProviderInput]
    let failedSourceIDs: Set<String>
    let invalidatedSourceIDs: Set<String>

    init(
        inputs: [SpendDashboardModel.ProviderInput],
        failedSourceIDs: Set<String>,
        invalidatedSourceIDs: Set<String> = [])
    {
        self.inputs = inputs
        self.failedSourceIDs = failedSourceIDs
        self.invalidatedSourceIDs = invalidatedSourceIDs
    }

    var failedSourceCount: Int {
        self.failedSourceIDs.count
    }
}

struct CodexSpendSnapshotLoadContext: Sendable {
    let account: CodexSpendScanRequest
    let cacheRoot: URL
    let now: Date
    let force: Bool
    let historyDays: Int
    let refreshPricingInBackground: Bool
    let includePiSessions: Bool
}

// swiftlint:disable:next type_body_length
enum SpendDashboardSource {
    typealias CodexSnapshotLoader = @Sendable (CodexSpendSnapshotLoadContext) async throws
        -> CostUsageTokenSnapshot
    typealias CachedFullCorpusLoader = @Sendable () async -> CostUsageTokenSnapshot?
    typealias FullCorpusScanner = @Sendable () async throws -> CostUsageTokenSnapshot

    static let scanDays = 30
    static let systemUnassignedAggregateSourceID = "codex:system-unassigned"

    @MainActor
    static func configuration(settings: SettingsStore, store: UsageDomain) -> SpendDashboardConfiguration {
        let providers = self.costCapableProviders(store: store)
        let codexRequests = providers.contains(.codex)
            ? self.codexRequests(settings: settings, store: store)
            : []
        return self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexRequests: codexRequests)
    }

    @MainActor
    private static func configuration(
        settings: SettingsStore,
        store: UsageDomain,
        providers: [UsageProvider],
        codexRequests: [CodexSpendScanRequest]) -> SpendDashboardConfiguration
    {
        SpendDashboardConfiguration(
            costUsageEnabled: settings.costUsageEnabled,
            preferredCurrencyCode: settings.preferredCurrencyCode,
            providerIDs: providers.map(\.rawValue),
            codexAccountIdentities: codexRequests.map {
                "\($0.id)|\($0.cacheIdentity)|\($0.sharedHomePath ?? "")|" +
                    ($0.sessionOwnershipTimeline?.revision ?? "untracked")
            },
            codexAccountDisplayNames: self.codexDisplayNamesByID(codexRequests),
            sourceOwnershipFingerprints: self.sourceOwnershipFingerprints(
                providers: providers,
                settings: settings,
                store: store),
            sourceRevisions: self.sourceRevisions(providers: providers, settings: settings, store: store))
    }

    @MainActor
    static func makeRequest(
        settings: SettingsStore,
        store: UsageDomain,
        mode: SpendDashboardRequestBuildMode,
        now: Date? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }) async -> SpendDashboardLoadRequest
    {
        guard settings.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: self.configuration(settings: settings, store: store),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: now ?? nowProvider(),
                force: mode.forcesLoader)
        }

        let initialProviders = self.costCapableProviders(store: store)
        let providerBaselines = initialProviders.filter { $0 != .codex }.map { provider in
            (
                provider: provider,
                publication: store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider),
                publicationRevision: store.tokenSnapshotPublicationRevision(for: provider))
        }
        for baseline in providerBaselines where mode.shouldRefresh(hasPublication: baseline.publication != nil) {
            if UsageDomain.tokenCostRequiresProviderSnapshot(baseline.provider) {
                await store.refreshProvider(baseline.provider)
            } else {
                await store.refreshTokenUsageNow(for: baseline.provider, force: true)
            }
        }

        // A later provider refresh can suspend while an earlier provider publishes again.
        // Capture every provider only after all refresh work finishes so the request owns the
        // newest same-scope publication available at this boundary.
        let captureNow = now ?? nowProvider()
        let providers = self.costCapableProviders(store: store)
        if providers.contains(.codex) {
            CodexSessionOwnershipBootstrap.seedAtLaunch(settings: settings, at: captureNow)
        }
        let codexRequests = providers.contains(.codex)
            ? self.codexRequests(settings: settings, store: store)
            : []
        let configuration = self.configuration(
            settings: settings,
            store: store,
            providers: providers,
            codexRequests: codexRequests)
        guard configuration.costUsageEnabled else {
            return SpendDashboardLoadRequest(
                configuration: configuration,
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: captureNow,
                force: mode.forcesLoader)
        }

        var inputs: [SpendDashboardModel.ProviderInput] = []
        var unavailableSourceIDs: Set<String> = []
        var confirmedEmptySourceIDs: Set<String> = []
        for provider in providers where provider != .codex {
            guard let baseline = providerBaselines.first(where: { $0.provider == provider }) else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            let shouldRefresh = mode.shouldRefresh(hasPublication: baseline.publication != nil)
            let current = store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
            guard let current else {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            if shouldRefresh, baseline.publicationRevision == current.publicationRevision {
                unavailableSourceIDs.insert(provider.rawValue)
                continue
            }
            guard let snapshot = current.snapshot else {
                confirmedEmptySourceIDs.insert(provider.rawValue)
                continue
            }
            inputs.append(SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: store.metadata(for: provider).displayName,
                snapshot: snapshot))
        }
        return SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: inputs,
            unavailableSourceIDs: unavailableSourceIDs,
            confirmedEmptySourceIDs: confirmedEmptySourceIDs,
            codexRequests: codexRequests,
            now: captureNow,
            force: mode.forcesLoader)
    }

    @MainActor
    static func makeCodexRefreshRequest(
        settings: SettingsStore,
        store: UsageDomain,
        now: Date = Date()) -> SpendDashboardLoadRequest
    {
        guard settings.costUsageEnabled,
              self.costCapableProviders(store: store).contains(.codex)
        else {
            return SpendDashboardLoadRequest(
                configuration: SpendDashboardConfiguration(
                    costUsageEnabled: settings.costUsageEnabled,
                    preferredCurrencyCode: settings.preferredCurrencyCode,
                    providerIDs: [],
                    codexAccountIdentities: []),
                capturedInputs: [],
                unavailableSourceIDs: [],
                codexRequests: [],
                now: now,
                force: true)
        }

        CodexSessionOwnershipBootstrap.seedAtLaunch(settings: settings, at: now)
        let requests = self.codexRequests(settings: settings, store: store)
        let configuration = self.configuration(
            settings: settings,
            store: store,
            providers: [.codex],
            codexRequests: requests)
        return SpendDashboardLoadRequest(
            configuration: configuration,
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: requests,
            now: now,
            force: true)
    }

    static func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        await self.load(request, codexSnapshotLoader: { context in
            try await self.loadCodexSnapshot(context)
        })
    }

    static func load(
        _ request: SpendDashboardLoadRequest,
        codexSnapshotLoader: CodexSnapshotLoader) async -> SpendDashboardLoadResult
    {
        var inputs = request.capturedInputs
        var failedSourceIDs = request.unavailableSourceIDs
        var invalidatedSourceIDs: Set<String> = []
        for account in request.codexRequests {
            let sourceID = "codex:\(account.id)"
            do {
                guard account.isHomeReadable else {
                    failedSourceIDs.insert(sourceID)
                    continue
                }
                guard account.usageIdentity.isSystemUnassigned ||
                    self.currentAuthFingerprint(for: account) == account.authFingerprint
                else {
                    failedSourceIDs.insert(sourceID)
                    invalidatedSourceIDs.insert(sourceID)
                    continue
                }
                let cacheRoot = UsageDomain.costUsageCacheDirectory()
                    .appendingPathComponent("accounts", isDirectory: true)
                    .appendingPathComponent(account.cacheIdentity, isDirectory: true)
                let snapshot = try await codexSnapshotLoader(CodexSpendSnapshotLoadContext(
                    account: account,
                    cacheRoot: cacheRoot,
                    now: request.now,
                    force: request.force,
                    historyDays: Self.scanDays,
                    refreshPricingInBackground: false,
                    includePiSessions: false))
                try Task.checkCancellation()
                guard account.usageIdentity.isSystemUnassigned ||
                    self.currentAuthFingerprint(for: account) == account.authFingerprint
                else {
                    failedSourceIDs.insert(sourceID)
                    invalidatedSourceIDs.insert(sourceID)
                    continue
                }
                inputs.append(SpendDashboardModel.ProviderInput(
                    id: sourceID,
                    provider: .codex,
                    displayName: account.displayName,
                    modelProviderName: ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName,
                    snapshot: snapshot,
                    accountDiagnostic: account.diagnostic(lastScanAt: snapshot.updatedAt)))
            } catch is CancellationError {
                failedSourceIDs.formUnion(request.codexRequests.map { "codex:\($0.id)" })
                return SpendDashboardLoadResult(
                    inputs: [],
                    failedSourceIDs: failedSourceIDs,
                    invalidatedSourceIDs: invalidatedSourceIDs)
            } catch {
                failedSourceIDs.insert(sourceID)
            }
        }
        let lateInvalidatedSourceIDs = Set(request.codexRequests.compactMap { account in
            account.usageIdentity.isSystemUnassigned ||
                self.currentAuthFingerprint(for: account) == account.authFingerprint
                ? nil
                : "codex:\(account.id)"
        })
        failedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        invalidatedSourceIDs.formUnion(lateInvalidatedSourceIDs)
        inputs.removeAll { lateInvalidatedSourceIDs.contains($0.id) }
        inputs = self.aggregateSystemUnassignedInputs(inputs)
        return SpendDashboardLoadResult(
            inputs: inputs,
            failedSourceIDs: failedSourceIDs,
            invalidatedSourceIDs: invalidatedSourceIDs)
    }

    /// Each ambient home has its own cache and failure status, but the dashboard
    /// presents their retained history as one System / Unassigned row. This is
    /// deliberately after per-home loading so one unreadable home does not hide
    /// successful history from another home.
    static func aggregateSystemUnassignedInputs(
        _ inputs: [SpendDashboardModel.ProviderInput]) -> [SpendDashboardModel.ProviderInput]
    {
        let systemInputs = inputs.filter {
            $0.provider == .codex &&
                $0.accountDiagnostic?.accountKey == UsageIdentity.systemUnassignedAccountKey
        }
        guard !systemInputs.isEmpty,
              let snapshot = CodexStackedUsageSummary.mergedUnassignedSnapshot(systemInputs.map(\.snapshot))
        else { return inputs }

        let diagnostics = systemInputs.compactMap(\.accountDiagnostic)
        let homes = diagnostics.map(\.codexHome).sorted()
        let firstInput = systemInputs[0]
        let diagnostic = SpendDashboardAccountDiagnostic(
            accountKey: UsageIdentity.systemUnassignedAccountKey,
            email: nil,
            workspaceAccountID: nil,
            authFingerprint: nil,
            codexHome: homes.joined(separator: "\n"),
            lastScanAt: diagnostics.compactMap(\.lastScanAt).min(),
            sidecarFingerprint: diagnostics.map(\.sidecarFingerprint).sorted().joined(separator: ","),
            duplicateAccountKeys: [],
            storedAccountID: nil,
            canRemove: false)
        let merged = SpendDashboardModel.ProviderInput(
            id: self.systemUnassignedAggregateSourceID,
            provider: .codex,
            displayName: firstInput.displayName,
            modelProviderName: firstInput.modelProviderName,
            snapshot: snapshot,
            accountDiagnostic: diagnostic)
        guard let firstIndex = inputs.firstIndex(where: { input in
            input.provider == .codex &&
                input.accountDiagnostic?.accountKey == UsageIdentity.systemUnassignedAccountKey
        }) else { return inputs }
        var result = inputs.filter { input in
            !(input.provider == .codex &&
                input.accountDiagnostic?.accountKey == UsageIdentity.systemUnassignedAccountKey)
        }
        result.insert(merged, at: min(firstIndex, result.count))
        return result
    }

    static func loadCodexSnapshot(
        _ context: CodexSpendSnapshotLoadContext,
        publishFullCorpus: Bool = true) async throws -> CostUsageTokenSnapshot
    {
        if let sharedHomePath = context.account.sharedHomePath,
           let timeline = context.account.sessionOwnershipTimeline
        {
            if publishFullCorpus, context.account.usageIdentity.isSystemUnassigned {
                _ = try await self.loadFullCorpusCodexSnapshot(
                    sharedHomePath: sharedHomePath,
                    now: context.now,
                    forceRefresh: context.force,
                    historyDays: context.historyDays)
            }
            let sharedSnapshot = try await CostUsageFetcher(
                cacheRoot: context.cacheRoot.appendingPathComponent("shared", isDirectory: true))
                .loadAttributedSharedCodexTokenSnapshot(
                    now: context.now,
                    sharedCodexHomePath: sharedHomePath,
                    usageIdentity: context.account.usageIdentity,
                    timeline: timeline,
                    historyDays: context.historyDays,
                    forceRefresh: context.force)
            if context.account.usageIdentity.isSystemUnassigned ||
                context.account.scansSharedHomeOnly
            {
                return sharedSnapshot
            }
            let directSnapshot = try await self.loadDirectCodexSnapshot(context)
            return CodexStackedUsageSummary.mergedUnassignedSnapshot(
                self.snapshotsWithTrackedUsage([directSnapshot, sharedSnapshot])) ?? directSnapshot
        }
        return try await self.loadDirectCodexSnapshot(context)
    }

    /// Menu cards are a partition of one ambient corpus. Unlike Usage & Spend,
    /// they must not merge isolated managed-home history into the shared rows.
    static func loadCodexMenuPartitionSnapshot(
        _ context: CodexSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot
    {
        guard let sharedHomePath = context.account.sharedHomePath,
              let timeline = context.account.sessionOwnershipTimeline
        else { return try await self.loadDirectCodexSnapshot(context) }
        return try await CostUsageFetcher(
            cacheRoot: context.cacheRoot.appendingPathComponent("shared", isDirectory: true))
            .loadAttributedSharedCodexTokenSnapshot(
                now: context.now,
                sharedCodexHomePath: sharedHomePath,
                usageIdentity: context.account.usageIdentity,
                timeline: timeline,
                historyDays: context.historyDays,
                forceRefresh: context.force)
    }

    /// Publishes one projection-independent cache for the complete ambient rollout corpus.
    /// Account-specific scans use separate caches and ownership filters.
    static func loadFullCorpusCodexSnapshot(
        sharedHomePath: String,
        now: Date,
        forceRefresh: Bool,
        historyDays: Int,
        cacheRoot: URL? = nil) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher(cacheRoot: cacheRoot).loadTokenSnapshot(
            provider: .codex,
            environment: CodexHomeScope.scopedEnvironment(base: [:], codexHome: sharedHomePath),
            now: now,
            forceRefresh: forceRefresh,
            codexHomePath: sharedHomePath,
            usageIdentity: nil,
            historyDays: historyDays,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false)
    }

    static func loadCachedOrScanFullCorpusSnapshot(
        cachedLoader: CachedFullCorpusLoader,
        scanner: FullCorpusScanner) async -> CostUsageTokenSnapshot?
    {
        if let cached = await cachedLoader(), cached.codexCorpusCoverageIsComplete != false {
            return cached
        }
        return try? await scanner()
    }

    private static func loadDirectCodexSnapshot(
        _ context: CodexSpendSnapshotLoadContext) async throws -> CostUsageTokenSnapshot
    {
        try await CostUsageFetcher(cacheRoot: context.cacheRoot).loadTokenSnapshot(
            provider: .codex,
            environment: CodexHomeScope.scopedEnvironment(base: [:], codexHome: context.account.homePath),
            now: context.now,
            forceRefresh: context.force,
            codexHomePath: context.account.homePath,
            usageIdentity: context.account.usageIdentity,
            historyDays: context.historyDays,
            refreshPricingInBackground: context.refreshPricingInBackground,
            includePiSessions: context.includePiSessions)
    }

    static func snapshotsWithTrackedUsage(
        _ snapshots: [CostUsageTokenSnapshot]) -> [CostUsageTokenSnapshot]
    {
        let tracked = snapshots.filter { snapshot in
            !snapshot.daily.isEmpty || !snapshot.projects.isEmpty || !snapshot.sessions.isEmpty ||
                snapshot.last30DaysTokens != nil || snapshot.last30DaysCostUSD != nil ||
                snapshot.last30DaysRequests != nil
        }
        return tracked.isEmpty ? Array(snapshots.prefix(1)) : tracked
    }

    @MainActor
    static func costCapableProviders(store: UsageDomain) -> [UsageProvider] {
        store.enabledProvidersForDisplay().filter {
            ProviderDescriptorRegistry.descriptor(for: $0).tokenCost.supportsTokenCost &&
                !$0.reportsTokensWithoutCost
        }
    }

    @MainActor
    static func codexRequests(settings: SettingsStore, store: UsageDomain) -> [CodexSpendScanRequest] {
        let accounts = settings.codexVisibleAccountProjection.visibleAccounts
        let providerName = store.metadata(for: .codex).displayName
        var candidates: [(source: AccountSessionSource, request: CodexSpendScanRequest)] = []
        var sharedLiveHomePath: String?
        for (index, account) in accounts.enumerated() {
            switch account.selectionSource {
            case .liveSystem:
                // The ambient home can contain sessions from prior logins. It is
                // intentionally not assigned to whichever account is active now.
                if let storedAccountID = account.storedAccountID {
                    let managedHome = settings.managedCodexRemoteHomePath(
                        forActiveSource: .managedAccount(id: storedAccountID))
                    let identity = UsageIdentity.subscription(
                        account: account,
                        localHomePath: managedHome)
                    let request = self.codexRequest(
                        account: account,
                        homePath: managedHome,
                        providerName: providerName,
                        index: index,
                        count: accounts.count,
                        sourceOverride: .managedAccount(id: storedAccountID),
                        usageIdentity: identity,
                        retainUnavailable: true)
                    guard let request else { continue }
                    candidates.append((
                        AccountSessionSource(
                            codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                            attribution: .assigned(identity)),
                        request))
                }
                if let ambientHome = settings.liveSystemCodexHomePath(forActiveSource: .liveSystem) {
                    sharedLiveHomePath = ambientHome
                    let request = self.systemUnassignedRequest(homePath: ambientHome, providerName: providerName)
                    candidates.append((
                        AccountSessionSource(
                            codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                            attribution: .unassigned),
                        request))
                }
            case .managedAccount, .profileHome:
                let homePath: String? = switch account.selectionSource {
                case let .managedAccount(id):
                    settings.managedCodexRemoteHomePath(forActiveSource: .managedAccount(id: id))
                case let .profileHome(path):
                    settings.profileCodexHomePath(forActiveSource: .profileHome(path: path))
                case .liveSystem:
                    nil
                }
                let identity = UsageIdentity.subscription(account: account, localHomePath: homePath)
                let request = self.codexRequest(
                    account: account,
                    homePath: homePath,
                    providerName: providerName,
                    index: index,
                    count: accounts.count,
                    usageIdentity: identity,
                    retainUnavailable: true)
                guard let request else { continue }
                candidates.append((
                    AccountSessionSource(
                        codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                        attribution: .assigned(identity)),
                    request))
            }
        }

        let plannedSources = AccountSessionAttributionPlan.make(sources: candidates.map(\.source))
        let requests = plannedSources.sources.compactMap { source -> CodexSpendScanRequest? in
            switch source.attribution {
            case .unassigned:
                return self.systemUnassignedRequest(homePath: source.codexHome.path, providerName: providerName)
            case let .assigned(identity):
                return candidates.first { $0.request.usageIdentity.accountKey == identity.accountKey }?.request
            }
        }
        let timeline = try? FileCodexSessionOwnershipTimelineStore.default.load()
        let attributedRequests = self.requestsByAddingLiveSystemAttributionTargets(
            requests,
            accounts: accounts,
            sharedLiveHomePath: sharedLiveHomePath,
            providerName: providerName,
            timeline: timeline,
            readCurrentAuthFingerprint: true)
        return self.requestsByApplyingSharedSessionOwnership(
            self.markDuplicateAccounts(attributedRequests),
            sharedLiveHomePath: sharedLiveHomePath,
            timeline: timeline)
    }

    /// Builds a menu-only cache plan from the already reconciled projection.
    /// It never opens auth.json, hashes live credentials, or reloads account state.
    static func cachedCodexRequests(
        projection: CodexVisibleAccountProjection,
        providerName: String,
        ownershipTimeline: CodexSessionOwnershipTimeline? = nil) -> [CodexSpendScanRequest]
    {
        var candidates: [(source: AccountSessionSource, request: CodexSpendScanRequest)] = []
        var sharedLiveHomePath: String?
        for (index, account) in projection.visibleAccounts.enumerated() {
            if account.selectionSource == .liveSystem {
                if let managedHome = account.managedCodexHomePath {
                    let identity = UsageIdentity.subscription(account: account, localHomePath: managedHome)
                    if let request = self.codexRequest(
                        account: account,
                        homePath: managedHome,
                        providerName: providerName,
                        index: index,
                        count: projection.visibleAccounts.count,
                        sourceOverride: .liveSystem,
                        usageIdentity: identity,
                        retainUnavailable: true,
                        readCurrentAuthFingerprint: false,
                        homeReadabilityOverride: true)
                    {
                        candidates.append((
                            AccountSessionSource(
                                codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                                attribution: .assigned(identity)),
                            request))
                    }
                }
                if let ambientHome = account.codexHomePath {
                    sharedLiveHomePath = ambientHome
                    let request = self.systemUnassignedRequest(
                        homePath: ambientHome, providerName: providerName, homeReadabilityOverride: true)
                    candidates.append((
                        AccountSessionSource(
                            codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                            attribution: .unassigned),
                        request))
                }
                continue
            }
            guard let home = account.codexHomePath else { continue }
            let identity = UsageIdentity.subscription(account: account, localHomePath: home)
            guard let request = self.codexRequest(
                account: account,
                homePath: home,
                providerName: providerName,
                index: index,
                count: projection.visibleAccounts.count,
                usageIdentity: identity,
                retainUnavailable: true,
                readCurrentAuthFingerprint: false,
                homeReadabilityOverride: true)
            else { continue }
            candidates.append((
                AccountSessionSource(
                    codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                    attribution: .assigned(identity)),
                request))
        }
        // Reconciliation can temporarily expose only managed/profile rows even though
        // the live ~/.codex home still owns the shared rollout corpus. Keep one
        // cache-only unassigned source without reopening auth or triggering a scan.
        if sharedLiveHomePath == nil,
           let ambientHome = Self.cacheOnlyAmbientCodexHomePath(),
           !candidates.contains(where: \.request.usageIdentity.isSystemUnassigned)
        {
            sharedLiveHomePath = ambientHome
            let request = self.systemUnassignedRequest(
                homePath: ambientHome,
                providerName: providerName,
                homeReadabilityOverride: true)
            candidates.append((
                AccountSessionSource(
                    codexHome: URL(fileURLWithPath: request.homePath, isDirectory: true),
                    attribution: .unassigned),
                request))
        }
        let plan = AccountSessionAttributionPlan.make(sources: candidates.map(\.source))
        let requests = plan.sources.compactMap { source -> CodexSpendScanRequest? in
            switch source.attribution {
            case .unassigned:
                self.systemUnassignedRequest(
                    homePath: source.codexHome.path, providerName: providerName, homeReadabilityOverride: true)
            case let .assigned(identity):
                candidates.first { $0.request.usageIdentity.accountKey == identity.accountKey }?.request
            }
        }
        let timeline = ownershipTimeline ?? (try? FileCodexSessionOwnershipTimelineStore.default.load())
        let attributedRequests = self.requestsByAddingLiveSystemAttributionTargets(
            requests,
            accounts: projection.visibleAccounts,
            sharedLiveHomePath: sharedLiveHomePath,
            providerName: providerName,
            timeline: timeline,
            readCurrentAuthFingerprint: false)
        return self.requestsByApplyingSharedSessionOwnership(
            self.markDuplicateAccounts(attributedRequests),
            sharedLiveHomePath: sharedLiveHomePath,
            timeline: timeline)
    }

    private static func cacheOnlyAmbientCodexHomePath() -> String? {
        let home = CodexHomeScope.ambientHomeURL(env: ProcessInfo.processInfo.environment)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: sessions,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]),
              !entries.isEmpty
        else { return nil }
        return home.path
    }

    @MainActor
    private static func sourceRevisions(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageDomain) -> [String]
    {
        ["settings:\(settings.configRevision)"] + providers.compactMap { provider in
            guard provider != .codex else { return nil }
            let current = store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
            guard let current else { return "\(provider.rawValue):unavailable" }
            guard let snapshot = current.snapshot else {
                return "\(provider.rawValue):empty:\(current.publicationRevision)"
            }
            return "\(provider.rawValue):snapshot:\(current.publicationRevision):\(self.snapshotRevision(snapshot))"
        }
    }

    private static func snapshotRevision(_ snapshot: CostUsageTokenSnapshot) -> String {
        var encoder = SpendDashboardSnapshotRevisionEncoder()
        encoder.append(snapshot.currencyCode)
        encoder.append(snapshot.historyDays)
        encoder.append(snapshot.historyCoverageIsEstablished)
        encoder.append(snapshot.updatedAt.timeIntervalSinceReferenceDate)
        encoder.append(snapshot.last30DaysTokens)
        encoder.append(snapshot.last30DaysCostUSD)
        encoder.append(snapshot.daily.count)
        for entry in snapshot.daily {
            encoder.append(entry.date)
            encoder.append(entry.inputTokens)
            encoder.append(entry.cacheReadTokens)
            encoder.append(entry.cacheCreationTokens)
            encoder.append(entry.outputTokens)
            encoder.append(entry.totalTokens)
            encoder.append(entry.requestCount)
            encoder.append(entry.costUSD)
            encoder.append(entry.modelBreakdowns?.count)
            for breakdown in entry.modelBreakdowns ?? [] {
                encoder.append(breakdown.modelName)
                encoder.append(breakdown.totalTokens)
                encoder.append(breakdown.requestCount)
                encoder.append(breakdown.costUSD)
                encoder.append(breakdown.standardCostUSD)
                encoder.append(breakdown.priorityCostUSD)
                encoder.append(breakdown.standardTokens)
                encoder.append(breakdown.priorityTokens)
            }
        }
        return encoder.finalize()
    }

    @MainActor
    private static func sourceOwnershipFingerprints(
        providers: [UsageProvider],
        settings: SettingsStore,
        store: UsageDomain) -> [String]
    {
        providers.compactMap { provider in
            guard provider != .codex else { return nil }
            var config = settings.providerConfig(for: provider) ?? ProviderConfig(id: provider)
            config.enabled = nil
            config.quotaWarnings = nil
            // The dashboard follows the effective account, not the whole saved-account collection.
            // Inactive-account edits must not invalidate visible spend for the selected account.
            config.tokenAccounts = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = (try? encoder.encode(config)) ?? Data()
            let scope = store.tokenSnapshotScopeSignature(for: provider)
            let accountOwnership = settings.effectiveSelectedTokenAccount(for: provider)
                .map { store.tokenAccountSnapshotCacheKey(provider: provider, account: $0) }
                ?? "ambient"
            return "\(provider.rawValue):\(self.sha256(encoded)):\(self.sha256(scope)):" +
                self.sha256(accountOwnership)
        }
    }

    static func codexRequest(
        account: CodexVisibleAccount,
        homePath: String?,
        providerName: String,
        index: Int,
        count: Int,
        sourceOverride: CodexActiveSource? = nil,
        usageIdentity: UsageIdentity? = nil,
        retainUnavailable: Bool = false,
        readCurrentAuthFingerprint: Bool = true,
        homeReadabilityOverride: Bool? = nil,
        scansSharedHomeOnly: Bool = false) -> CodexSpendScanRequest?
    {
        let normalizedHomePath = CodexHomeScope.normalizedHomePath(homePath)
        guard normalizedHomePath != nil || retainUnavailable else { return nil }
        let resolvedHomePath = normalizedHomePath ?? "unavailable:\(account.id)"
        var isDirectory: ObjCBool = false
        let isHomeReadable = homeReadabilityOverride ?? (FileManager.default.fileExists(
            atPath: resolvedHomePath, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: resolvedHomePath))
        guard isHomeReadable || retainUnavailable else { return nil }
        let requestedSource = sourceOverride ?? account.selectionSource
        // A live account merged with a persisted managed account owns the managed
        // home under that persisted UUID. Both the dashboard scanner and the
        // cache-only menu must therefore derive the exact same cache scope.
        let source: CodexActiveSource = if case .liveSystem = requestedSource,
                                           let storedAccountID = account.storedAccountID
        {
            .managedAccount(id: storedAccountID)
        } else {
            requestedSource
        }
        let sourceToken = self.sourceToken(source)
        let liveAuthFingerprint = isHomeReadable && readCurrentAuthFingerprint
            ? CodexAuthFingerprint.fingerprint(homePath: resolvedHomePath)
            : nil
        let authFingerprint = liveAuthFingerprint
            ?? CodexAuthFingerprint.normalize(account.authFingerprint)
        let cacheIdentity = self.sha256([
            account.id,
            sourceToken,
            resolvedHomePath,
            authFingerprint ?? "missing-auth",
        ].joined(separator: "\u{0}"))
        let displayName = count == 1
            ? providerName
            : "\(providerName) · #\(codexBarLocalizedInteger(index + 1))"
        return CodexSpendScanRequest(
            id: account.id,
            displayName: displayName,
            source: source,
            homePath: resolvedHomePath,
            authFingerprint: authFingerprint,
            authFileWasReadable: liveAuthFingerprint != nil,
            cacheIdentity: cacheIdentity,
            usageIdentity: usageIdentity ?? UsageIdentity.subscription(
                account: account,
                localHomePath: resolvedHomePath),
            isHomeReadable: isHomeReadable,
            email: account.email,
            workspaceAccountID: account.workspaceAccountID,
            storedAccountID: account.storedAccountID,
            canRemove: account.canRemove,
            scansSharedHomeOnly: scansSharedHomeOnly)
    }

    static func systemUnassignedRequest(
        homePath: String,
        providerName: String,
        homeReadabilityOverride: Bool? = nil) -> CodexSpendScanRequest
    {
        let resolvedHomePath = CodexHomeScope.normalizedHomePath(homePath) ?? homePath
        var isDirectory: ObjCBool = false
        let isHomeReadable = homeReadabilityOverride ?? (FileManager.default.fileExists(
            atPath: resolvedHomePath, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: resolvedHomePath))
        let identity = UsageIdentity.systemUnassigned(localHomePath: resolvedHomePath)
        return CodexSpendScanRequest(
            id: UsageIdentity.systemUnassignedSourceID(localHomePath: resolvedHomePath),
            displayName: "System / Unassigned",
            source: .liveSystem,
            homePath: resolvedHomePath,
            authFingerprint: nil,
            authFileWasReadable: false,
            cacheIdentity: self.sha256([identity.accountKey, resolvedHomePath].joined(separator: "\u{0}")),
            usageIdentity: identity,
            isHomeReadable: isHomeReadable)
    }

    static func markDuplicateAccounts(_ requests: [CodexSpendScanRequest]) -> [CodexSpendScanRequest] {
        requests.map { request in
            guard !request.usageIdentity.isSystemUnassigned else { return request }
            let duplicates = requests.compactMap { other -> String? in
                guard other.id != request.id,
                      !other.usageIdentity.isSystemUnassigned
                else { return nil }
                let sameAuth = request.authFingerprint != nil && request.authFingerprint == other.authFingerprint
                let sameWorkspace = request.workspaceAccountID != nil &&
                    request.workspaceAccountID == other.workspaceAccountID
                return sameAuth || sameWorkspace ? other.usageIdentity.accountKey : nil
            }.sorted()
            guard !duplicates.isEmpty else { return request }
            return CodexSpendScanRequest(
                id: request.id,
                displayName: request.displayName,
                source: request.source,
                homePath: request.homePath,
                authFingerprint: request.authFingerprint,
                authFileWasReadable: request.authFileWasReadable,
                cacheIdentity: request.cacheIdentity,
                usageIdentity: request.usageIdentity,
                isHomeReadable: request.isHomeReadable,
                email: request.email,
                workspaceAccountID: request.workspaceAccountID,
                storedAccountID: request.storedAccountID,
                canRemove: request.canRemove,
                duplicateAccountKeys: duplicates,
                scansSharedHomeOnly: request.scansSharedHomeOnly,
                sharedHomePath: request.sharedHomePath,
                sessionOwnershipTimeline: request.sessionOwnershipTimeline)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func requestsByAddingLiveSystemAttributionTargets(
        _ requests: [CodexSpendScanRequest],
        accounts: [CodexVisibleAccount],
        sharedLiveHomePath: String?,
        providerName: String,
        timeline: CodexSessionOwnershipTimeline?,
        readCurrentAuthFingerprint: Bool) -> [CodexSpendScanRequest]
    {
        guard let sharedLiveHomePath, let timeline else { return requests }
        var result = requests
        for (index, account) in accounts.enumerated() where account.selectionSource == .liveSystem {
            let identity = UsageIdentity.subscription(account: account, localHomePath: sharedLiveHomePath)
            guard !result.contains(where: { $0.usageIdentity.accountKey == identity.accountKey }),
                  timeline.events.contains(where: { $0.accountKey == identity.accountKey }) ||
                  timeline.manualAttributions.contains(where: { $0.accountKey == identity.accountKey }),
                  let request = self.codexRequest(
                      account: account,
                      homePath: sharedLiveHomePath,
                      providerName: providerName,
                      index: index,
                      count: accounts.count,
                      usageIdentity: identity,
                      retainUnavailable: true,
                      readCurrentAuthFingerprint: readCurrentAuthFingerprint,
                      homeReadabilityOverride: readCurrentAuthFingerprint ? nil : true,
                      scansSharedHomeOnly: true)
            else { continue }
            result.append(request)
        }
        return result
    }

    private static func requestsByApplyingSharedSessionOwnership(
        _ requests: [CodexSpendScanRequest],
        sharedLiveHomePath: String?,
        timeline: CodexSessionOwnershipTimeline? = nil) -> [CodexSpendScanRequest]
    {
        guard let sharedLiveHomePath,
              let timeline = timeline ?? (try? FileCodexSessionOwnershipTimelineStore.default.load())
        else { return requests }
        let normalizedSharedHome = CodexHomeScope.normalizedHomePath(sharedLiveHomePath) ?? sharedLiveHomePath
        return requests.map { request in
            if request.usageIdentity.isSystemUnassigned,
               request.homePath != normalizedSharedHome
            {
                return request
            }
            return request.attributingSharedHome(normalizedSharedHome, timeline: timeline)
        }
    }

    private static func codexDisplayNamesByID(_ requests: [CodexSpendScanRequest]) -> [String: String] {
        requests.reduce(into: [:]) { result, request in
            result["codex:\(request.id)"] = request.displayName
        }
    }

    private static func sourceToken(_ source: CodexActiveSource) -> String {
        switch source {
        case .liveSystem: "live"
        case let .managedAccount(id): "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path): "profile:\(path)"
        }
    }

    private static func sha256(_ value: String) -> String {
        self.sha256(Data(value.utf8))
    }

    private static func sha256(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private static func currentAuthFingerprint(for request: CodexSpendScanRequest) -> String? {
        let current = CodexAuthFingerprint.fingerprint(homePath: request.homePath)
        return request.authFileWasReadable ? current : current ?? request.authFingerprint
    }
}

private struct SpendDashboardSnapshotRevisionEncoder {
    private var hasher = SHA256()

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        self.append(UInt64(data.count))
        self.hasher.update(data: data)
    }

    mutating func append(_ value: Int) {
        self.append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Int?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func append(_ value: Bool) {
        self.appendPresence(value)
    }

    mutating func append(_ value: Double) {
        self.append(value.bitPattern)
    }

    mutating func append(_ value: Double?) {
        guard let value else {
            self.appendPresence(false)
            return
        }
        self.appendPresence(true)
        self.append(value)
    }

    mutating func finalize() -> String {
        self.hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func appendPresence(_ isPresent: Bool) {
        var byte: UInt8 = isPresent ? 1 : 0
        withUnsafeBytes(of: &byte) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }

    private mutating func append(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { bytes in
            self.hasher.update(data: Data(bytes))
        }
    }
}

@MainActor
@Observable
final class SpendDashboardController {
    typealias RequestBuilder = @MainActor @Sendable (SpendDashboardRequestBuildMode) async
        -> SpendDashboardLoadRequest
    typealias Loader = @Sendable (SpendDashboardLoadRequest) async -> SpendDashboardLoadResult

    private enum ReconciliationObservation: Sendable {
        case confirmedEmpty
        case confirmedNonempty(SpendDashboardModel.ProviderInput)
    }

    private struct ForcedOutcome: Sendable {
        let request: SpendDashboardLoadRequest
        let result: SpendDashboardLoadResult
        let invalidatedSourceIDs: Set<String>
        let observations: [String: ReconciliationObservation]

        func incorporating(capture: SpendDashboardLoadRequest) -> Self {
            var observations = self.observations
            for input in capture.capturedInputs {
                let forcedRevision = Self.sourceRevision(for: input.id, in: self.request.configuration)
                let captureRevision = Self.sourceRevision(for: input.id, in: capture.configuration)
                let hasNewerSourceRevision = forcedRevision != nil
                    && captureRevision != nil
                    && forcedRevision != captureRevision
                if self.result.failedSourceIDs.contains(input.id),
                   observations[input.id] == nil,
                   !hasNewerSourceRevision
                {
                    continue
                }
                observations[input.id] = .confirmedNonempty(input)
            }
            for sourceID in capture.confirmedEmptySourceIDs {
                observations[sourceID] = .confirmedEmpty
            }
            return Self(
                request: self.request,
                result: self.result,
                invalidatedSourceIDs: self.invalidatedSourceIDs,
                observations: observations)
        }

        private static func sourceRevision(
            for sourceID: String,
            in configuration: SpendDashboardConfiguration) -> String?
        {
            let prefix = "\(sourceID):"
            return configuration.sourceRevisions.first { $0.hasPrefix(prefix) }
        }

        var confirmedEmptySourceIDs: Set<String> {
            Set(self.observations.compactMap { sourceID, observation in
                guard case .confirmedEmpty = observation else { return nil }
                return sourceID
            })
        }

        var confirmedNonemptyInputs: [SpendDashboardModel.ProviderInput] {
            self.observations.sorted { $0.key < $1.key }.compactMap { _, observation in
                guard case let .confirmedNonempty(input) = observation else { return nil }
                return input
            }
        }
    }

    private struct ReconciledOutcome: Sendable {
        let result: SpendDashboardLoadResult
        let confirmedEmptySourceIDs: Set<String>
    }

    private enum LoadPhase: Sendable {
        case ordinary
        case forcing
        case reconciling(ForcedOutcome)

        var buildMode: SpendDashboardRequestBuildMode {
            switch self {
            case .ordinary: .refreshMissing
            case .forcing: .forceRefresh
            case .reconciling: .captureOnly
            }
        }

        var manualRefreshOutstanding: Bool {
            switch self {
            case .ordinary: false
            case .forcing, .reconciling: true
            }
        }
    }

    private(set) var model = SpendDashboardModel(requestedDays: 30, groups: [])
    private(set) var isRefreshing = false
    private(set) var failedSourceCount = 0
    private(set) var failedCodexDiagnostics: [SpendDashboardAccountDiagnostic] = []
    private(set) var generation: UInt64 = 0
    private(set) var configuration: SpendDashboardConfiguration?
    private(set) var selectedDays: Int

    private static let daysDefaultsKey = "settingsSpendDashboardDays"
    private let userDefaults: UserDefaults
    private let requestBuilder: RequestBuilder
    private let loader: Loader
    private let nowProvider: @Sendable () -> Date
    private var loadTask: Task<Void, Never>?
    private var loadedInputs: [SpendDashboardModel.ProviderInput] = []
    private var loadedAt = Date()
    private var lastSuccessfulConfiguration: SpendDashboardConfiguration?
    private var phase = LoadPhase.ordinary

    init(
        userDefaults: UserDefaults = CodexBarPreferences.processDefaults,
        requestBuilder: @escaping RequestBuilder,
        loader: @escaping Loader = SpendDashboardSource.load,
        nowProvider: @escaping @Sendable () -> Date = { Date() })
    {
        self.userDefaults = userDefaults
        self.requestBuilder = requestBuilder
        self.loader = loader
        self.nowProvider = nowProvider
        self.selectedDays = Self.normalizedDays(userDefaults.integer(forKey: Self.daysDefaultsKey))
    }

    func update(configuration: SpendDashboardConfiguration, force: Bool = false) {
        self.refreshRetainedCodexDisplayNames(configuration.codexAccountDisplayNames)
        if force {
            self.configuration = configuration
            self.startLoad(configuration: configuration, phase: .forcing)
            return
        }
        guard configuration != self.configuration else { return }
        let previousConfiguration = self.configuration
        self.configuration = configuration
        if self.phase.manualRefreshOutstanding,
           let previousConfiguration,
           Self.sameSourceOwnership(previousConfiguration, configuration)
        {
            return
        }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func startLoad(
        configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.generation &+= 1
        let generation = self.generation
        self.loadTask?.cancel()
        let invalidatedSourceIDs = switch phase {
        case let .reconciling(outcome): outcome.invalidatedSourceIDs
        case .ordinary, .forcing:
            Self.invalidatedSourceIDs(
                previous: self.lastSuccessfulConfiguration,
                current: configuration)
        }
        self.phase = phase

        if !invalidatedSourceIDs.isEmpty {
            self.loadedInputs.removeAll { invalidatedSourceIDs.contains($0.id) }
            self.failedSourceCount = 0
            self.failedCodexDiagnostics = []
            self.rebuildModel()
        }

        guard configuration.costUsageEnabled, !configuration.providerIDs.isEmpty else {
            self.loadedInputs = []
            self.failedSourceCount = 0
            self.failedCodexDiagnostics = []
            self.isRefreshing = false
            self.lastSuccessfulConfiguration = configuration
            self.phase = .ordinary
            self.loadTask = nil
            self.rebuildModel()
            return
        }

        self.isRefreshing = true
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            let request = await self.requestBuilder(phase.buildMode)
            guard !Task.isCancelled,
                  generation == self.generation
            else { return }
            await self.handleBuiltRequest(
                request,
                startedWith: configuration,
                phase: phase,
                generation: generation,
                invalidatedSourceIDs: invalidatedSourceIDs)
        }
    }

    private func handleBuiltRequest(
        _ request: SpendDashboardLoadRequest,
        startedWith startConfiguration: SpendDashboardConfiguration,
        phase: LoadPhase,
        generation: UInt64,
        invalidatedSourceIDs: Set<String>) async
    {
        guard let targetConfiguration = self.configuration else { return }
        if case let .reconciling(outcome) = phase,
           !Self.sameSourceOwnership(outcome.request.configuration, targetConfiguration)
        {
            self.startLoad(configuration: targetConfiguration, phase: .forcing)
            return
        }
        guard Self.sameSourceOwnership(startConfiguration, targetConfiguration) else {
            self.restartAfterBuildMismatch(targetConfiguration, phase: phase)
            return
        }

        let phase: LoadPhase = if case let .reconciling(outcome) = phase,
                                  Self.sameSourceOwnership(request.configuration, targetConfiguration)
        {
            .reconciling(outcome.incorporating(capture: request))
        } else {
            phase
        }

        if request.configuration != targetConfiguration {
            if case .forcing = phase,
               Self.sameSourceOwnership(request.configuration, targetConfiguration)
            {
                // Same-owner revision churn does not justify another provider force. The forced
                // loader executes once; its mandatory capture barrier reconciles the latest token.
                if targetConfiguration == startConfiguration {
                    self.configuration = request.configuration
                }
            } else if targetConfiguration == startConfiguration,
                      Self.sameSourceOwnership(targetConfiguration, request.configuration)
            {
                // The request owns an atomic newer same-owner capture. Adopt it even when the
                // external observation callback has not delivered that revision yet.
                self.configuration = request.configuration
            } else {
                let nextConfiguration = targetConfiguration == startConfiguration
                    ? request.configuration
                    : targetConfiguration
                self.restartAfterBuildMismatch(nextConfiguration, phase: phase)
                return
            }
        }

        switch phase {
        case .ordinary:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard request.configuration == latestConfiguration else {
                self.startLoad(configuration: latestConfiguration, phase: .ordinary)
                return
            }
            self.apply(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                confirmedEmptySourceIDs: request.confirmedEmptySourceIDs)

        case .forcing:
            let result = await self.loader(request)
            guard !Task.isCancelled,
                  generation == self.generation,
                  let latestConfiguration = self.configuration
            else { return }
            guard Self.sameSourceOwnership(request.configuration, latestConfiguration) else {
                self.startLoad(configuration: latestConfiguration, phase: .forcing)
                return
            }
            let outcome = ForcedOutcome(
                request: request,
                result: result,
                invalidatedSourceIDs: invalidatedSourceIDs,
                observations: Dictionary(uniqueKeysWithValues: request.confirmedEmptySourceIDs.map {
                    ($0, ReconciliationObservation.confirmedEmpty)
                }))
            self.startLoad(configuration: latestConfiguration, phase: .reconciling(outcome))

        case let .reconciling(outcome):
            let reconciled = Self.merge(outcome: outcome, capture: request)
            self.apply(
                request: request,
                result: reconciled.result,
                invalidatedSourceIDs: outcome.invalidatedSourceIDs,
                confirmedEmptySourceIDs: reconciled.confirmedEmptySourceIDs)
        }
    }

    private func restartAfterBuildMismatch(
        _ configuration: SpendDashboardConfiguration,
        phase: LoadPhase)
    {
        self.configuration = configuration
        let nextPhase: LoadPhase = switch phase {
        case .ordinary: .ordinary
        case .forcing: .forcing
        case let .reconciling(outcome):
            Self.sameSourceOwnership(outcome.request.configuration, configuration)
                ? .reconciling(outcome)
                : .forcing
        }
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    private func apply(
        request: SpendDashboardLoadRequest,
        result: SpendDashboardLoadResult,
        invalidatedSourceIDs: Set<String>,
        confirmedEmptySourceIDs: Set<String>)
    {
        let codexDisplayNames = request.configuration.codexAccountDisplayNames
        self.refreshRetainedCodexDisplayNames(codexDisplayNames)
        var nextInputs = result.inputs
        if !result.failedSourceIDs.isEmpty {
            let freshIDs = Set(nextInputs.map(\.id))
            let unsafeSourceIDs = invalidatedSourceIDs
                .union(result.invalidatedSourceIDs)
                .union(confirmedEmptySourceIDs)
            nextInputs.append(contentsOf: self.loadedInputs.filter {
                result.failedSourceIDs.contains($0.id) &&
                    !unsafeSourceIDs.contains($0.id) &&
                    !freshIDs.contains($0.id)
            }.map { Self.relabelCodexInput($0, displayNamesByID: codexDisplayNames) })
        }
        self.configuration = request.configuration
        self.loadedInputs = nextInputs
        self.loadedAt = request.now
        self.lastSuccessfulConfiguration = request.configuration
        self.failedSourceCount = result.failedSourceCount
        self.failedCodexDiagnostics = request.codexRequests.compactMap { account in
            guard result.failedSourceIDs.contains("codex:\(account.id)") else { return nil }
            return account.diagnostic(lastScanAt: nil)
        }
        self.isRefreshing = false
        self.phase = .ordinary
        self.loadTask = nil
        self.rebuildModel()
    }

    private static func merge(
        outcome: ForcedOutcome,
        capture: SpendDashboardLoadRequest) -> ReconciledOutcome
    {
        let forceFailed = outcome.result.failedSourceIDs
        let invalidated = outcome.result.invalidatedSourceIDs
        let barrierFailed = capture.unavailableSourceIDs
        var forcedCodexIDs = Set(outcome.request.codexRequests.map { "codex:\($0.id)" })
        if outcome.request.codexRequests.contains(where: \.usageIdentity.isSystemUnassigned) {
            forcedCodexIDs.insert(SpendDashboardSource.systemUnassignedAggregateSourceID)
        }
        let confirmedNonemptyInputs = outcome.confirmedNonemptyInputs
        let confirmedNonemptyIDs = Set(confirmedNonemptyInputs.map(\.id))
        var inputs = capture.capturedInputs.filter {
            (!forceFailed.contains($0.id) || confirmedNonemptyIDs.contains($0.id)) &&
                !invalidated.contains($0.id) &&
                !outcome.confirmedEmptySourceIDs.contains($0.id)
        }
        var capturedIDs = Set(inputs.map(\.id))
        for input in confirmedNonemptyInputs
            where !capturedIDs.contains(input.id) && !invalidated.contains(input.id)
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        for input in outcome.result.inputs
            where !capturedIDs.contains(input.id) &&
            !forceFailed.contains(input.id) &&
            !invalidated.contains(input.id) &&
            !outcome.confirmedEmptySourceIDs.contains(input.id) &&
            (forcedCodexIDs.contains(input.id) || barrierFailed.contains(input.id))
        {
            inputs.append(input)
            capturedIDs.insert(input.id)
        }
        return ReconciledOutcome(
            result: SpendDashboardLoadResult(
                inputs: inputs,
                failedSourceIDs: forceFailed.union(barrierFailed),
                invalidatedSourceIDs: invalidated),
            confirmedEmptySourceIDs: outcome.confirmedEmptySourceIDs)
    }

    func refresh() {
        guard let configuration else { return }
        self.update(configuration: configuration, force: true)
    }

    func selectDays(_ days: Int) {
        let days = Self.normalizedDays(days)
        guard days != self.selectedDays else { return }
        self.selectedDays = days
        self.userDefaults.set(days, forKey: Self.daysDefaultsKey)
        self.rebuildModel()
    }

    func refreshDateWindow(now: Date? = nil) {
        self.loadedAt = now ?? self.nowProvider()
        self.rebuildModel()
        guard let configuration else { return }
        let nextPhase: LoadPhase = self.phase.manualRefreshOutstanding ? .forcing : .ordinary
        self.startLoad(configuration: configuration, phase: nextPhase)
    }

    func stop() {
        self.loadTask?.cancel()
        self.loadTask = nil
        self.configuration = nil
        self.isRefreshing = false
        self.phase = .ordinary
    }

    private func rebuildModel() {
        self.model = SpendDashboardModel.build(
            inputs: self.loadedInputs,
            requestedDays: self.selectedDays,
            now: self.loadedAt,
            preferredCurrencyCode: self.configuration?.preferredCurrencyCode ?? "auto")
    }

    private func refreshRetainedCodexDisplayNames(_ displayNamesByID: [String: String]) {
        guard !displayNamesByID.isEmpty else { return }
        var didChange = false
        let relabeled = self.loadedInputs.map { input in
            let updated = Self.relabelCodexInput(input, displayNamesByID: displayNamesByID)
            didChange = didChange || updated.displayName != input.displayName
            return updated
        }
        guard didChange else { return }
        self.loadedInputs = relabeled
        self.rebuildModel()
    }

    static func relabelCodexInput(
        _ input: SpendDashboardModel.ProviderInput,
        displayNamesByID: [String: String]) -> SpendDashboardModel.ProviderInput
    {
        guard input.provider == .codex,
              let displayName = displayNamesByID[input.id],
              displayName != input.displayName
        else { return input }
        return SpendDashboardModel.ProviderInput(
            id: input.id,
            provider: input.provider,
            displayName: displayName,
            modelProviderName: input.modelProviderName,
            snapshot: input.snapshot,
            accountDiagnostic: input.accountDiagnostic)
    }

    private static func sameSourceOwnership(
        _ lhs: SpendDashboardConfiguration,
        _ rhs: SpendDashboardConfiguration) -> Bool
    {
        lhs.costUsageEnabled == rhs.costUsageEnabled &&
            lhs.providerIDs == rhs.providerIDs &&
            lhs.codexAccountIdentities == rhs.codexAccountIdentities &&
            lhs.sourceOwnershipFingerprints == rhs.sourceOwnershipFingerprints
    }

    private static func invalidatedSourceIDs(
        previous: SpendDashboardConfiguration?,
        current: SpendDashboardConfiguration) -> Set<String>
    {
        guard let previous else { return [] }
        let previousOwnership = self.sourceOwnershipByID(previous.sourceOwnershipFingerprints)
        let currentOwnership = self.sourceOwnershipByID(current.sourceOwnershipFingerprints)
        let providerIDs = Set(previousOwnership.keys).union(currentOwnership.keys)
        let changedProviderIDs = providerIDs.filter { previousOwnership[$0] != currentOwnership[$0] }

        let previousCodexOwnership = self.codexOwnershipByID(previous.codexAccountIdentities)
        let currentCodexOwnership = self.codexOwnershipByID(current.codexAccountIdentities)
        let codexIDs = Set(previousCodexOwnership.keys).union(currentCodexOwnership.keys)
        let changedCodexIDs = codexIDs.filter {
            previousCodexOwnership[$0] != currentCodexOwnership[$0]
        }
        return Set(changedProviderIDs).union(changedCodexIDs)
    }

    private static func sourceOwnershipByID(_ fingerprints: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: fingerprints.compactMap { fingerprint in
            guard let separator = fingerprint.firstIndex(of: ":") else { return nil }
            let sourceID = String(fingerprint[..<separator])
            guard !sourceID.isEmpty else { return nil }
            return (sourceID, fingerprint)
        })
    }

    private static func codexOwnershipByID(_ identities: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: identities.compactMap { identity in
            guard let separator = identity.lastIndex(of: "|") else { return nil }
            let accountID = String(identity[..<separator])
            guard !accountID.isEmpty else { return nil }
            return ("codex:\(accountID)", identity)
        })
    }

    private static func normalizedDays(_ value: Int) -> Int {
        value == 7 ? 7 : 30
    }
}
