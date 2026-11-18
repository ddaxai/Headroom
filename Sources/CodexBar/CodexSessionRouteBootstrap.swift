import CodexBarCore
import Foundation

enum CodexSessionRouteBootstrap {
    typealias Route = CodexSessionOwnershipTimeline.CodexRoute

    struct Verification {
        let relay: (RelayProfile) -> Bool
        let official: () -> Bool
    }

    /// Resolves the route represented by the current client configuration. The activation
    /// preference is only a hint: CC Switch can change `config.toml` while Headroom is not
    /// running, so a uniquely matching relay profile is authoritative for the next boundary.
    @MainActor
    static func resolveCurrentRoute(
        activationProfileID: UUID?,
        profiles: [RelayProfile],
        verification: Verification) -> Route
    {
        if let activationProfileID,
           let activeProfile = profiles.first(where: {
               $0.id == activationProfileID && $0.configuration(for: .codex)?.isEnabled == true
           }),
           verification.relay(activeProfile)
        {
            return .relay(profileID: activationProfileID)
        }

        let matchingProfiles = profiles.filter {
            $0.configuration(for: .codex)?.isEnabled == true && verification.relay($0)
        }
        if matchingProfiles.count == 1, let profileID = matchingProfiles.first?.id {
            return .relay(profileID: profileID)
        }
        return verification.official() ? .official : .unknown
    }

    @MainActor
    static func seedAtLaunch(
        activationProfileID: UUID?,
        profiles: [RelayProfile],
        at: Date,
        verification: Verification,
        record: (Route, Date) throws -> Void)
    {
        let route: Route = if let activationProfileID {
            if let profile = profiles.first(where: {
                $0.id == activationProfileID && $0.configuration(for: .codex)?.isEnabled == true
            }), verification.relay(profile) {
                .relay(profileID: activationProfileID)
            } else {
                // Activation metadata and the live config must agree. An explicit mismatch is not
                // evidence that either side is authoritative, so stop old provenance at launch.
                .unknown
            }
        } else {
            verification.official() ? .official : .unknown
        }

        do {
            try record(route, at)
        } catch {
            CodexBarLog.logger(LogCategories.app).warning(
                "Could not persist the launch Codex route boundary",
                metadata: ["error": String(describing: error)])
        }
    }

    @MainActor
    static func seedAtLaunch(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        at: Date = Date())
    {
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: homeDirectory,
            environment: environment)
        let activationProfileID = UserDefaultsRelayActivationStateStore().load()?
            .activeProfileIDsByTarget[.codex]
        let profiles = (try? FileRelayProfileStore().loadProfiles()) ?? []
        let transaction = RelayConfigurationTransaction()
        let fileSystem = LocalRelayConfigurationFileSystem()
        let routeStore = FileCodexSessionOwnershipTimelineStore.default

