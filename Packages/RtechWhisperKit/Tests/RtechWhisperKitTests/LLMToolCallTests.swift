import Foundation
import Testing

@testable import RtechWhisperKit

private let sse = ["Content-Type": "text/event-stream"]

private let searchTool = LLMToolDefinition(
    name: "search_notes", description: "Search notes",
    parameters: .object(["type": "object", "properties": .object(["query": .object(["type": "string"])])]))

private func toolDelta(index: Int, id: String? = nil, name: String? = nil, arguments: String?) -> String {
    var function: [String: Any] = [:]
    if let name { function["name"] = name }
    if let arguments { function["arguments"] = arguments }
    var call: [String: Any] = ["index": index, "function": function]
    if let id { call["id"] = id; call["type"] = "function" }
    let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["tool_calls": [call]]]]])
    return "data: \(String(decoding: json, as: UTF8.self))\n\n"
}

private func textDelta(_ text: String) -> String {
    let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text]]]])
    return "data: \(String(decoding: json, as: UTF8.self))\n\n"
}

private func collect(_ stream: AsyncThrowingStream<LLMStreamChunk, Error>) async throws -> [LLMStreamChunk] {
    var out: [LLMStreamChunk] = []
    for try await chunk in stream { out.append(chunk) }
    return out
}

@Suite("LLM tool calls")
struct LLMToolCallTests {
    @Test func theRequestCarriesToolsInTheOpenAIShape() async throws {
        let (client, host) = StubLLM.make(.init(chunks: ["data: [DONE]\n\n"], headers: sse))
        _ = try await collect(client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")], tools: [searchTool])))
        let (_, data) = try #require(StubLLM.requests(to: host).first)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "search_notes")
        #expect(function["description"] as? String == "Search notes")
        #expect((function["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func noToolsLeavesTheKeyOut() async throws {
        let (client, host) = StubLLM.make(.init(chunks: ["data: [DONE]\n\n"], headers: sse))
        _ = try await collect(client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")], tools: [])))
        let (_, data) = try #require(StubLLM.requests(to: host).first)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["tools"] == nil)
    }

    @Test func assistantToolCallsAndToolResultsEncodeForTheModel() throws {
        let call = LLMToolCall(id: "c1", name: "get_note", arguments: #"{"id":"n1"}"#)
        let messages = [
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: #"{"ok":true}"#, toolCallId: "c1"),
        ]
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)) as? [[String: Any]])
        let calls = try #require(json[0]["tool_calls"] as? [[String: Any]])
        #expect(calls[0]["id"] as? String == "c1")
        #expect(calls[0]["type"] as? String == "function")
        let function = try #require(calls[0]["function"] as? [String: String])
        #expect(function == ["name": "get_note", "arguments": #"{"id":"n1"}"#])
        #expect(json[1]["role"] as? String == "tool")
        #expect(json[1]["tool_call_id"] as? String == "c1")
        #expect(json[1]["tool_calls"] == nil)
    }

