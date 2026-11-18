#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Whether the local meter knows how to account for a wire protocol.  A protocol that is not
/// supported is intentionally represented as unavailable rather than as a zero-token result.
public enum LocalMeterProtocolStatus: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
}

public enum LocalMeterProtocolSupport {
    public static func status(for format: RelayAPIFormat) -> LocalMeterProtocolStatus {
        switch format {
        case .openAIResponses, .openAIChatCompletions, .anthropicMessages:
            .supported
        }
    }

    public static func shouldDisplayZero(for status: LocalMeterProtocolStatus) -> Bool {
        status == .supported
    }
}

/// Usage returned by an upstream Responses endpoint.  These values are kept beside, rather than
/// merged into, the local estimate so a relay's multiplier or omitted fields cannot masquerade as
/// Headroom's own measurement.
public struct LocalMeterReportedUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    /// Anthropic cache reads map here; the legacy property name remains stable for existing data.
    public let cachedInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let totalTokens: Int

    public init(
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        outputTokens: Int,
        reasoningTokens: Int = 0,
        totalTokens: Int)
    {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheCreationInputTokens = max(0, cacheCreationInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.totalTokens = max(0, totalTokens)
    }

    init(jsonObject object: [String: Any]) {
        let input = Self.integer(in: object, keys: ["input_tokens", "prompt_tokens"]) ?? 0
        let output = Self.integer(in: object, keys: ["output_tokens", "completion_tokens"]) ?? 0
        let cachedDetails = (object["input_tokens_details"] as? [String: Any])
            ?? (object["prompt_tokens_details"] as? [String: Any])
        let outputDetails = (object["output_tokens_details"] as? [String: Any])
            ?? (object["completion_tokens_details"] as? [String: Any])
        let cached = Self.integer(in: cachedDetails, keys: ["cached_tokens", "cache_read_tokens"])
            ?? Self.integer(in: object, keys: ["cached_tokens", "cache_read_input_tokens"])
            ?? 0
        let reasoning = Self.integer(in: outputDetails, keys: ["reasoning_tokens"])
            ?? Self.integer(in: object, keys: ["reasoning_tokens"])
            ?? 0
        let total = Self.integer(in: object, keys: ["total_tokens"])
            ?? input + output
        self.init(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningTokens: reasoning,
            totalTokens: total)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            inputTokens: container.decode(Int.self, forKey: .inputTokens),
            cachedInputTokens: container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0,
            cacheCreationInputTokens: container.decodeIfPresent(
                Int.self,
                forKey: .cacheCreationInputTokens) ?? 0,
            outputTokens: container.decode(Int.self, forKey: .outputTokens),
            reasoningTokens: container.decodeIfPresent(Int.self, forKey: .reasoningTokens) ?? 0,
            totalTokens: container.decode(Int.self, forKey: .totalTokens))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.inputTokens, forKey: .inputTokens)
        try container.encode(self.cachedInputTokens, forKey: .cachedInputTokens)
        try container.encode(self.cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
        try container.encode(self.outputTokens, forKey: .outputTokens)
        try container.encode(self.reasoningTokens, forKey: .reasoningTokens)
        try container.encode(self.totalTokens, forKey: .totalTokens)
    }

    private static func integer(in object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            guard let value = object[key] else { continue }
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String, let integer = Int(value) { return integer }
            if let value = value as? Double { return Int(value.rounded()) }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningTokens = "reasoning_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct LocalMeterUsageEstimate: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let provenance: LocalMeterTokenProvenance
    public let strategy: String

    public init(
        inputTokens: Int,
        outputTokens: Int,
        provenance: LocalMeterTokenProvenance = .localEstimated,
        strategy: String = LocalMeterTokenEstimator.strategy)
    {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.provenance = provenance
        self.strategy = strategy
    }

    public var totalTokens: Int {
        self.inputTokens + self.outputTokens
    }
}