        Self.seedAtLaunch(
            activationProfileID: activationProfileID,
            profiles: profiles,
            at: at,
            verification: Verification(
                relay: { profile in
                    Self.isExactRelayConfiguration(
                        profile: profile,
                        paths: paths,
                        transaction: transaction)
                },
                official: {
                    Self.isVerifiedOfficialConfiguration(
                        paths: paths,
                        transaction: transaction,
                        fileSystem: fileSystem)
                }),
            record: { route, date in
                switch route {
                case .official:
                    _ = try routeStore.recordOfficialCodexRoute(at: date)
                case let .relay(profileID):
                    _ = try routeStore.recordCodexRelayActivation(profileID: profileID, at: date)
                case .unknown:
                    _ = try routeStore.recordUnknownCodexRoute(at: date)
                }
            })
    }

    /// Reconciles the persisted route boundary with the current on-disk client configuration.
    /// This is intentionally read-only with respect to client configuration files; it only
    /// appends a local provenance boundary when the observed route changed.
    @MainActor
    static func reconcileCurrentRouteFromConfiguration(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        at date: Date = Date(),
        routeStore: FileCodexSessionOwnershipTimelineStore = .default)
    {
        let paths = RelayConfigurationPaths.standard(
            homeDirectory: homeDirectory,
            environment: environment)
        let activationProfileID = UserDefaultsRelayActivationStateStore().load()?
            .activeProfileIDsByTarget[.codex]
        let profiles = (try? FileRelayProfileStore().loadProfiles()) ?? []
        let transaction = RelayConfigurationTransaction()
        let fileSystem = LocalRelayConfigurationFileSystem()
        let route = Self.resolveCurrentRoute(
            activationProfileID: activationProfileID,
            profiles: profiles,
            verification: Verification(
                relay: { profile in
                    Self.isExactRelayConfiguration(
                        profile: profile,
                        paths: paths,
                        transaction: transaction)
                },
                official: {
                    Self.isVerifiedOfficialConfiguration(
                        paths: paths,
                        transaction: transaction,
                        fileSystem: fileSystem)
                }))

        let timeline = try? routeStore.load()
        let currentRoute = timeline?.codexRoute(atUnixMilliseconds: Int64.max)
        guard currentRoute != route else { return }
        let configurationDate: Date = if let attributes = try? FileManager.default.attributesOfItem(
            atPath: paths.codexConfigURL.path),
            let modificationDate = attributes[.modificationDate] as? Date
        {
            modificationDate
        } else {
            date
        }
        let latestBoundaryDate = timeline?.codexRouteEvents.last.map {
            Date(timeIntervalSince1970: TimeInterval($0.timestampUnixMs) / 1000)
        }
        let earliestMonotonicBoundary = [configurationDate, latestBoundaryDate].compactMap(\.self).max()
            ?? configurationDate
        let boundaryDate = min(date, earliestMonotonicBoundary)
        do {
            switch route {
            case .official:
                _ = try routeStore.recordOfficialCodexRoute(at: boundaryDate)
            case let .relay(profileID):
                _ = try routeStore.recordCodexRelayActivation(profileID: profileID, at: boundaryDate)
            case .unknown:
                _ = try routeStore.recordUnknownCodexRoute(at: boundaryDate)
            }
        } catch {
            CodexBarLog.logger(LogCategories.app).warning(
                "Could not reconcile the current Codex route boundary",
                metadata: ["error": String(describing: error)])
        }
    }

    static func endAtShutdown(at _: Date = Date()) {
        // Intentionally preserve the active on-disk Codex route across app restarts and updates.
        // External edits while Headroom is quit are reconciled from config.toml's mtime on launch.
    }

    @MainActor
    static func isExactRelayConfiguration(
        profile: RelayProfile,
        paths: RelayConfigurationPaths,
        transaction: RelayConfigurationTransaction) -> Bool
    {
        guard profile.configuration(for: .codex)?.isEnabled == true else { return false }
        var codexOnlyProfile = profile
        codexOnlyProfile.targets = profile.targets.map { configuration in
            var copy = configuration
            copy.isEnabled = configuration.app == .codex && configuration.isEnabled
            return copy
        }
        let mode: RelayCodexProviderMode = UserDefaultsCodexUnifiedHistoryStore().isEnabled
            ? .unified
            : .isolated
        let result = try? transaction.apply(
            profile: codexOnlyProfile,
            paths: paths,
            credentialStore: RouteBootstrapCredentialStore(),
            codexProviderMode: mode,
            dryRun: true)
        if let result,
           result.preview.changedTargets.isEmpty,
           result.preview.unchangedTargets == [.codex]
        {
            return true
        }
        let inspected = RelayExternalConfigurationInspector.inspect(paths: paths, profiles: [profile])
        return inspected.liveRouteByTarget[.codex] == .managedProfile(profile.id)
    }

    static func isVerifiedOfficialConfiguration(
        paths: RelayConfigurationPaths,
        transaction _: RelayConfigurationTransaction,
        fileSystem: LocalRelayConfigurationFileSystem) -> Bool
    {
        let data: Data?
        do {
            data = fileSystem.fileExists(at: paths.codexConfigURL)
                ? try fileSystem.readData(at: paths.codexConfigURL)
                : nil
        } catch {
            return false
        }
        switch CodexOfficialRouteConfigurationVerifier.topLevelProvider(in: data) {
        case .implicitOrOpenAI:
            return true
        case .shared:
            return CodexOfficialRouteConfigurationVerifier.hasExactSharedOfficialProvider(in: data)
        case .otherOrInvalid:
            return false
        }
    }
}

