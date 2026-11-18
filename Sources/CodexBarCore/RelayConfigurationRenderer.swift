import Foundation

struct RelayConfigurationRenderer {
    let fileSystem: any RelayConfigurationFileSystem
    let paths: RelayConfigurationPaths

    func render(
        profile: RelayProfile,
        credential: RelayRenderCredential,
        codexProviderMode: RelayCodexProviderMode = .isolated,
        codexServiceTier: CodexServiceTier? = nil,
        retiredProviderKeys: Set<String> = []) throws -> [RelayPreparedMutation]
    {
        try Self.validateProfile(profile)
        var mutations: [RelayPreparedMutation] = []
        for app in RelayTargetApp.allCases {
            guard let target = profile.configuration(for: app) else { continue }
            try mutations.append(contentsOf: self.render(
                target: target,
                profile: profile,
                credential: credential,
                codexProviderMode: codexProviderMode,
                codexServiceTier: codexServiceTier,
                retiredProviderKeys: retiredProviderKeys))
        }
        return mutations
    }

    private func render(
        target: RelayTargetConfiguration,
        profile: RelayProfile,
        credential: RelayRenderCredential,
        codexProviderMode: RelayCodexProviderMode,
        codexServiceTier: CodexServiceTier?,
        retiredProviderKeys: Set<String>) throws -> [RelayPreparedMutation]
    {
        let format = target.apiFormatOverride ?? profile.apiFormat
        let baseURL = try Self.normalizedBaseURL(
            target.baseURLOverride ?? profile.baseURL,
            format: format)
        switch target.app {
        case .codex:
            try Self.require(format, app: .codex, supported: [.openAIResponses])
            let model = try Self.requiredModel(target, profile: profile)
            return try [self.codexMutation(
                profile: profile,
                baseURL: baseURL,
                model: model,
                credential: credential,
                providerMode: codexProviderMode,
                serviceTier: codexServiceTier)]
        case .claudeCode:
            try Self.require(format, app: .claudeCode, supported: [.anthropicMessages])
            return try [self.claudeCodeMutation(
                baseURL: baseURL,
                model: Self.optionalModel(target, profile: profile),
                credential: credential)]
        case .claudeDesktop:
            throw RelayConfigurationError.unsupportedConfiguration(
                app: .claudeDesktop,
                reason: "configure Third-Party Inference inside Claude Desktop; "
                    + "no documented live-file API is available")
        case .grokBuild:
            try Self.require(format, app: .grokBuild, supported: [.openAIResponses])
            let model = try Self.requiredModel(target, profile: profile)
            return try [self.grokBuildMutation(
                profile: profile,
                baseURL: baseURL,
                model: model,
                credential: Self.inlineCredential(credential),
                retiredProviderKeys: retiredProviderKeys)]
        case .openCode:
            let model = try Self.requiredModel(target, profile: profile)
            return try [self.openCodeMutation(
                profile: profile,
                baseURL: baseURL,
                format: format,
                model: model,
                credential: Self.inlineCredential(credential),
                retiredProviderKeys: retiredProviderKeys)]
        case .piAgent:
            let model = try Self.requiredModel(target, profile: profile)
            return try self.piAgentMutations(
                providerID: profile.providerKey,
                baseURL: baseURL,
                format: format,
                model: model,
                credential: credential)
        }
    }

    func mutation(
        target: RelayTargetApp,
        url: URL,
        original: Data?,
        replacement: Data?) -> RelayPreparedMutation
    {
        RelayPreparedMutation(
            target: target,
            url: url,
            originalData: original,
            replacementData: replacement)
    }

    func existingData(target: RelayTargetApp, url: URL) throws -> Data? {
        guard self.fileSystem.fileExists(at: url) else { return nil }
        do {
            return try self.fileSystem.readData(at: url)
        } catch {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: target,
                reason: "the existing file is unreadable")
        }
    }

    private static func validateProfile(_ profile: RelayProfile) throws {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RelayConfigurationError.invalidProfile("name is empty") }
        let grouped = Dictionary(grouping: profile.targets, by: \.app)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw RelayConfigurationError.invalidProfile("an application appears more than once")
        }
    }

    private static func require(
        _ actual: RelayAPIFormat,
        app: RelayTargetApp,
        supported: [RelayAPIFormat]) throws
    {
        guard supported.contains(actual) else {
            throw RelayConfigurationError.incompatibleAPIFormat(
                app: app,
                actual: actual,
                supported: supported)
        }
    }

    private static func requiredModel(
        _ target: RelayTargetConfiguration,
        profile: RelayProfile) throws -> String
    {
        guard let model = optionalModel(target, profile: profile) else {
            throw RelayConfigurationError.missingModel(target.app)
        }
        return model
    }

    private static func optionalModel(
        _ target: RelayTargetConfiguration,
        profile: RelayProfile) -> String?
    {
        (target.model ?? profile.defaultModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func inlineCredential(_ credential: RelayRenderCredential) throws -> String {
        guard let value = credential.inlineValue, !value.isEmpty else {
            throw RelayConfigurationError.emptyCredential
        }
        return value
    }

    static func credentialHelperArguments(reference: String) -> [String] {
        ["relay", "credential", "read", "--reference", reference]
    }

    private static func normalizedBaseURL(_ url: URL, format: RelayAPIFormat) throws -> String {
        guard RelayEndpointValidator.isAllowed(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw RelayConfigurationError.invalidBaseURL
        }

        var normalized = url.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        let isOriginOnly = components.path.isEmpty || components.path == "/"
        if format != .anthropicMessages, isOriginOnly {
            normalized += "/v1"
        }
        return normalized
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
