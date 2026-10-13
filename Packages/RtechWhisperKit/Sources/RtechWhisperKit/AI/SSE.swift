import Foundation

/// Splits a byte stream into lines at `\n`, dropping a trailing `\r`.
/// Bytes arrive in arbitrary network chunks, so a line (or a multi-byte
/// UTF-8 character) may span several of them.
struct SSELineReader {
    private var buffer: [UInt8] = []

    /// The finished line when `byte` ends one, otherwise nil.
    mutating func push(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            buffer.append(byte)
            return nil
        }
        return take()
    }

    /// The unterminated last line, if any bytes are left.
    mutating func finish() -> String? {
        buffer.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// What one server-sent event of a chat-completions stream means.
enum LLMStreamEvent: Equatable {
    /// A non-empty piece of the assistant's content.
    case delta(String)
    /// A piece of a tool call (`choices[0].delta.tool_calls[n]`).
    case toolCall(LLMToolCallDelta)
    /// `choices[0].finish_reason`: why the model stopped (`stop`,
    /// `tool_calls`, `length`, ...).
    case finish(String)
    /// `data: [DONE]`: the stream is complete.
    case done
}

/// Turns SSE lines into chat-completion stream events. `data:` lines collect
/// until a blank line ends the event (the SSE rule); comment lines (`:`) and
/// other fields (`event:`, `id:`, `retry:`) are ignored. An event whose data
/// is not JSON, or is JSON with neither a content nor a tool-call delta, is
/// skipped. The relay's in-stream error event (hub protocol 11.1) throws.
struct SSEEventDecoder {
    private var data: [String] = []
    /// Tool-call pieces go to call slots numbered in order of first sight.
    /// An upstream `index` and a piece with no `index` never share a slot:
    /// each explicit index maps to its own slot, and index-less pieces are
    /// routed by id (or to the last call) into slots of their own. These span
    /// the whole stream, because an upstream may send one call per SSE event.
    private var nextSlot = 0
    private var explicitSlots: [Int: Int] = [:]
    private var idSlots: [String: Int] = [:]
    /// The slot the last piece went to; each slot's id and name; and the
    /// arguments seen so far for each index-less slot.
    private var last: Int?
    private var slotIds: [Int: String] = [:]
    private var slotNames: [Int: String] = [:]
    private var indexlessArguments: [Int: String] = [:]
    /// Explicit indices outside this range are skipped as malformed.
    static let indexRange = 0...1023

    /// The events a finished SSE event carries: empty until a blank line ends
    /// one. One chunk may carry text and tool-call pieces together.
    mutating func push(_ line: String) throws(HubError) -> [LLMStreamEvent] {
        if line.isEmpty {
            guard !data.isEmpty else { return [] }
            let payload = data.joined(separator: "\n")
            data.removeAll()
            return try decode(payload)
        }
        guard line.hasPrefix("data:") else { return [] }
        var value = line.dropFirst("data:".count)
        if value.first == " " { value = value.dropFirst() }
        data.append(String(value))
        return []
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let tool_calls: [ToolCall]?

                /// Content and each tool-call piece decode on their own, so a
                /// mistyped piece does not drop the chunk's text.
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    content = try? container.decodeIfPresent(String.self, forKey: .content)
                    tool_calls = (try? container.decodeIfPresent(LenientArray<ToolCall>.self, forKey: .tool_calls))?.elements
                }
                private enum CodingKeys: String, CodingKey { case content, tool_calls }
            }
            let delta: Delta?
            let finish_reason: String?
        }
        struct ErrorInner: Decodable { let message: String? }
        let choices: [Choice]?
        let error: ErrorInner?
        let code: String?
    }

    private mutating func decode(_ payload: String) throws(HubError) -> [LLMStreamEvent] {
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [.done] }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
            return []
        }
        if let error = chunk.error {
            if chunk.code == "upstream_timeout" { throw .upstreamUnavailable(status: 504) }
            throw .server(status: 502, code: chunk.code, message: error.message)
        }
        guard let choice = chunk.choices?.first else { return [] }
        var events: [LLMStreamEvent] = []
        if let text = choice.delta?.content, !text.isEmpty { events.append(.delta(text)) }
        for call in choice.delta?.tool_calls ?? [] {
            guard let index = toolCallSlot(call.index, id: call.id, name: call.function?.name,
                                           arguments: call.function?.arguments) else { continue }
            events.append(.toolCall(LLMToolCallDelta(
                index: index, id: call.id,
                name: call.function?.name, arguments: call.function?.arguments)))
        }
        if let reason = choice.finish_reason, !reason.isEmpty { events.append(.finish(reason)) }
        return events
    }

    /// The slot a tool-call piece belongs to, or nil for an out-of-range
    /// explicit index. With no `index`: a known id goes back to its call; a
    /// first id with no name adopts the last, still id-less call; a new id or
    /// name opens a call, except the last call's name again while its
    /// arguments are not yet whole JSON (an upstream that repeats the name on
    /// every fragment); a piece with only arguments continues the last call.
    private mutating func toolCallSlot(_ given: Int?, id: String?, name: String?, arguments: String?) -> Int? {
        let id = id.flatMap { $0.isEmpty ? nil : $0 }
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let slot: Int
        if let given {
            guard Self.indexRange.contains(given) else { return nil }
            slot = explicitSlots[given] ?? open()
            explicitSlots[given] = slot
        } else if let id, let known = idSlots[id] {
            slot = known
        } else if let id, let last, slotIds[last] == nil, name == nil || name == slotNames[last] {
            slot = last
        } else if id == nil, let last,
                  name == nil || (name == slotNames[last] && !isWholeJSON(indexlessArguments[last])) {
            slot = last
        } else {
            slot = open()
        }
        if let id, slotIds[slot] == nil {
            slotIds[slot] = id
            if given == nil { idSlots[id] = slot }
        }
        if let name, slotNames[slot] == nil { slotNames[slot] = name }
        if given == nil { indexlessArguments[slot, default: ""] += arguments ?? "" }
        last = slot
        return slot
    }

    private mutating func open() -> Int {
        defer { nextSlot += 1 }
        return nextSlot
    }

    private func isWholeJSON(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
    }
}