enum CodexOfficialRouteConfigurationVerifier {
    enum Provider: Equatable {
        case implicitOrOpenAI
        case shared
        case otherOrInvalid
    }

    static func isOfficialConfiguration(_ data: Data?) -> Bool {
        self.topLevelProvider(in: data) == .implicitOrOpenAI
    }

    static func topLevelProvider(in data: Data?) -> Provider {
        guard let data else { return .implicitOrOpenAI }
        guard let text = String(data: data, encoding: .utf8) else { return .otherOrInvalid }
        guard !text.contains("\"\"\""), !text.contains("'''") else { return .otherOrInvalid }
        var provider: String?
        var isInsideSection = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let line = self.strippingComment(from: String(rawLine)) else {
                return .otherOrInvalid
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("[") {
                guard let components = self.parseTableHeader(trimmed) else {
                    return .otherOrInvalid
                }
                isInsideSection = true
                if components == ["model_providers"] || self.isOpenAIProviderOverride(components) {
                    // An OpenAI-named provider can still point at a third-party base URL.
                    return .otherOrInvalid
                }
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { return .otherOrInvalid }
            guard let key = self.parseDottedKey(String(trimmed[..<equals])) else {
                return .otherOrInvalid
            }
            guard !isInsideSection else { continue }
            if key == ["model_providers"] || self.isOpenAIProviderOverride(key) {
                return .otherOrInvalid
            }
            guard key == ["model_provider"] else { continue }
            guard provider == nil,
                  let parsed = self.parseSingleLineString(String(trimmed[trimmed.index(after: equals)...]))
            else { return .otherOrInvalid }
            provider = parsed
        }

        return switch provider {
        case nil, "openai": Provider.implicitOrOpenAI
        case "codexbar_shared": Provider.shared
        default: Provider.otherOrInvalid
        }
    }

    static func hasExactSharedOfficialProvider(in data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        guard !text.contains("\"\"\""), !text.contains("'''") else { return false }
        let sharedSection = ["model_providers", "codexbar_shared"]
        let requiredKeys = Set(["name", "requires_openai_auth", "supports_websockets", "wire_api"])
        var isInsideSharedSection = false
        var foundSharedSection = false
        var matchedKeys: Set<String> = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let line = self.strippingComment(from: String(rawLine)) else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("[") {
                guard let components = self.parseTableHeader(trimmed) else { return false }
                if components.starts(with: sharedSection) {
                    guard components == sharedSection,
                          !trimmed.hasPrefix("[["),
                          !foundSharedSection
                    else { return false }
                    foundSharedSection = true
                    isInsideSharedSection = true
                } else {
                    isInsideSharedSection = false
                }
                continue
            }

            guard let equals = trimmed.firstIndex(of: "="),
                  let key = self.parseDottedKey(String(trimmed[..<equals]))
            else { return false }
            guard isInsideSharedSection else { continue }
            guard key.count == 1,
                  let field = key.first,
                  requiredKeys.contains(field),
                  !matchedKeys.contains(field)
            else { return false }
            let rawValue = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let matches: Bool = switch field {
            case "name": self.parseSingleLineString(rawValue) == "OpenAI"
            case "wire_api": self.parseSingleLineString(rawValue) == "responses"
            case "requires_openai_auth", "supports_websockets": rawValue == "true"
            default: false
            }
            guard matches else { return false }
            matchedKeys.insert(field)
        }

        return foundSharedSection && matchedKeys == requiredKeys
    }

