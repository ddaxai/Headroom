import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

public enum LocalAgentSpeedSource: String, CaseIterable, Hashable, Sendable, Codable {
    case codex
    case claude
    case antigravity
    case openCode
    case pi
}

public enum AgentSpeedMeasurementKind: String, Sendable, Equatable, Codable {
    /// Excludes first-token wait (`streamingMs = latencyMs - firstTokenMs >= 100`, `outputTokens >= 100`).
    case streamingExact
    /// End-to-end duration from request boundary to completion (`latencyMs >= 1000`, `outputTokens >= 200`).
    case endToEndEstimated
}

public struct AgentSpeedSample: Sendable, Equatable, Codable {
    public static let exactMinOutputTokens = 100
    public static let exactMinGenerationMs: Int64 = 100
    public static let estimatedMinOutputTokens = 200
    public static let estimatedMinDurationMs: Int64 = 1000
    public static let minPlausibleLatencyMs: Int64 = 100
    public static let maxPlausibleLatencyMs: Int64 = 60 * 60 * 1000

    public let source: LocalAgentSpeedSource
    public let timestamp: Date
    public let model: String?
    public let providerKey: String?
    public let codexAccountKey: String?
    public let codexRelayProfileID: UUID?
    public let codexHomePath: String?
    public let outputTokens: Int
    public let latencyMs: Int64
    public let firstTokenMs: Int64?

    public init(
        source: LocalAgentSpeedSource,
        timestamp: Date,
        model: String?,
        providerKey: String? = nil,
        codexAccountKey: String? = nil,
        codexRelayProfileID: UUID? = nil,
        codexHomePath: String? = nil,
        outputTokens: Int,
        latencyMs: Int64,
        firstTokenMs: Int64? = nil)
    {
        self.source = source
        self.timestamp = timestamp
        self.model = model
        self.providerKey = providerKey
        self.codexAccountKey = codexAccountKey
        self.codexRelayProfileID = codexRelayProfileID
        self.codexHomePath = codexHomePath
        self.outputTokens = outputTokens
        self.latencyMs = latencyMs
        self.firstTokenMs = firstTokenMs
    }

    public var streamingGenerationMs: Int64? {
        guard let firstTokenMs, firstTokenMs >= 0 else { return nil }
        let generationMs = self.latencyMs - firstTokenMs
        return generationMs >= Self.exactMinGenerationMs ? generationMs : nil
    }

    public var exactStreamingTokensPerSecond: Double? {
        guard self.outputTokens >= Self.exactMinOutputTokens,
              let generationMs = self.streamingGenerationMs
        else { return nil }
        let tps = Double(self.outputTokens) / (Double(generationMs) / 1000.0)
        return tps.isFinite && tps > 0 ? tps : nil
    }

    public var estimatedTokensPerSecond: Double? {
        guard self.firstTokenMs == nil,
              self.outputTokens >= Self.estimatedMinOutputTokens,
              self.latencyMs >= Self.estimatedMinDurationMs
        else { return nil }
        let tps = Double(self.outputTokens) / (Double(self.latencyMs) / 1000.0)
        return tps.isFinite && tps > 0 ? tps : nil
    }

    public var effectiveSpeed: (tokensPerSecond: Double, kind: AgentSpeedMeasurementKind)? {
        if let exact = self.exactStreamingTokensPerSecond {
            return (exact, .streamingExact)
        }
        if let estimated = self.estimatedTokensPerSecond {
            return (estimated, .endToEndEstimated)
        }
        return nil
    }
}

public struct AgentSpeedSummary: Sendable, Equatable, Codable {
    public let latestTokensPerSecond: Double?
    public let latestKind: AgentSpeedMeasurementKind?
    public let latestFirstTokenMs: Int64?
    public let latestModel: String?
    public let latestTimestamp: Date?
    public let rolling24hTokensPerSecond: Double?
    public let rolling24hKind: AgentSpeedMeasurementKind?
    public let rolling24hMedianFirstTokenMs: Int64?
    public let rolling24hSampleCount: Int

    public var hasData: Bool {
        self.latestTokensPerSecond != nil || self.rolling24hTokensPerSecond != nil
    }

    public static func summarize(
        _ samples: [AgentSpeedSample],
        now: Date = Date(),
        rollingWindowSeconds: TimeInterval = 24 * 60 * 60) -> AgentSpeedSummary?
    {
        let eligible = samples
            .compactMap { sample -> (sample: AgentSpeedSample, tps: Double, kind: AgentSpeedMeasurementKind)? in
                guard let speed = sample.effectiveSpeed else { return nil }
                return (sample, speed.tokensPerSecond, speed.kind)
            }
            .sorted { $0.sample.timestamp < $1.sample.timestamp }
        guard let latest = eligible.last else { return nil }

        let cutoff = now.addingTimeInterval(-rollingWindowSeconds)
        let recent = eligible
            .filter { $0.sample.timestamp >= cutoff && $0.sample.timestamp <= now.addingTimeInterval(60) }

        var exactOutput = 0
        var exactGenMs: Int64 = 0
        var estOutput = 0
        var estDurationMs: Int64 = 0
        var ttftValues: [Int64] = []

        for entry in recent {
            if let ttft = entry.sample.firstTokenMs, ttft > 0 {
                ttftValues.append(ttft)
            }
            switch entry.kind {
            case .streamingExact:
                if let genMs = entry.sample.streamingGenerationMs {
                    exactOutput += entry.sample.outputTokens
                    exactGenMs += genMs
                }
            case .endToEndEstimated:
                estOutput += entry.sample.outputTokens
                estDurationMs += entry.sample.latencyMs
            }
        }

        let rolling24hTokensPerSecond: Double?
        let rolling24hKind: AgentSpeedMeasurementKind?
        if exactOutput > 0, exactGenMs > 0 {
            rolling24hTokensPerSecond = Double(exactOutput) / (Double(exactGenMs) / 1000.0)
            rolling24hKind = .streamingExact
        } else if estOutput > 0, estDurationMs > 0 {
            rolling24hTokensPerSecond = Double(estOutput) / (Double(estDurationMs) / 1000.0)
            rolling24hKind = .endToEndEstimated
        } else {
            rolling24hTokensPerSecond = nil
            rolling24hKind = nil
        }

        let medianTTFT: Int64? = if ttftValues.isEmpty {
            nil
        } else {
            {
                let sorted = ttftValues.sorted()
                let mid = sorted.count / 2
                if sorted.count.isMultiple(of: 2) {
                    return (sorted[mid - 1] + sorted[mid]) / 2
                }
                return sorted[mid]
            }()
        }

        return AgentSpeedSummary(
            latestTokensPerSecond: latest.tps,
            latestKind: latest.kind,
            latestFirstTokenMs: latest.sample.firstTokenMs,
            latestModel: Self.cleanedModelName(latest.sample.model),
            latestTimestamp: latest.sample.timestamp,
            rolling24hTokensPerSecond: rolling24hTokensPerSecond,
            rolling24hKind: rolling24hKind,
            rolling24hMedianFirstTokenMs: medianTTFT,
            rolling24hSampleCount: recent.count)
    }

    public static func formatTokensPerSecond(_ value: Double, kind: AgentSpeedMeasurementKind) -> String {
        let number = value >= 1.0
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
        return switch kind {
        case .streamingExact: "\(number) tok/s"
        case .endToEndEstimated: "≈ \(number) tok/s"
        }
    }

    public static func formatFirstTokenSeconds(_ milliseconds: Int64) -> String {
        String(format: "%.1fs", Double(milliseconds) / 1000.0)
    }

    private static func cleanedModelName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("unknown") != .orderedSame
        else { return nil }
        return trimmed
    }
}

