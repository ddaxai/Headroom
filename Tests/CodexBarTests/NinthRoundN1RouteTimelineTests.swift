import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct NinthRoundN1RouteTimelineTests {
    @Test
    func `history before the first route boundary stays unknown`() throws {
        var timeline = CodexSessionOwnershipTimeline()

        #expect(timeline.codexRoute(atUnixMilliseconds: 999) == nil)
        let recordedRelay = try timeline.recordCodexRelayActivation(
            profileID: #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            atUnixMilliseconds: 1000)
        #expect(recordedRelay)
        #expect(timeline.codexRoute(atUnixMilliseconds: 999) == nil)
        #expect(timeline.codexRoute(atUnixMilliseconds: 1000)?.isRelay == true)

        let recordedOfficial = timeline.recordOfficialCodexRoute(atUnixMilliseconds: 2000)
        #expect(recordedOfficial)
        #expect(timeline.codexRoute(atUnixMilliseconds: 1999)?.isRelay == true)
        #expect(timeline.codexRoute(atUnixMilliseconds: 2000) == .official)
    }

    @Test
    func `route events round trip and change the provenance revision`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(fileURL: root.appendingPathComponent("timeline.json"))
        let profileID = UUID()
        let before = try store.load().revision

        #expect(try store.recordCodexRelayActivation(
            profileID: profileID,
            at: Date(timeIntervalSince1970: 10)))
        let relay = try store.load()
        #expect(relay.revision != before)
        #expect(relay.codexRoute(atUnixMilliseconds: 10000) == .relay(profileID: profileID))

        #expect(try store.recordOfficialCodexRoute(at: Date(timeIntervalSince1970: 20)))
        let official = try store.load()
        #expect(official.revision != relay.revision)
        #expect(official.codexRoute(atUnixMilliseconds: 20000) == .official)
    }

    @Test
    func `legacy schema migrates without inventing route history`() throws {
        let json =
            #"{"events":[{"accountKey":"codex:managed:first","timestampUnixMs":1000}],"manualAttributions":[]"#
                + #", "schemaVersion":2}"#
        let bytes = Data(json.utf8)
        let timeline = try JSONDecoder().decode(CodexSessionOwnershipTimeline.self, from: bytes)

        #expect(timeline.schemaVersion == CodexSessionOwnershipTimeline.currentSchemaVersion)
        #expect(timeline.codexRouteEvents.isEmpty)
        #expect(timeline.codexRoute(atUnixMilliseconds: .max) == nil)
    }

    @Test
    func `shared rows use route time while explicit providers take precedence`() {
        let accountKey = "codex:managed:official"
        let relayID = UUID()
        var timeline = CodexSessionOwnershipTimeline()
        _ = timeline.recordActivation(accountKey: accountKey, atUnixMilliseconds: 1000)
        _ = timeline.recordOfficialCodexRoute(atUnixMilliseconds: 1000)
        _ = timeline.recordCodexRelayActivation(profileID: relayID, atUnixMilliseconds: 2000)

        #expect(CodexSessionProvenanceClassifier.classify(
            timestampUnixMs: 1500,
            modelProvider: "codexbar_shared",
            timeline: timeline) == .official(accountKey: accountKey))
        #expect(CodexSessionProvenanceClassifier.classify(
            timestampUnixMs: 2500,
            modelProvider: "codexbar_shared",
            timeline: timeline) == .relay(profileID: relayID))
        #expect(CodexSessionProvenanceClassifier.classify(
            timestampUnixMs: 2500,
            modelProvider: "openai",
            timeline: timeline) == .official(accountKey: accountKey))
        #expect(CodexSessionProvenanceClassifier.classify(
            timestampUnixMs: 1500,
            modelProvider: "codexbar_relay",
            timeline: timeline) == .relay(profileID: nil))
        #expect(CodexSessionProvenanceClassifier.classify(
            timestampUnixMs: nil,
            modelProvider: "codexbar_shared",
            timeline: timeline) == .unassigned)
    }

    @Test
    func `official relay and unassigned components conserve the full corpus`() {
        let conserved = CodexStackedUsageSummary.isConservedPartition(
            total: .init(totalTokens: 1000, costUSD: 10),
            official: [
                .init(totalTokens: 300, costUSD: 3),
                .init(totalTokens: 200, costUSD: 2),
            ],
            relay: .init(totalTokens: 400, costUSD: 4),
            unassigned: .init(totalTokens: 100, costUSD: 1))
        let impossible = CodexStackedUsageSummary.isConservedPartition(
            total: .init(totalTokens: 999, costUSD: 10),
            official: [.init(totalTokens: 500, costUSD: 5)],
            relay: .init(totalTokens: 400, costUSD: 4),
            unassigned: .init(totalTokens: 100, costUSD: 1))

        #expect(conserved)
        #expect(!impossible)
    }

    @Test
    func `unassigned residual excludes the relay partition`() {
        let full = Self.snapshot(tokens: 1000, cost: 10, updatedAt: Date(timeIntervalSince1970: 10))
        let official = Self.snapshot(tokens: 600, cost: 6, updatedAt: full.updatedAt)
        let relay = Self.snapshot(tokens: 400, cost: 4, updatedAt: full.updatedAt)

        let unassigned = CodexStackedUsageSummary.unassignedTotal(
            accountSnapshots: [official],
            relaySnapshot: relay,
            sharedSnapshot: nil,
            fullCorpusSnapshot: full)

        #expect(unassigned == nil)
    }

    @Test
    func `menu partitions from different corpus generations fail closed`() {
        let first = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 11)
        let full = Self.snapshot(tokens: 1000, cost: 10, updatedAt: first)
        let official = Self.snapshot(tokens: 600, cost: 6, updatedAt: first)
        let relay = Self.snapshot(tokens: 400, cost: 4, updatedAt: later, corpusRevision: "corpus-b")

        #expect(!CodexStackedUsageSummary.shareCorpusGeneration([full, official, relay]))
        #expect(CodexStackedUsageSummary.shareCorpusGeneration([full, official]))
    }

    @Test
    func `exactly conserved partial menu partitions remain publishable during corpus catch up`() {
        let updatedAt = Date(timeIntervalSince1970: 10)
        let full = Self.snapshot(
            tokens: 1000,
            cost: 10,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)
        let official = Self.snapshot(
            tokens: 600,
            cost: 6,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)
        let relay = Self.snapshot(
            tokens: 300,
            cost: 3,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)
        let unassigned = Self.snapshot(
            tokens: 100,
            cost: 1,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)

        #expect(CodexStackedUsageSummary.isPublishableMenuPartition(
            fullCorpusSnapshot: full,
            officialSnapshots: [official],
            relaySnapshot: relay,
            unassignedSnapshot: unassigned))
        #expect(!CodexStackedUsageSummary.isPublishableMenuPartition(
            fullCorpusSnapshot: full,
            officialSnapshots: [official],
            relaySnapshot: relay,
            unassignedSnapshot: Self.snapshot(
                tokens: 99,
                cost: 1,
                updatedAt: updatedAt,
                corpusRevision: nil,
                coverageIsComplete: false)))
    }

    @Test
    @MainActor
    func `unconserved menu refresh retains last good official snapshots`() {
        let lastGood = [
            "official-alpha": Self.snapshot(
                tokens: 600,
                cost: 6,
                updatedAt: Date(timeIntervalSince1970: 10)),
        ]
        let candidate = [
            "official-alpha": Self.snapshot(
                tokens: 700,
                cost: 7,
                updatedAt: Date(timeIntervalSince1970: 20)),
        ]

        #expect(StatusItemController.codexMenuAccountSnapshotsAfterRefresh(
            candidates: candidate,
            lastGood: lastGood,
            partitionIsConserved: false) == lastGood)
        #expect(StatusItemController.codexMenuAccountSnapshotsAfterRefresh(
            candidates: candidate,
            lastGood: lastGood,
            partitionIsConserved: true) == candidate)
    }

    @Test
    @MainActor
    func `unconserved menu refresh retains last good relay profile snapshots`() {
        let profileID = UUID()
        let lastGood = [
            profileID: Self.snapshot(
                tokens: 300,
                cost: 3,
                updatedAt: Date(timeIntervalSince1970: 10)),
        ]
        let candidate = [
            profileID: Self.snapshot(
                tokens: 400,
                cost: 4,
                updatedAt: Date(timeIntervalSince1970: 20)),
        ]

        #expect(StatusItemController.relayProfileSnapshotsAfterRefresh(
            candidates: candidate,
            lastGood: lastGood,
            partitionIsConserved: false,
            fullCorpusSnapshot: nil) == lastGood)
        #expect(StatusItemController.relayProfileSnapshotsAfterRefresh(
            candidates: candidate,
            lastGood: [:],
            partitionIsConserved: false,
            fullCorpusSnapshot: Self.snapshot(
                tokens: 1000,
                cost: 10,
                updatedAt: Date(timeIntervalSince1970: 20))) == candidate)
        #expect(StatusItemController.relayProfileSnapshotsAfterRefresh(
            candidates: candidate,
            lastGood: lastGood,
            partitionIsConserved: true,
            fullCorpusSnapshot: Self.snapshot(
                tokens: 1000,
                cost: 10,
                updatedAt: Date(timeIntervalSince1970: 20))) == candidate)
    }

    @Test
    @MainActor
    func `conserved partial relay profile snapshots remain publishable`() {
        let profileID = UUID()
        let updatedAt = Date(timeIntervalSince1970: 10)
        let full = Self.snapshot(
            tokens: 1000,
            cost: 10,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)
        let relay = Self.snapshot(
            tokens: 300,
            cost: 3,
            updatedAt: updatedAt,
            corpusRevision: nil,
            coverageIsComplete: false)

        #expect(StatusItemController.currentRelayProfileSnapshots(
            [profileID: relay],
            fullCorpusSnapshot: full)[profileID] == relay)
    }

    @Test
    func `corpus revision changes when a rollout file is created or appended`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-corpus-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let empty = try #require(CostUsageScanner.codexSessionCorpusRevision(roots: [sessions]))
        let rollout = sessions.appendingPathComponent("rollout-test.jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        let created = try #require(CostUsageScanner.codexSessionCorpusRevision(roots: [sessions]))
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let appended = try #require(CostUsageScanner.codexSessionCorpusRevision(roots: [sessions]))

        #expect(empty != created)
        #expect(created != appended)
    }

    @Test
    @MainActor
    func `config mutation records unknown before committing the relay route`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-route-mutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(fileURL: root.appendingPathComponent("timeline.json"))
        let profileID = UUID()
        var timestamps = [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 11)]
        var mutationRan = false

        let result = try CodexRouteMutationTransaction.perform(
            store: store,
            targetRoute: .relay(profileID: profileID),
            now: { timestamps.removeFirst() },
            mutation: {
                mutationRan = true
                return 42
            })

        #expect(result == 42)
        #expect(mutationRan)
        let events = try store.load().codexRouteEvents
        #expect(events.map(\.route) == [.unknown, .relay(profileID: profileID)])
    }

    @Test
    @MainActor
    func `restored configuration stays unknown unless post commit verification proves official`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-route-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCodexSessionOwnershipTimelineStore(fileURL: root.appendingPathComponent("timeline.json"))
        var timestamps = [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 11)]

        _ = try CodexRouteMutationTransaction.perform(
            store: store,
            targetRoute: .unknown,
            committedRoute: { .unknown },
            now: { timestamps.removeFirst() },
            mutation: { 42 })

        #expect(try store.load().codexRouteEvents.map(\.route) == [.unknown])
    }

    @Test
    @MainActor
    func `launch bootstrap records only an exactly verified active relay`() {
        let profileID = UUID()
        let profile = Self.profile(id: profileID)
        let at = Date(timeIntervalSince1970: 30)
        var recorded: [(CodexSessionOwnershipTimeline.CodexRoute, Date)] = []

        CodexSessionRouteBootstrap.seedAtLaunch(
            activationProfileID: profileID,
            profiles: [profile],
            at: at,
            verification: .init(
                relay: { $0.id == profileID },
                official: { false }),
            record: { recorded.append(($0, $1)) })

        #expect(recorded.map(\.0) == [.relay(profileID: profileID)])
        #expect(recorded.map(\.1) == [at])
    }

    @Test
    @MainActor
    func `launch bootstrap fails closed when activation metadata and config disagree`() {
        let profileID = UUID()
        var recorded: [CodexSessionOwnershipTimeline.CodexRoute] = []

        CodexSessionRouteBootstrap.seedAtLaunch(
            activationProfileID: profileID,
            profiles: [Self.profile(id: profileID)],
            at: Date(timeIntervalSince1970: 40),
            verification: .init(
                relay: { _ in false },
                official: { true }),
            record: { route, _ in recorded.append(route) })

        #expect(recorded == [.unknown])
    }

    @Test
    func `plain Codex configuration verifier accepts only implicit or explicit OpenAI`() {
        #expect(CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(nil))
        #expect(CodexOfficialRouteConfigurationVerifier
            .isOfficialConfiguration(Data("model_provider = \"openai\"\n".utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(
            Data("model_provider = \"codexbar_relay\"\n".utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(
            Data("model_provider = \"openai\"\nmodel_provider = \"openai\"\n".utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(Data("""
        model_provider = "openai"
        [model_providers.openai]
        base_url = "https://third-party.example/v1"
        """.utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(Data("""
        model_provider = "openai"
        [model_providers."openai"]
        base_url = "https://third-party.example/v1"
        """.utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(Data("""
        model_provider = "openai"
        model_providers.openai = { base_url = "https://third-party.example/v1" }
        """.utf8)))
        #expect(!CodexOfficialRouteConfigurationVerifier.isOfficialConfiguration(Data([0xFF])))
    }

    @Test
    @MainActor
    func `launch verifier recognizes the generated shared official configuration`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-shared-official-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RelayConfigurationPaths.standard(homeDirectory: root, environment: [:])
        try FileManager.default.createDirectory(
            at: paths.codexConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("""
        model = "gpt-5.6-luna"

        [features]
        web_search = true

        [[mcp_servers.example.tools]]
        name = "read"
        """.utf8).write(to: paths.codexConfigURL)

        let transaction = RelayConfigurationTransaction()
        _ = try transaction.configureOfficialCodexUnified(paths: paths)
        let generated = try Data(contentsOf: paths.codexConfigURL)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: generated) == .shared)
        #expect(CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
            paths: paths,
            transaction: transaction,
            fileSystem: LocalRelayConfigurationFileSystem()))
    }

    @Test
    @MainActor
    func `launch verifier accepts semantically exact shared official configuration`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ninth-round-semantic-shared-official-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RelayConfigurationPaths.standard(homeDirectory: root, environment: [:])
        try FileManager.default.createDirectory(
            at: paths.codexConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("""
        model_provider = "codexbar_shared"

        [model_providers.codexbar_shared]
        wire_api = "responses"
        supports_websockets = true
        name = "OpenAI"
        requires_openai_auth = true

        [[mcp_servers.example.tools]]
        name = "read"
        """.utf8).write(to: paths.codexConfigURL)

        let transaction = RelayConfigurationTransaction()
        let preview = try transaction.configureOfficialCodexUnified(paths: paths, dryRun: true).preview
        #expect(preview.changedTargets == [.codex])
        #expect(CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
            paths: paths,
            transaction: transaction,
            fileSystem: LocalRelayConfigurationFileSystem()))
    }

    @Test
    func `official verifier rejects OpenAI provider array overrides and malformed array tables`() {
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "openai"
        [[model_providers.openai]]
        base_url = "https://third-party.example/v1"
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "codexbar_shared"
        [[mcp_servers.example]
        name = "broken"
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        "model_provider" = "third_party"
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data(#"""
        model_provider = "openai"
        [model_providers."open\u0061i"]
        base_url = "https://third-party.example/v1"
        """#.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data(#"""
        model_provider = "openai"
        model_providers."open\u0061i" = { base_url = "https://third-party.example/v1" }
        """#.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "codexbar_shared"
        [[mcp_servers..tools]]
        name = "broken"
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "codexbar_shared"
        [[mcp_servers."unterminated]]
        name = "broken"
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "openai"
        [model_providers]
        openai = { base_url = "https://third-party.example/v1" }
        """.utf8)) == .otherOrInvalid)
        #expect(CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: Data("""
        model_provider = "openai"
        broke\u{0301}n = true
        """.utf8)) == .otherOrInvalid)
        for unsafe in [
            """
            model_provider = "codexbar_shared"
            [model_providers.codexbar_shared]
            name = "OpenAI"
            requires_openai_auth = true
            supports_websockets = true
            wire_api = "responses"
            base_url = "https://third-party.example/v1"
            """,
            """
            model_provider = "codexbar_shared"
            [model_providers.codexbar_shared]
            name = "OpenAI"
            requires_openai_auth = true
            supports_websockets = true
            wire_api = "responses"
            [model_providers.codexbar_shared.auth]
            command = "helper"
            """,
        ] {
            #expect(!CodexOfficialRouteConfigurationVerifier.hasExactSharedOfficialProvider(in: Data(unsafe.utf8)))
        }
    }

    private static func profile(id: UUID) -> RelayProfile {
        RelayProfile(
            id: id,
            name: "Relay",
            baseURL: URL(string: "https://relay.example.com/v1")!,
            apiFormat: .openAIResponses,
            defaultModel: "gpt-test",
            credentialReference: "relay-\(id.uuidString)",
            credentialConfigured: true,
            targets: [.init(app: .codex, model: "gpt-test")])
    }

    private static func snapshot(
        tokens: Int,
        cost: Double,
        updatedAt: Date,
        corpusRevision: String? = "corpus-a",
        coverageIsComplete: Bool = true) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: tokens,
            last30DaysCostUSD: cost,
            rolling24Hours: .init(totalTokens: tokens, costUSD: cost),
            codexCorpusRevision: corpusRevision,
            codexCorpusCoverageIsComplete: coverageIsComplete,
            daily: [],
            updatedAt: updatedAt)
    }
}
