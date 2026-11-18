import Foundation

public enum ExternalRelayCredentialKind: Equatable, Sendable {
    case inlineAPIKey
    case commandHelper(String)
    case environmentVariable(String)
    case missing
}

public struct DiscoveredExternalRelayTarget: Equatable, Sendable {
    public let app: RelayTargetApp
    public let providerID: String
    public let baseURL: URL
    public let apiFormat: RelayAPIFormat
    public let model: String?
    public let isActive: Bool
    public let credentialKind: ExternalRelayCredentialKind
    public let importableAPIKey: String?

    public init(
        app: RelayTargetApp,
        providerID: String,
        baseURL: URL,
        apiFormat: RelayAPIFormat,
        model: String?,
        isActive: Bool,
        credentialKind: ExternalRelayCredentialKind,
        importableAPIKey: String?)
    {
        self.app = app
        self.providerID = providerID
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.model = model
        self.isActive = isActive
        self.credentialKind = credentialKind
        self.importableAPIKey = importableAPIKey
    }
}

public struct DiscoveredExternalRelay: Identifiable, Equatable, Sendable {
    public let id: String
    public let providerKey: String
    public let displayName: String
    public let baseURL: URL
    public let apiFormat: RelayAPIFormat
    public let defaultModel: String?
    public let targets: [RelayTargetApp: DiscoveredExternalRelayTarget]
    public let credentialKind: ExternalRelayCredentialKind
    public let importableAPIKey: String?

    public init(
        id: String,
        providerKey: String,
        displayName: String,
        baseURL: URL,
        apiFormat: RelayAPIFormat,
        defaultModel: String?,
        targets: [RelayTargetApp: DiscoveredExternalRelayTarget],
        credentialKind: ExternalRelayCredentialKind,
        importableAPIKey: String?)
    {
        self.id = id
        self.providerKey = providerKey
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiFormat = apiFormat
        self.defaultModel = defaultModel
        self.targets = targets
        self.credentialKind = credentialKind
        self.importableAPIKey = importableAPIKey
    }

    public var configuredTargets: [RelayTargetApp] {
        RelayTargetApp.allCases.filter { self.targets[$0] != nil }
    }

    public var activeTargets: [RelayTargetApp] {
        RelayTargetApp.allCases.filter { self.targets[$0]?.isActive == true }
    }

    public var hasImportableAPIKey: Bool {
        self.importableAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public func makeRelayProfile(
        id: UUID = UUID(),
        existingProfiles: [RelayProfile] = [],
        externalProviderBaseURLsByKey: [String: Set<String>] = [:]) -> RelayProfile
    {
        let resolvedProviderKey = RelayExternalConfigurationInspector.nonConflictingProviderKey(
            preferredName: self.displayName,
            explicitProviderKey: self.providerKey,
            baseURL: self.baseURL,
            profileID: id,
            existingProfiles: existingProfiles,
            externalProviderBaseURLsByKey: externalProviderBaseURLsByKey)
        let inferredUsageMode: RelayUsageQueryMode = Self.looksLikeSub2API(
            name: self.displayName,
            providerKey: resolvedProviderKey,
            baseURL: self.baseURL) ? .sub2API : .disabled
        let targetConfigs = RelayTargetApp.allCases.map { app -> RelayTargetConfiguration in
            guard app != .claudeDesktop, let detail = self.targets[app] else {
                return RelayTargetConfiguration(app: app, model: nil, isEnabled: false)
            }
            let baseURLOverride: URL? = RelayExternalConfigurationInspector.normalizedEndpointKey(detail.baseURL)
                == RelayExternalConfigurationInspector.normalizedEndpointKey(self.baseURL)
                ? nil
                : detail.baseURL
            let formatOverride: RelayAPIFormat? = detail.apiFormat == self.apiFormat ? nil : detail.apiFormat
            return RelayTargetConfiguration(
                app: app,
                model: detail.model,
                baseURLOverride: baseURLOverride,
                apiFormatOverride: formatOverride,
                isEnabled: true)
        }
        return RelayProfile(
            id: id,
            name: self.displayName,
            baseURL: self.baseURL,
            apiFormat: self.apiFormat,
            defaultModel: self.defaultModel,
            credentialReference: RelayCredentialReference.make(for: id),
            credentialConfigured: self.hasImportableAPIKey,
            usageQueryMode: inferredUsageMode,
            targets: targetConfigs,
            visibleTargets: Set(RelayTargetApp.allCases),
            providerKey: resolvedProviderKey)
    }

    private static func looksLikeSub2API(name: String, providerKey: String, baseURL: URL) -> Bool {
        let combined = "\(name) \(providerKey) \(baseURL.host ?? "")".lowercased()
        return combined.contains("sub2api")
    }
}

public enum RelayLiveTargetRoute: Equatable, Sendable {
    case official
    case managedProfile(UUID)
    case external(DiscoveredExternalRelayTarget, displayName: String)
}

public struct RelayExternalConfigurationReport: Equatable, Sendable {
    public let liveRouteByTarget: [RelayTargetApp: RelayLiveTargetRoute]
    public let unimportedRelays: [DiscoveredExternalRelay]
    public let externalProviderBaseURLsByKey: [String: Set<String>]