public struct LocalAgentSpeedReport: Sendable, Equatable {
    public let updatedAt: Date
    public let bySource: [LocalAgentSpeedSource: AgentSpeedSummary]
    public let codexOfficialSummary: AgentSpeedSummary?
    public let codexByAccountKey: [String: AgentSpeedSummary]
    public let codexByHomePath: [String: AgentSpeedSummary]
    public let codexByRelayProfileID: [UUID: AgentSpeedSummary]
    public let codexByProviderKey: [String: AgentSpeedSummary]
    public let openCodeByProviderKey: [String: AgentSpeedSummary]
    public let piByProviderKey: [String: AgentSpeedSummary]
    public let relayCombinedByProviderKey: [String: AgentSpeedSummary]

    public init(
        updatedAt: Date = Date(),
        bySource: [LocalAgentSpeedSource: AgentSpeedSummary] = [:],
        codexOfficialSummary: AgentSpeedSummary? = nil,
        codexByAccountKey: [String: AgentSpeedSummary] = [:],
        codexByHomePath: [String: AgentSpeedSummary] = [:],
        codexByRelayProfileID: [UUID: AgentSpeedSummary] = [:],
        codexByProviderKey: [String: AgentSpeedSummary] = [:],
        openCodeByProviderKey: [String: AgentSpeedSummary] = [:],
        piByProviderKey: [String: AgentSpeedSummary] = [:],
        relayCombinedByProviderKey: [String: AgentSpeedSummary] = [:])
    {
        self.updatedAt = updatedAt
        self.bySource = bySource
        self.codexOfficialSummary = codexOfficialSummary
        self.codexByAccountKey = codexByAccountKey
        self.codexByHomePath = codexByHomePath
        self.codexByRelayProfileID = codexByRelayProfileID
        self.codexByProviderKey = codexByProviderKey
        self.openCodeByProviderKey = openCodeByProviderKey
        self.piByProviderKey = piByProviderKey
        self.relayCombinedByProviderKey = relayCombinedByProviderKey
    }
}

public struct LocalAgentSpeedScanConfiguration: Sendable {
    public struct CodexManagedHome: Sendable, Equatable {
        public let accountKey: String
        public let homeURL: URL

        public init(accountKey: String, homeURL: URL) {
            self.accountKey = accountKey
            self.homeURL = homeURL
        }
    }

    public var homeDirectory: URL
    public var environment: [String: String]
    public var codexManagedHomes: [CodexManagedHome]
    public var codexOwnershipTimeline: CodexSessionOwnershipTimeline?
    public var relayProviderKeyByProfileID: [UUID: String]
    public var lookbackDays: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexManagedHomes: [CodexManagedHome] = [],
        codexOwnershipTimeline: CodexSessionOwnershipTimeline? = nil,
        relayProviderKeyByProfileID: [UUID: String] = [:],
        lookbackDays: Int = 7)
    {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.codexManagedHomes = codexManagedHomes
        self.codexOwnershipTimeline = codexOwnershipTimeline
        self.relayProviderKeyByProfileID = relayProviderKeyByProfileID
        self.lookbackDays = max(1, lookbackDays)
    }
}

/// Read-only local session speed scanner across Codex, Claude Code, Antigravity, OpenCode, and Pi.
///
/// Safety & anti-ban contract:
/// - Performs zero network requests, spawns zero subprocesses, and modifies zero configuration or lock files.
/// - Opens JSONL transcripts strictly read-only and SQLite databases strictly with
///   `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` and `sqlite3_busy_timeout(db, 0)`.
public final class LocalAgentSpeedScanner: @unchecked Sendable {
    public static let shared = LocalAgentSpeedScanner()

    private struct CacheKey: Hashable {
        let tag: String
        let path: String
    }

    private struct CacheEntry {
        let stamp: String
        let samples: [AgentSpeedSample]
    }

    private let lock = NSLock()
    private var fileCache: [CacheKey: CacheEntry] = [:]

    public init() {}

    public func clearCache() {
        self.lock.lock()
        self.fileCache.removeAll()
        self.lock.unlock()
    }

    public func scan(
        configuration: LocalAgentSpeedScanConfiguration = .init(),
        sources: Set<LocalAgentSpeedSource> = Set(LocalAgentSpeedSource.allCases),
        now: Date = Date()) -> LocalAgentSpeedReport
    {
        let fileCutoff = min(now, Date()).addingTimeInterval(-TimeInterval(configuration.lookbackDays) * 86400)
        let eventCutoff = now.addingTimeInterval(-TimeInterval(configuration.lookbackDays) * 86400)
        var allSamples: [AgentSpeedSample] = []

        if sources.contains(.antigravity) {
            allSamples.append(contentsOf: self.scanAntigravity(configuration: configuration, cutoff: fileCutoff))
        }
        if sources.contains(.codex) {
            allSamples.append(contentsOf: self.scanCodex(configuration: configuration, cutoff: fileCutoff))
        }
        if sources.contains(.claude) {
            allSamples.append(contentsOf: self.scanClaude(configuration: configuration, cutoff: fileCutoff))
        }
        if sources.contains(.openCode) {
            allSamples.append(contentsOf: self.scanOpenCode(configuration: configuration, cutoff: eventCutoff))
        }
        if sources.contains(.pi) {
            allSamples.append(contentsOf: self.scanPi(configuration: configuration, cutoff: fileCutoff))
        }

        return Self.buildReport(samples: allSamples, configuration: configuration, now: now)
    }

    private static func buildReport(
        samples: [AgentSpeedSample],
        configuration: LocalAgentSpeedScanConfiguration,
        now: Date) -> LocalAgentSpeedReport
    {
        var bySource: [LocalAgentSpeedSource: AgentSpeedSummary] = [:]
        for source in LocalAgentSpeedSource.allCases {
            let slice = samples.filter { $0.source == source }
            if let summary = AgentSpeedSummary.summarize(slice, now: now) {
                bySource[source] = summary
            }
        }

        let codexSamples = samples.filter { $0.source == .codex }
        let codexOfficialSamples = codexSamples.filter { sample in
            guard sample.codexRelayProfileID == nil else { return false }
            guard let providerKey = sample.providerKey?.lowercased() else { return true }
            return providerKey == "openai" || providerKey == "codexbar_shared"
        }
        let codexOfficialSummary = AgentSpeedSummary.summarize(codexOfficialSamples, now: now)

        var codexByAccountKey: [String: AgentSpeedSummary] = [:]
        for (key, group) in Dictionary(
            grouping: codexOfficialSamples.filter { $0.codexAccountKey != nil },
            by: { $0.codexAccountKey! })
        {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                codexByAccountKey[key] = summary
            }
        }

