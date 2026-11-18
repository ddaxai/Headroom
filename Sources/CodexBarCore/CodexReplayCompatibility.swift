import Foundation

/// Offline request projection. This does not intercept Codex traffic or edit persisted history.
public enum CodexReplayCompatibility {
    /// A provider bucket such as `codexbar_shared` does not establish backend/account identity.
    public enum Boundary: String, Sendable, Codable {
        case sameBackend
        case crossBackend
    }

    public enum Reason: String, Sendable, Codable {
        case opaqueCompaction
        case opaqueItem
        case encryptedContent
        case providerAttachment
        case incompleteToolExchange
        case serverLinkedHistory
        case unknownItemType
    }

    /// Deliberately excludes IDs, tool arguments, text, URLs and encrypted data.
    public struct Issue: Sendable, Codable, Equatable {
        public let inputIndex: Int?
        public let reason: Reason

        public init(inputIndex: Int?, reason: Reason) {
            self.inputIndex = inputIndex
            self.reason = reason
        }
    }

    public struct Report: Sendable, Codable, Equatable {
        public let boundary: Boundary
        public let inputItemCount: Int
        public let clearedItemIDs: Int
        public let omittedReasoningItems: Int
        public let issues: [Issue]

        public var ready: Bool {
            self.issues.isEmpty
        }
    }

    public struct Projection: Sendable {
        /// Nil when replay would lose context or contains an incomplete tool exchange.
        public let requestData: Data?
        public let report: Report
    }

    public enum Failure: Error, LocalizedError {
        case invalidRequest
        case invalidItem(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidRequest:
                "Expected a Responses request with a complete input array."
            case let .invalidItem(index):
                "Invalid request item at input[\(index)]."
            }
        }
    }

    /// Supply the complete model-visible input, after Codex's own rollback/compaction replay.
    /// A raw rollout is not an input array and must never be flattened by this helper.
    public static func prepare(requestData: Data, boundary: Boundary) throws -> Projection {
        guard var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let input = request["input"] as? [[String: Any]]
        else { throw Failure.invalidRequest }

        var state = ProjectionState(boundary: boundary)
        var projected: [[String: Any]] = []
        for (index, item) in input.enumerated() {
            if let item = try state.project(item, index: index) {
                projected.append(item)
            }
        }
        state.finishTools()
        // A server-side response/conversation may contain omitted input. Removing its reference
        // would silently lose context; an adapter must materialize full history first.
        if boundary == .crossBackend || state.clearedIDs > 0 || state.omittedReasoning > 0 {
            if self.hasServerHistoryReference(request) {
                state.issues.append(Issue(inputIndex: nil, reason: .serverLinkedHistory))
            }
        }
        let report = Report(
            boundary: boundary,
            inputItemCount: input.count,
            clearedItemIDs: state.clearedIDs,
            omittedReasoningItems: state.omittedReasoning,
            issues: state.issues)
        guard report.ready else { return Projection(requestData: nil, report: report) }
        request["input"] = projected
        return try Projection(
            requestData: JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
            report: report)
    }

    private static func hasServerHistoryReference(_ request: [String: Any]) -> Bool {
        ["previous_response_id", "conversation"].contains { key in
            guard let value = request[key], !(value is NSNull) else { return false }
            if let string = value as? String { return !string.isEmpty }
            return true
        }
    }
}

extension CodexReplayCompatibility {
    private struct ProjectionState {
        let boundary: Boundary
        var issues: [Issue] = []
        var clearedIDs = 0
        var omittedReasoning = 0
        var calls: [String: (type: String, index: Int)] = [:]
        var completedCalls: Set<String> = []