    public init(
        liveRouteByTarget: [RelayTargetApp: RelayLiveTargetRoute],
        unimportedRelays: [DiscoveredExternalRelay],
        externalProviderBaseURLsByKey: [String: Set<String>])
    {
        self.liveRouteByTarget = liveRouteByTarget
        self.unimportedRelays = unimportedRelays
        self.externalProviderBaseURLsByKey = externalProviderBaseURLsByKey
    }
}

public enum RelayExternalConfigurationInspector {
    private static let managedCodexProviderIDs: Set<String> = ["codexbar_relay", "codexbar_shared"]
    private static let builtInOfficialProviderIDs: Set<String> = [
        "openai",
        "openai-codex",
        "anthropic",
        "opencode",
        "google",
        "github-copilot",
        "xai",
    ]

    public static func inspect(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem = LocalRelayConfigurationFileSystem())
        -> RelayExternalConfigurationReport
    {
        var liveRoutes: [RelayTargetApp: RelayLiveTargetRoute] = [:]
        var rawObservations: [RawProviderObservation] = []
        var externalURLsByKey: [String: Set<String>] = [:]

        let codexResult = self.inspectCodex(paths: paths, profiles: profiles, fileSystem: fileSystem)
        liveRoutes[.codex] = codexResult.route
        rawObservations.append(contentsOf: codexResult.observations)

        let claudeResult = self.inspectClaudeCode(paths: paths, profiles: profiles, fileSystem: fileSystem)
        liveRoutes[.claudeCode] = claudeResult.route
        rawObservations.append(contentsOf: claudeResult.observations)

        let grokResult = self.inspectGrokBuild(paths: paths, profiles: profiles, fileSystem: fileSystem)
        liveRoutes[.grokBuild] = grokResult.route
        rawObservations.append(contentsOf: grokResult.observations)

        let openCodeResult = self.inspectOpenCode(paths: paths, profiles: profiles, fileSystem: fileSystem)
        liveRoutes[.openCode] = openCodeResult.route
        rawObservations.append(contentsOf: openCodeResult.observations)

        let piResult = self.inspectPiAgent(paths: paths, profiles: profiles, fileSystem: fileSystem)
        liveRoutes[.piAgent] = piResult.route
        rawObservations.append(contentsOf: piResult.observations)

        for obs in rawObservations {
            let slug = RelayProviderKey.slug(for: obs.providerKey)
            externalURLsByKey[slug, default: []].insert(self.normalizedEndpointKey(obs.detail.baseURL))
        }

        let unimported = self.groupUnimportedObservations(rawObservations, profiles: profiles)
        return RelayExternalConfigurationReport(
            liveRouteByTarget: liveRoutes,
            unimportedRelays: unimported,
            externalProviderBaseURLsByKey: externalURLsByKey)
    }

    public static func nonConflictingProviderKey(
        preferredName: String,
        explicitProviderKey: String? = nil,
        baseURL: URL,
        profileID: UUID,
        existingProfiles: [RelayProfile],
        externalProviderBaseURLsByKey: [String: Set<String>] = [:]) -> String
    {
        let baseSlug = RelayProviderKey.slug(for: explicitProviderKey ?? preferredName, fallbackID: profileID)
        let normalizedURL = self.normalizedEndpointKey(baseURL)
        let takenByProfiles = Set(existingProfiles.filter { $0.id != profileID }.map(\.providerKey))

        func conflicts(_ candidate: String) -> Bool {
            if takenByProfiles.contains(candidate) {
                return true
            }
            if explicitProviderKey == nil,
               self.builtInOfficialProviderIDs.contains(candidate) || self.managedCodexProviderIDs.contains(candidate)
            {
                return true
            }
            if let externalURLs = externalProviderBaseURLsByKey[candidate],
               !externalURLs.isEmpty,
               !externalURLs.contains(normalizedURL)
            {
                return true
            }
            return false
        }

        if !conflicts(baseSlug) {
            return baseSlug
        }
        let headroomCandidate = "\(baseSlug)-headroom"
        if !conflicts(headroomCandidate) {
            return headroomCandidate
        }
        var suffix = 2
        while suffix < 1000 {
            let numbered = "\(baseSlug)-\(suffix)"
            if !conflicts(numbered) {
                return numbered
            }
            suffix += 1
        }
        return RelayProviderKey.slug(for: "", fallbackID: profileID)
    }

    public static func normalizedEndpointKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" { path = "" }
        components.path = path
        components.fragment = nil
        return components.string ?? url.absoluteString.lowercased()
    }
}

// MARK: - Per-Target Inspection

extension RelayExternalConfigurationInspector {
    private struct RawProviderObservation {
        let providerKey: String
        let displayName: String
        let detail: DiscoveredExternalRelayTarget
    }

    private struct TargetInspectionResult {
        let route: RelayLiveTargetRoute
        let observations: [RawProviderObservation]
    }

