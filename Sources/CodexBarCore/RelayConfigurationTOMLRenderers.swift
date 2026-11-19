import Foundation

extension RelayConfigurationRenderer {
    func codexMutation(
        profile: RelayProfile,
        baseURL: String,
        model: String,
        credential: RelayRenderCredential,
        providerMode: RelayCodexProviderMode,
        serviceTier: CodexServiceTier? = nil) throws -> RelayPreparedMutation
    {
        let url = self.paths.codexConfigURL
        let original = try self.existingData(target: .codex, url: url)
        let source = try Self.decodeUTF8(original, app: .codex)
        let providerID = providerMode.providerID
        let auth = """
        [model_providers.\(providerID).auth]
        command = \(Self.tomlString(self.paths.credentialHelperURL.path))
        args = \(Self.tomlArray(Self.credentialHelperArguments(reference: credential.locator.reference)))
        """
        let provider = """
        [model_providers.\(providerID)]
        name = \(Self.tomlString(profile.name))
        base_url = \(Self.tomlString(baseURL))
        wire_api = "responses"

        \(auth)
        """
        let routed = try RelayTOMLEditor.rewrite(
            source,
            app: .codex,
            rules: .init(
                replacingTopLevel: [
                    "model_provider": Self.tomlString(providerID),
                    "model": Self.tomlString(model),
                ],
                rejectingTopLevel: ["model_providers"],
                removeSection: { name in
                    let canonical = RelayTOMLEditor.canonicalSectionName(name)
                    return ["codexbar_relay", "codexbar_shared"].contains { managedID in
                        canonical == "model_providers.\(managedID)"
                            || canonical?.hasPrefix("model_providers.\(managedID).") == true
                    }
                },
                appendedSections: provider))
        let replacement = try serviceTier.map { try Self.codexConfiguration(routed, serviceTier: $0) } ?? routed
        return self.mutation(
            target: .codex,
            url: url,
            original: original,
            replacement: Data(replacement.utf8))
    }

    static func codexServiceTier(in data: Data?) throws -> CodexServiceTier? {
        guard let data else { return .standard }
        let source = try Self.decodeUTF8(data, app: .codex)
        return try RelayTOMLEditor.codexServiceTier(source)
    }

    static func codexConfiguration(_ source: String, serviceTier: CodexServiceTier) throws -> String {
        let replacement = try RelayTOMLEditor.replacingCodexServiceTier(source, with: serviceTier)
        return serviceTier == .fast ? try RelayTOMLEditor.enablingCodexFastMode(replacement) : replacement
    }

    func codexServiceTierMutation(_ serviceTier: CodexServiceTier) throws -> RelayPreparedMutation {
        let url = self.paths.codexConfigURL
        let original = try self.existingData(target: .codex, url: url)
        let source = try Self.decodeUTF8(original, app: .codex)
        return try self.mutation(
            target: .codex,
            url: url,
            original: original,
            replacement: Data(Self.codexConfiguration(source, serviceTier: serviceTier).utf8))
    }

    static func unifiedOfficialCodexConfiguration(_ source: String) throws -> String {
        let provider = """
        [model_providers.codexbar_shared]
        name = "OpenAI"
        requires_openai_auth = true
        supports_websockets = true
        wire_api = "responses"
        """
        return try RelayTOMLEditor.rewrite(
            source,
            app: .codex,
            rules: RelayTOMLEditor.Rules(
                replacingTopLevel: ["model_provider": Self.tomlString("codexbar_shared")],
                rejectingTopLevel: ["model_providers"],
                removeSection: { name in
                    let canonical = RelayTOMLEditor.canonicalSectionName(name)
                    return ["codexbar_relay", "codexbar_shared"].contains { managedID in
                        canonical == "model_providers.\(managedID)"
                            || canonical?.hasPrefix("model_providers.\(managedID).") == true
                    }
                },
                appendedSections: provider))
    }

    func unifiedOfficialCodexMutation() throws -> RelayPreparedMutation {
        let url = self.paths.codexConfigURL
        let original = try self.existingData(target: .codex, url: url)
        let source = try Self.decodeUTF8(original, app: .codex)
        let replacement = try Self.unifiedOfficialCodexConfiguration(source)
        return self.mutation(
            target: .codex,
            url: url,
            original: original,
            replacement: Data(replacement.utf8))
    }

