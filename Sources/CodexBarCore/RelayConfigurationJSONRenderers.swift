import Foundation

extension RelayConfigurationRenderer {
    private static let legacyManagedProviderID = "codexbar-relay"

    func piAgentMutations(
        providerID: String,
        baseURL: String,
        format: RelayAPIFormat,
        model: String,
        credential: RelayRenderCredential) throws -> [RelayPreparedMutation]
    {
        let settings = try self.readJSONObject(
            target: .piAgent,
            url: self.paths.piAgentSettingsURL,
            defaultValue: [:])
        var settingsRoot = settings.root
        settingsRoot["defaultProvider"] = providerID
        settingsRoot["defaultModel"] = model

        let models = try self.readJSONObject(
            target: .piAgent,
            url: self.paths.piAgentModelsURL,
            defaultValue: [:])
        var modelsRoot = models.root
        var providers = try Self.objectField(modelsRoot, key: "providers", app: .piAgent) ?? [:]
        var provider = providers[providerID] as? [String: Any] ?? [:]
        var configuredModels = provider["models"] as? [[String: Any]] ?? []
        if !configuredModels.contains(where: { $0["id"] as? String == model }) {
            configuredModels.append(["id": model, "name": model])
        }
        providers.removeValue(forKey: Self.legacyManagedProviderID)
        provider["baseUrl"] = baseURL
        provider["api"] = Self.piAPIName(for: format)
        provider["apiKey"] = "!" + Self.credentialHelperCommand(
            executableURL: self.paths.credentialHelperURL,
            reference: credential.locator.reference)
        provider["models"] = configuredModels
        providers[providerID] = provider
        modelsRoot["providers"] = providers

        return try [
            self.mutation(
                target: .piAgent,
                url: self.paths.piAgentSettingsURL,
                original: settings.data,
                replacement: Self.encodeJSON(settingsRoot)),
            self.mutation(
                target: .piAgent,
                url: self.paths.piAgentModelsURL,
                original: models.data,
                replacement: Self.encodeJSON(modelsRoot)),
        ]
    }

    private static func piAPIName(for format: RelayAPIFormat) -> String {
        switch format {
        case .openAIResponses: "openai-responses"
        case .openAIChatCompletions: "openai-completions"
        case .anthropicMessages: "anthropic-messages"
        }
    }

