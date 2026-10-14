import Foundation
import Testing

@testable import RtechWhisperKit

/// Feeds raw chunk JSON through the SSE decoder, one event each.
private func decode(_ chunks: [String]) throws -> [LLMStreamEvent] {
    var decoder = SSEEventDecoder()
    var events: [LLMStreamEvent] = []
    for chunk in chunks {
        _ = try decoder.push("data: \(chunk)")
        events += try decoder.push("")
    }
    return events
}

/// The whole calls the chunks' tool-call pieces make.
private func calls(_ chunks: [String]) throws -> [LLMToolCall] {
    var assembler = ToolCallAssembler()
    for case .toolCall(let delta) in try decode(chunks) {
        assembler.add(LLMToolCallDelta(index: delta.index, id: delta.id, name: delta.name, arguments: delta.arguments))
    }
    return assembler.calls
}

/// One chunk with one tool-call piece; `index` nil leaves the key out.
private func piece(index: Int? = nil, id: String? = nil, name: String? = nil, arguments: String? = nil) -> String {
    var fields: [String] = []
    if let index { fields.append(#""index":\#(index)"#) }
    if let id { fields.append(#""id":"\#(id)""#) }
    var function: [String] = []
    if let name { function.append(#""name":"\#(name)""#) }
    if let arguments {
        let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        function.append(#""arguments":"\#(escaped)""#)
    }
    fields.append(#""function":{\#(function.joined(separator: ","))}"#)
    return #"{"choices":[{"delta":{"tool_calls":[{\#(fields.joined(separator: ","))}]}}]}"#
}

@Suite("Chat plumbing P3 fixes: stream")
struct ChatPlumbingStreamTests {
    // A mistyped tool_calls field keeps the chunk's text; a bad
    // entry does not drop a good one beside it.
    @Test func aMistypedToolCallKeepsTheText() throws {
        let events = try decode([
            #"{"choices":[{"delta":{"content":"hi","tool_calls":[{"index":"zero","function":{"name":"x"}}]}}]}"#,
            #"{"choices":[{"delta":{"content":" there","tool_calls":{"not":"an array"}}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":7},{"index":1,"id":"b","function":{"name":"get_note","arguments":"{}"}}]}}]}"#,
        ])
        #expect(events.compactMap { if case .delta(let text) = $0 { text } else { nil } } == ["hi", " there"])
        #expect(try calls([
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":7},{"index":1,"id":"b","function":{"name":"get_note","arguments":"{}"}}]}}]}"#,
        ]).map(\.id) == ["b"])
    }

    // Text and tool-call pieces in one event come out text first.
    @Test func textAndToolCallInOneEventKeepTheirOrder() throws {
        let events = try decode([
            #"{"choices":[{"delta":{"content":"Looking.","tool_calls":[{"index":0,"id":"a","function":{"name":"get_note","arguments":"{}"}}]}}]}"#,
        ])
        #expect(events == [.delta("Looking."), .toolCall(LLMToolCallDelta(index: 0, id: "a", name: "get_note", arguments: "{}"))])
    }

    // Interleaved index-less calls go back to their own call by id.
    @Test func interleavedIndexlessCallsRouteById() throws {
        #expect(try calls([
            piece(id: "a", name: "get_note", arguments: #"{"id":"#),
            piece(id: "b", name: "list_folders", arguments: "{}"),
            piece(id: "a", arguments: #""x"}"#),
        ]) == [
            LLMToolCall(id: "a", name: "get_note", arguments: #"{"id":"x"}"#),
            LLMToolCall(id: "b", name: "list_folders", arguments: "{}"),
        ])
    }

    // A name-only piece, then the id: one call.
    @Test func anIdAfterTheNameJoinsTheSameCall() throws {
        #expect(try calls([
            piece(name: "get_note", arguments: ""),
            piece(id: "c1", arguments: #"{"id":"x"}"#),
        ]) == [LLMToolCall(id: "c1", name: "get_note", arguments: #"{"id":"x"}"#)])
    }

    // An index out of range is skipped, not trapped on.
    @Test func anOutOfRangeIndexIsSkipped() throws {
        #expect(try calls([
            piece(index: Int.max, id: "big", name: "get_note", arguments: "{}"),
            piece(index: -1, id: "neg", name: "get_note", arguments: "{}"),
            piece(index: 0, id: "ok", name: "get_note", arguments: "{}"),
        ]).map(\.id) == ["ok"])
    }

    // The name repeated on every fragment is one call until its
    // arguments are whole; then the same name opens the next call.
    @Test func aRepeatedNameContinuesAnUnfinishedCall() throws {
        let found = try calls([
            piece(name: "get_note", arguments: #"{"id":"#),
            piece(name: "get_note", arguments: #""a"}"#),
            piece(name: "get_note", arguments: #"{"id":"b"}"#),
        ])
        #expect(found.map(\.arguments) == [#"{"id":"a"}"#, #"{"id":"b"}"#])
    }

    // An explicit index never lands in an index-less call's slot.
    @Test func explicitAndIndexlessPiecesKeepSeparateSlots() throws {
        #expect(try calls([
            piece(id: "x", name: "get_note", arguments: "{}"),
            piece(id: "y", name: "get_note", arguments: "{}"),
            piece(index: 1, id: "z", name: "list_folders", arguments: "{}"),
        ]).map(\.id) == ["x", "y", "z"])
    }
}

@Suite("Chat plumbing P3 fixes: tool calls")
struct ChatPlumbingToolCallTests {
    // The same index with a new id is a second call.
    @Test func aNewIdAtTheSameIndexOpensANewCall() {
        var assembler = ToolCallAssembler()
        assembler.add(LLMToolCallDelta(index: 0, id: "a", name: "get_note", arguments: "{}"))
        assembler.add(LLMToolCallDelta(index: 0, id: "b", name: "list_folders", arguments: "{}"))
        assembler.add(LLMToolCallDelta(index: 0, id: "b", arguments: ""))
        #expect(assembler.calls == [
            LLMToolCall(id: "a", name: "get_note", arguments: "{}"),
            LLMToolCall(id: "b", name: "list_folders", arguments: "{}"),
        ])
    }

    // A name piece on a known index replaces the name so far. llama.cpp
    // (common/chat.cpp compute_diffs) resends the whole name when it grows, so
    // a partial name is followed by the full one, never by a suffix.
    @Test func aPartialNameThenTheFullNameKeepsTheFullName() {
        var assembler = ToolCallAssembler()
        assembler.add(LLMToolCallDelta(index: 0, id: "a", name: "get_we", arguments: ""))
        assembler.add(LLMToolCallDelta(index: 0, name: "get_weather", arguments: "{}"))
        #expect(assembler.calls.map(\.name) == ["get_weather"])
    }

    // One full name, or the same full name sent again, is unchanged.
    @Test func aSingleOrRepeatedFullNameIsUnchanged() {
        var assembler = ToolCallAssembler()
        assembler.add(LLMToolCallDelta(index: 0, id: "a", name: "create_note", arguments: "{}"))
        assembler.add(LLMToolCallDelta(index: 1, id: "b", name: "get_note", arguments: "{"))
        assembler.add(LLMToolCallDelta(index: 1, name: "get_note", arguments: "}"))
        #expect(assembler.calls.map(\.name) == ["create_note", "get_note"])
    }

    // A call with no id gets an id unique beyond this step, and
    // no arguments go back as {}; the same holds for a non-stream call.
    @Test func standInsAreUniqueAndArgumentsAreJSON() async throws {
        var first = ToolCallAssembler(), second = ToolCallAssembler()
        first.add(LLMToolCallDelta(index: 0, name: "list_folders"))
        second.add(LLMToolCallDelta(index: 0, name: "list_folders"))
        let a = try #require(first.calls.first), b = try #require(second.calls.first)
        #expect(a.id.hasPrefix("call_") && a.id != b.id && a.id != "call_0")
        #expect(a.arguments == "{}")
        #expect(first.calls == first.calls)

        let body = #"{"choices":[{"message":{"content":"","tool_calls":[{"type":"function","function":{"name":"list_folders"}}]}}]}"#
        let (client, _) = StubLLM.make(.init(chunks: [body]))
        let call = try #require(try await client.complete(LLMChatRequest(model: "m", messages: [.user("x")])).toolCalls.first)
        #expect(call.id.hasPrefix("call_") && call.arguments == "{}")
    }

    // One malformed non-stream tool call does not lose the content.
    @Test func aMalformedCompletionToolCallKeepsTheContent() async throws {
        let body = #"{"choices":[{"finish_reason":"tool_calls","message":{"content":"hi","tool_calls":[{"id":"bad","type":"function"},{"id":"ok","type":"function","function":{"name":"get_note","arguments":"{}"}}]}}]}"#
        let (client, _) = StubLLM.make(.init(chunks: [body]))
        let completion = try await client.complete(LLMChatRequest(model: "m", messages: [.user("x")]))
        #expect(completion.content == "hi")
        #expect(completion.toolCalls == [LLMToolCall(id: "ok", name: "get_note", arguments: "{}")])
    }

    // Integers beyond 2^53 keep every digit.
    @Test func bigIntegersStayExact() throws {
        let value = try JSONValue(parsing: #"{"n":9007199254740993}"#)
        #expect(value["n"]?.intValue == 9_007_199_254_740_993)
        #expect(value.jsonString == #"{"n":9007199254740993}"#)
        #expect(try JSONValue(parsing: "2.5") == 2.5)
    }

    // A number sent as a string with a newline still reads.
    @Test func intValueTrimsNewlines() {
        #expect(JSONValue.string(" 5\n").intValue == 5)
    }
}

@Suite("ios-pr-236 review fixes: tool-call ids")
struct ToolCallIdChangeTests {
    // An upstream that changes the id partway through a call still makes one
    // call: the first id is kept and the arguments join. (llama-server at
    // f280b26 pins the first id per index, so it never sends such a change.)
    @Test func aChangedIdMidArgumentsKeepsOneCall() throws {
        #expect(try calls([
            piece(index: 0, id: "srv", name: "create_note", arguments: #"{"title":"#),
            piece(index: 0, id: "model1234", name: "create_note", arguments: #""x"}"#),
        ]) == [LLMToolCall(id: "srv", name: "create_note", arguments: #"{"title":"x"}"#)])
    }

    // The id can also arrive after the arguments are whole; the echo brings
    // no arguments, so it is not a second create_note({}).
    @Test func aChangedIdAfterWholeArgumentsIsNotADuplicate() throws {
        #expect(try calls([
            piece(index: 0, id: "srv", name: "create_note", arguments: #"{"title":"x"}"#),
            piece(index: 0, id: "model1234", name: "create_note", arguments: ""),
        ]) == [LLMToolCall(id: "srv", name: "create_note", arguments: #"{"title":"x"}"#)])
    }

    // An upstream that reuses one index for a second call of the same tool
    // still gets two calls once the first is whole and the second has a body.
    @Test func aSecondSameNameCallAtTheSameIndexStaysApart() throws {
        #expect(try calls([
            piece(index: 0, id: "a", name: "get_note", arguments: #"{"id":"1"}"#),
            piece(index: 0, id: "b", name: "get_note", arguments: #"{"id":"2"}"#),
        ]) == [
            LLMToolCall(id: "a", name: "get_note", arguments: #"{"id":"1"}"#),
            LLMToolCall(id: "b", name: "get_note", arguments: #"{"id":"2"}"#),
        ])
    }
}