    private static func inspectCodex(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem) -> TargetInspectionResult
    {
        guard let data = self.readDataIfExists(paths.codexConfigURL, fileSystem: fileSystem),
              let source = String(data: data, encoding: .utf8)
        else {
            return TargetInspectionResult(route: .official, observations: [])
        }
        let doc = SimpleTOMLDocument.parse(source)
        let activeProviderID = Self.nonEmpty(doc.topLevel["model_provider"]?.stringValue)
        let topModel = Self.nonEmpty(doc.topLevel["model"]?.stringValue)
        let authJSONKey = self.readCodexAuthAPIKey(
            codexDirectory: paths.codexConfigURL.deletingLastPathComponent(),
            fileSystem: fileSystem)

        let providerSections = self.extractPrefixedSections(doc.sections, prefix: "model_providers.")
        var observations: [RawProviderObservation] = []
        var activeRoute: RelayLiveTargetRoute = .official

        for (providerID, fields) in providerSections.sorted(by: { $0.key < $1.key }) {
            let authFields = doc.sections["model_providers.\(providerID).auth"] ?? [:]
            let helperRef = Self.extractHeadroomCredentialReference(fromTOMLAuth: authFields)
            let isActive = activeProviderID == providerID

            if providerID == "codexbar_shared",
               fields["requires_openai_auth"]?.boolValue == true,
               Self.nonEmpty(fields["base_url"]?.stringValue) == nil
            {
                if isActive { activeRoute = .official }
                continue
            }
            guard let rawBaseURL = Self.nonEmpty(fields["base_url"]?.stringValue),
                  let baseURL = RelayEndpointValidator.validatedURL(rawBaseURL)
            else {
                continue
            }

            let wireAPI = Self.nonEmpty(fields["wire_api"]?.stringValue)?.lowercased()
            let format: RelayAPIFormat = (wireAPI == "chat" || wireAPI == "completions")
                ? .openAIChatCompletions
                : .openAIResponses
            let displayName = Self.nonEmpty(fields["name"]?.stringValue)
                ?? Self.humanizeProviderName(providerID: providerID, baseURL: baseURL)

            if let helperRef,
               let matched = profiles.first(where: { $0.credentialReference == helperRef })
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
                continue
            }
            if self.managedCodexProviderIDs.contains(providerID) {
                if isActive {
                    if let matched = self.matchManagedProfile(
                        target: .codex,
                        providerID: nil,
                        baseURL: baseURL,
                        model: topModel,
                        profiles: profiles)
                    {
                        activeRoute = .managedProfile(matched.id)
                    } else {
                        let detail = DiscoveredExternalRelayTarget(
                            app: .codex,
                            providerID: providerID,
                            baseURL: baseURL,
                            apiFormat: format,
                            model: topModel,
                            isActive: true,
                            credentialKind: Self.tomlCredentialKind(
                                fields: fields,
                                authFields: authFields,
                                fallbackKey: authJSONKey),
                            importableAPIKey: Self.tomlImportableKey(fields: fields, fallbackKey: authJSONKey))
                        activeRoute = .external(detail, displayName: displayName)
                        observations.append(RawProviderObservation(
                            providerKey: RelayProviderKey.slug(for: displayName),
                            displayName: displayName,
                            detail: detail))
                    }
                }
                continue
            }
            if self.builtInOfficialProviderIDs.contains(providerID.lowercased()) {
                if isActive { activeRoute = .official }
                continue
            }

            let inlineKey = Self.tomlImportableKey(
                fields: fields,
                fallbackKey: isActive || Self.usesDefaultOpenAIEnvKey(fields) ? authJSONKey : nil)
            let credKind = Self.tomlCredentialKind(
                fields: fields,
                authFields: authFields,
                fallbackKey: inlineKey)
            let detail = DiscoveredExternalRelayTarget(
                app: .codex,
                providerID: providerID,
                baseURL: baseURL,
                apiFormat: format,
                model: isActive ? topModel : nil,
                isActive: isActive,
                credentialKind: credKind,
                importableAPIKey: inlineKey)

            if let matched = self.matchManagedProfile(
                target: .codex,
                providerID: providerID,
                baseURL: baseURL,
                model: topModel,
                profiles: profiles)
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
            } else {
                if isActive { activeRoute = .external(detail, displayName: displayName) }
                observations.append(RawProviderObservation(
                    providerKey: providerID,
                    displayName: displayName,
                    detail: detail))
            }
        }

        if let activeProviderID,
           activeProviderID != "openai",
           providerSections[activeProviderID] == nil
        {
            // Unresolved custom provider name without a matching section.
            activeRoute = .official
        }

        return TargetInspectionResult(route: activeRoute, observations: observations)
    }

    private static func inspectClaudeCode(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem) -> TargetInspectionResult
    {
        guard let root = self.readJSONCObject(paths.claudeCodeSettingsURL, fileSystem: fileSystem) else {
            return TargetInspectionResult(route: .official, observations: [])
        }
        let env = root["env"] as? [String: Any] ?? [:]
        let apiKeyHelper = Self.nonEmpty(root["apiKeyHelper"] as? String)
        if let apiKeyHelper,
           let ref = Self.extractHeadroomCredentialReference(fromCommandString: apiKeyHelper),
           let matched = profiles.first(where: { $0.credentialReference == ref })
        {
            return TargetInspectionResult(route: .managedProfile(matched.id), observations: [])
        }

        guard let rawBaseURL = Self.nonEmpty(env["ANTHROPIC_BASE_URL"] as? String),
              let baseURL = RelayEndpointValidator.validatedURL(rawBaseURL)
        else {
            return TargetInspectionResult(route: .official, observations: [])
        }

        let inlineToken = Self.nonEmpty(env["ANTHROPIC_AUTH_TOKEN"] as? String)
            ?? Self.nonEmpty(env["ANTHROPIC_API_KEY"] as? String)
        let model = Self.nonEmpty(env["ANTHROPIC_MODEL"] as? String)
            ?? Self.nonEmpty(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String)
            ?? Self.nonEmpty(root["model"] as? String)
        let credKind: ExternalRelayCredentialKind = if inlineToken != nil {
            .inlineAPIKey
        } else if let apiKeyHelper {
            .commandHelper(apiKeyHelper)
        } else {
            .missing
        }
        let displayName = Self.humanizeProviderName(providerID: nil, baseURL: baseURL)
        let inferredKey = RelayProviderKey.slug(for: displayName)

        if let matched = self.matchManagedProfile(
            target: .claudeCode,
            providerID: inferredKey,
            baseURL: baseURL,
            model: model,
            profiles: profiles,
            allowEndpointOnlyMatch: true)
        {
            return TargetInspectionResult(route: .managedProfile(matched.id), observations: [])
        }

        let detail = DiscoveredExternalRelayTarget(
            app: .claudeCode,
            providerID: inferredKey,
            baseURL: baseURL,
            apiFormat: .anthropicMessages,
            model: model,
            isActive: true,
            credentialKind: credKind,
            importableAPIKey: inlineToken)
        let observation = RawProviderObservation(
            providerKey: inferredKey,
            displayName: displayName,
            detail: detail)
        return TargetInspectionResult(
            route: .external(detail, displayName: displayName),
            observations: [observation])
    }

    private static func inspectGrokBuild(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem) -> TargetInspectionResult
    {
        guard let data = self.readDataIfExists(paths.grokBuildConfigURL, fileSystem: fileSystem),
              let source = String(data: data, encoding: .utf8)
        else {
            return TargetInspectionResult(route: .official, observations: [])
        }
        let doc = SimpleTOMLDocument.parse(source)
        let defaultProviderID = Self.nonEmpty(doc.sections["models"]?["default"]?.stringValue)
        let modelSections = self.extractPrefixedSections(doc.sections, prefix: "model.")
        var observations: [RawProviderObservation] = []
        var activeRoute: RelayLiveTargetRoute = .official

        for (providerID, fields) in modelSections.sorted(by: { $0.key < $1.key }) {
            let isActive = defaultProviderID == providerID
            guard let rawBaseURL = Self.nonEmpty(fields["base_url"]?.stringValue),
                  let baseURL = RelayEndpointValidator.validatedURL(rawBaseURL)
            else {
                continue
            }
            let model = Self.nonEmpty(fields["model"]?.stringValue)
            let displayName = Self.nonEmpty(fields["name"]?.stringValue)
                ?? Self.humanizeProviderName(providerID: providerID, baseURL: baseURL)
            let inlineKey = Self.nonEmpty(fields["api_key"]?.stringValue)
            let envKey = Self.nonEmpty(fields["env_key"]?.stringValue)
            let credKind: ExternalRelayCredentialKind = if inlineKey != nil {
                .inlineAPIKey
            } else if let envKey {
                .environmentVariable(envKey)
            } else {
                .missing
            }
            let backend = Self.nonEmpty(fields["api_backend"]?.stringValue)?.lowercased()
            let format: RelayAPIFormat = backend == "chat" ? .openAIChatCompletions : .openAIResponses

            if let matched = self.matchManagedProfile(
                target: .grokBuild,
                providerID: providerID == "codexbar-relay" ? nil : providerID,
                baseURL: baseURL,
                model: model,
                profiles: profiles,
                allowEndpointOnlyMatch: providerID == "codexbar-relay")
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
                continue
            }
            if providerID == "codexbar-relay" {
                continue
            }

            let detail = DiscoveredExternalRelayTarget(
                app: .grokBuild,
                providerID: providerID,
                baseURL: baseURL,
                apiFormat: format,
                model: model,
                isActive: isActive,
                credentialKind: credKind,
                importableAPIKey: inlineKey)
            if isActive { activeRoute = .external(detail, displayName: displayName) }
            observations.append(RawProviderObservation(
                providerKey: providerID,
                displayName: displayName,
                detail: detail))
        }

        return TargetInspectionResult(route: activeRoute, observations: observations)
    }

    private static func inspectOpenCode(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem) -> TargetInspectionResult
    {
        guard let root = self.readJSONCObject(paths.openCodeConfigURL, fileSystem: fileSystem) else {
            return TargetInspectionResult(route: .official, observations: [])
        }
        let activeModelSpec = Self.nonEmpty(root["model"] as? String)
        let activeParts: (providerID: String, modelID: String?)? = activeModelSpec.flatMap { spec in
            guard let slash = spec.firstIndex(of: "/") else { return (spec, nil) }
            let provider = String(spec[..<slash])
            let model = String(spec[spec.index(after: slash)...])
            return (provider, Self.nonEmpty(model))
        }
        let providersDict = (root["provider"] as? [String: Any])
            ?? (root["providers"] as? [String: Any])
            ?? [:]

        var observations: [RawProviderObservation] = []
        var activeRoute: RelayLiveTargetRoute = .official

        for providerID in providersDict.keys.sorted() {
            guard let entry = providersDict[providerID] as? [String: Any] else { continue }
            let isActive = activeParts?.providerID == providerID
            let options = entry["options"] as? [String: Any] ?? [:]
            let rawBaseURL = Self.nonEmpty(options["baseURL"] as? String)
                ?? Self.nonEmpty(options["baseUrl"] as? String)
                ?? Self.nonEmpty(entry["baseURL"] as? String)
            guard let rawBaseURL,
                  let baseURL = RelayEndpointValidator.validatedURL(rawBaseURL)
            else {
                continue
            }

            let npmPackage = Self.nonEmpty(entry["npm"] as? String)?.lowercased() ?? ""
            let format: RelayAPIFormat = if npmPackage.contains("anthropic") {
                .anthropicMessages
            } else if npmPackage.contains("openai-compatible") {
                .openAIChatCompletions
            } else {
                .openAIResponses
            }
            let modelsMap = entry["models"] as? [String: Any] ?? [:]
            let firstCatalogModel = modelsMap.keys.sorted().first
            let model = (isActive ? activeParts?.modelID : nil) ?? firstCatalogModel
            let displayName = Self.nonEmpty(entry["name"] as? String)
                ?? Self.humanizeProviderName(providerID: providerID, baseURL: baseURL)
            let rawKey = Self.nonEmpty(options["apiKey"] as? String)
                ?? Self.nonEmpty(entry["apiKey"] as? String)
            let (credKind, importableKey) = Self.classifyJSONAPIKey(rawKey)

            if let matched = self.matchManagedProfile(
                target: .openCode,
                providerID: providerID == "codexbar-relay" ? nil : providerID,
                baseURL: baseURL,
                model: model,
                profiles: profiles,
                allowEndpointOnlyMatch: providerID == "codexbar-relay")
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
                continue
            }
            if providerID == "codexbar-relay" {
                continue
            }

            let detail = DiscoveredExternalRelayTarget(
                app: .openCode,
                providerID: providerID,
                baseURL: baseURL,
                apiFormat: format,
                model: model,
                isActive: isActive,
                credentialKind: credKind,
                importableAPIKey: importableKey)
            if isActive { activeRoute = .external(detail, displayName: displayName) }
            observations.append(RawProviderObservation(
                providerKey: providerID,
                displayName: displayName,
                detail: detail))
        }

        return TargetInspectionResult(route: activeRoute, observations: observations)
    }

    private static func inspectPiAgent(
        paths: RelayConfigurationPaths,
        profiles: [RelayProfile],
        fileSystem: any RelayConfigurationFileSystem) -> TargetInspectionResult
    {
        let settingsRoot = self.readJSONCObject(paths.piAgentSettingsURL, fileSystem: fileSystem) ?? [:]
        let modelsRoot = self.readJSONCObject(paths.piAgentModelsURL, fileSystem: fileSystem) ?? [:]
        let authURL = paths.piAgentModelsURL.deletingLastPathComponent().appendingPathComponent("auth.json")
        let authRoot = self.readJSONCObject(authURL, fileSystem: fileSystem) ?? [:]

        let defaultProvider = Self.nonEmpty(settingsRoot["defaultProvider"] as? String)
        let defaultModel = Self.nonEmpty(settingsRoot["defaultModel"] as? String)
        let providersDict = modelsRoot["providers"] as? [String: Any] ?? [:]

        var observations: [RawProviderObservation] = []
        var activeRoute: RelayLiveTargetRoute = .official

        for providerID in providersDict.keys.sorted() {
            guard let entry = providersDict[providerID] as? [String: Any] else { continue }
            let isActive = defaultProvider == providerID
            let rawAPIKey = Self.nonEmpty(entry["apiKey"] as? String)
            if let rawAPIKey,
               rawAPIKey.hasPrefix("!"),
               let ref = Self.extractHeadroomCredentialReference(fromCommandString: String(rawAPIKey.dropFirst())),
               let matched = profiles.first(where: { $0.credentialReference == ref })
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
                continue
            }

            let rawBaseURL = Self.nonEmpty(entry["baseUrl"] as? String)
                ?? Self.nonEmpty(entry["baseURL"] as? String)
            guard let rawBaseURL,
                  let baseURL = RelayEndpointValidator.validatedURL(rawBaseURL)
            else {
                continue
            }

            let apiType = Self.nonEmpty(entry["api"] as? String)?.lowercased() ?? ""
            let format: RelayAPIFormat = if apiType.contains("anthropic") {
                .anthropicMessages
            } else if apiType.contains("completions") {
                .openAIChatCompletions
            } else {
                .openAIResponses
            }
            let modelsList = entry["models"] as? [[String: Any]] ?? []
            let firstModelID = modelsList.compactMap { Self.nonEmpty($0["id"] as? String) }.first
            let model = (isActive ? defaultModel : nil) ?? firstModelID
            let displayName = Self.nonEmpty(entry["name"] as? String)
                ?? Self.humanizeProviderName(providerID: providerID, baseURL: baseURL)

            let authFileKey = Self.extractPiAuthKey(for: providerID, in: authRoot)
            let (credKind, importableKey): (ExternalRelayCredentialKind, String?) = if let rawAPIKey {
                if rawAPIKey.hasPrefix("!") {
                    (.commandHelper(String(rawAPIKey.dropFirst())), authFileKey)
                } else {
                    Self.classifyJSONAPIKey(rawAPIKey)
                }
            } else if let authFileKey {
                (.inlineAPIKey, authFileKey)
            } else {
                (.missing, nil)
            }

            if let matched = self.matchManagedProfile(
                target: .piAgent,
                providerID: providerID == "codexbar-relay" ? nil : providerID,
                baseURL: baseURL,
                model: model,
                profiles: profiles,
                allowEndpointOnlyMatch: providerID == "codexbar-relay")
            {
                if isActive { activeRoute = .managedProfile(matched.id) }
                continue
            }
            if providerID == "codexbar-relay" {
                continue
            }

            let detail = DiscoveredExternalRelayTarget(
                app: .piAgent,
                providerID: providerID,
                baseURL: baseURL,
                apiFormat: format,
                model: model,
                isActive: isActive,
                credentialKind: credKind,
                importableAPIKey: importableKey)
            if isActive { activeRoute = .external(detail, displayName: displayName) }
            observations.append(RawProviderObservation(
                providerKey: providerID,
                displayName: displayName,
                detail: detail))
        }

        return TargetInspectionResult(route: activeRoute, observations: observations)
    }
}

