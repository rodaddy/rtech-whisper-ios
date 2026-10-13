import Foundation

/// One chat message in an OpenAI-style chat-completions body.
public struct LLMMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    /// The calls an assistant message asked for; left out of the body when nil.
    public var toolCalls: [LLMToolCall]?
    /// The call a `tool` message answers; left out of the body when nil.
    public var toolCallId: String?

    public init(role: Role, content: String, toolCalls: [LLMToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public static func system(_ content: String) -> LLMMessage { LLMMessage(role: .system, content: content) }
    public static func user(_ content: String) -> LLMMessage { LLMMessage(role: .user, content: content) }
}

/// What to ask the model. A `nil` field is left out of the body, so the
/// upstream default applies.
public struct LLMChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [LLMMessage]
    public var temperature: Double?
    public var maxTokens: Int?
    /// The functions the model may call (OpenAI `tools`). The hub relay passes
    /// them to llama-swap, which answers with native `tool_calls`.
    public var tools: [LLMToolDefinition]?

    public init(
        model: String, messages: [LLMMessage], temperature: Double? = nil, maxTokens: Int? = nil,
        tools: [LLMToolDefinition]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.tools = tools
    }
}

/// The first choice of a non-streamed chat completion.
public struct LLMChatCompletion: Sendable, Equatable {
    /// The message content as the model sent it, untrimmed; empty when the
    /// choice had no content.
    public let content: String
    public let finishReason: String?
    /// The tool calls the model asked for; empty when it answered in text.
    public let toolCalls: [LLMToolCall]

    public init(content: String, finishReason: String?, toolCalls: [LLMToolCall] = []) {
        self.content = content
        self.finishReason = finishReason
        self.toolCalls = toolCalls
    }
}

/// One entry of `GET /api/llm/v1/models`.
public struct LLMModel: Decodable, Sendable, Equatable {
    public let id: String
    public let ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

/// Anything that answers a non-streamed chat completion. `LLMClient` is the
/// real one; the cleanup and title services take this so they can be driven
/// by a fake.
public protocol LLMCompleting: Sendable {
    func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion
}

/// The hub's LLM relay (hub protocol section 11): OpenAI-style chat
/// completions forwarded to llama-swap, authenticated with the device key.
/// The `URLSession` is injected so tests can answer with a stub `URLProtocol`.
public struct LLMClient: LLMCompleting, LLMChatStreaming {
    public static let chatPath = "api/llm/v1/chat/completions"
    public static let modelsPath = "api/llm/v1/models"
    /// The only chat model on llama-swap today.
    public static let defaultModel = "qwen3-4b-instruct"

    public let configuration: HubConfiguration
    private let key: String
    private let session: URLSession

    /// How long one request may go without bytes. The relay allows 120 s per
    /// call (protocol section 11) and a non-streamed call sends nothing until
    /// it is done, so the 60 s URLSession default would give up on a slow
    /// cleanup or title (a cold model load) the hub is still working on.
    public static let requestTimeout: TimeInterval = 180

    /// A session whose request timeout covers the relay's 120 s budget.
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    public init(configuration: HubConfiguration = HubConfiguration(), key: String, session: URLSession = defaultSession) {
        self.configuration = configuration
        self.key = key
        self.session = session
    }

    /// `POST /api/llm/v1/chat/completions` without streaming: the first choice.
    public func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        let urlRequest = try makeChatRequest(request, stream: false)
        let data = try await fetch(urlRequest)
        struct Body: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let tool_calls: [LLMToolCall]?