public struct LocalMeterUsageDifference: Codable, Equatable, Sendable {
    public let localTotalTokens: Int
    public let reportedTotalTokens: Int
    public let reportedMinusLocalTotal: Int

    public init(localTotalTokens: Int, reportedTotalTokens: Int) {
        let localTotalTokens = max(0, localTotalTokens)
        let reportedTotalTokens = max(0, reportedTotalTokens)
        self.localTotalTokens = localTotalTokens
        self.reportedTotalTokens = reportedTotalTokens
        self.reportedMinusLocalTotal = reportedTotalTokens - localTotalTokens
    }
}

public struct OpenAIResponsesOutputDelta: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case output
        case reasoning
    }

    public let unitID: String
    public let text: String
    public let kind: Kind

    public init(unitID: String, text: String, kind: Kind) {
        self.unitID = unitID
        self.text = text
        self.kind = kind
    }
}

public enum OpenAIResponsesStreamStatus: String, Codable, Sendable {
    case completed
    case incomplete
    case failed
    case aborted
}

public struct OpenAIResponsesStreamResult: Equatable, Sendable {
    public let responseID: String?
    public let model: String?
    public let status: OpenAIResponsesStreamStatus
    public let outputText: String
    public let reasoningText: String
    public let usage: LocalMeterReportedUsage?

    public var isComplete: Bool {
        self.status == .completed
    }
}

public enum OpenAIResponsesSSEParserError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidJSON
}

/// Incremental parser for the OpenAI Responses Server-Sent Events wire format.
///
/// The parser consumes arbitrary byte chunks, including chunks that split a UTF-8 sequence or a
/// JSON object in the middle. It keeps only the current in-memory event and a set of stable event
/// identities; neither request bodies nor response text are written to disk.
public struct OpenAIResponsesSSEParser: Sendable {
    private var pendingBytes = Data()
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []
    private var seenEventKeys: Set<String> = []
    private var seenDeltaIDs: Set<String> = []
    private var capturedOutputTextByItemID: [String: String] = [:]
    private var capturedReasoningTextByItemID: [String: String] = [:]
    private var responseID: String?
    private var model: String?
    private var outputText = ""
    private var reasoningText = ""
    private var usage: LocalMeterReportedUsage?
    private var terminalStatus: OpenAIResponsesStreamStatus?

    public init() {}

    public var reportedUsage: LocalMeterReportedUsage? {
        self.usage
    }

    public var status: OpenAIResponsesStreamStatus? {
        self.terminalStatus
    }