        mutating func project(_ source: [String: Any], index: Int) throws -> [String: Any]? {
            guard let type = source["type"] as? String ?? (source["role"] is String ? "message" : nil) else {
                throw Failure.invalidItem(index)
            }
            let prefix = Self.prefixes[type]
            let invalidID: Bool = if let id = source["id"], !(id is NSNull) {
                if let id = id as? String, let prefix {
                    !id.hasPrefix(prefix + "_") || id.count <= prefix.count + 1
                } else {
                    true
                }
            } else {
                false
            }
            if ["compaction", "compaction_summary", "context_compaction"].contains(type) {
                if self.boundary == .crossBackend || invalidID {
                    self.block(index, .opaqueCompaction)
                }
                return source
            }
            if type == "reasoning" {
                if self.boundary == .crossBackend {
                    self.omittedReasoning += 1
                    return nil
                }
                if invalidID {
                    if Self.containsEncryptedContent(source) {
                        self.block(index, .encryptedContent)
                    } else {
                        self.omittedReasoning += 1
                        return nil
                    }
                }
                return source
            }
            guard Self.portableTypes.contains(type) else {
                if prefix == nil || self.boundary == .crossBackend || invalidID {
                    self.block(index, prefix == nil ? .unknownItemType : .opaqueItem)
                }
                return source
            }
            try self.validatePortableShape(source, type: type, index: index)
            if self.boundary == .crossBackend {
                if Self.containsEncryptedContent(source) { self.block(index, .encryptedContent) }
                if Self.containsProviderAttachment(source) { self.block(index, .providerAttachment) }
            }
            self.trackTool(source, type: type, index: index)
            var item = source
            if invalidID || (self.boundary == .crossBackend && item["id"] != nil && !(item["id"] is NSNull)) {
                item.removeValue(forKey: "id")
                self.clearedIDs += 1
            }
            if self.boundary == .crossBackend {
                item.removeValue(forKey: "internal_chat_message_metadata_passthrough")
            }
            return item
        }

        private func validatePortableShape(_ item: [String: Any], type: String, index: Int) throws {
            let valid: Bool = switch type {
            case "message":
                item["role"] is String && (item["content"] is String || item["content"] is [[String: Any]])
            case "function_call":
                item["name"] is String && item["arguments"] is String
            case "custom_tool_call":
                item["name"] is String && item["input"] is String
            default:
                item["output"] is String || item["output"] is [[String: Any]]
            }
            guard valid else { throw Failure.invalidItem(index) }
        }

        private mutating func trackTool(_ item: [String: Any], type: String, index: Int) {
            guard type != "message" else { return }
            guard let callID = item["call_id"] as? String, !callID.isEmpty else {
                self.block(index, .incompleteToolExchange)
                return
            }
            if type.hasSuffix("_output") {
                let callType = String(type.dropLast("_output".count))
                guard self.calls[callID]?.type == callType, self.completedCalls.insert(callID).inserted else {
                    self.block(index, .incompleteToolExchange)
                    return
                }
            } else {
                guard self.calls[callID] == nil else {
                    self.block(index, .incompleteToolExchange)
                    return
                }
                self.calls[callID] = (type, index)
            }
        }

        mutating func finishTools() {
            for (callID, call) in self.calls.sorted(by: { $0.value.index < $1.value.index })
                where !self.completedCalls.contains(callID)
            {
                self.block(call.index, .incompleteToolExchange)
            }
        }

        private mutating func block(_ index: Int, _ reason: Reason) {
            self.issues.append(Issue(inputIndex: index, reason: reason))
        }

        private static func containsEncryptedContent(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                return object.contains { key, child in
                    if ["encrypted_content", "encrypted_function_args"].contains(key), !(child is NSNull) {
                        if let string = child as? String { return !string.isEmpty }
                        if let array = child as? [Any] { return !array.isEmpty }
                        return true
                    }
                    return Self.containsEncryptedContent(child)
                }
            }
            return (value as? [Any])?.contains(where: Self.containsEncryptedContent) ?? false
        }

        private static func containsProviderAttachment(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                if object["file_id"] != nil, !(object["file_id"] is NSNull) { return true }
                return object.values.contains(where: self.containsProviderAttachment)
            }
            return (value as? [Any])?.contains(where: Self.containsProviderAttachment) ?? false
        }

        private static let portableTypes: Set<String> = [
            "message", "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output",
        ]

        /// Matches ResponseItem::id_prefix in Codex protocol. Unknown future types are blocked.
        private static let prefixes = [
            "message": "msg", "agent_message": "amsg", "reasoning": "rs", "local_shell_call": "lsh",
            "function_call": "fc", "function_call_output": "fco", "custom_tool_call": "ctc",
            "custom_tool_call_output": "ctco", "tool_search_call": "tsc", "tool_search_output": "tso",
            "web_search_call": "ws", "image_generation_call": "ig", "additional_tools": "at",
            "compaction": "cmp", "compaction_summary": "cmp", "context_compaction": "cmp",
        ]
    }
}