        var codexByHomePath: [String: AgentSpeedSummary] = [:]
        for (home, group) in Dictionary(
            grouping: codexSamples.filter { $0.codexHomePath != nil },
            by: { $0.codexHomePath! })
        {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                codexByHomePath[home] = summary
            }
        }

        var codexByRelayProfileID: [UUID: AgentSpeedSummary] = [:]
        for (profileID, group) in Dictionary(
            grouping: codexSamples.filter { $0.codexRelayProfileID != nil },
            by: { $0.codexRelayProfileID! })
        {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                codexByRelayProfileID[profileID] = summary
            }
        }

        var codexByProviderKey: [String: AgentSpeedSummary] = [:]
        for (providerKey, group) in Dictionary(
            grouping: codexSamples.filter { $0.providerKey != nil },
            by: { $0.providerKey! })
        {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                codexByProviderKey[providerKey] = summary
            }
        }

        var openCodeByProviderKey: [String: AgentSpeedSummary] = [:]
        let openCodeSamples = samples.filter { $0.source == .openCode && $0.providerKey != nil }
        for (providerKey, group) in Dictionary(grouping: openCodeSamples, by: { $0.providerKey! }) {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                openCodeByProviderKey[providerKey] = summary
            }
        }

        var piByProviderKey: [String: AgentSpeedSummary] = [:]
        let piSamples = samples.filter { $0.source == .pi && $0.providerKey != nil }
        for (providerKey, group) in Dictionary(grouping: piSamples, by: { $0.providerKey! }) {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                piByProviderKey[providerKey] = summary
            }
        }

        var relaySamplesByProviderKey: [String: [AgentSpeedSample]] = [:]
        for sample in samples {
            if sample.source == .codex {
                if let profileID = sample.codexRelayProfileID,
                   let mappedKey = configuration.relayProviderKeyByProfileID[profileID]
                {
                    relaySamplesByProviderKey[mappedKey, default: []].append(sample)
                } else if let providerKey = sample.providerKey,
                          providerKey != "openai",
                          providerKey != "codexbar_shared"
                {
                    relaySamplesByProviderKey[providerKey, default: []].append(sample)
                }
            } else if sample.source == .pi || sample.source == .openCode {
                if let providerKey = sample.providerKey, providerKey != "unassigned" {
                    relaySamplesByProviderKey[providerKey, default: []].append(sample)
                }
            }
        }
        var relayCombinedByProviderKey: [String: AgentSpeedSummary] = [:]
        for (providerKey, group) in relaySamplesByProviderKey {
            if let summary = AgentSpeedSummary.summarize(group, now: now) {
                relayCombinedByProviderKey[providerKey] = summary
            }
        }

        return LocalAgentSpeedReport(
            updatedAt: now,
            bySource: bySource,
            codexOfficialSummary: codexOfficialSummary,
            codexByAccountKey: codexByAccountKey,
            codexByHomePath: codexByHomePath,
            codexByRelayProfileID: codexByRelayProfileID,
            codexByProviderKey: codexByProviderKey,
            openCodeByProviderKey: openCodeByProviderKey,
            piByProviderKey: piByProviderKey,
            relayCombinedByProviderKey: relayCombinedByProviderKey)
    }

    private func cachedSamples(
        tag: String,
        path: String,
        stamp: String,
        compute: () -> [AgentSpeedSample]) -> [AgentSpeedSample]
    {
        let key = CacheKey(tag: tag, path: path)
        self.lock.lock()
        if let hit = self.fileCache[key], hit.stamp == stamp {
            self.lock.unlock()
            return hit.samples
        }
        self.lock.unlock()

        let computed = compute()
        self.lock.lock()
        self.fileCache[key] = CacheEntry(stamp: stamp, samples: computed)
        self.lock.unlock()
        return computed
    }
}

// MARK: - 1. Antigravity (IDE + CLI) Read-Only Scanner

extension LocalAgentSpeedScanner {
    private func scanAntigravity(
        configuration: LocalAgentSpeedScanConfiguration,
        cutoff: Date) -> [AgentSpeedSample]
    {
        let fm = FileManager.default
        let geminiBase = configuration.homeDirectory.appendingPathComponent(".gemini", isDirectory: true)
        var roots: [URL] = [
            geminiBase.appendingPathComponent("antigravity", isDirectory: true),
            geminiBase.appendingPathComponent("antigravity-cli", isDirectory: true),
        ]
        if let customAgy = Self.nonEmpty(configuration.environment["AGY_DIR"]) {
            roots.append(URL(fileURLWithPath: customAgy, isDirectory: true))
        }

        var seenSessionIDs: Set<String> = []
        var samples: [AgentSpeedSample] = []

        for root in roots {
            let brainDir = root.appendingPathComponent("brain", isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for sessionDir in entries {
                let sessionID = sessionDir.lastPathComponent
                let logsDir = sessionDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                let fullURL = logsDir.appendingPathComponent("transcript_full.jsonl", isDirectory: false)
                let compactURL = logsDir.appendingPathComponent("transcript.jsonl", isDirectory: false)
                let transcriptURL: URL
                if fm.fileExists(atPath: fullURL.path) {
                    transcriptURL = fullURL
                } else if fm.fileExists(atPath: compactURL.path) {
                    transcriptURL = compactURL
                } else {
                    continue
                }

                guard let meta = Self.fileStamp(for: transcriptURL),
                      meta.modifiedAt >= cutoff
                else { continue }
                guard seenSessionIDs.insert("\(root.standardizedFileURL.path):\(sessionID)").inserted else {
                    continue
                }

                let dbCandidate = root
                    .appendingPathComponent("conversations", isDirectory: true)
                    .appendingPathComponent("\(sessionID).db", isDirectory: false)
                let dbStamp = Self.sqliteCompositeStamp(for: dbCandidate)
                let combinedStamp = "\(meta.stamp)|db:\(dbStamp)"

                let fileSamples = self.cachedSamples(
                    tag: "agy",
                    path: transcriptURL.standardizedFileURL.path,
                    stamp: combinedStamp)
                {
                    Self.parseAntigravityTranscript(
                        transcriptURL: transcriptURL,
                        antigravityRoot: root,
                        sessionID: sessionID)
                }
                samples.append(contentsOf: fileSamples)
            }
        }
        return samples
    }

    private static func parseAntigravityTranscript(
        transcriptURL: URL,
        antigravityRoot: URL,
        sessionID: String) -> [AgentSpeedSample]
    {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return [] }
        var stepsByIndex: [UInt64: [String: Any]] = [:]
        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let stepIndex = Self.uint64Value(obj["step_index"])
            else { return }
            stepsByIndex[stepIndex] = obj
        }
        guard !stepsByIndex.isEmpty else { return [] }

        let orderedIndices = stepsByIndex.keys.sorted()
        var currentSelectedModel: String?
        var selectedModelByStep: [UInt64: String] = [:]
        var wantedDoneSteps: [UInt64] = []

        for step in orderedIndices {
            guard let row = stepsByIndex[step] else { continue }
            let type = row["type"] as? String
            if type == "USER_INPUT",
               let content = row["content"] as? String,
               let switched = Self.antigravityModelFromSettingsChange(content)
            {
                currentSelectedModel = switched
            } else if type == "PLANNER_RESPONSE" {
                if let currentSelectedModel {
                    selectedModelByStep[step] = currentSelectedModel
                }
                if (row["status"] as? String) == "DONE" {
                    wantedDoneSteps.append(step)
                }
            }
        }
        guard !wantedDoneSteps.isEmpty else { return [] }

        let nativeGenerations = Self.readAntigravityNativeGenerations(
            antigravityRoot: antigravityRoot,
            sessionID: sessionID,
            steps: wantedDoneSteps)

        var previousStepTimestampMs: Int64?
        var results: [AgentSpeedSample] = []

