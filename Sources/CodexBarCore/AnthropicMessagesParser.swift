#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum AnthropicMessagesStreamStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case aborted
}

public struct AnthropicMessagesReportedUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0)
    {
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.cacheCreationInputTokens = max(0, cacheCreationInputTokens)
        self.cacheReadInputTokens = max(0, cacheReadInputTokens)
    }

    public var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + self.cacheCreationInputTokens + self.cacheReadInputTokens + outputTokens
    }
}

public struct AnthropicMessagesOutputDelta: Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case output
        case reasoning
    }

    public let unitID: String
    public let blockIndex: Int
    public let text: String
    public let kind: Kind

    public init(unitID: String, blockIndex: Int, text: String, kind: Kind) {
        self.unitID = unitID
        self.blockIndex = blockIndex
        self.text = text
        self.kind = kind
    }
}

public struct AnthropicMessagesResult: Equatable, Sendable {
    public let messageID: String?
    public let model: String?
    public let status: AnthropicMessagesStreamStatus
    public let outputText: String
    public let reasoningText: String
    public let usage: AnthropicMessagesReportedUsage?

    public var isComplete: Bool {
        self.status == .completed
    }
}

public enum AnthropicMessagesParserError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidJSON
}

private enum AnthropicMessagesTokenMaterial {
    static func fragments(from content: [[String: Any]]) -> (output: [String], reasoning: [String]) {
        var output: [String] = []
        var reasoning: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = Self.nonemptyString(block["text"]) { output.append(text) }
            case "thinking":
                if let thinking = Self.nonemptyString(block["thinking"]) { reasoning.append(thinking) }
            case "tool_use":
                if let name = Self.nonemptyString(block["name"]) { output.append(name) }
                if let input = block["input"], let json = Self.nonemptyJSON(input) { output.append(json) }
            default:
                break
            }
        }
        return (output, reasoning)
    }

    static func nonemptyJSON(_ value: Any) -> String? {
        if let dictionary = value as? [String: Any], dictionary.isEmpty { return nil }
        if let array = value as? [Any], array.isEmpty { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              !json.isEmpty
        else {
            return nil
        }
        return json
    }

    static func integer(in object: [String: Any]?, key: String) -> Int? {
        guard let value = object?[key] else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        if let value = value as? Double { return Int(value.rounded()) }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }
}

public enum AnthropicMessagesJSONParser {
    public static func parse(_ data: Data) throws -> AnthropicMessagesResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw AnthropicMessagesParserError.invalidJSON
        }
        if dictionary["type"] as? String == "error" || dictionary["error"] != nil {
            return AnthropicMessagesResult(
                messageID: nil,
                model: nil,
                status: .failed,
                outputText: "",
                reasoningText: "",
                usage: nil)
        }

        let material = AnthropicMessagesTokenMaterial.fragments(
            from: dictionary["content"] as? [[String: Any]] ?? [])
        let usage = Self.usage(from: dictionary["usage"] as? [String: Any])
        return AnthropicMessagesResult(
            messageID: dictionary["id"] as? String,
            model: dictionary["model"] as? String,
            status: .completed,
            outputText: material.output.joined(),
            reasoningText: material.reasoning.joined(),
            usage: usage)
    }

    private static func usage(from object: [String: Any]?) -> AnthropicMessagesReportedUsage? {
        guard let object else { return nil }
        return AnthropicMessagesReportedUsage(
            inputTokens: AnthropicMessagesTokenMaterial.integer(in: object, key: "input_tokens"),
            outputTokens: AnthropicMessagesTokenMaterial.integer(in: object, key: "output_tokens"),
            cacheCreationInputTokens: AnthropicMessagesTokenMaterial.integer(
                in: object,
                key: "cache_creation_input_tokens") ?? 0,
            cacheReadInputTokens: AnthropicMessagesTokenMaterial.integer(
                in: object,
                key: "cache_read_input_tokens") ?? 0)
    }
}