    func grokBuildMutation(
        profile: RelayProfile,
        baseURL: String,
        model: String,
        credential: String,
        retiredProviderKeys: Set<String> = []) throws -> RelayPreparedMutation
    {
        let url = self.paths.grokBuildConfigURL
        let original = try self.existingData(target: .grokBuild, url: url)
        let source = try Self.decodeUTF8(original, app: .grokBuild)
        let managedModelSection = """
        [model."\(profile.providerKey)"]
        model = \(Self.tomlString(model))
        base_url = \(Self.tomlString(baseURL))
        name = \(Self.tomlString(profile.name))
        api_key = \(Self.tomlString(credential))
        api_backend = "responses"
        """
        let replacement = try RelayTOMLEditor.rewriteGrok(
            source,
            app: .grokBuild,
            managedModelSection: managedModelSection,
            providerID: profile.providerKey,
            retiredProviderKeys: retiredProviderKeys)
        return self.mutation(
            target: .grokBuild,
            url: url,
            original: original,
            replacement: Data(replacement.utf8))
    }

    func scrubGrokInlineCredentialsMutation(providerKeys: Set<String>) throws -> RelayPreparedMutation? {
        let url = self.paths.grokBuildConfigURL
        guard let original = try self.existingData(target: .grokBuild, url: url) else { return nil }
        let source = try Self.decodeUTF8(original, app: .grokBuild)
        let removedSections = Set(providerKeys.map { "model.\($0)" })
        let replacement = try RelayTOMLEditor.rewrite(
            source,
            app: .grokBuild,
            rules: .init(
                replacingTopLevel: [:],
                rejectingTopLevel: [],
                removeSection: {
                    guard let canonical = RelayTOMLEditor.canonicalSectionName($0) else { return false }
                    return removedSections.contains(canonical)
                },
                appendedSections: ""))
        return self.mutation(
            target: .grokBuild,
            url: url,
            original: original,
            replacement: Data(replacement.utf8))
    }

    func clearExternalCodexOfficialMutation(
        providerMode: RelayCodexProviderMode) throws -> RelayPreparedMutation?
    {
        let url = self.paths.codexConfigURL
        guard let original = try self.existingData(target: .codex, url: url) else { return nil }
        let source = try Self.decodeUTF8(original, app: .codex)
        let replacement: String = switch providerMode {
        case .unified:
            try Self.unifiedOfficialCodexConfiguration(source)
        case .isolated:
            try RelayTOMLEditor.rewrite(
                source,
                app: .codex,
                rules: .init(
                    replacingTopLevel: [:],
                    removingTopLevel: ["model_provider"],
                    rejectingTopLevel: ["model_providers"],
                    removeSection: Self.isManagedCodexProviderSection,
                    appendedSections: ""))
        }
        return self.mutation(
            target: .codex,
            url: url,
            original: original,
            replacement: replacement.isEmpty ? nil : Data(replacement.utf8))
    }

    func clearExternalGrokOfficialMutation() throws -> RelayPreparedMutation? {
        let url = self.paths.grokBuildConfigURL
        guard let original = try self.existingData(target: .grokBuild, url: url) else { return nil }
        let source = try Self.decodeUTF8(original, app: .grokBuild)
        let clearedDefault = try RelayTOMLEditor.setGrokDefault(source, app: .grokBuild, providerID: nil)
        let replacement = try RelayTOMLEditor.rewrite(
            clearedDefault,
            app: .grokBuild,
            rules: .init(
                replacingTopLevel: [:],
                rejectingTopLevel: ["models", "model"],
                removeSection: { RelayTOMLEditor.canonicalSectionName($0) == "model.codexbar-relay" },
                appendedSections: ""))
        return self.mutation(
            target: .grokBuild,
            url: url,
            original: original,
            replacement: replacement.isEmpty ? nil : Data(replacement.utf8))
    }