        for step in orderedIndices {
            guard let row = stepsByIndex[step] else { continue }
            let stepTimeMs = (row["created_at"] as? String).flatMap(Self.parseISO8601Millis)
            defer {
                if let stepTimeMs {
                    previousStepTimestampMs = stepTimeMs
                }
            }

            guard (row["type"] as? String) == "PLANNER_RESPONSE",
                  (row["status"] as? String) == "DONE"
            else { continue }

            let outputTokens = Self.intValue(row["output_tokens"])
                ?? (row["usage"] as? [String: Any]).flatMap { Self.intValue($0["output_tokens"]) }
                ?? 0
            guard outputTokens > 0 else { continue }

            let endMs = stepTimeMs ?? 0
            guard endMs > 0 else { continue }

            let native = nativeGenerations[step]
            let resolvedModel = native?.model
                ?? (row["model"] as? String)
                ?? selectedModelByStep[step].map(Self.normalizeAntigravityModelID)

            if let nativeTiming = native?.timing {
                results.append(AgentSpeedSample(
                    source: .antigravity,
                    timestamp: Date(timeIntervalSince1970: Double(endMs) / 1000.0),
                    model: resolvedModel,
                    outputTokens: outputTokens,
                    latencyMs: nativeTiming.latencyMs,
                    firstTokenMs: nativeTiming.firstTokenMs))
            } else if let prevMs = previousStepTimestampMs,
                      let estimatedLatency = Self.plausibleLatencyMs(startMs: prevMs, endMs: endMs)
            {
                results.append(AgentSpeedSample(
                    source: .antigravity,
                    timestamp: Date(timeIntervalSince1970: Double(endMs) / 1000.0),
                    model: resolvedModel,
                    outputTokens: outputTokens,
                    latencyMs: estimatedLatency,
                    firstTokenMs: nil))
            }
        }
        return results
    }

    private static func antigravityModelFromSettingsChange(_ content: String) -> String? {
        guard let marker = content.range(of: "Model Selection") else { return nil }
        let rest = content[marker.lowerBound...]
        guard let toRange = rest.range(of: " to ") else { return nil }
        let tail = rest[toRange.upperBound...]
        let endIndex = tail.range(of: ". ")?.lowerBound
            ?? tail.firstIndex(of: "\n")
            ?? tail.firstIndex(of: "`")
            ?? tail.endIndex
        let candidate = tail[..<endIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.caseInsensitiveCompare("none") != .orderedSame else {
            return nil
        }
        return candidate
    }

    static func normalizeAntigravityModelID(_ display: String) -> String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(" ") else { return trimmed }
        let lowered = trimmed.lowercased()
        var slug = ""
        var previousDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." {
                slug.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash, !slug.isEmpty {
                slug.append("-")
                previousDash = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug
    }

    private struct AntigravityNativeTiming {
        let latencyMs: Int64
        let firstTokenMs: Int64
    }

    private struct AntigravityNativeGeneration {
        let model: String?
        let timing: AntigravityNativeTiming?
    }

    private static func readAntigravityNativeGenerations(
        antigravityRoot: URL,
        sessionID: String,
        steps: [UInt64]) -> [UInt64: AntigravityNativeGeneration]
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = antigravityRoot
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent("\(sessionID).db", isDirectory: false)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dbURL.path, isDirectory: &isDir),
              !isDir.boolValue
        else { return [:] }

        // Enforce strict profile-root containment so symlinks never escape the Antigravity directory.
        let resolvedRoot = antigravityRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDB = dbURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedDB.hasPrefix(rootPrefix) else { return [:] }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(resolvedDB, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 0)

        var stepStmt: OpaquePointer?
        var genStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT metadata FROM steps WHERE idx = ?1 AND step_type = 15",
            -1,
            &stepStmt,
            nil) == SQLITE_OK,
            sqlite3_prepare_v2(
                db,
                "SELECT data FROM gen_metadata WHERE idx = ?1",
                -1,
                &genStmt,
                nil) == SQLITE_OK
        else {
            if let stepStmt { sqlite3_finalize(stepStmt) }
            if let genStmt { sqlite3_finalize(genStmt) }
            return [:]
        }
        defer {
            sqlite3_finalize(stepStmt)
            sqlite3_finalize(genStmt)
        }

        var result: [UInt64: AntigravityNativeGeneration] = [:]
        for step in steps {
            guard let stepIndex = Int64(exactly: step) else { continue }
            sqlite3_reset(stepStmt)
            sqlite3_clear_bindings(stepStmt)
            sqlite3_bind_int64(stepStmt, 1, stepIndex)
            guard sqlite3_step(stepStmt) == SQLITE_ROW,
                  let metaBlob = Self.sqliteBlob(stepStmt, column: 0),
                  let generationIndex = AntigravityProtobufDecoder.decodeStepGenerationIndex(metaBlob),
                  let genIdx = Int64(exactly: generationIndex)
            else { continue }

            sqlite3_reset(genStmt)
            sqlite3_clear_bindings(genStmt)
            sqlite3_bind_int64(genStmt, 1, genIdx)
            guard sqlite3_step(genStmt) == SQLITE_ROW,
                  let genBlob = Self.sqliteBlob(genStmt, column: 0)
            else { continue }

            let decoded = AntigravityProtobufDecoder.decodeGeneration(genBlob)
            if decoded.model != nil || decoded.timing != nil {
                result[step] = AntigravityNativeGeneration(
                    model: decoded.model,
                    timing: decoded.timing.map {
                        AntigravityNativeTiming(latencyMs: $0.latencyMs, firstTokenMs: $0.firstTokenMs)
                    })
            }
        }
        return result
        #else
        return [:]
        #endif
    }
}

/// Minimal zero-dependency wire decoder for Antigravity's `steps.metadata` and `gen_metadata.data` blobs.
enum AntigravityProtobufDecoder {
    struct Timing: Equatable {
        let latencyMs: Int64
        let firstTokenMs: Int64
    }

    static func decodeStepGenerationIndex(_ data: Data) -> UInt64? {
        guard let refBytes = self.firstLengthDelimitedField(tag: 20, in: data[...]) else {
            return nil
        }
        // Proto3 omits scalar uint64 when index == 0.
        return self.firstVarintField(tag: 3, in: refBytes) ?? 0
    }

    static func decodeGeneration(_ data: Data) -> (model: String?, timing: Timing?) {
        guard let responseBytes = self.firstLengthDelimitedField(tag: 1, in: data[...]) else {
            return (nil, nil)
        }
        let baseModel = self.firstLengthDelimitedField(tag: 19, in: responseBytes)
            .flatMap { String(data: Data($0), encoding: .utf8) }
        let tieredModel = self.firstLengthDelimitedField(tag: 21, in: responseBytes)
            .flatMap { String(data: Data($0), encoding: .utf8) }

        let orchestratorModel: String? = switch baseModel {
        case "gemini-pro-orchestrator": "gemini-4-carbon"
        case "gemini-pro-orchestrator-argon": "gemini-4-argon"
        case "gemini-flash-worker-agy": "gemini-4-hydrogen"
        default: nil
        }

        let filteredTiered = tieredModel.flatMap { raw -> String? in
            let slug = LocalAgentSpeedScanner.normalizeAntigravityModelID(raw)
            if orchestratorModel != nil,
               slug.contains("orchestrator") || slug == "gemini-flash" || slug == "gemini-flash-worker-agy"
            {
                return nil
            }
            return raw
        }

        let resolvedModel = [filteredTiered, orchestratorModel, baseModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.caseInsensitiveCompare("unknown") != .orderedSame }

        let timing: Timing? = {
            guard let firstTokenBytes = self.firstLengthDelimitedField(tag: 11, in: responseBytes),
                  let streamingBytes = self.firstLengthDelimitedField(tag: 12, in: responseBytes),
                  let firstTokenMs = self.decodeDurationMillis(firstTokenBytes),
                  let streamingMs = self.decodeDurationMillis(streamingBytes)
            else { return nil }
            let latencyMs = firstTokenMs + streamingMs
            guard latencyMs > 0 else { return nil }
            return Timing(latencyMs: latencyMs, firstTokenMs: firstTokenMs)
        }()

        return (resolvedModel, timing)
    }

    private static func decodeDurationMillis(_ slice: Data.SubSequence) -> Int64? {
        let seconds = Int64(bitPattern: self.firstVarintField(tag: 1, in: slice) ?? 0)
        let nanos = Int32(truncatingIfNeeded: self.firstVarintField(tag: 2, in: slice) ?? 0)
        let (secMs, overflow1) = seconds.multipliedReportingOverflow(by: 1000)
        guard !overflow1 else { return nil }
        let (totalMs, overflow2) = secMs.addingReportingOverflow(Int64(nanos) / 1_000_000)
        guard !overflow2, totalMs >= 0 else { return nil }
        return totalMs
    }