    func claudeCodeMutation(
        baseURL: String,
        model: String?,
        credential: RelayRenderCredential) throws -> RelayPreparedMutation
    {
        let url = self.paths.claudeCodeSettingsURL
        let existing = try self.readJSONObject(target: .claudeCode, url: url, defaultValue: [:])
        var root = existing.root
        var environment = try Self.objectField(root, key: "env", app: .claudeCode) ?? [:]
        environment["ANTHROPIC_BASE_URL"] = baseURL
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        if let model {
            environment["ANTHROPIC_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
            environment["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
        } else {
            environment.removeValue(forKey: "ANTHROPIC_MODEL")
            environment.removeValue(forKey: "ANTHROPIC_DEFAULT_HAIKU_MODEL")
            environment.removeValue(forKey: "ANTHROPIC_DEFAULT_SONNET_MODEL")
            environment.removeValue(forKey: "ANTHROPIC_DEFAULT_OPUS_MODEL")
        }
        root["env"] = environment
        root["apiKeyHelper"] = Self.credentialHelperCommand(
            executableURL: self.paths.credentialHelperURL,
            reference: credential.locator.reference)
        return try self.mutation(
            target: .claudeCode,
            url: url,
            original: existing.data,
            replacement: Self.encodeJSON(root))
    }

    func openCodeMutation(
        profile: RelayProfile,
        baseURL: String,
        format: RelayAPIFormat,
        model: String,
        credential: String,
        retiredProviderKeys: Set<String> = []) throws -> RelayPreparedMutation
    {
        let url = self.paths.openCodeConfigURL
        let existing = try self.readJSONObject(target: .openCode, url: url, defaultValue: [:])
        var root = existing.root
        let schema: OpenCodeSchema = if existing.data == nil {
            .v1
        } else {
            try Self.openCodeSchema(root)
        }
        switch schema {
        case .v1:
            var providers = try Self.objectField(root, key: "provider", app: .openCode) ?? [:]
            let existingProvider = providers[profile.providerKey] as? [String: Any] ?? [:]
            providers.removeValue(forKey: Self.legacyManagedProviderID)
            Self.scrubOpenCodeProviderAPIKeys(&providers, keys: retiredProviderKeys)
            var provider = Self.openCodeV1Provider(
                profile: profile,
                baseURL: baseURL,
                format: format,
                model: model,
                credential: credential)
            var models = existingProvider["models"] as? [String: Any] ?? [:]
            let generatedModels = provider["models"] as? [String: Any] ?? [:]
            for (id, metadata) in generatedModels where models[id] == nil {
                models[id] = metadata
            }
            provider["models"] = models
            providers[profile.providerKey] = existingProvider.merging(provider) { _, new in new }
            root["provider"] = providers
            root["model"] = "\(profile.providerKey)/\(model)"
        case .v2:
            throw RelayConfigurationError.unsupportedConfiguration(
                app: .openCode,
                reason: "the detected V2 providers/package/settings schema is not implemented yet")
        }
        return try self.mutation(
            target: .openCode,
            url: url,
            original: existing.data,
            replacement: Self.encodeJSON(root))
    }

    private static let claudeManagedEnvKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
    ]

    func clearExternalClaudeCodeOfficialMutation() throws -> RelayPreparedMutation? {
        let url = self.paths.claudeCodeSettingsURL
        let existing = try self.readJSONObject(target: .claudeCode, url: url, defaultValue: [:])
        guard let original = existing.data else { return nil }
        var root = existing.root
        if var environment = try Self.objectField(root, key: "env", app: .claudeCode) {
            for key in Self.claudeManagedEnvKeys {
                environment.removeValue(forKey: key)
            }
            if environment.isEmpty {
                root.removeValue(forKey: "env")
            } else {
                root["env"] = environment
            }
        }
        root.removeValue(forKey: "apiKeyHelper")
        let replacement: Data? = root.isEmpty ? nil : try Self.encodeJSON(root)
        return self.mutation(target: .claudeCode, url: url, original: original, replacement: replacement)
    }

    func clearExternalOpenCodeOfficialMutation() throws -> RelayPreparedMutation? {
        let url = self.paths.openCodeConfigURL
        let existing = try self.readJSONObject(target: .openCode, url: url, defaultValue: [:])
        guard let original = existing.data else { return nil }
        var root = existing.root
        root.removeValue(forKey: "model")
        return try self.mutation(
            target: .openCode,
            url: url,
            original: original,
            replacement: Self.encodeJSON(root))
    }

    func clearExternalPiAgentOfficialMutation() throws -> RelayPreparedMutation? {
        let url = self.paths.piAgentSettingsURL
        let existing = try self.readJSONObject(target: .piAgent, url: url, defaultValue: [:])
        guard let original = existing.data else { return nil }
        var root = existing.root
        root.removeValue(forKey: "defaultProvider")
        root.removeValue(forKey: "defaultModel")
        let replacement: Data? = root.isEmpty ? nil : try Self.encodeJSON(root)
        return self.mutation(target: .piAgent, url: url, original: original, replacement: replacement)
    }

    static func surgicallyRestoredClaudeCodeData(current: Data?, baseline: Data?) throws -> Data? {
        guard let current,
              let currentRoot = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any]
        else {
            return baseline
        }
        let baselineRoot: [String: Any]
        if let baseline {
            guard let parsed = (try? JSONSerialization.jsonObject(with: baseline)) as? [String: Any] else {
                return baseline
            }
            baselineRoot = parsed
        } else {
            baselineRoot = [:]
        }

        var merged = currentRoot
        merged["apiKeyHelper"] = baselineRoot["apiKeyHelper"]
        merged["model"] = baselineRoot["model"]

        var mergedEnv = (currentRoot["env"] as? [String: Any]) ?? [:]
        let baselineEnv = (baselineRoot["env"] as? [String: Any]) ?? [:]
        for key in Self.claudeManagedEnvKeys {
            mergedEnv[key] = baselineEnv[key]
        }
        if mergedEnv.isEmpty, baselineRoot["env"] == nil {
            merged.removeValue(forKey: "env")
        } else if !mergedEnv.isEmpty || baselineRoot["env"] != nil {
            merged["env"] = mergedEnv
        }

        if let baseline, NSDictionary(dictionary: merged).isEqual(to: baselineRoot) {
            return baseline
        }
        if baseline == nil, merged.isEmpty {
            return nil
        }
        return try Self.encodeJSON(merged)
    }

