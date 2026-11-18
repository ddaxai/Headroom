import Foundation
import Testing
@testable import CodexBarCore

@Suite("M5 S5 OpenAI Responses SSE parser", .serialized)
struct OpenAIResponsesSSEParserTests {
    @Test
    func `JSON split at arbitrary byte boundaries preserves final usage and deltas`() throws {
        var parser = OpenAIResponsesSSEParser()
        let bytes = Array(Self.completedFixture.utf8)
        var allDeltas: [OpenAIResponsesOutputDelta] = []
        var offset = 0
        let chunkSizes = [1, 2, 5, 3, 13, 8, 21, 34, 55]
        var sizeIndex = 0
        while offset < bytes.count {
            let size = min(chunkSizes[sizeIndex % chunkSizes.count], bytes.count - offset)
            try allDeltas.append(contentsOf: parser.append(Data(bytes[offset..<(offset + size)])))
            offset += size
            sizeIndex += 1
        }

        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.responseID == "resp_fixture_123")
        #expect(result.model == "gpt-5.4")
        #expect(result.outputText == "Hello from the fixture.")
        #expect(result.reasoningText == "I checked the request.")
        #expect(allDeltas.map(\.text).joined() == "I checked the request.Hello from the fixture.")
        #expect(result.usage?.inputTokens == 321)
        #expect(result.usage?.cachedInputTokens == 123)
        #expect(result.usage?.outputTokens == 88)
        #expect(result.usage?.reasoningTokens == 17)
        #expect(result.usage?.totalTokens == 409)
    }

    @Test
    func `UTF8 scalar split across byte chunks remains intact`() throws {
        var parser = OpenAIResponsesSSEParser()
        let stream = Self.stream([
            Self.event("response.output_text.delta", jsonParts: [
                #"{"type":"response.output_text.delta","sequence_number":1,"response_id":"resp-utf8","#,
                #""item_id":"msg-utf8","delta":"你好🙂"}"#,
            ]),
            Self.event("response.completed", jsonParts: [
                #"{"type":"response.completed","response":{"id":"resp-utf8","status":"completed"}}"#,
            ]),
        ])
        for byte in stream.utf8 {
            _ = try parser.append(Data([byte]))
        }
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.outputText == "你好🙂")
    }

    @Test
    func `usage is absent before the completed event and appears only in the final chunk`() throws {
        var parser = OpenAIResponsesSSEParser()
        let prefix = try #require(Self.completedFixture.components(separatedBy: "event: response.completed").first)

        _ = try parser.append(Data(prefix.utf8))

        #expect(parser.reportedUsage == nil)
        #expect(parser.status == nil)

        _ = try parser
            .append(Data(#require(Self.completedFixture.components(separatedBy: "event: response.completed").last?
                    .utf8)))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.usage?.totalTokens == 409)
    }

    @Test
    func `midstream disconnect is aborted and never reports a completed response`() throws {
        var parser = OpenAIResponsesSSEParser()
        let truncated = try #require(Self.completedFixture.components(separatedBy: "event: response.output_text.done")
            .first)

        _ = try parser.append(Data(truncated.utf8))
        let result = try parser.finish()

        #expect(result.status == .aborted)
        #expect(result.usage == nil)
        #expect(!result.isComplete)
    }

    @Test
    func `duplicate request stream events are emitted once by stable event identity`() throws {
        var parser = OpenAIResponsesSSEParser()
        let duplicate = Self.stream([
            Self.event(
                "response.output_text.delta",
                id: "response-1",
                jsonParts: [
                    #"{"type":"response.output_text.delta","sequence_number":4,"response_id":"resp_fixture_123","#,
                    #""delta":"same"}"#,
                ]),
            Self.event(
                "response.output_text.delta",
                id: "response-1",
                jsonParts: [
                    #"{"type":"response.output_text.delta","sequence_number":4,"response_id":"resp_fixture_123","#,
                    #""delta":"same"}"#,
                ]),
            Self.event("response.completed", jsonParts: [
                #"{"type":"response.completed","response":{"id":"resp_fixture_123","model":"gpt-5.4","#,
                #""status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#,
            ]),
        ])

        let deltas = try parser.append(Data(duplicate.utf8))
        let result = try parser.finish()

        #expect(deltas.count == 1)
        #expect(deltas.first?.text == "same")
        #expect(result.status == .completed)
    }

    @Test
    func `CRLF and multiline data fields remain valid SSE`() throws {
        var parser = OpenAIResponsesSSEParser()
        let stream = [
            "event: response.completed\r\n",
            "data: {\"type\":\"response.completed\",\r\n",
            "data: \"response\":{\"id\":\"resp-crlf\",\"status\":\"completed\",\r\n",
            "data: \"usage\":{\"input_tokens\":2,\"output_tokens\":3,\"total_tokens\":5}}}\r\n\r\n",
        ].joined()

        _ = try parser.append(Data(stream.utf8))
        let result = try parser.finish()

        #expect(result.responseID == "resp-crlf")
        #expect(result.usage?.totalTokens == 5)
    }

    @Test
    func `supported and unsupported protocols keep distinct availability states`() {
        #expect(LocalMeterProtocolSupport.status(for: .openAIResponses) == .supported)
        #expect(LocalMeterProtocolSupport.status(for: .openAIChatCompletions) == .supported)
        #expect(LocalMeterProtocolSupport.status(for: .anthropicMessages) == .supported)
        #expect(LocalMeterProtocolSupport.shouldDisplayZero(for: .unsupported) == false)
    }

    @Test
    func `completed output items recover text when no delta was received`() throws {
        var parser = OpenAIResponsesSSEParser()
        let stream = Self.stream([
            Self.event("response.output_item.done", jsonParts: [
                #"{"type":"response.output_item.done","sequence_number":1,"output_index":0,"item":{"id":"msg-final","#,
                #""type":"message","status":"completed","content":[{"type":"output_text","text":"final item text","#,
                #""annotations":[]}]}}"#,
            ]),
            Self.event("response.reasoning_text.done", jsonParts: [
                #"{"type":"response.reasoning_text.done","sequence_number":2,"item_id":"rs-final","output_index":1,"#,
                #""content_index":0,"text":"final reasoning"}"#,
            ]),
            Self.event("response.completed", jsonParts: [
                #"{"type":"response.completed","sequence_number":3,"response":{"id":"resp-final","model":"gpt-5.4","#,
                #""status":"completed","usage":{"#,
                #""input_tokens":2,"output_tokens":3,"total_tokens":5}}}"#,
            ]),
        ])

        _ = try parser.append(Data(stream.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.outputText == "final item text")
        #expect(result.reasoningText == "final reasoning")
    }

    @Test
    func `events after a terminal response do not mutate the completed result`() throws {
        var parser = OpenAIResponsesSSEParser()
        let stream = Self.stream([
            Self.event("response.completed", jsonParts: [
                #"{"type":"response.completed","sequence_number":1,"response":{"id":"resp-terminal","#,
                #""model":"gpt-5.4","#,
                #""status":"completed","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#,
            ]),
            Self.event("response.output_text.delta", jsonParts: [
                #"{"type":"response.output_text.delta","sequence_number":2,"item_id":"msg-late","output_index":0,"#,
                #""content_index":0,"delta":"late replay"}"#,
            ]),
        ])

        _ = try parser.append(Data(stream.utf8))
        let result = try parser.finish()

        #expect(result.status == .completed)
        #expect(result.outputText.isEmpty)
        #expect(result.usage?.totalTokens == 2)
    }

    /// Shape transcribed from the OpenAI Responses API streaming event reference. It retains
    /// response metadata, reasoning, and cached-token fields so the fixture exercises the same
    /// nested usage locations used by real Responses payloads.
    static let completedFixture = Self.stream([
        Self.event("response.created", jsonParts: [
            #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_fixture_123","object":"response","#,
            #""created_at":1720000000,"#,
            #""status":"in_progress","model":"gpt-5.4","output":[],"parallel_tool_calls":true,"metadata":{}}}"#,
        ]),
        Self.event("response.output_item.added", jsonParts: [
            #"{"type":"response.output_item.added","sequence_number":1,"response_id":"resp_fixture_123","#,
            #""output_index":0,"#,
            #""item":{"id":"rs_fixture_1","#,
            #""type":"reasoning","status":"in_progress","summary":[]}}"#,
        ]),
        Self.event("response.reasoning_summary_text.delta", jsonParts: [
            #"{"type":"response.reasoning_summary_text.delta","sequence_number":2,"item_id":"rs_fixture_1","#,
            #""output_index":0,"#,
            #""summary_index":0,"#,
            #""delta":"I checked the request."}"#,
        ]),
        Self.event("response.reasoning_summary_text.done", jsonParts: [
            #"{"type":"response.reasoning_summary_text.done","sequence_number":3,"item_id":"rs_fixture_1","#,
            #""output_index":0,"#,
            #""summary_index":0,"#,
            #""text":"I checked the request."}"#,
        ]),
        Self.event("response.output_item.added", jsonParts: [
            #"{"type":"response.output_item.added","sequence_number":4,"response_id":"resp_fixture_123","#,
            #""output_index":1,"#,
            #""item":{"id":"msg_fixture_1","#,
            #""type":"message","role":"assistant","content":[],"status":"in_progress"}}"#,
        ]),
        Self.event("response.output_text.delta", jsonParts: [
            #"{"type":"response.output_text.delta","sequence_number":5,"item_id":"msg_fixture_1","output_index":1,"#,
            #""content_index":0,"delta":"Hello from the "}"#,
        ]),
        Self.event("response.output_text.delta", jsonParts: [
            #"{"type":"response.output_text.delta","sequence_number":6,"item_id":"msg_fixture_1","output_index":1,"#,
            #""content_index":0,"delta":"fixture."}"#,
        ]),
        Self.event("response.output_text.done", jsonParts: [
            #"{"type":"response.output_text.done","sequence_number":7,"item_id":"msg_fixture_1","output_index":1,"#,
            #""content_index":0,"text":"Hello from the fixture."}"#,
        ]),
        Self.event("response.completed", jsonParts: [
            #"{"type":"response.completed","sequence_number":8,"response":{"id":"resp_fixture_123","#,
            #""object":"response","#,
            #""status":"completed","model":"gpt-5.4","#,
            #""reasoning":{"effort":"medium","summary":"auto"},"usage":{"input_tokens":321,"#,
            #""input_tokens_details":{"cached_tokens":123},"#,
            #""output_tokens":88,"output_tokens_details":{"reasoning_tokens":17},"total_tokens":409}}}"#,
        ]),
    ])

    private static func event(
        _ name: String,
        id: String? = nil,
        jsonParts: [String]) -> String
    {
        let idLine = id.map { "id: \($0)\n" } ?? ""
        return "\(idLine)event: \(name)\ndata: \(jsonParts.joined())"
    }

    private static func stream(_ events: [String]) -> String {
        events.joined(separator: "\n\n") + "\n\n"
    }
}
