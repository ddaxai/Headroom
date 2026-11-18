import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CodexReplayCompatibilityTests {
    @Test(arguments: [false, true])
    func `wrong reasoning ID at input 397 is omitted on HTTP and websocket request copies`(websocket: Bool) throws {
        let messages = (0..<397).map { _ in Self.message }
        var request: [String: Any] = ["model": "fixture-model", "input": messages + [Self.badReasoning]]
        if websocket { request["type"] = "response.create" }
        let original = try Self.data(request)
        let copy = original
        let projection = try CodexReplayCompatibility.prepare(requestData: original, boundary: .sameBackend)
        let output = try Self.object(#require(projection.requestData))

        #expect(projection.report.ready)
        #expect(projection.report.omittedReasoningItems == 1)
        #expect((output["input"] as? [[String: Any]])?.count == 397)
        #expect(original == copy)
        #expect(try (Self.object(original)["input"] as? [[String: Any]])?.count == 398)
        #expect(output["type"] as? String == (websocket ? "response.create" : nil))
    }

    @Test
    func `API official API round trip preserves text images and both kinds of completed tool calls`() throws {
        let items: [[String: Any]] = [
            Self.message,
            Self.badReasoning,
            ["type": "function_call", "id": "item_fixture", "call_id": "call_one", "name": "read", "arguments": "{}"],
            [
                "type": "function_call_output",
                "id": "fco_fixture",
                "call_id": "call_one",
                "output": "file read complete",
            ],
            ["type": "custom_tool_call", "id": "ctc_fixture", "call_id": "call_two", "name": "edit", "input": "patch"],
            [
                "type": "custom_tool_call_output",
                "call_id": "call_two",
                "output": [["type": "input_text", "text": "done"]],
            ],
            [
                "type": "message",
                "role": "assistant",
                "id": "msg_fixture",
                "phase": "final_answer",
                "content": [["type": "output_text", "text": "Keep the decisions and pending work."]],
            ],
        ]
        let source = try Self.data(["model": "fixture-model", "input": items])
        let forward = try CodexReplayCompatibility.prepare(requestData: source, boundary: .crossBackend)
        let request = try #require(forward.requestData)
        let reverse = try CodexReplayCompatibility.prepare(requestData: request, boundary: .crossBackend)
        let projected = try #require(Self.object(request)["input"] as? [[String: Any]])

        #expect(forward.report.ready)
        #expect(forward.report.clearedItemIDs == 5)
        #expect(forward.report.omittedReasoningItems == 1)
        #expect(reverse.report.ready)
        #expect(reverse.report.clearedItemIDs == 0)
        #expect(reverse.requestData == request)
        #expect(projected.allSatisfy { $0["id"] == nil })
        #expect(try NSArray(array: #require(projected[0]["content"] as? [Any])) ==
            NSArray(array: #require(items[0]["content"] as? [Any])))
        #expect(projected[1]["call_id"] as? String == "call_one")
        #expect(projected[2]["output"] as? String == "file read complete")
        #expect(projected[3]["call_id"] as? String == "call_two")
        #expect(projected.last?["phase"] as? String == "final_answer")
        #expect(try Self.data(Self.object(source)) == source)
    }

    @Test(arguments: ["compaction", "compaction_summary", "context_compaction"])
    func `foreign opaque compaction requires a checkpoint instead of losing compressed context`(type: String) throws {
        let data = try Self.data(["input": [
            Self.message,
            [
                "type": type,
                "id": "cmp_fixture",
                "encrypted_content": "fixture-ciphertext",
            ],
        ]])
        let projection = try CodexReplayCompatibility.prepare(requestData: data, boundary: .crossBackend)
        #expect(!projection.report.ready)
        #expect(projection.requestData == nil)
        #expect(projection.report.issues == [.init(inputIndex: 1, reason: .opaqueCompaction)])
        let reportText = try #require(String(data: JSONEncoder().encode(projection.report), encoding: .utf8))
        #expect(!reportText.contains("fixture-ciphertext"))
        #expect(!reportText.contains("cmp_fixture"))
    }

    @Test
    func `valid same backend reasoning and compaction stay intact`() throws {
        let items: [[String: Any]] = [
            ["type": "reasoning", "id": "rs_fixture", "summary": [], "encrypted_content": "fixture-ciphertext"],
            ["type": "compaction", "id": "cmp_fixture", "encrypted_content": "fixture-checkpoint"],
        ]
        let request = try Self.data(["input": items])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .sameBackend)
        #expect(projection.report.ready)
        #expect(projection.requestData == request)
    }

    @Test(arguments: ["item_fixture", "rs_", "bare", "msg_fixture"])
    func `malformed opaque reasoning ID is blocked on the same backend`(id: String) throws {
        let request = try Self.data(["input": [[
            "type": "reasoning",
            "id": id,
            "summary": [],
            "encrypted_content": "fixture-ciphertext",
        ]]])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .sameBackend)
        #expect(projection.requestData == nil)
        #expect(projection.report.issues == [.init(inputIndex: 0, reason: .encryptedContent)])
    }

    @Test
    func `foreign reasoning is omitted even when its ID has a valid prefix`() throws {
        let request = try Self.data(["input": [
            Self.message,
            [
                "type": "reasoning",
                "id": "rs_fixture",
                "summary": [],
                "encrypted_content": "fixture-ciphertext",
            ],
        ]])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .crossBackend)
        #expect(projection.report.ready)
        #expect(projection.report.omittedReasoningItems == 1)
    }

    @Test(arguments: ["previous_response_id", "conversation"])
    func `server history reference blocks cross backend replay rather than dropping the reference`(key: String) throws {
        let request = try Self.data(["input": [Self.message], key: "fixture-server-reference"])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .crossBackend)
        #expect(projection.requestData == nil)
        #expect(projection.report.issues.contains(.init(inputIndex: nil, reason: .serverLinkedHistory)))
    }

    @Test
    func `bad IDs cannot be repaired against an earlier websocket server cache`() throws {
        let request = try Self.data(["input": [Self.badReasoning], "previous_response_id": "resp_fixture"])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .sameBackend)
        #expect(projection.requestData == nil)
    }

    @Test(arguments: ["future_item", "item_reference", "web_search_call"])
    func `unrecognized or provider owned items block cross backend projection`(type: String) throws {
        let request = try Self.data(["input": [["type": type, "id": "fixture-id"]]])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .crossBackend)
        #expect(projection.requestData == nil)
        #expect(!projection.report.ready)
    }

    @Test
    func `foreign uploaded attachment IDs and encrypted tool arguments require materialization`() throws {
        let request = try Self.data(["input": [
            ["type": "message", "role": "user", "content": [["type": "input_image", "file_id": "file_fixture"]]],
            [
                "type": "function_call",
                "name": "tool",
                "arguments": "{}",
                "call_id": "call_one",
                "encrypted_function_args": ["fixture-encrypted-args"],
            ],
            ["type": "function_call_output", "call_id": "call_one", "output": "complete"],
        ]])
        let projection = try CodexReplayCompatibility.prepare(requestData: request, boundary: .crossBackend)
        #expect(projection.requestData == nil)
        #expect(projection.report.issues.map(\.reason) == [.providerAttachment, .encryptedContent])
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func `pending orphan duplicate reversed and mismatched tool exchanges block projection`(scenario: Int) throws {
        let call: [String: Any] = [
            "type": "function_call",
            "call_id": "call_fixture",
            "name": "read",
            "arguments": "{}",
        ]
        let output: [String: Any] = ["type": "function_call_output", "call_id": "call_fixture", "output": "done"]
        let cases = [
            [call],
            [output],
            [call, output, output],
            [output, call],
            [call, ["type": "custom_tool_call_output", "call_id": "call_fixture", "output": "done"]],
        ]
        let projection = try CodexReplayCompatibility.prepare(
            requestData: Self.data(["input": cases[scenario]]), boundary: .crossBackend)
        #expect(projection.requestData == nil)
        #expect(projection.report.issues.allSatisfy { $0.reason == .incompleteToolExchange })
    }

    @Test
    func `malformed input and raw rollout are rejected without exposing their contents`() throws {
        for data in try [
            Data("sensitive-invalid-json".utf8),
            Self.data(["input": [42]]),
            Self.data(["type": "response_item", "payload": Self.message]),
        ] {
            #expect(throws: CodexReplayCompatibility.Failure.self) {
                try CodexReplayCompatibility.prepare(requestData: data, boundary: .crossBackend)
            }
        }
    }

    @Test
    func `portable wrong IDs are removed while valid same backend message IDs stay`() throws {
        var valid = Self.message
        valid["id"] = "msg_fixture"
        let projection = try CodexReplayCompatibility.prepare(
            requestData: Self.data(["input": [Self.message, valid]]), boundary: .sameBackend)
        let request = try #require(projection.requestData)
        let items = try #require(Self.object(request)["input"] as? [[String: Any]])
        #expect(projection.report.clearedItemIDs == 1)
        #expect(items[0]["id"] == nil)
        #expect(items[1]["id"] as? String == "msg_fixture")
    }

    @Test
    func `request output is owner only and rejects existing files symlinks and hard links`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("request.json")
        let symlink = root.appendingPathComponent("symlink.json")
        let hardlink = root.appendingPathComponent("hardlink.json")
        let original = Data("original-file".utf8)
        try original.write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        for url in [source, symlink, hardlink] {
            #expect(throws: (any Error).self) { try CodexBarCLI.writeReplayRequest(Data(), to: url) }
        }
        #expect(try Data(contentsOf: source) == original)
        let output = root.appendingPathComponent("new.json")
        try CodexBarCLI.writeReplayRequest(original, to: output)
        #expect(try Data(contentsOf: output) == original)
        let permissions = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    private static var message: [String: Any] {
        [
            "type": "message", "role": "user", "id": "item_fixture",
            "content": [
                ["type": "input_text", "text": "Retain pending work."],
                ["type": "input_image", "image_url": "data:image/png;base64,fixture", "detail": "high"],
            ],
        ]
    }

    private static var badReasoning: [String: Any] {
        [
            "type": "reasoning", "id": "item_fixture_reasoning",
            "summary": [["type": "summary_text", "text": "fixture summary"]], "encrypted_content": NSNull(),
        ]
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