    private static func firstVarintField(tag wantedTag: UInt64, in slice: Data.SubSequence) -> UInt64? {
        var index = slice.startIndex
        let end = slice.endIndex
        var found: UInt64?
        while index < end {
            guard let key = self.readVarint(in: slice, from: &index) else { break }
            let tag = key >> 3
            let wireType = key & 0x7
            switch wireType {
            case 0:
                guard let value = self.readVarint(in: slice, from: &index) else { return found }
                if tag == wantedTag { found = value }
            case 1:
                guard end - index >= 8 else { return found }
                index += 8
            case 2:
                guard let length = self.readVarint(in: slice, from: &index),
                      let intLen = Int(exactly: length),
                      end - index >= intLen
                else { return found }
                index += intLen
            case 5:
                guard end - index >= 4 else { return found }
                index += 4
            default:
                return found
            }
        }
        return found
    }

    private static func firstLengthDelimitedField(
        tag wantedTag: UInt64,
        in slice: Data.SubSequence) -> Data.SubSequence?
    {
        var index = slice.startIndex
        let end = slice.endIndex
        var found: Data.SubSequence?
        while index < end {
            guard let key = self.readVarint(in: slice, from: &index) else { break }
            let tag = key >> 3
            let wireType = key & 0x7
            switch wireType {
            case 0:
                guard self.readVarint(in: slice, from: &index) != nil else { return found }
            case 1:
                guard end - index >= 8 else { return found }
                index += 8
            case 2:
                guard let length = self.readVarint(in: slice, from: &index),
                      let intLen = Int(exactly: length),
                      end - index >= intLen
                else { return found }
                let sub = slice[index..<(index + intLen)]
                index += intLen
                if tag == wantedTag { found = sub }
            case 5:
                guard end - index >= 4 else { return found }
                index += 4
            default:
                return found
            }
        }
        return found
    }