public struct AnthropicMessagesSSEParser: Sendable {
    private var pendingBytes = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var nextOrdinalByBlock: [Int: Int] = [:]
    private var messageID: String?
    private var model: String?
    private var outputText = ""
    private var reasoningText = ""
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cacheCreationInputTokens = 0
    private var cacheReadInputTokens = 0
    private var hasUsage = false
    private var terminalStatus: AnthropicMessagesStreamStatus?

    public init() {}

    public var reportedUsage: AnthropicMessagesReportedUsage? {
        guard self.hasUsage else { return nil }
        return AnthropicMessagesReportedUsage(
            inputTokens: self.inputTokens,
            outputTokens: self.outputTokens,
            cacheCreationInputTokens: self.cacheCreationInputTokens,
            cacheReadInputTokens: self.cacheReadInputTokens)
    }

    public var status: AnthropicMessagesStreamStatus? {
        self.terminalStatus
    }

    @discardableResult
    public mutating func append(_ chunk: Data) throws -> [AnthropicMessagesOutputDelta] {
        self.pendingBytes.append(chunk)
        var deltas: [AnthropicMessagesOutputDelta] = []
        while let newline = self.pendingBytes.firstIndex(of: 0x0A) {
            let lineData = self.pendingBytes[..<newline]
            self.pendingBytes.removeSubrange(...newline)
            var line = Data(lineData)
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                throw AnthropicMessagesParserError.invalidUTF8
            }
            try deltas.append(contentsOf: self.consume(line: text))
        }
        return deltas
    }

    public mutating func finish() throws -> AnthropicMessagesResult {
        if !self.pendingBytes.isEmpty {
            let line = self.pendingBytes
            self.pendingBytes.removeAll(keepingCapacity: false)
            guard let text = String(data: line, encoding: .utf8) else {
                throw AnthropicMessagesParserError.invalidUTF8
            }
            _ = try self.consume(line: text)
        }
        if !self.dataLines.isEmpty || self.eventName != nil {
            _ = try self.dispatchEvent()
        }
        if self.terminalStatus == nil { self.terminalStatus = .aborted }
        return self.result()
    }

    public mutating func abort() {
        self.terminalStatus = .aborted
    }

    private mutating func consume(line: String) throws -> [AnthropicMessagesOutputDelta] {
        guard !line.isEmpty else { return try self.dispatchEvent() }
        if line.first == ":" { return [] }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": self.eventName = value
        case "data": self.dataLines.append(value)
        default: break
        }
        return []
    }

    private mutating func dispatchEvent() throws -> [AnthropicMessagesOutputDelta] {
        defer {
            self.eventName = nil
            self.dataLines.removeAll(keepingCapacity: true)
        }
        guard !self.dataLines.isEmpty else { return [] }
        guard self.terminalStatus == nil else { return [] }
        let payload = self.dataLines.joined(separator: "\n")
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw AnthropicMessagesParserError.invalidJSON
        }
        let type = (self.eventName?.isEmpty == false ? self.eventName : nil)
            ?? dictionary["type"] as? String
            ?? ""
        return self.processEvent(type: type, dictionary: dictionary)
    }

    private mutating func processEvent(
        type: String,
        dictionary: [String: Any]) -> [AnthropicMessagesOutputDelta]
    {
        switch type {
        case "message_start":
            self.processMessageStart(dictionary)
            return []
        case "content_block_start":
            return self.processContentBlockStart(dictionary)
        case "content_block_delta":
            return self.processContentBlockDelta(dictionary)
        case "message_delta":
            self.processMessageDelta(dictionary)
            return []
        case "message_stop":
            self.terminalStatus = .completed
            return []
        case "error":
            self.terminalStatus = .failed
            return []
        case "ping", "content_block_stop":
            return []
        default:
            return []
        }
    }

    private mutating func processMessageStart(_ dictionary: [String: Any]) {
        guard let message = dictionary["message"] as? [String: Any] else { return }
        if let messageID = message["id"] as? String, !messageID.isEmpty {
            self.messageID = messageID
        }
        if let model = message["model"] as? String, !model.isEmpty {
            self.model = model
        }
        guard let usage = message["usage"] as? [String: Any] else { return }
        self.hasUsage = true
        self.inputTokens = AnthropicMessagesTokenMaterial.integer(in: usage, key: "input_tokens")
            .map { max(0, $0) }
        self.cacheCreationInputTokens = max(
            0,
            AnthropicMessagesTokenMaterial.integer(in: usage, key: "cache_creation_input_tokens") ?? 0)
        self.cacheReadInputTokens = max(
            0,
            AnthropicMessagesTokenMaterial.integer(in: usage, key: "cache_read_input_tokens") ?? 0)
        // Anthropic's message_start sample carries an initial output_tokens value, but the
        // authoritative stream total arrives cumulatively in message_delta. Keep it unknown until
        // that event so a disconnect cannot masquerade as a measured zero or final value.
        self.outputTokens = nil
    }

    private mutating func processMessageDelta(_ dictionary: [String: Any]) {
        guard let usage = dictionary["usage"] as? [String: Any],
              let cumulative = AnthropicMessagesTokenMaterial.integer(in: usage, key: "output_tokens")
        else {
            return
        }
        self.hasUsage = true
        self.outputTokens = max(self.outputTokens ?? 0, max(0, cumulative))
    }

    private mutating func processContentBlockStart(
        _ dictionary: [String: Any]) -> [AnthropicMessagesOutputDelta]
    {
        let index = Self.integer(dictionary["index"]) ?? 0
        guard let block = dictionary["content_block"] as? [String: Any] else { return [] }
        switch block["type"] as? String {
        case "text":
            return self.emit(block["text"] as? String, blockIndex: index, kind: .output)
        case "thinking":
            return self.emit(block["thinking"] as? String, blockIndex: index, kind: .reasoning)
        case "tool_use":
            var deltas = self.emit(block["name"] as? String, blockIndex: index, kind: .output)
            if let input = block["input"], let json = AnthropicMessagesTokenMaterial.nonemptyJSON(input) {
                deltas.append(contentsOf: self.emit(json, blockIndex: index, kind: .output))
            }
            return deltas
        default:
            return []
        }
    }

    private mutating func processContentBlockDelta(
        _ dictionary: [String: Any]) -> [AnthropicMessagesOutputDelta]
    {
        let index = Self.integer(dictionary["index"]) ?? 0
        guard let delta = dictionary["delta"] as? [String: Any] else { return [] }
        switch delta["type"] as? String {
        case "text_delta":
            return self.emit(delta["text"] as? String, blockIndex: index, kind: .output)
        case "thinking_delta":
            return self.emit(delta["thinking"] as? String, blockIndex: index, kind: .reasoning)
        case "input_json_delta":
            return self.emit(delta["partial_json"] as? String, blockIndex: index, kind: .output)
        case "signature_delta":
            return []
        default:
            return []
        }
    }

    private mutating func emit(
        _ text: String?,
        blockIndex: Int,
        kind: AnthropicMessagesOutputDelta.Kind) -> [AnthropicMessagesOutputDelta]
    {
        guard let text, !text.isEmpty else { return [] }
        let ordinal = self.nextOrdinalByBlock[blockIndex, default: 0]
        self.nextOrdinalByBlock[blockIndex] = ordinal + 1
        switch kind {
        case .output: self.outputText.append(text)
        case .reasoning: self.reasoningText.append(text)
        }
        return [AnthropicMessagesOutputDelta(
            unitID: Self.unitID(
                messageID: self.messageID,
                blockIndex: blockIndex,
                ordinal: ordinal,
                kind: kind,
                text: text),
            blockIndex: blockIndex,
            text: text,
            kind: kind)]
    }

    private func result() -> AnthropicMessagesResult {
        AnthropicMessagesResult(
            messageID: self.messageID,
            model: self.model,
            status: self.terminalStatus ?? .aborted,
            outputText: self.outputText,
            reasoningText: self.reasoningText,
            usage: self.reportedUsage)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func unitID(
        messageID: String?,
        blockIndex: Int,
        ordinal: Int,
        kind: AnthropicMessagesOutputDelta.Kind,
        text: String) -> String
    {
        let material = Data(
            "\(messageID ?? "")\u{0}\(blockIndex)\u{0}\(ordinal)\u{0}\(kind.rawValue)\u{0}\(text)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "anthropic-delta:\(digest)"
    }
}

/// Joins Anthropic Messages parsing to the same request accumulator as the OpenAI protocols.
/// Cache lanes remain upstream-reported metadata; the M4 ledger entry continues to hold only the
/// dependency-free local estimate, so provider values can never replace local token accounting.
public actor LocalMeterAnthropicMessagesSession {
    private let context: LocalMeterRequestContext
    private let attemptID: String
    private let inputText: String
    private let accumulator: LocalMeterUsageAccumulator
    private var parser = AnthropicMessagesSSEParser()
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
        await self.accumulator.record(.begin(
            context: self.context,
            attemptID: self.attemptID,
            inputTokens: LocalMeterTokenEstimator.estimate(self.inputText).tokens))
    }

    @discardableResult
    public func append(_ chunk: Data) async throws -> [AnthropicMessagesOutputDelta] {
        await self.start()
        let deltas: [AnthropicMessagesOutputDelta]
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
        guard !self.finished else { return await self.recordForRequest() }
        self.finished = true
        let result: AnthropicMessagesResult
        do {
            result = try self.parser.finish()
        } catch {
            await self.abortMeasurement()
            throw error
        }
        if result.isComplete {
            await self.completeMeasurement(reportedUsage: Self.reportedUsage(from: result.usage))
        } else {
            await self.abortMeasurement()
        }
        return await self.recordForRequest()
    }

    public func completeNonStreaming(_ data: Data) async throws -> LocalMeterUsageRecord? {
        await self.start()
        guard !self.finished else { return await self.recordForRequest() }
        self.finished = true
        let result: AnthropicMessagesResult
        do {
            result = try AnthropicMessagesJSONParser.parse(data)
        } catch {
            await self.abortMeasurement()
            throw error
        }
        await self.recordNonStreamingText(result.outputText, stream: .output, result: result)
        await self.recordNonStreamingText(result.reasoningText, stream: .reasoning, result: result)
        if result.isComplete {
            await self.completeMeasurement(reportedUsage: Self.reportedUsage(from: result.usage))
        } else {
            await self.abortMeasurement()
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

    private func recordNonStreamingText(
        _ text: String,
        stream: LocalMeterTextStream,
        result: AnthropicMessagesResult) async
    {
        guard !text.isEmpty else { return }
        await self.accumulator.record(.outputText(
            requestID: self.context.requestID,
            attemptID: self.attemptID,
            unitID: Self.nonStreamingUnitID(result: result, stream: stream, text: text),
            stream: stream,
            text: text))
    }

    private func completeMeasurement(reportedUsage: LocalMeterReportedUsage?) async {
        await self.accumulator.record(.completeWithReportedUsage(
            requestID: self.context.requestID,
            attemptID: self.attemptID,
            reportedUsage: reportedUsage))
    }

    private func abortMeasurement() async {
        await self.accumulator.record(.abort(
            requestID: self.context.requestID,
            attemptID: self.attemptID))
    }

    private func recordForRequest() async -> LocalMeterUsageRecord? {
        await self.accumulator.records.first { $0.entry.key.requestID == self.context.requestID }
    }

    private static func reportedUsage(
        from usage: AnthropicMessagesReportedUsage?) -> LocalMeterReportedUsage?
    {
        guard let usage,
              let inputTokens = usage.inputTokens,
              let outputTokens = usage.outputTokens
        else { return nil }
        return LocalMeterReportedUsage(
            inputTokens: inputTokens,
            cachedInputTokens: usage.cacheReadInputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens,
            outputTokens: outputTokens,
            totalTokens: inputTokens
                + usage.cacheCreationInputTokens
                + usage.cacheReadInputTokens
                + outputTokens)
    }

    private static func nonStreamingUnitID(
        result: AnthropicMessagesResult,
        stream: LocalMeterTextStream,
        text: String) -> String
    {
        let material = Data("\(result.messageID ?? "")\u{0}\(stream.rawValue)\u{0}\(text)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "anthropic-response:\(digest)"
    }
}