    @discardableResult
    public mutating func append(_ chunk: Data) throws -> [OpenAIResponsesOutputDelta] {
        self.pendingBytes.append(chunk)
        var deltas: [OpenAIResponsesOutputDelta] = []
        while let newline = self.pendingBytes.firstIndex(of: 0x0A) {
            let lineData = self.pendingBytes[..<newline]
            self.pendingBytes.removeSubrange(...newline)
            var line = Data(lineData)
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                throw OpenAIResponsesSSEParserError.invalidUTF8
            }
            try deltas.append(contentsOf: self.consume(line: text))
        }
        return deltas
    }

    public mutating func finish() throws -> OpenAIResponsesStreamResult {
        if !self.pendingBytes.isEmpty {
            let line = self.pendingBytes
            self.pendingBytes.removeAll(keepingCapacity: false)
            guard let text = String(data: line, encoding: .utf8) else {
                throw OpenAIResponsesSSEParserError.invalidUTF8
            }
            _ = try self.consume(line: text)
        }
        if !self.dataLines.isEmpty || self.eventName != nil || self.eventID != nil {
            _ = try self.dispatchEvent()
        }
        if self.terminalStatus == nil {
            self.terminalStatus = .aborted
        }
        return self.result()
    }

    public mutating func abort() {
        self.terminalStatus = .aborted
    }

    private mutating func consume(line: String) throws -> [OpenAIResponsesOutputDelta] {
        guard !line.isEmpty else {
            return try self.dispatchEvent()
        }
        if line.first == ":" { return [] }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": self.eventName = value
        case "id": self.eventID = value
        case "data": self.dataLines.append(value)
        default: break
        }
        return []
    }

    private mutating func dispatchEvent() throws -> [OpenAIResponsesOutputDelta] {
        defer {
            self.eventName = nil
            self.eventID = nil
            self.dataLines.removeAll(keepingCapacity: true)
        }
        guard !self.dataLines.isEmpty else { return [] }
        let payload = self.dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            if self.terminalStatus == nil { self.terminalStatus = .completed }
            return []
        }
        guard self.terminalStatus == nil else { return [] }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw OpenAIResponsesSSEParserError.invalidJSON
        }

        let type = (self.eventName?.isEmpty == false ? self.eventName : nil)
            ?? (dictionary["type"] as? String)
            ?? ""
        let key = Self.eventKey(
            explicitID: self.eventID,
            type: type,
            dictionary: dictionary)
        guard self.seenEventKeys.insert(key).inserted else { return [] }

        return self.processEvent(dictionary: dictionary, type: type, payload: payload)
    }

    private mutating func processEvent(
        dictionary: [String: Any],
        type: String,
        payload: String) -> [OpenAIResponsesOutputDelta]
    {
        var deltas = self.updateMetadata(from: dictionary)
        let response = dictionary["response"] as? [String: Any]
        if let response {
            deltas.append(contentsOf: self.updateMetadata(from: response))
        }
        self.updateUsage(from: dictionary, response: response)

        deltas.append(contentsOf: self.processTextEvent(
            type: type,
            dictionary: dictionary,
            payload: payload))
        self.updateTerminalStatus(for: type)
        return deltas
    }

    private mutating func updateUsage(
        from dictionary: [String: Any],
        response: [String: Any]?)
    {
        if let usageObject = dictionary["usage"] as? [String: Any] {
            self.usage = LocalMeterReportedUsage(jsonObject: usageObject)
        } else if let usageObject = response?["usage"] as? [String: Any] {
            self.usage = LocalMeterReportedUsage(jsonObject: usageObject)
        }
    }

    private mutating func processTextEvent(
        type: String,
        dictionary: [String: Any],
        payload: String) -> [OpenAIResponsesOutputDelta]
    {
        switch type {
        case "response.output_text.delta", "response.reasoning_summary_text.delta",
             "response.reasoning_text.delta", "response.reasoning.delta":
            self.processTextDelta(type: type, dictionary: dictionary, payload: payload)
        case "response.output_text.done":
            self.captureFinalText(
                dictionary["text"] as? String,
                itemID: dictionary["item_id"] as? String,
                kind: .output)
        case "response.reasoning_text.done", "response.reasoning_summary_text.done":
            self.captureFinalText(
                dictionary["text"] as? String,
                itemID: dictionary["item_id"] as? String,
                kind: .reasoning)
        default:
            []
        }
    }

    private mutating func processTextDelta(
        type: String,
        dictionary: [String: Any],
        payload: String) -> [OpenAIResponsesOutputDelta]
    {
        guard let text = dictionary["delta"] as? String, !text.isEmpty else { return [] }
        let kind: OpenAIResponsesOutputDelta.Kind = type == "response.output_text.delta"
            ? .output
            : .reasoning
        let unitID = Self.deltaID(type: type, dictionary: dictionary, payload: payload)
        guard self.seenDeltaIDs.insert(unitID).inserted else { return [] }
        self.append(text: text, kind: kind, itemID: dictionary["item_id"] as? String)
        return [OpenAIResponsesOutputDelta(unitID: unitID, text: text, kind: kind)]
    }

    private mutating func append(
        text: String,
        kind: OpenAIResponsesOutputDelta.Kind,
        itemID: String?)
    {
        switch kind {
        case .output:
            if let itemID {
                self.capturedOutputTextByItemID[itemID, default: ""].append(text)
            }
            self.outputText.append(text)
        case .reasoning:
            if let itemID {
                self.capturedReasoningTextByItemID[itemID, default: ""].append(text)
            }
            self.reasoningText.append(text)
        }
    }

    private mutating func updateTerminalStatus(for type: String) {
        switch type {
        case "response.completed":
            self.terminalStatus = .completed
        case "response.incomplete":
            self.terminalStatus = .incomplete
        case "response.failed", "error":
            self.terminalStatus = .failed
        case "response.aborted", "response.cancelled":
            self.terminalStatus = .aborted
        default:
            break
        }
    }

    private mutating func updateMetadata(from dictionary: [String: Any]) -> [OpenAIResponsesOutputDelta] {
        var deltas: [OpenAIResponsesOutputDelta] = []
        if let id = dictionary["id"] as? String, !id.isEmpty, self.responseID == nil {
            self.responseID = id
        }
        if let id = dictionary["response_id"] as? String, !id.isEmpty, self.responseID == nil {
            self.responseID = id
        }
        if let value = dictionary["model"] as? String, !value.isEmpty {
            self.model = value
        }
        if let item = dictionary["item"] as? [String: Any] {
            deltas.append(contentsOf: self.captureOutputItem(item))
        }
        if let output = dictionary["output"] as? [[String: Any]] {
            deltas.append(contentsOf: self.captureCompletedOutput(output))
        }
        return deltas
    }

    private mutating func captureCompletedOutput(_ output: [[String: Any]]) -> [OpenAIResponsesOutputDelta] {
        var deltas: [OpenAIResponsesOutputDelta] = []
        for item in output {
            deltas.append(contentsOf: self.captureOutputItem(item))
        }
        return deltas
    }

    private mutating func captureOutputItem(_ item: [String: Any]) -> [OpenAIResponsesOutputDelta] {
        let type = item["type"] as? String ?? ""
        let itemID = item["id"] as? String
        if type == "message", let content = item["content"] as? [[String: Any]] {
            var deltas: [OpenAIResponsesOutputDelta] = []
            var captured = itemID.flatMap { self.capturedOutputTextByItemID[$0] } ?? ""
            for (index, part) in content.enumerated() where part["type"] as? String == "output_text" {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                let missing = Self.missingFinalText(text, alreadyCaptured: captured)
                guard !missing.isEmpty else { continue }
                let unitID = Self.itemDeltaID(
                    kind: .output,
                    itemID: itemID,
                    index: index,
                    text: missing)
                guard self.seenDeltaIDs.insert(unitID).inserted else { continue }
                self.outputText.append(missing)
                captured.append(missing)
                deltas.append(OpenAIResponsesOutputDelta(unitID: unitID, text: missing, kind: .output))
            }
            if let itemID, !captured.isEmpty {
                self.capturedOutputTextByItemID[itemID] = captured
            }
            return deltas
        } else if type == "reasoning", let summary = item["summary"] as? [[String: Any]] {
            var deltas: [OpenAIResponsesOutputDelta] = []
            var captured = itemID.flatMap { self.capturedReasoningTextByItemID[$0] } ?? ""
            for (index, part) in summary.enumerated() {
                guard let text = part["text"] as? String, !text.isEmpty else { continue }
                let missing = Self.missingFinalText(text, alreadyCaptured: captured)
                guard !missing.isEmpty else { continue }
                let unitID = Self.itemDeltaID(
                    kind: .reasoning,
                    itemID: itemID,
                    index: index,
                    text: missing)
                guard self.seenDeltaIDs.insert(unitID).inserted else { continue }
                self.reasoningText.append(missing)
                captured.append(missing)
                deltas.append(OpenAIResponsesOutputDelta(unitID: unitID, text: missing, kind: .reasoning))
            }
            if let itemID, !captured.isEmpty {
                self.capturedReasoningTextByItemID[itemID] = captured
            }
            return deltas
        }
        return []
    }

    private mutating func captureFinalText(
        _ text: String?,
        itemID: String?,
        kind: OpenAIResponsesOutputDelta.Kind) -> [OpenAIResponsesOutputDelta]
    {
        guard let text, !text.isEmpty else { return [] }
        switch kind {
        case .output:
            let alreadyCaptured = itemID.flatMap { self.capturedOutputTextByItemID[$0] }
                ?? self.outputText
            let missing = Self.missingFinalText(text, alreadyCaptured: alreadyCaptured)
            guard !missing.isEmpty else { return [] }
            let unitID = Self.finalTextID(kind: kind, itemID: itemID, text: missing)
            guard self.seenDeltaIDs.insert(unitID).inserted else { return [] }
            self.outputText.append(missing)
            if let itemID {
                self.capturedOutputTextByItemID[itemID, default: ""].append(missing)
            }
            return [OpenAIResponsesOutputDelta(unitID: unitID, text: missing, kind: kind)]
        case .reasoning:
            let alreadyCaptured = itemID.flatMap { self.capturedReasoningTextByItemID[$0] }
                ?? self.reasoningText
            let missing = Self.missingFinalText(text, alreadyCaptured: alreadyCaptured)
            guard !missing.isEmpty else { return [] }
            let unitID = Self.finalTextID(kind: kind, itemID: itemID, text: missing)
            guard self.seenDeltaIDs.insert(unitID).inserted else { return [] }
            self.reasoningText.append(missing)
            if let itemID {
                self.capturedReasoningTextByItemID[itemID, default: ""].append(missing)
            }
            return [OpenAIResponsesOutputDelta(unitID: unitID, text: missing, kind: kind)]
        }
    }

    private static func missingFinalText(_ text: String, alreadyCaptured: String) -> String {
        guard !alreadyCaptured.isEmpty else { return text }
        // A reconnect may begin in the middle of an item. In that case the fresh parser sees a
        // suffix delta before the server repeats the full `*.done` text; the full value is already
        // represented by the accumulator and must not be emitted as a second unit.
        if text == alreadyCaptured || text.hasSuffix(alreadyCaptured) || alreadyCaptured.hasSuffix(text) {
            return ""
        }
        if text.hasPrefix(alreadyCaptured) {
            return String(text.dropFirst(alreadyCaptured.count))
        }
        return text
    }

    private static func itemDeltaID(
        kind: OpenAIResponsesOutputDelta.Kind,
        itemID: String?,
        index: Int,
        text: String) -> String
    {
        "item:\(kind.rawValue):\(itemID ?? ""):\(index):\(self.digest(text))"
    }

    private static func finalTextID(
        kind: OpenAIResponsesOutputDelta.Kind,
        itemID: String?,
        text: String) -> String
    {
        "final:\(kind.rawValue):\(itemID ?? ""):\(self.digest(text))"
    }

    private func result() -> OpenAIResponsesStreamResult {
        OpenAIResponsesStreamResult(
            responseID: self.responseID,
            model: self.model,
            status: self.terminalStatus ?? .aborted,
            outputText: self.outputText,
            reasoningText: self.reasoningText,
            usage: self.usage)
    }

    private static func eventKey(
        explicitID: String?,
        type: String,
        dictionary: [String: Any]) -> String
    {
        if let explicitID, !explicitID.isEmpty { return "event:\(explicitID)" }
        let sequence = dictionary["sequence_number"] as? NSNumber
        let responseID = (dictionary["response_id"] as? String)
            ?? (dictionary["response"] as? [String: Any])?["id"] as? String
            ?? ""
        if let sequence {
            return "\(type):\(responseID):sequence:\(sequence.intValue)"
        }
        return "payload:\(Self.digest(dictionary))"
    }

    private static func deltaID(type: String, dictionary: [String: Any], payload: String) -> String {
        let responseID = dictionary["response_id"] as? String ?? ""
        let itemID = dictionary["item_id"] as? String ?? ""
        let outputIndex = (dictionary["output_index"] as? NSNumber)?.stringValue ?? ""
        let contentIndex = (dictionary["content_index"] as? NSNumber)?.stringValue ?? ""
        if let sequence = dictionary["sequence_number"] as? NSNumber {
            return "\(type):\(responseID):\(sequence.intValue)"
        }
        if !itemID.isEmpty || !outputIndex.isEmpty || !contentIndex.isEmpty {
            return "\(type):\(responseID):\(itemID):\(outputIndex):\(contentIndex):\(Self.digest(payload))"
        }
        return "\(type):\(Self.digest(payload))"
    }

    private static func digest(_ value: Any) -> String {
        let data: Data = if let value = value as? String {
            Data(value.utf8)
        } else if JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        {
            encoded
        } else {
            Data(String(describing: value).utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A streaming measurement session joins the protocol parser to the M4 ledger accumulator. It
/// starts with a local estimate of the request input, records each stable output unit as it
/// arrives, and publishes a record only after a completed Responses event.
public actor LocalMeterResponsesSession {
    private let context: LocalMeterRequestContext
    private let attemptID: String
    private let inputText: String
    private let accumulator: LocalMeterUsageAccumulator
    private var parser = OpenAIResponsesSSEParser()
    private var started = false
    private var finished = false

    public init(
        context: LocalMeterRequestContext,
        attemptID: String,
        inputText: String,
        accumulator: LocalMeterUsageAccumulator)
    {
        self.context = context
        self.attemptID = attemptID
        self.inputText = inputText
        self.accumulator = accumulator
    }

    public func start() async {
        guard !self.started else { return }
        self.started = true
        let inputTokens = LocalMeterTokenEstimator.estimate(self.inputText).tokens
        await self.accumulator.record(.begin(
            context: self.context,
            attemptID: self.attemptID,
            inputTokens: inputTokens))
    }

    @discardableResult
    public func append(_ chunk: Data) async throws -> [OpenAIResponsesOutputDelta] {
        await self.start()
        let deltas: [OpenAIResponsesOutputDelta]
        do {
            deltas = try self.parser.append(chunk)
        } catch {
            self.finished = true
            self.parser.abort()
            await self.abortMeasurement()
            throw error
        }
        for delta in deltas {
            await self.accumulator.record(.outputText(
                requestID: self.context.requestID,
                attemptID: self.attemptID,
                unitID: delta.unitID,
                stream: delta.kind == .output ? .output : .reasoning,
                text: delta.text))
        }
        return deltas
    }

    public func finish() async throws -> LocalMeterUsageRecord? {
        await self.start()
        guard !self.finished else {
            return await self.recordForRequest()
        }
        self.finished = true
        let result: OpenAIResponsesStreamResult
        do {
            result = try self.parser.finish()
        } catch {
            await self.abortMeasurement()
            return nil
        }
        if result.isComplete {
            await self.accumulator.record(.completeWithReportedUsage(
                requestID: self.context.requestID,
                attemptID: self.attemptID,
                reportedUsage: result.usage))
        } else {
            await self.accumulator.record(.abort(
                requestID: self.context.requestID,
                attemptID: self.attemptID))
        }
        return await self.recordForRequest()
    }

    public func abort() async {
        await self.start()
        guard !self.finished else { return }
        self.finished = true
        self.parser.abort()
        await self.abortMeasurement()
    }

    private func abortMeasurement() async {
        await self.accumulator.record(.abort(
            requestID: self.context.requestID,
            attemptID: self.attemptID))
    }

    private func recordForRequest() async -> LocalMeterUsageRecord? {
        await self.accumulator.records.first { $0.entry.key.requestID == self.context.requestID }
    }
}