                    /// Each tool call decodes on its own, so a malformed
                    /// entry is skipped instead of losing the content.
                    init(from decoder: Decoder) throws {
                        let container = try decoder.container(keyedBy: CodingKeys.self)
                        content = try container.decodeIfPresent(String.self, forKey: .content)
                        tool_calls = (try? container.decodeIfPresent(
                            LenientArray<LLMToolCall>.self, forKey: .tool_calls))?.elements
                    }
                    private enum CodingKeys: String, CodingKey { case content, tool_calls }
                }
                let message: Message?
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
        guard let choice = body.choices.first else {
            throw .decoding("The completion had no choices.")
        }
        return LLMChatCompletion(
            content: choice.message?.content ?? "", finishReason: choice.finish_reason,
            toolCalls: choice.message?.tool_calls ?? [])
    }

    /// `POST /api/llm/v1/chat/completions` with `stream: true`: the content
    /// deltas in order. The stream finishes at `data: [DONE]`; it throws a
    /// `HubError` for a non-2xx answer, for the relay's in-stream error event,
    /// and when the connection closes before `[DONE]` (a cut-short stream).
    /// Cancelling the consuming task cancels the request.
    public func stream(_ request: LLMChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do throws(HubError) {
                    try await runStream(request) { chunk in
                        if case .content(let text) = chunk { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same stream as `stream`, with the tool-call pieces as well as the
    /// text, for a request that carries `tools`. Same errors and cancellation.
    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do throws(HubError) {
                    try await runStream(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `GET /api/llm/v1/models`: the model ids the relay allows.
    public func models() async throws(HubError) -> [LLMModel] {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: Self.modelsPath))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await fetch(request)
        struct Body: Decodable { let data: [LLMModel] }
        do {
            return try JSONDecoder().decode(Body.self, from: data).data
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    // MARK: Transport

    private struct WireBody: Encodable {
        let model: String
        let messages: [LLMMessage]
        let temperature: Double?
        let max_tokens: Int?
        let stream: Bool?
        let tools: [LLMToolDefinition]?
    }

    func makeChatRequest(_ chat: LLMChatRequest, stream: Bool) throws(HubError) -> URLRequest {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: Self.chatPath))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let body = WireBody(
            model: chat.model,
            messages: chat.messages,
            temperature: chat.temperature,
            max_tokens: chat.maxTokens,
            stream: stream ? true : nil,
            tools: chat.tools?.isEmpty == false ? chat.tools : nil
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .decoding("Could not encode the request: \(error)")
        }
        return request
    }

    private func fetch(_ request: URLRequest) async throws(HubError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        let http = try Self.http(response)
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.from(
                status: http.statusCode,
                body: data,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return data
    }

    private func runStream(_ chat: LLMChatRequest, yield: (LLMStreamChunk) -> Void) async throws(HubError) {
        let request = try makeChatRequest(chat, stream: true)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        let http = try Self.http(response)

        var lines = SSELineReader()
        var events = SSEEventDecoder()
        var errorBody = Data()
        let ok = (200..<300).contains(http.statusCode)
        do {
            for try await byte in bytes {
                guard ok else {
                    errorBody.append(byte)
                    continue
                }
                guard let line = lines.push(byte) else { continue }
                if try handle(line, events: &events, yield: yield) { return }
            }
        } catch let error as HubError {
            throw error
        } catch is CancellationError {
            throw .network("The stream was cancelled.")
        } catch {
            throw .network(error.localizedDescription)
        }
        guard ok else {
            throw HubError.from(
                status: http.statusCode,
                body: errorBody,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        if let last = lines.finish(), try handle(last, events: &events, yield: yield) { return }
        if try handle("", events: &events, yield: yield) { return }
        throw .network("The LLM stream closed before [DONE].")
    }

    /// Feeds one line through the decoder. Returns true at `[DONE]`.
    private func handle(_ line: String, events: inout SSEEventDecoder, yield: (LLMStreamChunk) -> Void) throws(HubError) -> Bool {
        for event in try events.push(line) {
            switch event {
            case .delta(let text): yield(.content(text))
            case .toolCall(let delta): yield(.toolCall(delta))
            case .finish(let reason): yield(.finish(reason: reason))
            case .done: return true
            }
        }
        return false
    }

    private static func http(_ response: URLResponse) throws(HubError) -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw .network("The hub answered without an HTTP response.")
        }
        return http
    }
}
