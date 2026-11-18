#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum OpenAIChatCompletionsStreamStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case aborted
}

public struct OpenAIChatCompletionsOutputDelta: Equatable, Sendable {
    public let unitID: String
    public let choiceIndex: Int
    public let text: String

    public init(unitID: String, choiceIndex: Int, text: String) {
        self.unitID = unitID
        self.choiceIndex = choiceIndex
        self.text = text
    }
}

public struct OpenAIChatCompletionsResult: Equatable, Sendable {
    public let completionID: String?
    public let model: String?
    public let status: OpenAIChatCompletionsStreamStatus
    public let outputText: String
    public let usage: LocalMeterReportedUsage?

    public var isComplete: Bool {
        self.status == .completed
    }
}

public enum OpenAIChatCompletionsParserError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidJSON
}

private enum OpenAIChatCompletionsTokenMaterial {
    static func fragments(from container: [String: Any]) -> [String] {
        var fragments: [String] = []
        if let content = container["content"] as? String, !content.isEmpty {
            fragments.append(content)
        } else if let parts = container["content"] as? [[String: Any]] {
            fragments.append(contentsOf: parts.compactMap { part in
                guard let text = part["text"] as? String, !text.isEmpty else { return nil }
                return text
            })
        }
        let toolCalls = (container["tool_calls"] as? [[String: Any]] ?? [])
            .sorted { Self.index($0) < Self.index($1) }
        for toolCall in toolCalls {
            guard let function = toolCall["function"] as? [String: Any] else { continue }
            for key in ["name", "arguments"] {
                if let value = function[key] as? String, !value.isEmpty {
                    fragments.append(value)
                }
            }
        }
        return fragments
    }

    private static func index(_ value: [String: Any]) -> Int {
        if let index = value["index"] as? Int { return index }
        if let index = value["index"] as? NSNumber { return index.intValue }
        return 0
    }
}

/// Parser for a non-streaming `chat.completion` response. The payload is kept in memory and only
/// the output text plus accounting metadata leave this boundary.
public enum OpenAIChatCompletionsJSONParser {
    public static func parse(_ data: Data) throws -> OpenAIChatCompletionsResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw OpenAIChatCompletionsParserError.invalidJSON
        }

        let choices = dictionary["choices"] as? [[String: Any]] ?? []
        let outputText = choices
            .sorted { Self.choiceIndex($0) < Self.choiceIndex($1) }
            .flatMap { choice -> [String] in
                guard let message = choice["message"] as? [String: Any] else { return [] }
                return OpenAIChatCompletionsTokenMaterial.fragments(from: message)
            }
            .joined()
        let usage = (dictionary["usage"] as? [String: Any])
            .map(LocalMeterReportedUsage.init(jsonObject:))
        return OpenAIChatCompletionsResult(
            completionID: dictionary["id"] as? String,
            model: dictionary["model"] as? String,
            status: .completed,
            outputText: outputText,
            usage: usage)
    }

    private static func choiceIndex(_ choice: [String: Any]) -> Int {
        if let value = choice["index"] as? Int { return value }
        if let value = choice["index"] as? NSNumber { return value.intValue }
        return 0
    }
}

/// Incremental parser for Chat Completions Server-Sent Events.
///
/// OpenAI emits usage in a final, choices-empty chunk when `stream_options.include_usage` is
/// enabled, followed by `[DONE]`. A finish reason alone is not sufficient proof of a complete
/// stream because an interrupted connection can omit both the usage chunk and `[DONE]`.
public struct OpenAIChatCompletionsSSEParser: Sendable {
    private var pendingBytes = Data()
    private var dataLines: [String] = []
    private var nextOrdinalByChoice: [Int: Int] = [:]
    private var outputTextByChoice: [Int: String] = [:]
    private var completionID: String?
    private var model: String?
    private var usage: LocalMeterReportedUsage?
    private var terminalStatus: OpenAIChatCompletionsStreamStatus?

    public init() {}

    public var reportedUsage: LocalMeterReportedUsage? {
        self.usage
    }

    public var status: OpenAIChatCompletionsStreamStatus? {
        self.terminalStatus
    }

