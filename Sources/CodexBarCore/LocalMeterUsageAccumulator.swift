#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct LocalMeterCredentialFingerprint: Codable, Hashable, Sendable {
    public let value: String

    public init?(apiKey: String) {
        let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let material = Data("headroom.local-meter.credential.v1\u{0}\(normalized)".utf8)
        self.value = SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value.count == 64,
              value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) })
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Local Meter credential fingerprint")
        }
        self.value = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }
}

public struct LocalMeterRequestContext: Equatable, Sendable {
    public let requestID: String
    public let sessionID: String?
    public let routeProfileID: UUID
    public let targetApp: RelayTargetApp
    public let model: String
    public let startedAt: Date
    public let credentialFingerprint: LocalMeterCredentialFingerprint?

    public init(
        requestID: String,
        sessionID: String?,
        routeProfileID: UUID,
        targetApp: RelayTargetApp,
        model: String,
        startedAt: Date,
        credentialFingerprint: LocalMeterCredentialFingerprint?)
    {
        self.requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = Self.cleaned(sessionID)
        self.routeProfileID = routeProfileID
        self.targetApp = targetApp
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.credentialFingerprint = credentialFingerprint
    }

    public var ledgerKey: UsageLedgerKey {
        UsageLedgerKey(
            identityID: "relay:\(self.routeProfileID.uuidString.lowercased()):\(self.targetApp.rawValue)",
            routeProfileID: self.routeProfileID,
            targetApp: self.targetApp,
            model: self.model,
            requestID: self.requestID,
            sessionID: self.sessionID,
            timestamp: self.startedAt)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct LocalMeterUsageRecord: Codable, Equatable, Sendable {
    public let entry: UsageLedgerEntry
    public let credentialFingerprint: LocalMeterCredentialFingerprint?
    /// Headroom's dependency-free estimate. This is deliberately optional for records written by
    /// older S3/S4 builds, whose ledger entry remains fully readable.
    public let localEstimate: LocalMeterUsageEstimate?
    /// Usage reported by the upstream Responses endpoint, when one was present in the terminal
    /// event. It is kept separate from `entry.amounts`, which always contains the local estimate.
    public let reportedUsage: LocalMeterReportedUsage?

    public init(
        entry: UsageLedgerEntry,
        credentialFingerprint: LocalMeterCredentialFingerprint?,
        localEstimate: LocalMeterUsageEstimate? = nil,
        reportedUsage: LocalMeterReportedUsage? = nil)
    {
        self.entry = entry
        self.credentialFingerprint = credentialFingerprint
        self.localEstimate = localEstimate
        self.reportedUsage = reportedUsage
    }

    public var reportedDifference: LocalMeterUsageDifference? {
        guard let localEstimate, let reportedUsage else { return nil }
        return LocalMeterUsageDifference(
            localTotalTokens: localEstimate.totalTokens,
            reportedTotalTokens: reportedUsage.totalTokens)
    }
}

public enum LocalMeterMeasurementEvent: Sendable {
    case begin(context: LocalMeterRequestContext, attemptID: String, inputTokens: Int)
    case output(requestID: String, attemptID: String, unitID: String, tokens: Int)
    case outputText(
        requestID: String,
        attemptID: String,
        unitID: String,
        stream: LocalMeterTextStream,
        text: String)
    case abort(requestID: String, attemptID: String)
    case complete(requestID: String, attemptID: String)
    case completeWithReportedUsage(
        requestID: String,
        attemptID: String,
        reportedUsage: LocalMeterReportedUsage?)
}

public enum LocalMeterTextStream: String, Sendable {
    case output
    case reasoning
}

/// Builds one immutable M4 ledger entry per logical request.
///
/// A retry starts a fresh attempt and discards output from the abandoned attempt. A reconnect
/// keeps the same attempt ID, so replayed output units are ignored by their stable unit ID.
/// Once a request completes, later writes using the same request ID cannot mutate or duplicate it.
public actor LocalMeterUsageAccumulator {
    private struct RequestState {
        let context: LocalMeterRequestContext
        var inputTokens: Int
        var activeAttemptID: String?
        var outputTokensByUnitID: [String: Int]
        var outputTextByUnitID: [String: String]
        var outputTextUnitOrder: [String]
        var reasoningTextByUnitID: [String: String]
        var reasoningTextUnitOrder: [String]
        var finalizedRecord: LocalMeterUsageRecord?
    }

    private var statesByRequestID: [String: RequestState] = [:]

    public init() {}

    public var records: [LocalMeterUsageRecord] {
        self.statesByRequestID.values
            .compactMap(\.finalizedRecord)
            .sorted { lhs, rhs in
                if lhs.entry.key.timestamp != rhs.entry.key.timestamp {
                    return lhs.entry.key.timestamp < rhs.entry.key.timestamp
                }
                return (lhs.entry.key.requestID ?? "") < (rhs.entry.key.requestID ?? "")
            }
    }

    public func record(_ event: LocalMeterMeasurementEvent) {
        switch event {
        case let .begin(context, attemptID, inputTokens):
            self.begin(context: context, attemptID: attemptID, inputTokens: inputTokens)
        case let .output(requestID, attemptID, unitID, tokens):
            self.output(
                requestID: requestID,
                attemptID: attemptID,
                unitID: unitID,
                tokens: tokens)
        case let .outputText(requestID, attemptID, unitID, stream, text):
            self.outputText(
                requestID: requestID,
                attemptID: attemptID,
                unitID: unitID,
                stream: stream,
                text: text)
        case let .abort(requestID, attemptID):
            self.abort(requestID: requestID, attemptID: attemptID)
        case let .complete(requestID, attemptID):
            self.complete(requestID: requestID, attemptID: attemptID, reportedUsage: nil)
        case let .completeWithReportedUsage(requestID, attemptID, reportedUsage):
            self.complete(
                requestID: requestID,
                attemptID: attemptID,
                reportedUsage: reportedUsage)
        }
    }

    private func begin(
        context: LocalMeterRequestContext,
        attemptID: String,
        inputTokens: Int)
    {
        let requestID = context.requestID
        let attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestID.isEmpty, !attemptID.isEmpty else { return }
        guard var state = self.statesByRequestID[requestID] else {
            self.statesByRequestID[requestID] = RequestState(
                context: context,
                inputTokens: max(0, inputTokens),
                activeAttemptID: attemptID,
                outputTokensByUnitID: [:],
                outputTextByUnitID: [:],
                outputTextUnitOrder: [],
                reasoningTextByUnitID: [:],
                reasoningTextUnitOrder: [],
                finalizedRecord: nil)
            return
        }
        guard state.finalizedRecord == nil else { return }
        state.inputTokens = max(state.inputTokens, max(0, inputTokens))
        if state.activeAttemptID != attemptID {
            state.activeAttemptID = attemptID
            state.outputTokensByUnitID.removeAll(keepingCapacity: true)
            state.outputTextByUnitID.removeAll(keepingCapacity: true)
            state.outputTextUnitOrder.removeAll(keepingCapacity: true)
            state.reasoningTextByUnitID.removeAll(keepingCapacity: true)
            state.reasoningTextUnitOrder.removeAll(keepingCapacity: true)
        }
        self.statesByRequestID[requestID] = state
    }

    private func outputText(
        requestID: String,
        attemptID: String,
        unitID: String,
        stream: LocalMeterTextStream,
        text: String)
    {
        let requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitID = unitID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unitID.isEmpty, !text.isEmpty,
              var state = self.statesByRequestID[requestID],
              state.finalizedRecord == nil,
              state.activeAttemptID == attemptID
        else { return }
        switch stream {
        case .output:
            guard state.outputTextByUnitID[unitID] == nil else { return }
            state.outputTextByUnitID[unitID] = text
            state.outputTextUnitOrder.append(unitID)
        case .reasoning:
            guard state.reasoningTextByUnitID[unitID] == nil else { return }
            state.reasoningTextByUnitID[unitID] = text
            state.reasoningTextUnitOrder.append(unitID)
        }
        self.statesByRequestID[requestID] = state
    }

    private func output(
        requestID: String,
        attemptID: String,
        unitID: String,
        tokens: Int)
    {
        let requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitID = unitID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unitID.isEmpty,
              var state = self.statesByRequestID[requestID],
              state.finalizedRecord == nil,
              state.activeAttemptID == attemptID
        else { return }
        state.outputTokensByUnitID[unitID] = max(
            state.outputTokensByUnitID[unitID] ?? 0,
            max(0, tokens))
        self.statesByRequestID[requestID] = state
    }

    private func abort(requestID: String, attemptID: String) {
        let requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var state = self.statesByRequestID[requestID],
              state.finalizedRecord == nil,
              state.activeAttemptID == attemptID
        else { return }
        state.activeAttemptID = nil
        state.outputTokensByUnitID.removeAll(keepingCapacity: true)
        state.outputTextByUnitID.removeAll(keepingCapacity: true)
        state.outputTextUnitOrder.removeAll(keepingCapacity: true)
        state.reasoningTextByUnitID.removeAll(keepingCapacity: true)
        state.reasoningTextUnitOrder.removeAll(keepingCapacity: true)
        self.statesByRequestID[requestID] = state
    }

    private func complete(
        requestID: String,
        attemptID: String,
        reportedUsage: LocalMeterReportedUsage?)
    {
        let requestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        let attemptID = attemptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var state = self.statesByRequestID[requestID],
              state.finalizedRecord == nil,
              state.activeAttemptID == attemptID
        else { return }
        let outputText = state.outputTextUnitOrder.compactMap { state.outputTextByUnitID[$0] }.joined()
        let reasoningText = state.reasoningTextUnitOrder.compactMap { state.reasoningTextByUnitID[$0] }.joined()
        let outputTokens = state.outputTokensByUnitID.values.reduce(0, +)
            + LocalMeterTokenEstimator.estimate(outputText).tokens
            + LocalMeterTokenEstimator.estimate(reasoningText).tokens
        state.finalizedRecord = LocalMeterUsageRecord(
            entry: UsageLedgerEntry(
                key: state.context.ledgerKey,
                attribution: .relay,
                amounts: UsageLedgerAmounts(
                    inputTokens: state.inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: 0,
                    cacheCreationTokens: 0,
                    totalTokens: state.inputTokens + outputTokens,
                    requestCount: 1,
                    costUSD: nil)),
            credentialFingerprint: state.context.credentialFingerprint,
            localEstimate: LocalMeterUsageEstimate(
                inputTokens: state.inputTokens,
                outputTokens: outputTokens),
            reportedUsage: reportedUsage)
        state.activeAttemptID = nil
        state.outputTokensByUnitID.removeAll(keepingCapacity: false)
        state.outputTextByUnitID.removeAll(keepingCapacity: false)
        state.outputTextUnitOrder.removeAll(keepingCapacity: false)
        state.reasoningTextByUnitID.removeAll(keepingCapacity: false)
        state.reasoningTextUnitOrder.removeAll(keepingCapacity: false)
        self.statesByRequestID[requestID] = state
    }
}
