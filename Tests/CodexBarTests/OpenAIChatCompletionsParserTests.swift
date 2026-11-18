import Foundation
import Testing
@testable import CodexBarCore

@Suite("M5 S7 Chat Completions parser", .serialized)
struct OpenAIChatCompletionsParserTests {
    @Test
    func `non streaming response preserves text and reported usage details`() throws {
        let result = try OpenAIChatCompletionsJSONParser.parse(Data(Self.nonStreamingFixture.utf8))

        #expect(result.status == .completed)
        #expect(result.completionID == "chatcmpl-fixture-nonstream")
        #expect(result.model == "gpt-5.4")
        #expect(result.outputText == "Hello! How can I assist you today?")
        #expect(result.usage?.inputTokens == 19)
        #expect(result.usage?.cachedInputTokens == 7)
        #expect(result.usage?.outputTokens == 10)
        #expect(result.usage?.reasoningTokens == 3)
        #expect(result.usage?.totalTokens == 29)
    }

    @Test
    func `SSE split at arbitrary byte boundaries preserves deltas and final usage`() throws {
        var parser = OpenAIChatCompletionsSSEParser()
        let bytes = Array(Self.streamingFixture.utf8)
        let chunkSizes = [1, 2, 5, 3, 13, 8, 21, 34]
        var offset = 0
        var chunkIndex = 0
        var deltas: [OpenAIChatCompletionsOutputDelta] = []
        while offset < bytes.count {
            let size = min(chunkSizes[chunkIndex % chunkSizes.count], bytes.count - offset)
            try deltas.append(contentsOf: parser.append(Data(bytes[offset..<(offset + size)])))
            offset += size
            chunkIndex += 1
        }

        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.completionID == "chatcmpl-fixture-stream")
        #expect(result.model == "gpt-5.4")
        #expect(deltas.map(\.text).joined() == "Hello from Chat Completions.")
        #expect(result.outputText == "Hello from Chat Completions.")
        #expect(result.usage?.inputTokens == 31)
        #expect(result.usage?.cachedInputTokens == 9)
        #expect(result.usage?.outputTokens == 18)
        #expect(result.usage?.reasoningTokens == 4)
        #expect(result.usage?.totalTokens == 49)
    }

    @Test
    func `stream usage is absent until the final usage-only chunk`() throws {
        var parser = OpenAIChatCompletionsSSEParser()
        let splitMarker = [
            #"data: {"id":"chatcmpl-fixture-stream","object":"chat.completion.chunk","#,
            #""created":1720000000,"model":"gpt-5.4","choices":[],"usage""#,
        ].joined()
        let markerRange = try #require(Self.streamingFixture.range(of: splitMarker))
        let prefix = String(Self.streamingFixture[..<markerRange.lowerBound])
        let suffix = String(Self.streamingFixture[markerRange.lowerBound...])

        _ = try parser.append(Data(prefix.utf8))

        #expect(parser.reportedUsage == nil)
        #expect(parser.status == nil)

        _ = try parser.append(Data(suffix.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.usage?.totalTokens == 49)
    }

    @Test
    func `stream without usage still completes with reported usage absent`() throws {
        var parser = OpenAIChatCompletionsSSEParser()

        _ = try parser.append(Data(Self.streamingWithoutUsageFixture.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.outputText == "Hello without reported usage.")
        #expect(result.usage == nil)
    }

    @Test
    func `usage in the final choices chunk is retained`() throws {
        var parser = OpenAIChatCompletionsSSEParser()

        _ = try parser.append(Data(Self.streamingUsageInChoiceFixture.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.outputText == "Usage beside choices.")
        #expect(result.usage?.inputTokens == 23)
        #expect(result.usage?.outputTokens == 11)
        #expect(result.usage?.totalTokens == 34)
    }

    @Test
    func `multiple choices and tool calls preserve output token material`() throws {
        var parser = OpenAIChatCompletionsSSEParser()

        let deltas = try parser.append(Data(Self.multiChoiceToolCallFixture.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(Set(deltas.map(\.choiceIndex)) == [0, 1])
        #expect(result.outputText.contains("Visible answer."))
        #expect(result.outputText.contains("lookup_weather"))
        #expect(result.outputText.contains(#"{"city":"Paris"}"#))
        #expect(result.usage?.totalTokens == 62)
    }

    @Test
    func `stream interrupted before DONE is aborted even after a finish reason`() throws {
        var parser = OpenAIChatCompletionsSSEParser()
        let interrupted = Self.sse([
            Self.chunk(
                choices: #"[{"index":0,"delta":{"content":"partial"},"logprobs":null,"finish_reason":null}]"#),
            Self.chunk(
                choices: #"[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]"#),
        ])

        _ = try parser.append(Data(interrupted.utf8))
        let result = try parser.finish()

        #expect(result.status == .aborted)
        #expect(!result.isComplete)
        #expect(result.usage == nil)
    }

    @Test
    func `repeated visible text in distinct chunks remains distinct output`() throws {
        var parser = OpenAIChatCompletionsSSEParser()
        let repeated = Self.sse([
            Self.chunk(
                choices: [
                    #"[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"#,
                    #""finish_reason":null}]"#,
                ].joined()),
            Self.chunk(
                choices: #"[{"index":0,"delta":{"content":"ha"},"logprobs":null,"finish_reason":null}]"#),
            Self.chunk(
                choices: #"[{"index":0,"delta":{"content":"ha"},"logprobs":null,"finish_reason":null}]"#),
            "data: [DONE]",
        ])

        let deltas = try parser.append(Data(repeated.utf8))
        let result = try parser.finish()

        #expect(deltas.map(\.text) == ["ha", "ha"])
        #expect(Set(deltas.map(\.unitID)).count == 2)
        #expect(result.outputText == "haha")
    }

    @Test
    func `Anthropic Messages becomes supported without changing other protocol states`() {
        #expect(LocalMeterProtocolSupport.status(for: .openAIResponses) == .supported)
        #expect(LocalMeterProtocolSupport.status(for: .openAIChatCompletions) == .supported)
        #expect(LocalMeterProtocolSupport.status(for: .anthropicMessages) == .supported)
        #expect(LocalMeterProtocolSupport.shouldDisplayZero(for: .unsupported) == false)
    }

    /// The field layout is transcribed from the official OpenAI Chat Completions create example:
    /// https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
    /// Only identifiers and fixture values are deterministic substitutions.
    static let nonStreamingFixture = #"""
    {
      "id": "chatcmpl-fixture-nonstream",
      "object": "chat.completion",
      "created": 1741569952,
      "model": "gpt-5.4",
      "choices": [{
        "index": 0,
        "message": {
          "role": "assistant",
          "content": "Hello! How can I assist you today?",
          "refusal": null,
          "annotations": []
        },
        "logprobs": null,
        "finish_reason": "stop"
      }],
      "usage": {
        "prompt_tokens": 19,
        "completion_tokens": 10,
        "total_tokens": 29,
        "prompt_tokens_details": {"cached_tokens": 7, "audio_tokens": 0},
        "completion_tokens_details": {
          "reasoning_tokens": 3,
          "audio_tokens": 0,
          "accepted_prediction_tokens": 0,
          "rejected_prediction_tokens": 0
        }
      },
      "service_tier": "default"
    }
    """#

    /// The chunks follow the official `chat.completion.chunk` schema. In particular, the usage
    /// chunk has empty choices and appears immediately before `[DONE]` when include_usage is set.
    static let streamingFixture = Self.sse([
        Self.chunk(
            choices: #"[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]"#),
        Self.chunk(
            choices: #"[{"index":0,"delta":{"content":"Hello from "},"logprobs":null,"finish_reason":null}]"#),
        Self.chunk(
            choices: #"[{"index":0,"delta":{"content":"Chat Completions."},"logprobs":null,"finish_reason":null}]"#),
        Self.chunk(
            choices: #"[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]"#),
        Self.usageChunk,
        "data: [DONE]",
    ])

    static let streamingWithoutUsageFixture = Self.sse([
        Self.chunk(
            choices: #"[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]"#),
        Self.chunk(
            choices: [
                #"[{"index":0,"delta":{"content":"Hello without reported usage."},"#,
                #""logprobs":null,"finish_reason":"stop"}]"#,
            ].joined()),
        "data: [DONE]",
    ])

    static let streamingUsageInChoiceFixture = Self.sse([
        Self.chunk(
            choices: [
                #"[{"index":0,"delta":{"content":"Usage beside choices."},"#,
                #""logprobs":null,"finish_reason":null}]"#,
            ].joined()),
        [
            #"data: {"id":"chatcmpl-fixture-choice-usage","object":"chat.completion.chunk","#,
            #""created":1720000000,"model":"gpt-5.4","choices":[{"index":0,"delta":{},"#,
            #""logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":23,"#,
            #""completion_tokens":11,"total_tokens":34}}"#,
        ].joined(),
        "data: [DONE]",
    ])

    static let multiChoiceToolCallFixture = Self.sse([
        [
            #"data: {"id":"chatcmpl-fixture-multi-tool","#,
            #""object":"chat.completion.chunk","created":1720000000,"#,
            #""model":"gpt-5.4","choices":["#,
            #"{"index":0,"delta":{"content":"Visible answer."},"#,
            #""logprobs":null,"finish_reason":"stop"},"#,
            #"{"index":1,"delta":{"tool_calls":[{"index":0,"id":"call_fixture","#,
            #""type":"function","function":{"name":"lookup_weather","#,
            #""arguments":"{\"city\":\"Paris\"}"}}]},"logprobs":null,"#,
            #""finish_reason":"tool_calls"}],"usage":{"prompt_tokens":37,"#,
            #""completion_tokens":25,"total_tokens":62}}"#,
        ].joined(),
        "data: [DONE]",
    ])

    static func chunk(choices: String) -> String {
        [
            #"data: {"id":"chatcmpl-fixture-stream","object":"chat.completion.chunk","#,
            #""created":1720000000,"model":"gpt-5.4","choices":"#,
            choices,
            #", "usage":null}"#,
        ].joined()
    }

    private static let usageChunk = [
        #"data: {"id":"chatcmpl-fixture-stream","object":"chat.completion.chunk","#,
        #""created":1720000000,"model":"gpt-5.4","choices":[],"usage":{"prompt_tokens":31,"#,
        #""completion_tokens":18,"total_tokens":49,"prompt_tokens_details":{"cached_tokens":9,"#,
        #""audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":4,"audio_tokens":0,"#,
        #""accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}"#,
    ].joined()

    private static func sse(_ events: [String]) -> String {
        events.joined(separator: "\n\n") + "\n\n"
    }
}