    static func surgicallyRestoredOpenCodeData(current: Data?, baseline: Data?) throws -> Data? {
        guard let current,
              let currentRoot = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any]
        else {
            return baseline
        }
        let baselineRoot: [String: Any]
        if let baseline {
            guard let parsed = (try? JSONSerialization.jsonObject(with: baseline)) as? [String: Any] else {
                return baseline
            }
            baselineRoot = parsed
        } else {
            baselineRoot = [:]
        }

        var merged = currentRoot
        merged["model"] = baselineRoot["model"]
        let baselineProviders = baselineRoot["provider"] as? [String: Any]
        if var mergedProviders = merged["provider"] as? [String: Any] {
            if baselineProviders?[Self.legacyManagedProviderID] == nil {
                mergedProviders.removeValue(forKey: Self.legacyManagedProviderID)
            } else {
                mergedProviders[Self.legacyManagedProviderID] = baselineProviders?[Self.legacyManagedProviderID]
            }
            if mergedProviders.isEmpty, baselineProviders == nil {
                merged.removeValue(forKey: "provider")
            } else {
                merged["provider"] = mergedProviders
            }
        }

        if let baseline, NSDictionary(dictionary: merged).isEqual(to: baselineRoot) {
            return baseline
        }
        if baseline == nil, merged.keys.allSatisfy({ $0 == "$schema" }) {
            return nil
        }
        return try Self.encodeJSON(merged)
    }

    func scrubInlineCredentialMutations(providerKeys: Set<String>) throws -> [RelayPreparedMutation] {
        var result: [RelayPreparedMutation] = []
        if let grok = try? self.scrubGrokInlineCredentialsMutation(providerKeys: providerKeys) {
            result.append(grok)
        }
        if let openCode = try? self.scrubOpenCodeInlineCredentialsMutation(providerKeys: providerKeys) {
            result.append(openCode)
        }
        return result
    }

    private func scrubOpenCodeInlineCredentialsMutation(providerKeys: Set<String>) throws -> RelayPreparedMutation? {
        let url = self.paths.openCodeConfigURL
        let existing = try self.readJSONObject(target: .openCode, url: url, defaultValue: [:])
        guard let original = existing.data else { return nil }
        var root = existing.root
        guard (try? Self.openCodeSchema(root)) == .v1,
              var providers = try Self.objectField(root, key: "provider", app: .openCode)
        else { return nil }
        Self.scrubOpenCodeProviderAPIKeys(&providers, keys: providerKeys)
        root["provider"] = providers
        return try self.mutation(
            target: .openCode,
            url: url,
            original: original,
            replacement: Self.encodeJSON(root))
    }

    private static func scrubOpenCodeProviderAPIKeys(_ providers: inout [String: Any], keys: Set<String>) {
        for key in keys {
            guard var entry = providers[key] as? [String: Any],
                  var options = entry["options"] as? [String: Any],
                  options["apiKey"] != nil
            else { continue }
            options.removeValue(forKey: "apiKey")
            entry["options"] = options
            providers[key] = entry
        }
    }

    private func readJSONObject(
        target: RelayTargetApp,
        url: URL,
        defaultValue: [String: Any]) throws -> (root: [String: Any], data: Data?)
    {
        guard let data = try self.existingData(target: target, url: url) else {
            return (defaultValue, nil)
        }
        do {
            let projection = try RelayJSONC.sanitizedProjection(data)
            guard !projection.hadComments else {
                throw RelayConfigurationError.invalidExistingConfiguration(
                    app: target,
                    reason: "comments cannot yet be preserved; remove them or use a plain JSON configuration")
            }
            guard let root = try JSONSerialization.jsonObject(with: projection.data) as? [String: Any] else {
                throw RelayJSONC.Error.rootIsNotObject
            }
            return (root, data)
        } catch let error as RelayConfigurationError {
            throw error
        } catch {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: target,
                reason: "the file is not a supported JSON/JSONC object")
        }
    }

    private static func objectField(
        _ object: [String: Any],
        key: String,
        app: RelayTargetApp) throws -> [String: Any]?
    {
        guard let value = object[key] else { return nil }
        guard let result = value as? [String: Any] else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: app,
                reason: "\(key) must be a JSON object")
        }
        return result
    }

    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func credentialHelperCommand(executableURL: URL, reference: String) -> String {
        ([executableURL.path] + self.credentialHelperArguments(reference: reference))
            .map(self.shellQuote)
            .joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum OpenCodeSchema {
        case v1
        case v2
    }

    private static func openCodeSchema(_ root: [String: Any]) throws -> OpenCodeSchema {
        if root["providers"] != nil {
            if root["provider"] != nil {
                throw RelayConfigurationError.invalidExistingConfiguration(
                    app: .openCode,
                    reason: "both V1 provider and V2 providers fields are present")
            }
            return .v2
        }
        if root["provider"] != nil { return .v1 }
        if let schema = root["$schema"] as? String {
            let normalized = schema.lowercased()
            if normalized.contains("v2") { return .v2 }
            if normalized == "https://opencode.ai/config.json" { return .v1 }
        }
        throw RelayConfigurationError.schemaVersionRequired(.openCode)
    }

    private static func openCodeV1Provider(
        profile: RelayProfile,
        baseURL: String,
        format: RelayAPIFormat,
        model: String,
        credential: String) -> [String: Any]
    {
        let package = switch format {
        case .openAIResponses: "@ai-sdk/openai"
        case .openAIChatCompletions: "@ai-sdk/openai-compatible"
        case .anthropicMessages: "@ai-sdk/anthropic"
        }
        return [
            "npm": package,
            "name": profile.name,
            "options": [
                "apiKey": credential,
                "baseURL": baseURL,
            ],
            "models": [
                model: ["name": model],
            ],
        ]
    }
}

