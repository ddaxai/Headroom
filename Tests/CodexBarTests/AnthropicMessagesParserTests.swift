import Foundation
import Testing
@testable import CodexBarCore

@Suite("M5 S8 Anthropic Messages parser", .serialized)
struct AnthropicMessagesParserTests {
    @Test
    func `non streaming response keeps cache lanes separate from base input`() throws {
        let result = try AnthropicMessagesJSONParser.parse(Data(Self.nonStreamingFixture.utf8))

        #expect(result.status == .completed)
        #expect(result.messageID == "msg_fixture_nonstream")
        #expect(result.model == "claude-fixture-model")
        #expect(result.outputText.contains("It is sunny."))
        #expect(result.outputText.contains("lookup_weather"))
        #expect(result.outputText.contains(#"{"city":"Paris"}"#))
        #expect(result.reasoningText == "I should inspect the weather.")
        #expect(result.usage?.inputTokens == 21)
        #expect(result.usage?.cacheCreationInputTokens == 13)
        #expect(result.usage?.cacheReadInputTokens == 8)
        #expect(result.usage?.outputTokens == 17)
        #expect(result.usage?.totalTokens == 59)
    }

    @Test
    func `SSE byte splits preserve thinking text tool input and final usage`() throws {
        var parser = AnthropicMessagesSSEParser()
        let bytes = Array(Self.streamingFixture.utf8)
        let chunkSizes = [1, 2, 5, 3, 13, 8, 21, 34]
        var offset = 0
        var chunkIndex = 0
        var deltas: [AnthropicMessagesOutputDelta] = []
        while offset < bytes.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], bytes.count - offset)
            try deltas.append(contentsOf: parser.append(Data(bytes[offset..<(offset + size)])))
            offset += size
            chunkIndex += 1
        }

        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.messageID == "msg_fixture_stream")
        #expect(result.model == "claude-fixture-model")
        #expect(result.outputText.contains("Hello from Anthropic."))
        #expect(result.outputText.contains("lookup_weather"))
        #expect(result.outputText.contains(#"{"city":"Paris"}"#))
        #expect(result.reasoningText == "I checked the request.")
        #expect(deltas.contains { $0.kind == .reasoning })
        #expect(deltas.contains { $0.kind == .output })
        #expect(result.usage?.inputTokens == 31)
        #expect(result.usage?.cacheCreationInputTokens == 12)
        #expect(result.usage?.cacheReadInputTokens == 7)
        #expect(result.usage?.outputTokens == 19)
        #expect(result.usage?.totalTokens == 69)
    }

    @Test
    func `message delta output usage is cumulative rather than additive`() throws {
        var parser = AnthropicMessagesSSEParser()

        _ = try parser.append(Data(Self.streamingFixture.utf8))
        let result = try parser.finish()

        #expect(result.usage?.outputTokens == 19)
        #expect(result.usage?.outputTokens != 27)
    }

    @Test
    func `message start followed by disconnect keeps input known and output unknown`() throws {
        var parser = AnthropicMessagesSSEParser()

        _ = try parser.append(Data(Self.messageStartEvent.utf8))
        let result = try parser.finish()

        #expect(result.status == .aborted)
        #expect(result.usage?.inputTokens == 31)
        #expect(result.usage?.cacheCreationInputTokens == 12)
        #expect(result.usage?.cacheReadInputTokens == 7)
        #expect(result.usage?.outputTokens == nil)
        #expect(result.usage?.totalTokens == nil)
    }

    @Test
    func `output remains unknown until a message delta usage event`() throws {
        var parser = AnthropicMessagesSSEParser()
        let prefix = try #require(Self.streamingFixture.components(separatedBy: "event: message_delta").first)

        _ = try parser.append(Data(prefix.utf8))

        #expect(parser.reportedUsage?.inputTokens == 31)
        #expect(parser.reportedUsage?.outputTokens == nil)
        #expect(parser.status == nil)
    }

    @Test
    func `ping content lifecycle and message stop are accepted`() throws {
        var parser = AnthropicMessagesSSEParser()

        let deltas = try parser.append(Data(Self.streamingFixture.utf8))
        let result = try parser.finish()

        #expect(!deltas.isEmpty)
        #expect(result.status == .completed)
    }

    @Test
    func `error event fails without fabricating usage`() throws {
        var parser = AnthropicMessagesSSEParser()
        let stream = Self.event(
            "error",
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)

        _ = try parser.append(Data(stream.utf8))
        let result = try parser.finish()

        #expect(result.status == .failed)
        #expect(result.usage == nil)
        #expect(result.outputText.isEmpty)
    }

    /// Shapes are transcribed from Anthropic's official Messages streaming event documentation:
    /// https://docs.anthropic.com/en/api/messages-streaming
    /// Identifiers, model names, text, and usage values are deterministic fixture substitutions.
    static let messageStartEvent = Self.event(
        "message_start",
        [
            #"{"type":"message_start","message":{"id":"msg_fixture_stream","type":"message","role":"assistant","#,
            #""model":"claude-fixture-model","content":[],"stop_reason":null,"stop_sequence":null,"#,
            #""usage":{"input_tokens":31,"#,
            #""cache_creation_input_tokens":12,"cache_read_input_tokens":7,"output_tokens":1}}}"#,
        ].joined())

    static let streamingFixture = [
        Self.messageStartEvent,
        Self.event(
            "content_block_start",
            [
                #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","#,
                #""thinking":"","signature":""}}"#,
            ].joined()),
        Self.event("ping", #"{"type":"ping"}"#),
        Self.event(
            "content_block_delta",
            [
                #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","#,
                #""thinking":"I checked the request."}}"#,
            ].joined()),
        Self.event(
            "content_block_delta",
            [
                #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","#,
                #""signature":"fixture-signature"}}"#,
            ].joined()),
        Self.event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        Self.event(
            "content_block_start",
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
        Self.event(
            "content_block_delta",
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}"#),
        Self.event(
            "content_block_delta",
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"from Anthropic."}}"#),
        Self.event("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        Self.event(
            "content_block_start",
            [
                #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_fixture","#,
                #""name":"lookup_weather","input":{}}}"#,
            ].joined()),
        Self.event(
            "content_block_delta",
            [
                #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","#,
                #""partial_json":"{\"city\":\"Par"}}"#,
            ].joined()),
        Self.event(
            "content_block_delta",
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"is\"}"}}"#),
        Self.event("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
        Self.event(
            "message_delta",
            [
                #"{"type":"message_delta","delta":{"stop_reason":null,"stop_sequence":null},"#,
                #""usage":{"output_tokens":8}}"#,
            ].joined()),
        Self.event(
            "message_delta",
            [
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"#,
                #""usage":{"output_tokens":19}}"#,
            ].joined()),
        Self.event("message_stop", #"{"type":"message_stop"}"#),
    ].joined()

    /// Shape transcribed from the official non-streaming Messages response schema.
    static let nonStreamingFixture = #"""
    {
      "id": "msg_fixture_nonstream",
      "type": "message",
      "role": "assistant",
      "model": "claude-fixture-model",
      "content": [
        {"type": "thinking", "thinking": "I should inspect the weather.", "signature": "fixture"},
        {"type": "text", "text": "It is sunny."},
        {"type": "tool_use", "id": "toolu_fixture", "name": "lookup_weather", "input": {"city": "Paris"}}
      ],
      "stop_reason": "tool_use",
      "stop_sequence": null,
      "usage": {
        "input_tokens": 21,
        "cache_creation_input_tokens": 13,
        "cache_read_input_tokens": 8,
        "output_tokens": 17
      }
    }
    """#

    static func event(_ name: String, _ json: String) -> String {
        "event: \(name)\ndata: \(json)\n\n"
    }
}