    static func surgicallyRestoredCodexData(current: Data?, baseline: Data?) throws -> Data? {
        guard let current, let currentSource = String(data: current, encoding: .utf8) else {
            return baseline
        }
        let baselineSource = baseline.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let strippedCurrent = try Self.stripManagedCodexElements(currentSource)
        let strippedBaseline = (try? Self.stripManagedCodexElements(baselineSource)) ?? baselineSource
        if strippedCurrent == strippedBaseline {
            return baseline
        }

        var managedTopKeys: Set = ["model_provider", "model", "service_tier"]
        if Self.hasLoopbackTopLevelBaseURL(currentSource) {
            managedTopKeys.insert("base_url")
        }
        let baselineTop = Self.extractTopLevelRawAssignments(
            baselineSource,
            keys: managedTopKeys)
        var replacing: [String: String] = [:]
        var removing: Set<String> = []
        for key in managedTopKeys {
            if let value = baselineTop[key] {
                replacing[key] = value
            } else {
                removing.insert(key)
            }
        }
        let baselineManagedSections = try Self.extractSections(
            baselineSource,
            app: .codex,
            matching: Self.isManagedCodexProviderSection)
        let restored = try RelayTOMLEditor.rewrite(
            currentSource,
            app: .codex,
            rules: .init(
                replacingTopLevel: replacing,
                removingTopLevel: removing,
                rejectingTopLevel: ["model_providers"],
                removeSection: Self.isManagedCodexProviderSection,
                appendedSections: baselineManagedSections))
        if baseline == nil, restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return Data(restored.utf8)
    }

    static func surgicallyRestoredGrokData(current: Data?, baseline: Data?) throws -> Data? {
        guard let current, let currentSource = String(data: current, encoding: .utf8) else {
            return baseline
        }
        let baselineSource = baseline.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let strippedCurrent = try Self.stripManagedGrokElements(currentSource)
        let strippedBaseline = (try? Self.stripManagedGrokElements(baselineSource)) ?? baselineSource
        if strippedCurrent == strippedBaseline {
            return baseline
        }

        let baselineDoc = SimpleTOMLDocument.parse(baselineSource)
        let baselineDefault = baselineDoc.sections["models"]?["default"]?.stringValue
        let baselineManagedSections = try Self.extractSections(
            baselineSource,
            app: .grokBuild,
            matching: { RelayTOMLEditor.canonicalSectionName($0) == "model.codexbar-relay" })
        let updatedDefault = try RelayTOMLEditor.setGrokDefault(
            currentSource,
            app: .grokBuild,
            providerID: baselineDefault)
        let restored = try RelayTOMLEditor.rewrite(
            updatedDefault,
            app: .grokBuild,
            rules: .init(
                replacingTopLevel: [:],
                rejectingTopLevel: ["models", "model"],
                removeSection: { RelayTOMLEditor.canonicalSectionName($0) == "model.codexbar-relay" },
                appendedSections: baselineManagedSections))
        if baseline == nil, restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return Data(restored.utf8)
    }

    private static func isManagedCodexProviderSection(_ name: String) -> Bool {
        let canonical = RelayTOMLEditor.canonicalSectionName(name)
        return ["codexbar_relay", "codexbar_shared"].contains { managedID in
            canonical == "model_providers.\(managedID)"
                || canonical?.hasPrefix("model_providers.\(managedID).") == true
        }
    }

    private static func hasLoopbackTopLevelBaseURL(_ source: String) -> Bool {
        guard let raw = extractTopLevelRawAssignments(source, keys: ["base_url"])["base_url"]?
            .lowercased()
        else {
            return false
        }
        return raw.contains("127.0.0.1")
            || raw.contains("localhost")
            || raw.contains("[::1]")
            || raw.contains("//::1")
    }