    @discardableResult
    public mutating func append(_ chunk: Data) throws -> [OpenAIChatCompletionsOutputDelta] {
        self.pendingBytes.append(chunk)
        var deltas: [OpenAIChatCompletionsOutputDelta] = []
        while let newline = self.pendingBytes.firstIndex(of: 0x0A) {
            let lineData = self.pendingBytes[..<newline]
            self.pendingBytes.removeSubrange(...newline)
            var line = Data(lineData)
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8) else {
                throw OpenAIChatCompletionsParserError.invalidUTF8
            }
            try deltas.append(contentsOf: self.consume(line: text))
        }
        return deltas
    }

    public mutating func finish() throws -> OpenAIChatCompletionsResult {
        if !self.pendingBytes.isEmpty {
            let line = self.pendingBytes
            self.pendingBytes.removeAll(keepingCapacity: false)
            guard let text = String(data: line, encoding: .utf8) else {
                throw OpenAIChatCompletionsParserError.invalidUTF8
            }
            _ = try self.consume(line: text)
        }
        if !self.dataLines.isEmpty {
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

    private mutating func consume(line: String) throws -> [OpenAIChatCompletionsOutputDelta] {
        guard !line.isEmpty else {
            return try self.dispatchEvent()
        }
        if line.first == ":" { return [] }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return [] }
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        self.dataLines.append(value)
        return []
    }

    private mutating func dispatchEvent() throws -> [OpenAIChatCompletionsOutputDelta] {
        defer { self.dataLines.removeAll(keepingCapacity: true) }
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
            throw OpenAIChatCompletionsParserError.invalidJSON
        }
        if dictionary["error"] != nil {
            self.terminalStatus = .failed
            return []
        }
        self.updateMetadata(from: dictionary)
        return self.captureDeltas(from: dictionary)
    }

    private mutating func updateMetadata(from dictionary: [String: Any]) {
        if let id = dictionary["id"] as? String, !id.isEmpty {
            self.completionID = id
        }
        if let model = dictionary["model"] as? String, !model.isEmpty {
            self.model = model
        }
        if let usage = dictionary["usage"] as? [String: Any] {
            self.usage = LocalMeterReportedUsage(jsonObject: usage)
        }
    }

    private mutating func captureDeltas(
        from dictionary: [String: Any]) -> [OpenAIChatCompletionsOutputDelta]
    {
        guard let choices = dictionary["choices"] as? [[String: Any]] else { return [] }
        var deltas: [OpenAIChatCompletionsOutputDelta] = []
        for choice in choices {
            let choiceIndex = Self.choiceIndex(choice)
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            for text in OpenAIChatCompletionsTokenMaterial.fragments(from: delta) {
                let ordinal = self.nextOrdinalByChoice[choiceIndex, default: 0]
                self.nextOrdinalByChoice[choiceIndex] = ordinal + 1
                self.outputTextByChoice[choiceIndex, default: ""].append(text)
                deltas.append(OpenAIChatCompletionsOutputDelta(
                    unitID: Self.unitID(
                        completionID: self.completionID,
                        choiceIndex: choiceIndex,
                        ordinal: ordinal,
                        text: text),
                    choiceIndex: choiceIndex,
                    text: text))
            }
        }
        return deltas
    }

    private func result() -> OpenAIChatCompletionsResult {
        OpenAIChatCompletionsResult(
            completionID: self.completionID,
            model: self.model,
            status: self.terminalStatus ?? .aborted,
            outputText: self.outputTextByChoice.keys.sorted().compactMap {
                self.outputTextByChoice[$0]
            }.joined(),
            usage: self.usage)
    }

    private static func choiceIndex(_ choice: [String: Any]) -> Int {
        if let value = choice["index"] as? Int { return value }
        if let value = choice["index"] as? NSNumber { return value.intValue }
        return 0
    }

    private static func unitID(
        completionID: String?,
        choiceIndex: Int,
        ordinal: Int,
        text: String) -> String
    {
        let material = Data("\(completionID ?? "")\u{0}\(choiceIndex)\u{0}\(ordinal)\u{0}\(text)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "chat-delta:\(digest)"
    }
}

/// Joins Chat Completions parsing to the same request accumulator used by Responses. Retries use
/// a new attempt ID and replace abandoned output, while a replay on the same attempt keeps stable
/// delta identities and therefore cannot double-count the prefix.
public actor LocalMeterChatCompletionsSession {
    private let context: LocalMeterRequestContext
    private let attemptID: String
    private let inputText: String
    private let accumulator: LocalMeterUsageAccumulator
    private var parser = OpenAIChatCompletionsSSEParser()
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
    public func append(_ chunk: Data) async throws -> [OpenAIChatCompletionsOutputDelta] {
        await self.start()
        let deltas: [OpenAIChatCompletionsOutputDelta]
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
                stream: .output,
                text: delta.text))
        }
        return deltas
    }

    public func finish() async throws -> LocalMeterUsageRecord? {
        await self.start()
        guard !self.finished else { return await self.recordForRequest() }
        self.finished = true
        let result: OpenAIChatCompletionsResult
        do {
            result = try self.parser.finish()
        } catch {
            await self.abortMeasurement()
            throw error
        }
        if result.isComplete {
            await self.completeMeasurement(reportedUsage: result.usage)
        } else {
            await self.abortMeasurement()
        }
        return await self.recordForRequest()
    }

    public func completeNonStreaming(_ data: Data) async throws -> LocalMeterUsageRecord? {
        await self.start()
        guard !self.finished else { return await self.recordForRequest() }
        self.finished = true
        let result: OpenAIChatCompletionsResult
        do {
            result = try OpenAIChatCompletionsJSONParser.parse(data)
        } catch {
            await self.abortMeasurement()
            throw error
        }
        if !result.outputText.isEmpty {
            await self.accumulator.record(.outputText(
                requestID: self.context.requestID,
                attemptID: self.attemptID,
                unitID: Self.nonStreamingUnitID(result: result),
                stream: .output,
                text: result.outputText))
        }
        await self.completeMeasurement(reportedUsage: result.usage)
        return await self.recordForRequest()
    }

    public func abort() async {
        await self.start()
        guard !self.finished else { return }
        self.finished = true
        self.parser.abort()
        await self.abortMeasurement()
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

    private static func nonStreamingUnitID(result: OpenAIChatCompletionsResult) -> String {
        let material = Data("\(result.completionID ?? "")\u{0}\(result.outputText)".utf8)
        let digest = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "chat-response:\(digest)"
    }
}
