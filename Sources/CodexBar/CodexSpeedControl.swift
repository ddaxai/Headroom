import CodexBarCore
import Foundation
import SwiftUI

enum CodexSpeedScope: Equatable {
    case official
    case relay(UUID)

    var preferenceKey: String {
        switch self {
        case .official: "official"
        case let .relay(id): "relay.\(id.uuidString.lowercased())"
        }
    }
}

struct CodexSpeedPreferences {
    private let defaults: UserDefaults
    private static let key = "codex.serviceTierByRoute"

    init(defaults: UserDefaults = CodexBarPreferences.processDefaults) {
        self.defaults = defaults
    }

    func tier(for scope: CodexSpeedScope) -> CodexServiceTier? {
        (self.defaults.dictionary(forKey: Self.key)?[scope.preferenceKey] as? String)
            .flatMap(CodexServiceTier.init(rawValue:))
    }

    func store(_ tier: CodexServiceTier, for scope: CodexSpeedScope) {
        var values = self.defaults.dictionary(forKey: Self.key) ?? [:]
        values[scope.preferenceKey] = tier.rawValue
        self.defaults.set(values, forKey: Self.key)
    }
}

struct CodexSpeedSnapshot: Equatable {
    let scope: CodexSpeedScope
    let tier: CodexServiceTier?
}

enum CodexSpeedError: LocalizedError {
    case unknownRoute

    var errorDescription: String? {
        L("codex_speed_unknown_route")
    }
}

/// Isolated actions also keep UI tests from reading the user's real client configuration.
@MainActor
struct CodexSpeedActions {
    var read: () throws -> CodexSpeedSnapshot = { throw CodexSpeedError.unknownRoute }
    var write: (CodexServiceTier, CodexSpeedScope) throws -> CodexSpeedSnapshot = { _, _ in
        throw CodexSpeedError.unknownRoute
    }

    func tierForSwitch(
        to profileID: UUID,
        preferences: CodexSpeedPreferences = CodexSpeedPreferences()) -> CodexServiceTier
    {
        if let current = try? self.read(), let tier = current.tier {
            preferences.store(tier, for: current.scope)
        }
        return preferences.tier(for: .relay(profileID)) ?? .standard
    }

    static func live(paths: RelayConfigurationPaths, transaction: RelayConfigurationTransaction) -> Self {
        self.live(
            paths: paths,
            transaction: transaction,
            preferences: CodexSpeedPreferences(),
            activationStore: UserDefaultsRelayActivationStateStore(),
            profileStore: FileRelayProfileStore())
    }

    static func live(
        paths: RelayConfigurationPaths,
        transaction: RelayConfigurationTransaction,
        preferences: CodexSpeedPreferences,
        activationStore: UserDefaultsRelayActivationStateStore,
        profileStore: FileRelayProfileStore) -> Self
    {
        self.live(paths: paths, transaction: transaction, preferences: preferences, resolveScope: {
            let route = try CodexSessionRouteBootstrap.resolveCurrentRoute(
                activationProfileID: activationStore.load()?.activeProfileIDsByTarget[.codex],
                profiles: profileStore.loadProfiles(),
                verification: .init(
                    relay: {
                        CodexSessionRouteBootstrap.isExactRelayConfiguration(
                            profile: $0, paths: paths, transaction: transaction)
                    },
                    official: {
                        CodexSessionRouteBootstrap.isVerifiedOfficialConfiguration(
                            paths: paths, transaction: transaction, fileSystem: LocalRelayConfigurationFileSystem())
                    }))
            return switch route {
            case .official: .official
            case let .relay(profileID): .relay(profileID)
            case .unknown: throw CodexSpeedError.unknownRoute
            }
        })
    }

    static func live(
        paths: RelayConfigurationPaths,
        transaction: RelayConfigurationTransaction,
        preferences: CodexSpeedPreferences,
        resolveScope: @escaping () throws -> CodexSpeedScope) -> Self
    {
        let read = {
            let scope = try resolveScope()
            let data = try Data(contentsOf: paths.codexConfigURL)
            return try CodexSpeedSnapshot(scope: scope, tier: CodexServiceTier.configured(in: data))
        }
        return Self(read: read, write: { tier, expectedScope in
            let original = try Data(contentsOf: paths.codexConfigURL)
            guard try resolveScope() == expectedScope else { throw CodexSpeedError.unknownRoute }
            let result = try transaction.setCodexServiceTier(
                tier, paths: paths, expectedConfiguration: original)
            preferences.store(tier, for: expectedScope)
            // The transaction verified readback before publishing the preference.
            if let backup = result.backupDirectory { try? transaction.discardBackup(directory: backup, paths: paths) }
            return CodexSpeedSnapshot(scope: expectedScope, tier: tier)
        })
    }
}

@MainActor
struct CodexSpeedControl: View {
    let actions: CodexSpeedActions
    @State private var snapshot: CodexSpeedSnapshot?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L("codex_speed_title"))
                    .font(ConsoleDesign.mono(10, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.primaryText)
                ForEach(CodexServiceTier.allCases, id: \.rawValue) { tier in
                    RelayQuickSwitchChoice(
                        title: tier == .fast ? L("codex_speed_fast") : L("codex_speed_standard"),
                        isSelected: self.snapshot?.tier == tier,
                        isReady: self.snapshot != nil,
                        helpText: L("codex_speed_help"))
                    {
                        self.select(tier)
                    }
                    .disabled(self.snapshot == nil)
                }
                Spacer(minLength: 0)
            }
            Text(self.error ?? L("codex_speed_new_chat_hint"))
                .font(ConsoleDesign.mono(9))
                .foregroundStyle(self.error == nil ? ConsoleDesign.secondaryText : ConsoleDesign.criticalForeground)
                .lineLimit(1)
                .help(self.error ?? L("codex_speed_help"))
        }
        .onAppear(perform: self.reload)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_speed_title"))
    }

    private func reload() {
        do {
            self.snapshot = try self.actions.read()
            self.error = nil
        } catch {
            self.snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func select(_ tier: CodexServiceTier) {
        guard let scope = self.snapshot?.scope else { return }
        do {
            self.snapshot = try self.actions.write(tier, scope)
            self.error = nil
        } catch {
            // Re-read after failures instead of displaying an optimistic, uncommitted tier.
            self.snapshot = try? self.actions.read()
            self.error = error.localizedDescription
        }
    }
}