    @Test func streamedToolCallPiecesAssembleIntoWholeCalls() async throws {
        // The arguments arrive in fragments, split across network chunks,
        // with a second call interleaved, as llama-server streams them.
        let body = textDelta("Looking.")
            + toolDelta(index: 0, id: "call-a", name: "search_notes", arguments: "")
            + toolDelta(index: 0, arguments: #"{"query": "#)
            + toolDelta(index: 1, id: "call-b", name: "list_folders", arguments: "{}")
            + toolDelta(index: 0, arguments: #""groceries"}"#)
            + "data: [DONE]\n\n"
        // Cut inside the first arguments fragment and inside the second
        // call's event, wherever JSONSerialization put their keys.
        let bytes = Data(body.utf8)
        func offset(_ marker: String) throws -> Int {
            body.utf8.distance(from: body.startIndex, to: try #require(body.range(of: marker)).lowerBound) + 3
        }
        let first = try offset(#"\"query"#), second = try offset("list_folders")
        let chunks = [bytes.subdata(in: 0..<first), bytes.subdata(in: first..<second), bytes.subdata(in: second..<bytes.count)]
        let (client, _) = StubLLM.make(.init(bytes: chunks, headers: sse))
        let events = try await collect(client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")], tools: [searchTool])))
        #expect(events.first == .content("Looking."))
        var assembler = ToolCallAssembler()
        for case .toolCall(let delta) in events { assembler.add(delta) }
        #expect(assembler.calls == [
            LLMToolCall(id: "call-a", name: "search_notes", arguments: #"{"query": "groceries"}"#),
            LLMToolCall(id: "call-b", name: "list_folders", arguments: "{}"),
        ])
    }

    @Test func theTextOnlyStreamDropsToolPieces() async throws {
        let body = textDelta("a") + toolDelta(index: 0, id: "c", name: "x", arguments: "{}") + textDelta("b") + "data: [DONE]\n\n"
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        var out: [String] = []
        for try await piece in client.stream(LLMChatRequest(model: "m", messages: [.user("x")])) { out.append(piece) }
        #expect(out == ["a", "b"])
    }

    @Test func aCompletionDecodesToolCalls() async throws {
        // The shape the hub relay returned for qwen3-4b-instruct in the live probe.
        let body = #"{"choices":[{"finish_reason":"tool_calls","index":0,"message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"searchNotes","arguments":"{\"query\": \"groceries\"}"},"id":"cFLg"}]}}]}"#
        let (client, _) = StubLLM.make(.init(chunks: [body]))
        let completion = try await client.complete(LLMChatRequest(model: "m", messages: [.user("x")], tools: [searchTool]))
        #expect(completion.finishReason == "tool_calls")
        #expect(completion.toolCalls == [LLMToolCall(id: "cFLg", name: "searchNotes", arguments: #"{"query": "groceries"}"#)])
    }

    @Test func assemblerNamesACallWithNoIdAndDropsANamelessOne() throws {
        var assembler = ToolCallAssembler()
        assembler.add(LLMToolCallDelta(index: 2, name: "get_note", arguments: "{}"))
        assembler.add(LLMToolCallDelta(index: 0, arguments: "{}"))
        let call = try #require(assembler.calls.first)
        #expect(assembler.calls.count == 1 && call.name == "get_note" && call.id.hasPrefix("call_"))
    }

    @Test func jsonValueRoundTripsAndReadsLooseNumbers() throws {
        let value = try JSONValue(parsing: #"{"a":[1,2.5,true,null,"x"],"b":{"c":"d"}}"#)
        #expect(value["a"] == .array([.number(1), .number(2.5), .bool(true), .null, .string("x")]))
        #expect(try JSONValue(parsing: value.jsonString) == value)
        #expect(JSONValue.number(7).intValue == 7)
        #expect(JSONValue.string("7").intValue == 7)
        #expect(JSONValue.number(7.5).intValue == nil)
    }
}

/// One SSE event from raw chunk JSON.
private func event(_ json: String) -> String { "data: \(json)\n\n" }

@Suite("LLM stream r3 review fixes")
struct LLMStreamR3ReviewFixTests {
    @Test func indexlessCallsInSeparateChunksStayApart() async throws {
        // An upstream that sends parallel calls one per chunk and no `index`.
        let body = event(#"{"choices":[{"delta":{"tool_calls":[{"id":"1","function":{"name":"get_note","arguments":""}}]}}]}"#)
            + event(#"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"{\"id\":\"a\"}"}}]}}]}"#)
            + event(#"{"choices":[{"delta":{"tool_calls":[{"id":"2","function":{"name":"get_note","arguments":"{\"id\":"}}]}}]}"#)
            + event(#"{"choices":[{"delta":{"tool_calls":[{"id":"2","function":{"arguments":"\"b\"}"}}]}}]}"#)
            + "data: [DONE]\n\n"
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        let events = try await collect(client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")], tools: [searchTool])))
        var assembler = ToolCallAssembler()
        for case .toolCall(let delta) in events { assembler.add(delta) }
        #expect(assembler.calls == [
            LLMToolCall(id: "1", name: "get_note", arguments: #"{"id":"a"}"#),
            LLMToolCall(id: "2", name: "get_note", arguments: #"{"id":"b"}"#),
        ])
    }

    @Test func theFinishReasonIsPassedOn() async throws {
        let body = textDelta("cut")
            + event(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
            + "data: [DONE]\n\n"
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        let events = try await collect(client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")])))
        #expect(events == [.content("cut"), .finish(reason: "length")])
    }
}