    private static func stripManagedCodexElements(_ source: String) throws -> String {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let withoutFastMode = try RelayTOMLEditor.strippingCodexFastMode(source)
        var removingKeys: Set = ["model_provider", "model", "service_tier", "features.fast_mode"]
        if Self.hasLoopbackTopLevelBaseURL(withoutFastMode) {
            removingKeys.insert("base_url")
        }
        return try RelayTOMLEditor.rewrite(
            withoutFastMode,
            app: .codex,
            rules: .init(
                replacingTopLevel: [:],
                removingTopLevel: removingKeys,
                rejectingTopLevel: [],
                removeSection: Self.isManagedCodexProviderSection,
                appendedSections: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripManagedGrokElements(_ source: String) throws -> String {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let withoutDefault = try RelayTOMLEditor.setGrokDefault(source, app: .grokBuild, providerID: nil)
        return try RelayTOMLEditor.rewrite(
            withoutDefault,
            app: .grokBuild,
            rules: .init(
                replacingTopLevel: [:],
                rejectingTopLevel: [],
                removeSection: { RelayTOMLEditor.canonicalSectionName($0) == "model.codexbar-relay" },
                appendedSections: ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractTopLevelRawAssignments(_ source: String, keys: Set<String>) -> [String: String] {
        var values: [String: String] = [:]
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
                continue
            }
            let rawKey = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let key = RelayTOMLEditor.canonicalSectionName(rawKey) ?? rawKey
            guard keys.contains(key) else { continue }
            values[key] = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    private static func extractSections(
        _ source: String,
        app: RelayTargetApp,
        matching predicate: (String) -> Bool) throws -> String
    {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var captured: [String] = []
        var including = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let rawHeader = trimmed.hasPrefix("[[")
                    ? String(trimmed.dropFirst(2).prefix { $0 != "]" })
                    : String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                including = predicate(rawHeader.trimmingCharacters(in: .whitespaces))
            }
            if including {
                captured.append(line)
            }
        }
        return captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeUTF8(_ data: Data?, app: RelayTargetApp) throws -> String {
        guard let data else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: app,
                reason: "the file is not UTF-8")
        }
        return value
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(self.tomlString).joined(separator: ", ") + "]"
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F: escaped += String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}

private enum RelayTOMLEditor {
    static func enablingCodexFastMode(_ source: String) throws -> String {
        var lines = source.components(separatedBy: "\n")
        var section: String?
        var featuresHeader: Int?
        var flag: (index: Int, key: String)?
        for (index, line) in lines.enumerated() {
            if let header = try Self.sectionName(line, app: .codex) {
                section = Self.canonicalSectionName(header)
                if section == "features" {
                    guard featuresHeader == nil, !line.trimmingCharacters(in: .whitespaces).hasPrefix("[[") else {
                        throw Self.ambiguousCodexFeatures()
                    }
                    featuresHeader = index
                }
                continue
            }
            guard let rawKey = Self.assignmentKey(line), let key = Self.canonicalSectionName(rawKey) else { continue }
            if section == nil, key == "features" { throw Self.ambiguousCodexFeatures() }
            if section == "features" && key == "fast_mode" || section == nil && key == "features.fast_mode" {
                guard flag == nil else { throw Self.ambiguousCodexFeatures() }
                flag = (index, section == nil ? "features.fast_mode" : "fast_mode")
            }
        }
        if let flag {
            lines[flag.index] = "\(flag.key) = true"
        } else if let featuresHeader {
            lines.insert("fast_mode = true", at: featuresHeader + 1)
        } else {
            lines.insert("features.fast_mode = true", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func strippingCodexFastMode(_ source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        var section: String?
        for line in lines {
            if let header = try Self.sectionName(line, app: .codex) {
                section = Self.canonicalSectionName(header)
                kept.append(line)
                continue
            }
            if let rawKey = Self.assignmentKey(line),
               let key = Self.canonicalSectionName(rawKey),
               (section == "features" && key == "fast_mode") || (section == nil && key == "features.fast_mode")
            {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func ambiguousCodexFeatures() -> RelayConfigurationError {
        .invalidExistingConfiguration(app: .codex, reason: "ambiguous features.fast_mode configuration")
    }

    static func codexServiceTier(_ source: String) throws -> CodexServiceTier? {
        let assignments = try Self.codexServiceTierAssignments(source)
        guard let assignment = assignments.first else { return .standard }
        let line = source.components(separatedBy: "\n")[assignment]
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^([\"'])([a-z]+)\1\s*(?:#.*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 2), in: value)
        else { return nil }
        return switch value[range] {
        case "fast", "priority": .fast
        case "default", "auto": .standard
        default: nil
        }
    }

    static func replacingCodexServiceTier(_ source: String, with tier: CodexServiceTier) throws -> String {
        let assignments = try Self.codexServiceTierAssignments(source)
        var lines = source.components(separatedBy: "\n")
        let replacement = "service_tier = \"\(tier.rawValue)\""
        if let index = assignments.first {
            lines[index] = replacement
        } else {
            lines.insert(replacement, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    private static func codexServiceTierAssignments(_ source: String) throws -> [Int] {
        guard !source.contains("\"\"\""), !source.contains("'''") else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: .codex, reason: "multiline TOML strings require a full TOML parser")
        }
        var result: [Int] = []
        var section: String?
        var selectedProfile = false
        var profileOverridesTier = false
        for (index, line) in source.components(separatedBy: "\n").enumerated() {
            if let header = try Self.sectionName(line, app: .codex) {
                section = Self.canonicalSectionName(header)
                continue
            }
            guard let rawKey = Self.assignmentKey(line), let key = Self.canonicalSectionName(rawKey) else { continue }
            if section == nil, key == "profile" { selectedProfile = true }
            if section?.hasPrefix("profiles.") == true, key == "service_tier" { profileOverridesTier = true }
            if section == nil, key == "service_tier" {
                result.append(index)
            }
        }
        guard !selectedProfile || !profileOverridesTier else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: .codex, reason: "the selected Codex configuration profile may override service_tier")
        }
        guard result.count <= 1 else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: .codex, reason: "duplicate service_tier assignments")
        }
        return result
    }

    static func rewriteGrok(
        _ source: String,
        app: RelayTargetApp,
        managedModelSection: String,
        providerID: String,
        retiredProviderKeys: Set<String> = []) throws -> String
    {
        let defaultResult = try Self.replaceGrokDefault(source, app: app, providerID: providerID)
        let modelsSection = defaultResult.foundModelsSection
            ? managedModelSection
            : "[models]\ndefault = \"\(providerID)\"\n\n\(managedModelSection)"
        let retiredSections = Set(retiredProviderKeys.map { "model.\($0)" })
        return try Self.rewrite(
            defaultResult.source,
            app: app,
            rules: .init(
                replacingTopLevel: [:],
                rejectingTopLevel: ["models", "model"],
                removeSection: {
                    guard let name = RelayTOMLEditor.canonicalSectionName($0) else { return false }
                    return name == "model.codexbar-relay"
                        || name == "model.\(providerID)"
                        || retiredSections.contains(name)
                },
                appendedSections: modelsSection))
    }

    static func rewrite(
        _ source: String,
        app: RelayTargetApp,
        rules: Rules) throws -> String
    {
        guard !source.contains("\"\"\""), !source.contains("'''") else {
            throw RelayConfigurationError.invalidExistingConfiguration(
                app: app,
                reason: "multiline TOML strings require a full TOML parser")
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let firstSection = try lines.firstIndex { try Self.sectionName($0, app: app) != nil } ?? lines.count
        let top = try Self.rewriteTopLevel(
            Array(lines[..<firstSection]),
            app: app,
            replacements: rules.replacingTopLevel,
            removals: rules.removingTopLevel,
            rejected: rules.rejectingTopLevel)
        let body = try Self.removeSections(
            Array(lines[firstSection...]),
            app: app,
            shouldRemove: rules.removeSection)
        return Self.join(top: top, body: body, appended: rules.appendedSections)
    }

    private static func rewriteTopLevel(
        _ lines: [String],
        app: RelayTargetApp,
        replacements: [String: String],
        removals: Set<String> = [],
        rejected: Set<String>) throws -> [String]
    {
        var output: [String] = []
        for line in lines {
            guard let rawKey = Self.assignmentKey(line) else {
                output.append(line)
                continue
            }
            let key = Self.canonicalSectionName(rawKey) ?? rawKey
            if rejected.contains(key) {
                throw RelayConfigurationError.invalidExistingConfiguration(
                    app: app,
                    reason: "top-level inline \(key) cannot be edited safely")
            }
            if replacements[key] == nil, !removals.contains(key) {
                output.append(line)
            }
        }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        if !output.isEmpty, !replacements.isEmpty { output.append("") }
        for key in replacements.keys.sorted() {
            if let value = replacements[key] { output.append("\(key) = \(value)") }
        }
        return output
    }

    static func setGrokDefault(
        _ source: String,
        app: RelayTargetApp,
        providerID: String?) throws -> String
    {
        if let providerID {
            let result = try Self.replaceGrokDefault(source, app: app, providerID: providerID)
            if result.foundModelsSection { return result.source }
            let trimmed = result.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "[models]\ndefault = \"\(providerID)\"\n"
                : "[models]\ndefault = \"\(providerID)\"\n\n\(trimmed)\n"
        }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        var inModels = false
        for line in lines {
            if let section = try Self.sectionName(line, app: app) {
                inModels = Self.canonicalSectionName(section) == "models"
            } else if inModels, Self.assignmentKey(line) == "default" {
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func replaceGrokDefault(
        _ source: String,
        app: RelayTargetApp,
        providerID: String) throws -> (source: String, foundModelsSection: Bool)
    {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var output: [String] = []
        var inModels = false
        var foundModels = false
        for line in lines {
            if let section = try Self.sectionName(line, app: app) {
                inModels = Self.canonicalSectionName(section) == "models"
                if inModels {
                    foundModels = true
                    output.append(line)
                    output.append("default = \"\(providerID)\"")
                    continue
                }
            }
            if inModels, Self.assignmentKey(line) == "default" { continue }
            output.append(line)
        }
        return (output.joined(separator: "\n"), foundModels)
    }

    private static func removeSections(
        _ lines: [String],
        app: RelayTargetApp,
        shouldRemove: (String) -> Bool) throws -> [String]
    {
        var output: [String] = []
        var skipping = false
        for line in lines {
            if let section = try Self.sectionName(line, app: app) {
                skipping = shouldRemove(section)
            }
            if !skipping { output.append(line) }
        }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            output.removeLast()
        }
        return output
    }

    private static func sectionName(_ line: String, app: RelayTargetApp) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return nil }
        guard let closing = trimmed.firstIndex(of: "]") else {
            throw RelayConfigurationError.invalidExistingConfiguration(app: app, reason: "malformed TOML table header")
        }
        if trimmed.hasPrefix("[[") {
            guard trimmed[closing...].hasPrefix("]]") else {
                throw RelayConfigurationError.invalidExistingConfiguration(
                    app: app,
                    reason: "malformed TOML array table")
            }
            return String(trimmed.dropFirst(2).prefix { $0 != "]" }).trimmingCharacters(in: .whitespaces)
        }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func assignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
    }

    static func canonicalSectionName(_ rawValue: String) -> String? {
        var components: [String] = []
        var component = ""
        var quote: Character?
        var escaped = false

        func appendComponent() -> Bool {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            components.append(trimmed)
            component = ""
            return true
        }

        for character in rawValue {
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    component.append(character)
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                } else {
                    component.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                guard component.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                quote = character
            } else if character == "." {
                guard appendComponent() else { return nil }
            } else {
                component.append(character)
            }
        }

        guard quote == nil, !escaped, appendComponent() else { return nil }
        return components.joined(separator: ".")
    }

    private static func join(top: [String], body: [String], appended: String) -> String {
        var sections = top
        if !body.isEmpty {
            if !sections.isEmpty { sections.append("") }
            sections.append(contentsOf: body)
        }
        let trimmedAppended = appended.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAppended.isEmpty {
            if !sections.isEmpty { sections.append("") }
            sections.append(trimmedAppended)
        }
        while sections.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            sections.removeLast()
        }
        return sections.isEmpty ? "" : sections.joined(separator: "\n") + "\n"
    }

    struct Rules {
        let replacingTopLevel: [String: String]
        let removingTopLevel: Set<String>
        let rejectingTopLevel: Set<String>
        let removeSection: (String) -> Bool
        let appendedSections: String

        init(
            replacingTopLevel: [String: String],
            removingTopLevel: Set<String> = [],
            rejectingTopLevel: Set<String>,
            removeSection: @escaping (String) -> Bool,
            appendedSections: String)
        {
            self.replacingTopLevel = replacingTopLevel
            self.removingTopLevel = removingTopLevel
            self.rejectingTopLevel = rejectingTopLevel
            self.removeSection = removeSection
            self.appendedSections = appendedSections
        }
    }
}