    private static func readVarint(in slice: Data.SubSequence, from index: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < slice.endIndex, shift < 64 {
            let byte = slice[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }
}

// MARK: - 2. Codex Read-Only Rollout Scanner (Multi-Account + Relay Partitioned)

extension LocalAgentSpeedScanner {
    private func scanCodex(
        configuration: LocalAgentSpeedScanConfiguration,
        cutoff: Date) -> [AgentSpeedSample]
    {
        let primaryHome: URL = if let configured = Self.nonEmpty(configuration.environment["CODEX_HOME"]) {
            URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            configuration.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        let primaryCanonical = primaryHome.resolvingSymlinksInPath().standardizedFileURL.path

        struct HomeTarget {
            let homeURL: URL
            let canonicalHomePath: String
            let fixedAccountKey: String?
            let usesSharedTimeline: Bool
        }

        var targets: [HomeTarget] = [
            HomeTarget(
                homeURL: primaryHome,
                canonicalHomePath: primaryCanonical,
                fixedAccountKey: nil,
                usesSharedTimeline: true),
        ]
        var seenHomes: Set<String> = [primaryCanonical]
        for managed in configuration.codexManagedHomes {
            let canonical = managed.homeURL.resolvingSymlinksInPath().standardizedFileURL.path
            if seenHomes.insert(canonical).inserted {
                targets.append(HomeTarget(
                    homeURL: managed.homeURL,
                    canonicalHomePath: canonical,
                    fixedAccountKey: managed.accountKey,
                    usesSharedTimeline: false))
            }
        }

        let timelineRevision = configuration.codexOwnershipTimeline?.revision ?? "none"
        var samples: [AgentSpeedSample] = []

        for target in targets {
            let sessionsDir = target.homeURL.appendingPathComponent("sessions", isDirectory: true)
            let files = Self.collectJSONLFiles(under: sessionsDir, cutoff: cutoff)
            for fileURL in files {
                guard let meta = Self.fileStamp(for: fileURL) else { continue }
                let stamp = "\(meta.stamp)|tl:\(target.usesSharedTimeline ? timelineRevision : (target.fixedAccountKey ?? "fixed"))"
                let fileSamples = self.cachedSamples(
                    tag: "codex",
                    path: fileURL.standardizedFileURL.path,
                    stamp: stamp)
                {
                    Self.parseCodexRollout(
                        fileURL: fileURL,
                        canonicalHomePath: target.canonicalHomePath,
                        fixedAccountKey: target.fixedAccountKey,
                        timeline: target.usesSharedTimeline ? configuration.codexOwnershipTimeline : nil,
                        relayProviderKeyByProfileID: configuration.relayProviderKeyByProfileID)
                }
                samples.append(contentsOf: fileSamples)
            }
        }
        return samples
    }

    private struct CodexRequestTimer {
        static let sameFlushSlackMs: Int64 = 100

        var lastBoundaryMs: Int64?
        var lastTokenCountMs: Int64?
        var requestStartMs: Int64?
        var lastModelOutputMs: Int64?
        var toolOutputAfterModelOutputMs: Int64?
        var usageRecord: (timestampMs: Int64, outputTokens: Int)?
        var firstOutputMs: Int64?

        mutating func observeBoundary(at timestampMs: Int64) {
            self.lastBoundaryMs = max(self.lastBoundaryMs ?? timestampMs, timestampMs)
        }

        mutating func observeToolOutput(at timestampMs: Int64) {
            self.lastBoundaryMs = max(self.lastBoundaryMs ?? timestampMs, timestampMs)
            if self.lastModelOutputMs != nil {
                self.toolOutputAfterModelOutputMs = timestampMs
            }
        }

        mutating func observeModelOutput(at timestampMs: Int64) {
            let trailsTokenCount = self.requestStartMs == nil &&
                (self.lastTokenCountMs.map { timestampMs - $0 <= Self.sameFlushSlackMs } ?? false)
            if trailsTokenCount { return }
            if self.requestStartMs == nil {
                self.requestStartMs = self.lastBoundaryMs
            }
            self.lastModelOutputMs = timestampMs
            self.toolOutputAfterModelOutputMs = nil
        }

        mutating func observeOutputItemStarted(at startedAtMs: Int64) {
            self.firstOutputMs = self.firstOutputMs.map { min($0, startedAtMs) } ?? startedAtMs
        }

        mutating func observeUsageRecord(at timestampMs: Int64, outputTokens: Int) {
            self.usageRecord = (timestampMs, outputTokens)
        }

        mutating func resetTurn(at timestampMs: Int64) {
            let boundary = max(self.lastBoundaryMs ?? timestampMs, timestampMs)
            let lastToken = self.lastTokenCountMs
            self = CodexRequestTimer()
            self.lastBoundaryMs = boundary
            self.lastTokenCountMs = lastToken
        }

        mutating func finishRequest(
            tokenCountMs: Int64?,
            deltaOutputTokens: Int) -> (latencyMs: Int64, firstTokenMs: Int64?, endMs: Int64)?
        {
            let startMs = self.requestStartMs ?? self.lastBoundaryMs
            let firstOutput = self.firstOutputMs
            let recordEndMs: Int64? = if let record = self.usageRecord,
                                         record.outputTokens == 0 || record.outputTokens == deltaOutputTokens
            {
                record.timestampMs
            } else {
                nil
            }
            let waitedForTools: Bool = switch (self.toolOutputAfterModelOutputMs, tokenCountMs) {
            case let (toolMs?, tokenMs?):
                tokenMs - toolMs <= Self.sameFlushSlackMs
            case (_?, nil):
                true
            case (nil, _):
                false
            }
            let endMs = recordEndMs ?? (waitedForTools ? self.lastModelOutputMs : tokenCountMs)

            let nextBoundary: Int64? = switch (self.lastBoundaryMs, tokenCountMs) {
            case let (lhs?, rhs?): max(lhs, rhs)
            case let (lhs?, nil): lhs
            case let (nil, rhs?): rhs
            case (nil, nil): nil
            }
            self = CodexRequestTimer()
            self.lastBoundaryMs = nextBoundary
            self.lastTokenCountMs = tokenCountMs

            guard let startMs, let endMs,
                  let latencyMs = LocalAgentSpeedScanner.plausibleLatencyMs(startMs: startMs, endMs: endMs)
            else { return nil }

            let ttft: Int64? = if let firstOutput {
                {
                    let delta = firstOutput - startMs
                    return (delta > 0 && delta <= latencyMs) ? delta : nil
                }()
            } else {
                nil
            }
            return (latencyMs, ttft, endMs)
        }
    }

    private static func parseCodexRollout(
        fileURL: URL,
        canonicalHomePath: String,
        fixedAccountKey: String?,
        timeline: CodexSessionOwnershipTimeline?,
        relayProviderKeyByProfileID: [UUID: String]) -> [AgentSpeedSample]
    {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var timer = CodexRequestTimer()
        var currentModel: String?
        var currentModelProvider: String?
        var previousCumulativeOutput = 0
        var results: [AgentSpeedSample] = []

        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }

            let timestampMs = (obj["timestamp"] as? String).flatMap(Self.parseISO8601Millis)
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                if let provider = payload?["model_provider"] as? String, !provider.isEmpty {
                    currentModelProvider = provider
                }
                if let model = payload?["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
            case "turn_context":
                if let model = payload?["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
                if let provider = payload?["model_provider"] as? String, !provider.isEmpty {
                    currentModelProvider = provider
                }
                if let timestampMs {
                    timer.observeBoundary(at: timestampMs)
                }
            case "response_item":
                guard let timestampMs, let itemType = payload?["type"] as? String else { return }
                if itemType == "message" {
                    let role = payload?["role"] as? String
                    if role == "assistant" {
                        timer.observeModelOutput(at: timestampMs)
                    } else {
                        timer.observeBoundary(at: timestampMs)
                    }
                } else if itemType == "reasoning" || itemType.hasSuffix("_call") {
                    timer.observeModelOutput(at: timestampMs)
                } else if itemType.hasSuffix("_output") {
                    timer.observeToolOutput(at: timestampMs)
                }
            case "token_usage_record":
                guard let timestampMs else { return }
                let usage = payload?["usage"] as? [String: Any]
                let out = Self.intValue(usage?["output_tokens"]) ?? 0
                timer.observeUsageRecord(at: timestampMs, outputTokens: out)
            case "event_msg":
                guard let eventType = payload?["type"] as? String else { return }
                switch eventType {
                case "thread_settings_applied":
                    if let model = payload?["model"] as? String, !model.isEmpty {
                        currentModel = model
                    }
                case "task_started", "turn_aborted":
                    if let timestampMs {
                        timer.resetTurn(at: timestampMs)
                    }
                case "item_completed":
                    if let item = payload?["item"] as? [String: Any],
                       let itemKind = item["type"] as? String,
                       itemKind == "Reasoning" || itemKind == "AgentMessage",
                       let startedAtMs = Self.int64Value(payload?["started_at_ms"])
                    {
                        timer.observeOutputItemStarted(at: startedAtMs)
                    }
                case "token_count":
                    let info = payload?["info"] as? [String: Any]
                    if let infoModel = (info?["model"] as? String) ?? (payload?["model"] as? String),
                       !infoModel.isEmpty
                    {
                        currentModel = infoModel
                    }
                    let totalUsage = info?["total_token_usage"] as? [String: Any]
                    let lastUsage = info?["last_token_usage"] as? [String: Any]
                    let totalOut = Self.intValue(totalUsage?["output_tokens"])
                    let lastOut = Self.intValue(lastUsage?["output_tokens"])

                    let deltaOut: Int
                    if let totalOut {
                        let diff = totalOut - previousCumulativeOutput
                        if diff >= 0 {
                            deltaOut = diff
                        } else {
                            deltaOut = lastOut ?? totalOut
                        }
                        previousCumulativeOutput = max(previousCumulativeOutput, totalOut)
                    } else if let lastOut {
                        deltaOut = lastOut
                    } else {
                        return
                    }
                    guard deltaOut > 0 else { return }
                    guard let finished = timer.finishRequest(
                        tokenCountMs: timestampMs,
                        deltaOutputTokens: deltaOut)
                    else { return }

                    let route = timeline?.codexRoute(atUnixMilliseconds: finished.endMs)
                    let relayProfileID: UUID? = if case let .relay(id) = route { id } else { nil }
                    let accountKey: String? = if let fixedAccountKey {
                        fixedAccountKey
                    } else if relayProfileID == nil {
                        timeline?.ownerAccountKey(atUnixMilliseconds: finished.endMs)
                    } else {
                        nil
                    }
                    let resolvedProviderKey: String? = if let relayProfileID,
                                                          let mapped = relayProviderKeyByProfileID[relayProfileID]
                    {
                        mapped
                    } else {
                        currentModelProvider
                    }

                    results.append(AgentSpeedSample(
                        source: .codex,
                        timestamp: Date(timeIntervalSince1970: Double(finished.endMs) / 1000.0),
                        model: currentModel,
                        providerKey: resolvedProviderKey,
                        codexAccountKey: accountKey,
                        codexRelayProfileID: relayProfileID,
                        codexHomePath: canonicalHomePath,
                        outputTokens: deltaOut,
                        latencyMs: finished.latencyMs,
                        firstTokenMs: finished.firstTokenMs))
                default:
                    break
                }
            default:
                break
            }
        }
        return results
    }
}

// MARK: - 3. Claude Code Read-Only Project Session Scanner

extension LocalAgentSpeedScanner {
    private func scanClaude(
        configuration: LocalAgentSpeedScanConfiguration,
        cutoff: Date) -> [AgentSpeedSample]
    {
        let claudeRoot: URL = if let configured = Self.nonEmpty(configuration.environment["CLAUDE_CONFIG_DIR"]) {
            URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            configuration.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        let projectsDir = claudeRoot.appendingPathComponent("projects", isDirectory: true)
        let files = Self.collectJSONLFiles(under: projectsDir, cutoff: cutoff)
        var samples: [AgentSpeedSample] = []

        for fileURL in files {
            guard let meta = Self.fileStamp(for: fileURL) else { continue }
            let fileSamples = self.cachedSamples(
                tag: "claude",
                path: fileURL.standardizedFileURL.path,
                stamp: meta.stamp)
            {
                Self.parseClaudeSession(fileURL: fileURL)
            }
            samples.append(contentsOf: fileSamples)
        }
        return samples
    }

    private struct ClaudeChainNode {
        let parentUUID: String?
        let timestampMs: Int64?
        let isAttachment: Bool
    }

    private struct ClaudeMessageAccumulator {
        let firstParentUUID: String?
        let startsAtFirstBlock: Bool
        let firstOutputMs: Int64?
        var endMs: Int64?
        var outputTokens: Int = 0
        var model: String?
    }

    private static func parseClaudeSession(fileURL: URL) -> [AgentSpeedSample] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var chain: [String: ClaudeChainNode] = [:]
        var messageOrder: [String] = []
        var messages: [String: ClaudeMessageAccumulator] = [:]

        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }

            let type = obj["type"] as? String
            let timestampMs = (obj["timestamp"] as? String).flatMap(Self.parseISO8601Millis)
            if let uuid = (obj["uuid"] as? String)?.lowercased() {
                let parent = (obj["parentUuid"] as? String)?.lowercased()
                chain[uuid] = ClaudeChainNode(
                    parentUUID: parent,
                    timestampMs: timestampMs,
                    isAttachment: type == "attachment")
            }

            guard type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let messageID = message["id"] as? String,
                  !messageID.isEmpty
            else { return }

            let usage = message["usage"] as? [String: Any]
            let outTokens = Self.intValue(usage?["output_tokens"]) ?? 0
            let model = message["model"] as? String

            if var existing = messages[messageID] {
                if let timestampMs {
                    existing.endMs = max(existing.endMs ?? timestampMs, timestampMs)
                }
                if outTokens > 0 {
                    existing.outputTokens = max(existing.outputTokens, outTokens)
                }
                if let model, !model.isEmpty {
                    existing.model = model
                }
                messages[messageID] = existing
            } else {
                let apiBlockIndex = Self.intValue(obj["apiBlockIndex"])
                let startsAtFirst = apiBlockIndex == nil || apiBlockIndex == 0
                let firstOutputMs: Int64? = if startsAtFirst,
                                               let blockEndMs = timestampMs,
                                               let thinkingMs = Self.int64Value(obj["thinkingDurationMs"]),
                                               thinkingMs > 0,
                                               let content = message["content"] as? [[String: Any]],
                                               (content.first?["type"] as? String) == "thinking"
                {
                    blockEndMs - thinkingMs
                } else {
                    nil
                }
                messageOrder.append(messageID)
                messages[messageID] = ClaudeMessageAccumulator(
                    firstParentUUID: (obj["parentUuid"] as? String)?.lowercased(),
                    startsAtFirstBlock: startsAtFirst,
                    firstOutputMs: firstOutputMs,
                    endMs: timestampMs,
                    outputTokens: outTokens,
                    model: model)
            }
        }

        var results: [AgentSpeedSample] = []
        for messageID in messageOrder {
            guard let acc = messages[messageID],
                  acc.startsAtFirstBlock,
                  acc.outputTokens > 0,
                  let endMs = acc.endMs,
                  let startMs = Self.resolveClaudeRequestStartMs(chain: chain, firstParent: acc.firstParentUUID),
                  let latencyMs = Self.plausibleLatencyMs(startMs: startMs, endMs: endMs)
            else { continue }

            let ttft: Int64? = if let firstOutput = acc.firstOutputMs {
                {
                    let delta = firstOutput - startMs
                    return (delta > 0 && delta <= latencyMs) ? delta : nil
                }()
            } else {
                nil
            }
            results.append(AgentSpeedSample(
                source: .claude,
                timestamp: Date(timeIntervalSince1970: Double(endMs) / 1000.0),
                model: acc.model,
                outputTokens: acc.outputTokens,
                latencyMs: latencyMs,
                firstTokenMs: ttft))
        }
        return results
    }