// MARK: - Profile Matching & Grouping

extension RelayExternalConfigurationInspector {
    private static func matchManagedProfile(
        target: RelayTargetApp,
        providerID: String?,
        baseURL: URL,
        model: String?,
        profiles: [RelayProfile],
        allowEndpointOnlyMatch: Bool = false) -> RelayProfile?
    {
        let normalizedURL = self.normalizedEndpointKey(baseURL)
        let normalizedSlug = providerID.map { RelayProviderKey.slug(for: $0) }

        if let normalizedSlug {
            let keyAndURLMatches = profiles.filter { profile in
                let targetURL = profile.targets.first(where: { $0.app == target })?.baseURLOverride ?? profile.baseURL
                return profile.providerKey == normalizedSlug
                    && self.normalizedEndpointKey(targetURL) == normalizedURL
            }
            if keyAndURLMatches.count == 1 {
                return keyAndURLMatches.first
            }
            if let model,
               let exactModel = keyAndURLMatches.first(where: {
                   ($0.configuration(for: target)?.model ?? $0.defaultModel) == model
               })
            {
                return exactModel
            }
        }

        guard allowEndpointOnlyMatch || normalizedSlug == nil else { return nil }
        let endpointMatches = profiles.filter { profile in
            let targetConfig = profile.targets.first(where: { $0.app == target })
            let targetURL = targetConfig?.baseURLOverride ?? profile.baseURL
            return (targetConfig?.isEnabled == true)
                && self.normalizedEndpointKey(targetURL) == normalizedURL
        }
        if endpointMatches.count == 1 {
            return endpointMatches.first
        }
        if let model {
            let modelMatches = endpointMatches.filter {
                ($0.configuration(for: target)?.model ?? $0.defaultModel) == model
            }
            if modelMatches.count == 1 {
                return modelMatches.first
            }
        }
        return nil
    }