    private static func isOpenAIProviderOverride(_ components: [String]) -> Bool {
        components.count >= 2
            && components[0] == "model_providers"
            && components[1] == "openai"
    }

    private static func parseTableHeader(_ value: String) -> [String]? {
        let isArrayTable = value.hasPrefix("[[")
        let rawName: Substring
        if isArrayTable {
            guard value.hasSuffix("]]"), value.count >= 4 else { return nil }
            rawName = value.dropFirst(2).dropLast(2)
        } else {
            guard value.hasSuffix("]"), value.count >= 2 else { return nil }
            rawName = value.dropFirst().dropLast()
        }
        return self.parseDottedKey(String(rawName))
    }

    /// Parses the TOML dotted-key grammar used by table headers and assignment keys. The launch
    /// route verifier intentionally fails closed on any syntax it cannot prove valid.
    private static func parseDottedKey(_ rawValue: String) -> [String]? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var index = value.startIndex
        var components: [String] = []

        func skipWhitespace() {
            while index < value.endIndex, value[index] == " " || value[index] == "\t" {
                index = value.index(after: index)
            }
        }

        func parseBareKey() -> String? {
            let start = index
            while index < value.endIndex {
                let scalars = value[index].unicodeScalars
                guard scalars.count == 1, let scalar = scalars.first else { break }
                let isBare = (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || scalar == "_"
                    || scalar == "-"
                guard isBare else { break }
                index = value.index(after: index)
            }
            guard start != index else { return nil }
            return String(value[start..<index])
        }

        func parseQuotedKey(quote: Character) -> String? {
            index = value.index(after: index)
            var result = ""
            while index < value.endIndex {
                let character = value[index]
                index = value.index(after: index)
                if character == quote { return result }
                guard character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                    return nil
                }
                guard quote == "\"", character == "\\" else {
                    result.append(character)
                    continue
                }
                guard index < value.endIndex else { return nil }
                let escaped = value[index]
                index = value.index(after: index)
                switch escaped {
                case "b": result.append("\u{0008}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "f": result.append("\u{000C}")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "u", "U":
                    let digitCount = escaped == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<digitCount {
                        guard index < value.endIndex, value[index].isHexDigit else { return nil }
                        hex.append(value[index])
                        index = value.index(after: index)
                    }
                    guard let scalarValue = UInt32(hex, radix: 16),
                          let scalar = UnicodeScalar(scalarValue)
                    else { return nil }
                    result.unicodeScalars.append(scalar)
                default:
                    return nil
                }
            }
            return nil
        }

        while true {
            skipWhitespace()
            guard index < value.endIndex else { return nil }
            let component: String? = switch value[index] {
            case "\"": parseQuotedKey(quote: "\"")
            case "'": parseQuotedKey(quote: "'")
            default: parseBareKey()
            }
            guard let component else { return nil }
            components.append(component)
            skipWhitespace()
            guard index < value.endIndex else { return components }
            guard value[index] == "." else { return nil }
            index = value.index(after: index)
        }
    }

    private static func strippingComment(from line: String) -> String? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
                continue
            }
            if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        guard quote == nil, !escaped else { return nil }
        return line
    }

    private static func parseSingleLineString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              let first = value.first,
              first == "\"" || first == "'",
              value.last == first
        else { return nil }
        let inner = value.dropFirst().dropLast()
        guard !inner.contains(first) else { return nil }
        return String(inner)
    }
}

private struct RouteBootstrapCredentialStore: RelayCredentialStoring, RelayCredentialLocating {
    func locator(for reference: String) throws -> RelayCredentialLocator {
        RelayCredentialLocator(service: FileRelayCredentialStore.locatorService, account: reference)
    }

    func loadCredential(reference _: String) throws -> String? {
        throw RelayCredentialStoreError.keychainUnavailable
    }

    func storeCredential(_: String, reference _: String) throws {
        throw RelayCredentialStoreError.keychainUnavailable
    }

    func removeCredential(reference _: String) throws {
        throw RelayCredentialStoreError.keychainUnavailable
    }
}