    private static func resolveClaudeRequestStartMs(
        chain: [String: ClaudeChainNode],
        firstParent: String?) -> Int64?
    {
        var cursor = firstParent
        for _ in 0..<32 {
            guard let current = cursor, let node = chain[current] else { return nil }
            if !node.isAttachment {
                return node.timestampMs
            }
            cursor = node.parentUUID
        }
        return nil
    }
}

// MARK: - 4. OpenCode Read-Only SQLite Scanner

extension LocalAgentSpeedScanner {
    private func scanOpenCode(
        configuration: LocalAgentSpeedScanConfiguration,
        cutoff: Date) -> [AgentSpeedSample]
    {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let dbURL = configuration.homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        let stamp = Self.sqliteCompositeStamp(for: dbURL)
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000.0)
        return self.cachedSamples(
            tag: "opencode",
            path: dbURL.standardizedFileURL.path,
            stamp: "\(stamp)|cutoff:\(cutoffMs / 3_600_000)")
        {
            Self.parseOpenCodeDatabase(dbURL: dbURL, cutoffMs: cutoffMs)
        }
        #else
        return []
        #endif
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func parseOpenCodeDatabase(dbURL: URL, cutoffMs: Int64) -> [AgentSpeedSample] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 0)

        let hasV2 = Self.sqliteTableExists(db, name: "session_v2") &&
            Self.sqliteTableExists(db, name: "session_message")
        let sql = hasV2
            ? """
            SELECT data, type FROM session_message
            WHERE time_created >= ?1 AND type IN ('assistant', 'compaction')
            ORDER BY time_created ASC
            """
            : """
            SELECT data, NULL FROM message
            WHERE time_created >= ?1
            ORDER BY time_created ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoffMs)

        var results: [AgentSpeedSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jsonPtr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonText = String(cString: jsonPtr)
            let rowType = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            guard let data = jsonText.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if !hasV2, (obj["role"] as? String) != "assistant" {
                continue
            }
            guard let tokens = obj["tokens"] as? [String: Any] else { continue }

            let isCompleted: Bool = if rowType == "compaction" {
                ["completed", "failed"].contains((obj["status"] as? String) ?? "")
            } else {
                (obj["time"] as? [String: Any])?["completed"] != nil
            }
            guard isCompleted else { continue }

            let output = (Self.intValue(tokens["output"]) ?? 0) + (Self.intValue(tokens["reasoning"]) ?? 0)
            guard output > 0 else { continue }

            let timeObj = obj["time"] as? [String: Any]
            guard let createdMs = Self.int64Value(timeObj?["created"]), createdMs > 0 else { continue }
            let streamedMs = Self.int64Value(timeObj?["streamed"])
            let completedMs = Self.int64Value(timeObj?["completed"])
            let endMs: Int64? = if let streamedMs, streamedMs > createdMs {
                streamedMs
            } else {
                completedMs
            }
            guard let endMs,
                  let latencyMs = Self.plausibleLatencyMs(startMs: createdMs, endMs: endMs)
            else { continue }

            let model = Self.openCodeModel(from: obj)
            let providerKey = Self.openCodeProviderKey(from: obj)
            results.append(AgentSpeedSample(
                source: .openCode,
                timestamp: Date(timeIntervalSince1970: Double(endMs) / 1000.0),
                model: model,
                providerKey: providerKey,
                outputTokens: output,
                latencyMs: latencyMs,
                firstTokenMs: nil))
        }
        return results
    }

    private static func openCodeModel(from obj: [String: Any]) -> String? {
        if let id = obj["modelID"] as? String ?? obj["modelId"] as? String, !id.isEmpty {
            return id
        }
        if let modelStr = obj["model"] as? String, !modelStr.isEmpty {
            return modelStr
        }
        if let modelDict = obj["model"] as? [String: Any] {
            return (modelDict["modelID"] as? String) ?? (modelDict["id"] as? String)
        }
        return nil
    }

    private static func openCodeProviderKey(from obj: [String: Any]) -> String {
        let candidates: [Any?] = [
            obj["providerID"],
            obj["providerId"],
            obj["provider"],
            (obj["model"] as? [String: Any])?["providerID"],
            (obj["model"] as? [String: Any])?["providerId"],
            (obj["model"] as? [String: Any])?["provider"],
            ((obj["model"] as? [String: Any])?["provider"] as? [String: Any])?["id"],
            (obj["provider"] as? [String: Any])?["id"],
        ]
        for candidate in candidates {
            if let str = candidate as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return "unassigned"
    }
    #endif
}

// MARK: - 5. Pi Agent / Oh My Pi Read-Only Session Scanner

extension LocalAgentSpeedScanner {
    private func scanPi(
        configuration: LocalAgentSpeedScanConfiguration,
        cutoff: Date) -> [AgentSpeedSample]
    {
        let roots = [
            configuration.homeDirectory.appendingPathComponent(".pi/agent/sessions", isDirectory: true),
            configuration.homeDirectory.appendingPathComponent(".omp/agent/sessions", isDirectory: true),
        ]
        var samples: [AgentSpeedSample] = []
        for root in roots {
            let files = Self.collectJSONLFiles(under: root, cutoff: cutoff)
            for fileURL in files {
                guard let meta = Self.fileStamp(for: fileURL) else { continue }
                let fileSamples = self.cachedSamples(
                    tag: "pi",
                    path: fileURL.standardizedFileURL.path,
                    stamp: meta.stamp)
                {
                    Self.parsePiSession(fileURL: fileURL)
                }
                samples.append(contentsOf: fileSamples)
            }
        }
        return samples
    }

    private static func parsePiSession(fileURL: URL) -> [AgentSpeedSample] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var results: [AgentSpeedSample] = []

        text.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (entry["type"] as? String) == "message",
                  let message = entry["message"] as? [String: Any],
                  (message["role"] as? String) == "assistant"
            else { return }

            let stopReason = (message["stopReason"] as? String) ?? (message["stop_reason"] as? String)
            if stopReason == "error" || stopReason == "aborted" {
                return
            }

            guard let usage = message["usage"] as? [String: Any] else { return }
            let output = Self.intValue(usage["output"]) ?? Self.intValue(usage["outputTokens"]) ?? 0
            guard output > 0 else { return }

            let entryTimestampMs = Self.parseFlexibleTimestampMs(entry["timestamp"])
            let msgTimestampMs = Self.parseFlexibleTimestampMs(message["timestamp"])
            let durationFieldMs: Int64? = if let d = Self.doubleValue(message["duration"]), d > 0 {
                Self.plausibleLatencyMs(startMs: 0, endMs: Int64(d.rounded()))
            } else {
                nil
            }
            let latencyMs: Int64? = durationFieldMs ?? {
                guard let start = msgTimestampMs, let end = entryTimestampMs else { return nil }
                return Self.plausibleLatencyMs(startMs: start, endMs: end)
            }()
            guard let latencyMs else { return }

            let endMs = entryTimestampMs ?? msgTimestampMs ?? 0
            guard endMs > 0 else { return }

            let model = (message["responseModel"] as? String) ?? (message["model"] as? String)
            let provider = (message["provider"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let providerKey = (provider?.isEmpty == false) ? provider! : "unassigned"

            results.append(AgentSpeedSample(
                source: .pi,
                timestamp: Date(timeIntervalSince1970: Double(endMs) / 1000.0),
                model: model,
                providerKey: providerKey,
                outputTokens: output,
                latencyMs: latencyMs,
                firstTokenMs: nil))
        }
        return results
    }
}

// MARK: - Low-Level Read-Only Helpers

extension LocalAgentSpeedScanner {
    fileprivate static func plausibleLatencyMs(startMs: Int64, endMs: Int64) -> Int64? {
        let (delta, overflow) = endMs.subtractingReportingOverflow(startMs)
        guard !overflow,
              delta >= AgentSpeedSample.minPlausibleLatencyMs,
              delta <= AgentSpeedSample.maxPlausibleLatencyMs
        else { return nil }
        return delta
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    fileprivate static func fileStamp(for url: URL) -> (modifiedAt: Date, stamp: String)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return nil }
        let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000.0)
        return (mtime, "\(mtimeMs):\(size)")
    }

    fileprivate static func sqliteCompositeStamp(for dbURL: URL) -> String {
        let main = Self.fileStamp(for: dbURL)?.stamp ?? "none"
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let wal = Self.fileStamp(for: walURL)?.stamp ?? "none"
        return "\(main)|wal:\(wal)"
    }

    fileprivate static func collectJSONLFiles(under root: URL, cutoff: Date) -> [URL] {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var results: [URL] = []
        var visitedDirs: Set<String> = []

        func walk(_ directory: URL) {
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedDirs.insert(canonical).inserted else { return }
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { return }

            for item in items {
                let resolvedItem = item.resolvingSymlinksInPath()
                var itemIsDir: ObjCBool = false
                guard fm.fileExists(atPath: resolvedItem.path, isDirectory: &itemIsDir) else { continue }
                if itemIsDir.boolValue {
                    walk(resolvedItem)
                } else if resolvedItem.pathExtension == "jsonl" {
                    if let stamp = Self.fileStamp(for: resolvedItem), stamp.modifiedAt >= cutoff {
                        results.append(resolvedItem)
                    }
                }
            }
        }

        walk(resolvedRoot)
        return results
    }

    fileprivate static func parseFlexibleTimestampMs(_ raw: Any?) -> Int64? {
        if let str = raw as? String {
            return self.parseISO8601Millis(str)
        }
        if let num = Self.int64Value(raw) {
            // Distinguish Unix seconds vs Unix milliseconds
            return num > 10_000_000_000 ? num : num * 1000
        }
        return nil
    }

    static func parseISO8601Millis(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let bytes = Array(trimmed.utf8)
        /// Fast ASCII path for YYYY-MM-DDTHH:MM:SS(.fraction)?(Z|[+-]HH:MM)
        func digit(_ idx: Int) -> Int? {
            let b = bytes[idx]
            return (b >= 48 && b <= 57) ? Int(b - 48) : nil
        }
        func num(_ start: Int, _ len: Int) -> Int? {
            guard start + len <= bytes.count else { return nil }
            var acc = 0
            for i in start..<(start + len) {
                guard let d = digit(i) else { return nil }
                acc = acc * 10 + d
            }
            return acc
        }
        if bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32,
           bytes[13] == 58, bytes[16] == 58,
           let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
           let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2)
        {
            var idx = 19
            var millis = 0
            if idx < bytes.count, bytes[idx] == 46 {
                idx += 1
                var scale = 100
                while idx < bytes.count, let d = digit(idx) {
                    if scale > 0 {
                        millis += d * scale
                        scale /= 10
                    }
                    idx += 1
                }
            }
            var tzOffsetSeconds = 0
            if idx < bytes.count {
                let tzChar = bytes[idx]
                if tzChar == 90 || tzChar == 122 {
                    idx += 1
                } else if tzChar == 43 || tzChar == 45 {
                    let sign = tzChar == 43 ? 1 : -1
                    idx += 1
                    guard let tzHour = num(idx, 2) else { return nil }
                    idx += 2
                    if idx < bytes.count, bytes[idx] == 58 { idx += 1 }
                    let tzMin = num(idx, 2) ?? 0
                    tzOffsetSeconds = sign * (tzHour * 3600 + tzMin * 60)
                }
            }
            if let epochDays = Self.daysFromCivil(year: year, month: month, day: day) {
                let totalSeconds = Int64(epochDays) * 86400
                    + Int64(hour * 3600 + minute * 60 + second - tzOffsetSeconds)
                return totalSeconds * 1000 + Int64(millis)
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) {
            return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed).map { Int64(($0.timeIntervalSince1970 * 1000.0).rounded()) }
    }

    /// Howard Hinnant's civil-to-days algorithm (exact proleptic Gregorian days since 1970-01-01).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month + (month > 2 ? -3 : 9)
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    fileprivate static func intValue(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    fileprivate static func int64Value(_ raw: Any?) -> Int64? {
        if let v = raw as? Int64 { return v }
        if let v = raw as? Int { return Int64(v) }
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String { return Int64(s) }
        return nil
    }

    fileprivate static func uint64Value(_ raw: Any?) -> UInt64? {
        if let v = raw as? UInt64 { return v }
        if let v = raw as? Int, v >= 0 { return UInt64(v) }
        if let n = raw as? NSNumber, n.int64Value >= 0 { return n.uint64Value }
        return nil
    }

    fileprivate static func doubleValue(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    fileprivate static func sqliteBlob(_ stmt: OpaquePointer?, column: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    fileprivate static func sqliteTableExists(_ db: OpaquePointer, name: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) != 0
    }
    #endif
}