    private static func groupUnimportedObservations(
        _ observations: [RawProviderObservation],
        profiles: [RelayProfile]) -> [DiscoveredExternalRelay]
    {
        struct Bucket {
            var providerKey: String
            var displayName: String
            var baseURL: URL
            var primaryFormat: RelayAPIFormat
            var targets: [RelayTargetApp: DiscoveredExternalRelayTarget]
            var credentialKind: ExternalRelayCredentialKind
            var importableAPIKey: String?
        }

        var bucketsByKey: [String: Bucket] = [:]
        var orderedKeys: [String] = []

        for obs in observations {
            let slug = RelayProviderKey.slug(for: obs.providerKey)
            let endpointKey = self.normalizedEndpointKey(obs.detail.baseURL)
            if profiles.contains(where: { profile in
                let targetURL = profile.targets.first(where: { $0.app == obs.detail.app })?.baseURLOverride
                    ?? profile.baseURL
                return profile.providerKey == slug && self.normalizedEndpointKey(targetURL) == endpointKey
            }) {
                continue
            }

            let groupID = "\(slug)|\(endpointKey)"
            if var existing = bucketsByKey[groupID] {
                if let currentTarget = existing.targets[obs.detail.app] {
                    if obs.detail.isActive, !currentTarget.isActive {
                        existing.targets[obs.detail.app] = obs.detail
                    }
                } else {
                    existing.targets[obs.detail.app] = obs.detail
                }
                if existing.importableAPIKey == nil, let key = obs.detail.importableAPIKey {
                    existing.importableAPIKey = key
                    existing.credentialKind = .inlineAPIKey
                }
                if obs.detail.app == .codex, obs.detail.apiFormat == .openAIResponses {
                    existing.primaryFormat = .openAIResponses
                }
                bucketsByKey[groupID] = existing
            } else {
                orderedKeys.append(groupID)
                bucketsByKey[groupID] = Bucket(
                    providerKey: slug,
                    displayName: obs.displayName,
                    baseURL: obs.detail.baseURL,
                    primaryFormat: obs.detail.apiFormat,
                    targets: [obs.detail.app: obs.detail],
                    credentialKind: obs.detail.credentialKind,
                    importableAPIKey: obs.detail.importableAPIKey)
            }
        }

        return orderedKeys.compactMap { key -> DiscoveredExternalRelay? in
            guard let bucket = bucketsByKey[key] else { return nil }
            let defaultModel = RelayTargetApp.allCases
                .compactMap { bucket.targets[$0]?.model }
                .first
            return DiscoveredExternalRelay(
                id: key,
                providerKey: bucket.providerKey,
                displayName: bucket.displayName,
                baseURL: bucket.baseURL,
                apiFormat: bucket.primaryFormat,
                defaultModel: defaultModel,
                targets: bucket.targets,
                credentialKind: bucket.credentialKind,
                importableAPIKey: bucket.importableAPIKey)
        }
        .sorted { lhs, rhs in
            let lhsActive = !lhs.activeTargets.isEmpty
            let rhsActive = !rhs.activeTargets.isEmpty
            if lhsActive != rhsActive { return lhsActive && !rhsActive }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

// MARK: - Helpers & Lightweight Readers

extension RelayExternalConfigurationInspector {
    private static func readDataIfExists(_ url: URL, fileSystem: any RelayConfigurationFileSystem) -> Data? {
        guard fileSystem.fileExists(at: url) else { return nil }
        return try? fileSystem.readData(at: url)
    }

    static func readJSONCObject(_ url: URL, fileSystem: any RelayConfigurationFileSystem) -> [String: Any]? {
        guard let data = self.readDataIfExists(url, fileSystem: fileSystem),
              let sanitized = stripJSONCCommentsAndTrailingCommas(data)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: sanitized)) as? [String: Any]
    }

    static func stripJSONCCommentsAndTrailingCommas(_ data: Data) -> Data? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        var withoutComments = ""
        var index = source.startIndex
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let ch = source[index]
            if inString {
                withoutComments.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if ch == "\"" {
                inString = true
                withoutComments.append(ch)
                index = next
            } else if ch == "/", next < source.endIndex, source[next] == "/" {
                var cursor = source.index(after: next)
                while cursor < source.endIndex, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                index = cursor
            } else if ch == "/", next < source.endIndex, source[next] == "*" {
                var cursor = source.index(after: next)
                var closed = false
                while cursor < source.endIndex {
                    let after = source.index(after: cursor)
                    if source[cursor] == "*", after < source.endIndex, source[after] == "/" {
                        index = source.index(after: after)
                        closed = true
                        break
                    }
                    cursor = after
                }
                if !closed { return nil }
            } else {
                withoutComments.append(ch)
                index = next
            }
        }
        if inString { return nil }

        var cleaned = ""
        var cursor = withoutComments.startIndex
        inString = false
        escaped = false
        while cursor < withoutComments.endIndex {
            let ch = withoutComments[cursor]
            if inString {
                cleaned.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else if ch == "\"" {
                inString = true
                cleaned.append(ch)
            } else if ch == "," {
                var lookahead = withoutComments.index(after: cursor)
                while lookahead < withoutComments.endIndex, withoutComments[lookahead].isWhitespace {
                    lookahead = withoutComments.index(after: lookahead)
                }
                if lookahead < withoutComments.endIndex,
                   withoutComments[lookahead] == "}" || withoutComments[lookahead] == "]"
                {
                    // Skip trailing comma
                } else {
                    cleaned.append(ch)
                }
            } else {
                cleaned.append(ch)
            }
            cursor = withoutComments.index(after: cursor)
        }
        return Data(cleaned.utf8)
    }

    private static func readCodexAuthAPIKey(
        codexDirectory: URL,
        fileSystem: any RelayConfigurationFileSystem) -> String?
    {
        let authURL = codexDirectory.appendingPathComponent("auth.json")
        guard let root = self.readJSONCObject(authURL, fileSystem: fileSystem),
              let key = Self.nonEmpty(root["OPENAI_API_KEY"] as? String),
              key.lowercased() != "null"
        else { return nil }
        return key
    }

    private static func extractPiAuthKey(for providerID: String, in authRoot: [String: Any]) -> String? {
        if let direct = nonEmpty(authRoot[providerID] as? String) {
            return direct
        }
        if let dict = authRoot[providerID] as? [String: Any] {
            let type = (dict["type"] as? String)?.lowercased()
            if type == nil || type == "api_key" || type == "apikey" {
                return Self.nonEmpty(dict["key"] as? String) ?? Self.nonEmpty(dict["apiKey"] as? String)
            }
        }
        return nil
    }

    private static func classifyJSONAPIKey(_ rawKey: String?) -> (ExternalRelayCredentialKind, String?) {
        guard let rawKey = nonEmpty(rawKey) else { return (.missing, nil) }
        if rawKey.hasPrefix("{env:"), rawKey.hasSuffix("}") {
            let name = String(rawKey.dropFirst(5).dropLast())
            return (.environmentVariable(name), nil)
        }
        if rawKey.hasPrefix("$") {
            return (.environmentVariable(String(rawKey.dropFirst())), nil)
        }
        return (.inlineAPIKey, rawKey)
    }

    private static func usesDefaultOpenAIEnvKey(_ fields: [String: SimpleTOMLValue]) -> Bool {
        guard let envKey = nonEmpty(fields["env_key"]?.stringValue) else { return true }
        return envKey == "OPENAI_API_KEY"
    }

    private static func tomlImportableKey(
        fields: [String: SimpleTOMLValue],
        fallbackKey: String?) -> String?
    {
        self.nonEmpty(fields["experimental_bearer_token"]?.stringValue)
            ?? self.nonEmpty(fields["api_key"]?.stringValue)
            ?? fallbackKey
    }

    private static func tomlCredentialKind(
        fields: [String: SimpleTOMLValue],
        authFields: [String: SimpleTOMLValue],
        fallbackKey: String?) -> ExternalRelayCredentialKind
    {
        if self.tomlImportableKey(fields: fields, fallbackKey: fallbackKey) != nil {
            return .inlineAPIKey
        }
        if let command = nonEmpty(authFields["command"]?.stringValue) {
            return .commandHelper(command)
        }
        if let envKey = Self.nonEmpty(fields["env_key"]?.stringValue) {
            return .environmentVariable(envKey)
        }
        return .missing
    }

    private static func extractHeadroomCredentialReference(
        fromTOMLAuth authFields: [String: SimpleTOMLValue]) -> String?
    {
        guard let args = authFields["args"]?.stringArrayValue,
              args.contains("credential-helper"),
              let refIndex = args.firstIndex(of: "--reference"),
              args.indices.contains(refIndex + 1)
        else { return nil }
        return Self.nonEmpty(args[refIndex + 1])
    }

    private static func extractHeadroomCredentialReference(fromCommandString command: String) -> String? {
        guard command.contains("credential-helper"),
              let range = command.range(of: "--reference")
        else { return nil }
        let remainder = command[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("'") {
            let dropped = remainder.dropFirst()
            if let endQuote = dropped.firstIndex(of: "'") {
                return Self.nonEmpty(String(dropped[..<endQuote]))
            }
        } else if remainder.hasPrefix("\"") {
            let dropped = remainder.dropFirst()
            if let endQuote = dropped.firstIndex(of: "\"") {
                return Self.nonEmpty(String(dropped[..<endQuote]))
            }
        }
        let token = remainder.prefix { !$0.isWhitespace }
        return Self.nonEmpty(String(token))
    }

    private static func extractPrefixedSections(
        _ sections: [String: [String: SimpleTOMLValue]],
        prefix: String) -> [String: [String: SimpleTOMLValue]]
    {
        var result: [String: [String: SimpleTOMLValue]] = [:]
        for (sectionName, values) in sections where sectionName.hasPrefix(prefix) {
            let suffix = String(sectionName.dropFirst(prefix.count))
            guard !suffix.isEmpty, !suffix.contains(".") else { continue }
            result[suffix] = values
        }
        return result
    }

    private static func humanizeProviderName(providerID: String?, baseURL: URL) -> String {
        if let host = baseURL.host?.lowercased(),
           host == "127.0.0.1" || host == "localhost" || host == "::1"
        {
            if baseURL.port == 15721 {
                return "CC Switch Local"
            }
            if let providerID = nonEmpty(providerID) {
                return providerID
            }
            return baseURL.port.map { "Local API (:\($0))" } ?? "Local API"
        }
        if let providerID = Self.nonEmpty(providerID) {
            return providerID
        }
        guard let host = baseURL.host else { return "External API" }
        let parts = host.split(separator: ".").map(String.init)
        let filtered = parts
            .filter { !["api", "www", "v1", "com", "net", "org", "io", "ai", "dev", "tech"].contains($0.lowercased()) }
        if let main = filtered.first ?? parts.first, !main.isEmpty {
            return main.prefix(1).uppercased() + main.dropFirst()
        }
        return host
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Minimal Read-Only TOML Parser

enum SimpleTOMLValue: Equatable {
    case string(String)
    case bool(Bool)
    case stringArray([String])

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var stringArrayValue: [String]? {
        if case let .stringArray(values) = self { return values }
        return nil
    }
}

struct SimpleTOMLDocument {
    var topLevel: [String: SimpleTOMLValue] = [:]
    var sections: [String: [String: SimpleTOMLValue]] = [:]

    static func parse(_ source: String) -> Self {
        var doc = Self()
        var currentSection: String?
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for rawLine in lines {
            let line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                currentSection = Self.parseSectionHeader(line)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let rawKey = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard let key = Self.canonicalPath(rawKey),
                  let parsedValue = Self.parseValue(rawValue)
            else { continue }

            if let currentSection {
                doc.sections[currentSection, default: [:]][key] = parsedValue
            } else {
                doc.topLevel[key] = parsedValue
            }
        }
        return doc
    }

    private static func parseSectionHeader(_ line: String) -> String? {
        if line.hasPrefix("[["), let close = line.range(of: "]]") {
            let inner = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            return Self.canonicalPath(inner)
        }
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let inner = String(line[line.index(after: line.startIndex)..<close])
        return Self.canonicalPath(inner)
    }

    static func canonicalPath(_ raw: String) -> String? {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in raw.trimmingCharacters(in: .whitespaces) {
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    current.append(ch)
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                let seg = current.trimmingCharacters(in: .whitespaces)
                guard !seg.isEmpty else { return nil }
                segments.append(seg)
                current = ""
            } else {
                current.append(ch)
            }
        }
        guard quote == nil else { return nil }
        let tail = current.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return nil }
        segments.append(tail)
        return segments.joined(separator: ".")
    }

    private static func parseValue(_ raw: String) -> SimpleTOMLValue? {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let str = parseQuotedString(raw) {
            return .string(str)
        }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            return Self.parseStringArray(inner).map(SimpleTOMLValue.stringArray)
        }
        return nil
    }

    private static func parseQuotedString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.first == "'", trimmed.last == "'" {
            return String(trimmed.dropFirst().dropLast())
        }
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        var out = ""
        var escaped = false
        for ch in trimmed.dropFirst().dropLast() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func parseStringArray(_ inner: String) -> [String]? {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var elements: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for ch in trimmed {
            if let activeQuote = quote {
                token.append(ch)
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                token.append(ch)
            } else if ch == "," {
                if let parsed = Self.parseQuotedString(token) {
                    elements.append(parsed)
                }
                token = ""
            } else {
                token.append(ch)
            }
        }
        let tail = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, let parsed = Self.parseQuotedString(tail) {
            elements.append(parsed)
        }
        return elements
    }

    private static func stripComment(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if let activeQuote = quote {
                out.append(ch)
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", ch == "\\" {
                    escaped = true
                } else if ch == activeQuote {
                    quote = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                out.append(ch)
            } else if ch == "#" {
                break
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