private enum RelayJSONC {
    struct Projection {
        let data: Data
        let hadComments: Bool
    }

    enum Error: Swift.Error {
        case invalidUTF8
        case unterminatedString
        case unterminatedBlockComment
        case rootIsNotObject
    }

    static func sanitizedProjection(_ data: Data) throws -> Projection {
        guard let source = String(data: data, encoding: .utf8) else { throw Error.invalidUTF8 }
        let comments = try Self.removeComments(source)
        let withoutTrailingCommas = try Self.removeTrailingCommas(comments.source)
        return Projection(data: Data(withoutTrailingCommas.utf8), hadComments: comments.hadComments)
    }

    private static func removeComments(_ source: String) throws -> (source: String, hadComments: Bool) {
        var output = ""
        var index = source.startIndex
        var inString = false
        var escaped = false
        var hadComments = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index = next
            } else if character == "/", next < source.endIndex, source[next] == "/" {
                hadComments = true
                index = Self.skipLineComment(source, from: source.index(after: next), output: &output)
            } else if character == "/", next < source.endIndex, source[next] == "*" {
                hadComments = true
                index = try Self.skipBlockComment(source, from: source.index(after: next))
            } else {
                output.append(character)
                index = next
            }
        }
        if inString { throw Error.unterminatedString }
        return (output, hadComments)
    }

    private static func skipLineComment(_ source: String, from start: String.Index, output: inout String) -> String
    .Index {
        var index = start
        while index < source.endIndex, source[index] != "\n" {
            index = source.index(after: index)
        }
        if index < source.endIndex {
            output.append("\n")
            return source.index(after: index)
        }
        return index
    }

    private static func skipBlockComment(_ source: String, from start: String.Index) throws -> String.Index {
        var index = start
        while index < source.endIndex {
            let next = source.index(after: index)
            if source[index] == "*", next < source.endIndex, source[next] == "/" {
                return source.index(after: next)
            }
            index = next
        }
        throw Error.unterminatedBlockComment
    }

    private static func removeTrailingCommas(_ source: String) throws -> String {
        var output = ""
        var index = source.startIndex
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
                output.append(character)
            } else if character == ",", Self.nextNonWhitespace(in: source, after: index).isOneOf("}", "]") {
                // JSONC permits this comma; omit it from the strict JSON projection.
            } else {
                output.append(character)
            }
            index = source.index(after: index)
        }
        if inString { throw Error.unterminatedString }
        return output
    }

    private static func nextNonWhitespace(in source: String, after index: String.Index) -> Character? {
        var cursor = source.index(after: index)
        while cursor < source.endIndex, source[cursor].isWhitespace {
            cursor = source.index(after: cursor)
        }
        return cursor < source.endIndex ? source[cursor] : nil
    }
}

extension Character? {
    fileprivate func isOneOf(_ values: Character...) -> Bool {
        guard let self else { return false }
        return values.contains(self)
    }
}
