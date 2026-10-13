import Foundation

/// Any JSON value: a tool's parameter schema, the arguments a model sends,
/// and the result a tool hands back.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    /// An integer a `Double` cannot hold exactly (beyond 2^53); smaller
    /// integers are `.number`.
    case integer(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            if abs(value) >= Self.exactDoubleLimit, let exact = try? container.decode(Int.self) {
                self = .integer(exact)
            } else {
                self = .number(value)
            }
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// 2^53: from here up, not every integer has an exact `Double`.
    static let exactDoubleLimit: Double = 9_007_199_254_740_992

    /// Parses JSON text. Throws for text that is not JSON.
    public init(parsing text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Compact JSON with sorted keys.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// A number with no fraction, or a string of digits (small models send both).
    public var intValue: Int? {
        switch self {
        case .number(let value) where value.rounded() == value && abs(value) < 1e15: Int(value)
        case .integer(let value): value
        case .string(let value): Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }
}

/// A function the model may call, sent in the request's `tools` array as
/// `{ type: "function", function: { name, description, parameters } }`.
public struct LLMToolDefinition: Encodable, Sendable, Equatable {
    public var name: String
    public var description: String
    /// A JSON Schema object for the arguments.
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    private struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    private enum CodingKeys: String, CodingKey { case type, function }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        try container.encode(Function(name: name, description: description, parameters: parameters), forKey: .function)
    }
}

/// One tool call the model asked for. `arguments` is the JSON text exactly as
/// the model sent it; it is not guaranteed to parse.
public struct LLMToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    private struct Function: Codable {
        let name: String
        let arguments: String?
    }

    private enum CodingKeys: String, CodingKey { case id, type, function }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.id = id.isEmpty ? Self.standInId() : id
        let function = try container.decode(Function.self, forKey: .function)
        name = function.name
        arguments = Self.normalized(function.arguments ?? "")
    }

    /// The id for a call the model sent without one: unique across the
    /// conversation, so no two assistant turns carry the same id.
    static func standInId() -> String { "call_\(UUID().uuidString)" }

    /// No arguments at all go back to the model as `{}`, not `""`, which a
    /// template that parses arguments as JSON would reject.
    static func normalized(_ arguments: String) -> String {
        arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : arguments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        try container.encode(Function(name: name, arguments: arguments), forKey: .function)
    }
}

/// One streamed piece of a tool call. Pieces with the same `index` belong to
/// one call: the first usually carries `id` and `name`, the rest carry
/// fragments of `arguments`.
public struct LLMToolCallDelta: Sendable, Equatable {
    public var index: Int
    public var id: String?
    public var name: String?
    public var arguments: String?

    public init(index: Int, id: String? = nil, name: String? = nil, arguments: String? = nil) {
        self.index = index
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One event of a streamed chat completion.
public enum LLMStreamChunk: Sendable, Equatable {
    /// A non-empty piece of the assistant's text.
    case content(String)
    /// A piece of a tool call; assemble them with `ToolCallAssembler`.
    case toolCall(LLMToolCallDelta)
    /// Why the model stopped (`finish_reason`): `stop`, `tool_calls`, or
    /// `length` when the reply was cut off at the token limit.
    case finish(reason: String)
}

/// Joins streamed tool-call pieces into whole calls, ordered by index.
/// Pieces with one index form one call, and the first id is kept. A piece
/// with a different id opens a new call at the same index only when it names
/// a different tool or the call so far is already whole JSON; such a new call
/// of the same tool that never gets arguments is an upstream re-sending the
/// call under a new id and is dropped. A non-empty name piece replaces the
/// name so far: the last one wins, so `get_we` then `get_weather` is
/// `get_weather`, and the same name again changes nothing.
///
/// Replacing matches llama-server (f280b26): `compute_diffs` in
/// common/chat.cpp accepts a tool name that grows by prefix at an existing
/// index and sends the COMPLETE new name (`tool_call_delta.name = newf.name`),
/// not the suffix, and tools/server/server-chat.cpp writes `function.name`
/// whenever that name is non-empty. Templates that do not emit the name
/// atomically (Qwen3-Coder XML, Mistral `[ARGS]`, tagged and XML
/// auto-parsers) can stream a partial name and then the full one. OpenAI
/// sends the name once, which replacing also handles.
///
/// Keeping the first id matches llama-server. The build tested here (llama.cpp
/// f280b26) pins one id per index in `task_result_state`:
/// `set_tool_call_ids` caches the first id each index gets (the model's own,
/// or a generated one if the model has none yet) and writes it into every
/// later parse before `compute_diffs` runs. So the id at an index never
/// changes partway through a stream, and no piece with a new id is sent.
/// If an upstream ever does swap the id, the call keeps the first one.
public struct ToolCallAssembler: Sendable {
    private struct Slot: Sendable {
        let index: Int
        /// Opened by a new id at an index whose call of the same tool was
        /// already whole: dropped at the end if it never gets a body.
        var echoCandidate = false
        let standInId = LLMToolCall.standInId()
        var id: String?
        var name: String?
        var arguments = ""
    }
    private var slots: [Slot] = []
    /// The slot each index's pieces go to now.
    private var current: [Int: Int] = [:]

    public init() {}

    public mutating func add(_ delta: LLMToolCallDelta) {
        let id = delta.id.flatMap { $0.isEmpty ? nil : $0 }
        let name = delta.name.flatMap { $0.isEmpty ? nil : $0 }
        var position = current[delta.index]
        var echo = false
        if let found = position, let id, let held = slots[found].id, held != id {
            let heldName = slots[found].name
            if let name, let heldName, name != heldName {
                position = nil
            } else if Self.isWholeJSON(slots[found].arguments) {
                // Same tool, finished body: a second call, or an upstream
                // re-sending the call with its new id and no new arguments.
                position = nil
                echo = true
            }
        }
        let at: Int
        if let position {
            at = position
        } else {
            at = slots.count
            slots.append(Slot(index: delta.index, echoCandidate: echo))
            current[delta.index] = at
        }
        if let id, slots[at].id == nil { slots[at].id = id }
        if let name { slots[at].name = name }
        // In place: a long body streams as many fragments.
        if let arguments = delta.arguments { slots[at].arguments.append(arguments) }
    }

    /// The finished calls, by index and then arrival. A piece that never got
    /// a name is dropped; a call with no id gets a unique stand-in, and one
    /// with no arguments gets `{}`.
    public var calls: [LLMToolCall] {
        slots.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .compactMap { _, slot in
                guard let name = slot.name else { return nil }
                if slot.echoCandidate, slot.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                return LLMToolCall(
                    id: slot.id ?? slot.standInId, name: name, arguments: LLMToolCall.normalized(slot.arguments))
            }
    }

    private static func isWholeJSON(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil
    }
}

/// An array decoded one element at a time: an element that fails to decode
/// is skipped instead of failing the whole array.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }

    /// Decodes any value, to step past it.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// Anything that streams a chat completion with tool-call pieces. `LLMClient`
/// is the real one; `ChatSession` takes this so tests can drive it.
public protocol LLMChatStreaming: Sendable {
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamChunk, Error>
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int) {
        self = abs(Double(value)) >= Self.exactDoubleLimit ? .integer(value) : .number(Double(value))
    }
    public init(floatLiteral value: Double) { self = .number(value) }
}
