import Foundation
import Observation

/// One chat with the agent: the messages, the assistant's reply streaming in,
/// and the tool loop. A turn sends the conversation (with the tools) to the
/// hub's LLM relay, which answers with native OpenAI `tool_calls`; the
/// session runs each call, hands the results back, and asks again, until the
/// model answers in text or `maxSteps` model calls have been made.
@MainActor
@Observable
public final class ChatSession {
    public enum Status: Equatable, Sendable {
        case idle
        /// The model's reply is arriving.
        case streaming
        /// Running the tool calls the model asked for.
        case runningTools
        /// The last turn failed. `nil` when the failure was not a hub error.
        case failed(HubError?)
        /// The last reply was cut off at the model's length limit; its text
        /// is incomplete and ends with `truncationMarker`.
        case truncated
    }

    /// How a turn ended.
    public enum TurnEnd: Equatable, Sendable {
        /// The model answered in text.
        case answered
        /// The model still wanted tools after `maxSteps` calls; those calls
        /// were not run.
        case stepLimit
        /// The model stopped at its length limit (`finish_reason: length`):
        /// the reply is incomplete and any tool calls in it were not run.
        case truncated
        case cancelled
        case failed
    }

    /// Ends the text of a reply cut off at the model's length limit, so the
    /// reply never reads as complete, on screen or after a relaunch.
    public static let truncationMarker = "[Reply cut off: the model reached its length limit.]"
    /// The answer, sent in place of a tool result that was never saved: the
    /// app closed while the call ran or before its result was stored, so it
    /// may well have run.
    static let unsavedResult = "Outcome unknown: the app closed before this tool's result was saved, so it may or may not have run. For create_note or update_note, check with search_notes or get_note before repeating it."

    /// The most model calls one turn makes.
    /// The answer to a write call whose request message the store did not take.
    static let unsavedRequest = "Not run: the request could not be saved, so the change was not made. Nothing was changed; try again."
    public static let maxSteps = 5
    /// A new conversation is titled with this much of the first message.
    public static let titleLength = 60
    /// The most text, in UTF-8 bytes, one request carries: the system
    /// prompt plus every message. Well under the relay's 1 MB body limit
    /// even after JSON escaping, and about 25-30k tokens, inside the default
    /// model's context. A longer history loses its old tool results first,
    /// then its oldest exchanges; the latest exchange's results are cut
    /// short, never dropped.
    public static let requestBudget = 100_000

    public private(set) var conversation: ChatConversation?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var status: Status = .idle
    /// The composer's unsent text for this conversation, typed or dictated.
    /// Held here, in memory only, so leaving the conversation screen (or a
    /// take that finishes after it closed) does not lose it. Starting or
    /// opening another conversation clears it.
    public var draft = ""
    /// Changes each time `draft` is cleared because another conversation
    /// was started or opened. A dictation reads it when the take stops and
    /// hands it to `appendDictation`, so text recorded in one chat never
    /// lands in the next one's draft.
    public private(set) var draftGeneration = 0
    /// True when the last write to the chat store failed. The conversation
    /// on screen is intact; it may be missing messages after a relaunch.
    public private(set) var saveFailed = false

    /// True while a turn runs, `open` is loading a conversation, or
    /// `retrySave` is saving.
    public var isBusy: Bool { turnTask != nil || loading || saving != nil }

    private let llm: any LLMChatStreaming
    private let tools: [String: ChatTool]
    private let definitions: [LLMToolDefinition]
    private let store: (any ChatPersisting)?
    private let model: String
    private let temperature: Double?
    private let requestBudget: Int
    /// True when `conversation` exists in the store. False when creating it
    /// failed: the next save tries again.
    private var persisted = false
    /// How many of `messages`, from the start, are in the store. Saves go in
    /// order and stop at the first failure, so the store never has a hole
    /// (a tool result whose call is missing); the next save retries the rest.
    private var savedCount = 0
    public let systemPrompt: String
    private var turnTask: Task<TurnEnd, Never>?
    /// True while `open` awaits the store, so a send cannot start a turn
    /// whose messages `open` would then replace.
    private var loading = false
    /// The `retrySave` in flight. A second caller waits for it rather than
    /// running a second save over the same messages at the same time.
    private var saving: Task<Bool, Never>?

    /// - Parameters:
    ///   - tools: offered to the model in this order; usually `NoteTools.all`.
    ///   - store: where conversations are kept; `nil` keeps them in memory.
    ///   - systemPrompt: defaults to the desktop's chat agent prompt with the
    ///     instructions for these tools.
    public init(
        llm: any LLMChatStreaming, tools: [ChatTool] = [], store: (any ChatPersisting)? = nil,
        model: String = LLMClient.defaultModel, temperature: Double? = nil, systemPrompt: String? = nil,
        requestBudget: Int = ChatSession.requestBudget
    ) {
        self.requestBudget = requestBudget
        self.llm = llm
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.definitions = tools.map(\.definition)
        self.store = store
        self.model = model
        self.temperature = temperature
        self.systemPrompt = systemPrompt ?? ChatPrompt.system(tools: tools.map(\.name))
    }

    // MARK: Conversations

    /// Clears the screen for a new conversation; it is saved on the first send.
    public func startNewConversation() {
        guard !isBusy else { return }
        conversation = nil
        persisted = false
        savedCount = 0
        messages = []
        status = .idle
        saveFailed = false
        clearDraft()
    }

    /// Adds a finished take's text after what is already in the draft.
    /// Does nothing, and returns false, when the conversation changed since
    /// `generation` was read: the take belongs to a chat no longer on screen.
    @discardableResult
    public func appendDictation(_ text: String, generation: Int) -> Bool {
        guard generation == draftGeneration else { return false }
        draft = draft.isEmpty ? text : draft + " " + text
        return true
    }

    private func clearDraft() {
        draft = ""
        draftGeneration += 1
    }

    /// The list renamed a conversation in the store; the one on screen shows
    /// the new title too. Any other id is ignored.
    public func renamed(_ id: UUID, to title: String) {
        guard conversation?.id == id else { return }
        conversation?.title = title
    }

    /// Loads a saved conversation.
    public func open(_ id: UUID) async throws {
        guard !isBusy, let store else { return }
        loading = true
        defer { loading = false }
        guard let found = try await store.conversation(id) else { throw ChatStoreError.conversationNotFound(id) }
        let loaded = try await store.messages(in: id)
        let previous = conversation?.id
        conversation = found
        persisted = true
        messages = loaded
        savedCount = loaded.count
        status = .idle
        saveFailed = false
        if found.id != previous { clearDraft() }
    }

    // MARK: Turns

    /// Sends a user message and runs the turn to its end. Returns nil, and
    /// does nothing, for blank text or while a turn is running.
    @discardableResult
    public func send(_ text: String) async -> TurnEnd? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return nil }
        return await run { await self.runTurn(text) }
    }

    /// Runs the failed turn again from the stored history, without adding
    /// another user message. Returns nil, and does nothing, unless the last
    /// turn failed and nothing is running. There is nothing to undo first:
    /// a failed step's partial reply was never kept.
    @discardableResult
    public func retry() async -> TurnEnd? {
        guard case .failed = status, !isBusy, !messages.isEmpty else { return nil }
        return await run { await self.runSteps() }
    }

    private func run(_ turn: @escaping @MainActor () async -> TurnEnd) async -> TurnEnd {
        let task = Task { await turn() }
        turnTask = task
        // Cancelling the caller cancels the turn as well.
        let end = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        turnTask = nil
        return end
    }

    /// Stops the running turn. Text already streamed stays; tool calls not
    /// yet run are answered as cancelled so the history stays valid.
    public func cancel() {
        turnTask?.cancel()
    }

    private func runTurn(_ text: String) async -> TurnEnd {
        await ensureConversation(title: text)
        await add(ChatMessage(role: .user, content: text))
        return await runSteps()
    }

    /// The model calls and tool runs of a turn whose user message is
    /// already in `messages`.
    private func runSteps() async -> TurnEnd {
        for step in 1...Self.maxSteps {
            if Task.isCancelled { return finish(.cancelled) }
            status = .streaming
            let request = LLMChatRequest(
                model: model,
                messages: [.system(systemPrompt)] + Self.fit(
                    Self.history(messages), budget: requestBudget - systemPrompt.utf8.count),
                temperature: temperature,
                tools: definitions.isEmpty ? nil : definitions)

            let index = messages.count
            messages.append(ChatMessage(role: .assistant, content: ""))
            var assembler = ToolCallAssembler()
            var failure: Error?
            var finishReason: String?
            do {
                for try await chunk in llm.streamChat(request) {
                    switch chunk {
                    case .content(let piece): messages[index].content += piece
                    case .toolCall(let delta): assembler.add(delta)
                    case .finish(let reason): finishReason = reason
                    }
                }
            } catch {
                failure = error
            }

            let cancelled = Task.isCancelled
            let truncated = !cancelled && failure == nil && finishReason == "length"
            if truncated {
                let text = messages[index].content
                messages[index].content = text.isEmpty ? Self.truncationMarker : text + "\n\n" + Self.truncationMarker
            }
            // A call cut off mid-stream, or in a reply cut off at the length
            // limit, is not run.
            let calls = (cancelled || failure != nil || truncated) ? [] : assembler.calls.filter { !$0.name.isEmpty }
            messages[index].toolCalls = calls
            // A failed step's reply is never kept, on screen or in the store:
            // it goes before any save, with whatever text streamed before the
            // error, so it can never reach the model as a finished reply and
            // a retry has nothing to delete.
            let failed = !cancelled && failure != nil
            if failed || (messages[index].content.isEmpty && calls.isEmpty) {
                messages.remove(at: index)
            } else {
                await saveUnsaved()
            }

            if cancelled { return finish(.cancelled) }
            if let failure {
                status = .failed(failure as? HubError)
                return .failed
            }
            if truncated {
                status = .truncated
                return .truncated
            }
            if calls.isEmpty { return finish(.answered) }
            if step == Self.maxSteps {
                await answer(calls, with: "Not run: the limit of \(Self.maxSteps) tool steps for one message was reached.")
                return finish(.stepLimit)
            }

            status = .runningTools
            for (position, call) in calls.enumerated() {
                if Task.isCancelled {
                    await answer(Array(calls[position...]), with: "Cancelled by the user.")
                    return finish(.cancelled)
                }
                // A write runs only once the message asking for it is in the
                // store. Otherwise a relaunch would show the request with no
                // call, and a resend would make the change a second time.
                if store != nil, savedCount <= index, tools[call.name]?.readOnly == false {
                    await add(Self.errorMessage(for: call, Self.unsavedRequest))
                    continue
                }
                await add(await execute(call))
            }
        }
        return finish(.stepLimit)
    }

    /// The messages as the model reads them, shaped so the relay accepts
    /// them: every tool call gets an answer, and every tool result answers
    /// a call. A call with no saved result (the app quit while it ran, or
    /// before its result was stored) is answered as outcome unknown, never
    /// as not run, since it may have run. A result whose call is not in the
    /// assistant message just before it (the store lost that message) is
    /// dropped.
    static func history(_ messages: [ChatMessage]) -> [LLMMessage] {
        var out: [LLMMessage] = []
        var unanswered: [LLMToolCall] = []
        func closeOpenCalls() {
            for call in unanswered {
                out.append(LLMMessage(
                    role: .tool, content: JSONValue.object(["error": .string(unsavedResult)]).jsonString,
                    toolCallId: call.id))
            }
            unanswered = []
        }
        for message in messages {
            if message.role == .tool {
                guard let open = unanswered.firstIndex(where: { $0.id == message.toolCallId }) else { continue }
                unanswered.remove(at: open)
            } else {
                closeOpenCalls()
            }
            out.append(message.llmMessage)
            if message.role == .assistant { unanswered = message.toolCalls }
        }
        closeOpenCalls()
        return out
    }

    /// A stand-in for a tool result dropped to fit the request budget.
    static let droppedResult = JSONValue.object([
        "error": "Result dropped to fit the request size limit. Call the tool again if you need it.",
    ]).jsonString

    /// Trims `history` to at most `budget` bytes of text. The latest
    /// exchange (from the last user message on) is the one the model is
    /// working on, so its tool results are never dropped. Older tool
    /// results go first, oldest first (a get_note body is the usual bulk),
    /// then whole older exchanges from the front, starting each time at a
    /// user message so no tool call is left without its answer. If the
    /// latest exchange alone is still over, its tool results are cut short,
    /// largest first, with a marker giving the original length.
    static func fit(_ history: [LLMMessage], budget: Int) -> [LLMMessage] {
        func size(_ message: LLMMessage) -> Int {
            message.content.utf8.count + (message.toolCalls ?? []).reduce(0) {
                $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.utf8.count
            }
        }
        let start = history.lastIndex(where: { $0.role == .user }) ?? history.startIndex
        var older = Array(history[..<start])
        var latest = Array(history[start...])
        var total = history.reduce(0) { $0 + size($1) }
        for index in older.indices where total > budget {
            guard older[index].role == .tool, older[index].content.utf8.count > droppedResult.utf8.count else { continue }
            total -= older[index].content.utf8.count - droppedResult.utf8.count
            older[index].content = droppedResult
        }
        while total > budget, !older.isEmpty {
            let next = older.indices.dropFirst().first(where: { older[$0].role == .user }) ?? older.endIndex
            total -= older[..<next].reduce(0) { $0 + size($1) }
            older.removeFirst(next)
        }
        let results = latest.indices.filter { latest[$0].role == .tool }
            .sorted { latest[$0].content.utf8.count > latest[$1].content.utf8.count }
        for index in results where total > budget {
            let before = latest[index].content.utf8.count
            let cut = truncatedResult(latest[index].content, toAtMost: before - (total - budget))
            guard cut.utf8.count < before else { continue }
            total -= before - cut.utf8.count
            latest[index].content = cut
        }
        return older + latest
    }

    /// `content` cut to its longest prefix that, wrapped with a truncation
    /// marker and the original length, fits in `limit` bytes. With no room
    /// for any of it, the marker alone.
    static func truncatedResult(_ content: String, toAtMost limit: Int) -> String {
        let length = content.utf8.count
        func wrap(_ kept: Substring) -> String {
            JSONValue.object([
                "truncated": .string(
                    "Result cut to fit the request size limit: the first \(kept.utf8.count) of \(length) bytes."),
                "original_length": .number(Double(length)),
                "partial_result": .string(String(kept)),
            ]).jsonString
        }
        func prefix(bytes: Int) -> Substring {
            var used = 0
            var end = content.startIndex
            for index in content.indices {
                used += content[index].utf8.count
                if used > bytes { break }
                end = content.index(after: index)
            }
            return content[..<end]
        }
        var keep = max(0, limit - wrap("").utf8.count)
        while true {
            let wrapped = wrap(prefix(bytes: keep))
            let over = wrapped.utf8.count - limit
            if over <= 0 || keep == 0 { return wrapped }
            keep = max(0, keep - over)
        }
    }

    private func finish(_ end: TurnEnd) -> TurnEnd {
        status = .idle
        return end
    }

    /// Runs one call. Every failure (unknown tool, arguments that are not a
    /// JSON object, a thrown error) becomes `{"error": ...}` for the model.
    private func execute(_ call: LLMToolCall) async -> ChatMessage {
        let result: Result<ChatToolOutput, ChatToolError>
        if let tool = tools[call.name] {
            do {
                let args = try Self.arguments(call.arguments)
                result = .success(try await tool.run(args))
            } catch let error as ChatToolError {
                result = .failure(error)
            } catch {
                result = .failure(ChatToolError(error.localizedDescription))
            }
        } else {
            result = .failure(ChatToolError("Unknown tool: \(call.name)"))
        }
        switch result {
        case .success(let output):
            return ChatMessage(
                role: .tool, content: output.data.jsonString, toolCallId: call.id, toolName: call.name,
                displayText: output.displayText)
        case .failure(let error):
            return Self.errorMessage(for: call, error.message)
        }
    }

    private func answer(_ calls: [LLMToolCall], with message: String) async {
        for call in calls { await add(Self.errorMessage(for: call, message)) }
    }

    private static func errorMessage(for call: LLMToolCall, _ message: String) -> ChatMessage {
        ChatMessage(
            role: .tool, content: JSONValue.object(["error": .string(message)]).jsonString,
            toolCallId: call.id, toolName: call.name, displayText: message, isError: true)
    }

    static func arguments(_ text: String) throws(ChatToolError) -> [String: JSONValue] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let value = try? JSONValue(parsing: text), case .object(let object) = value else {
            throw ChatToolError("The arguments were not a JSON object: \(text)")
        }
        return object
    }

    // MARK: Persistence

    private func ensureConversation(title text: String) async {
        guard conversation == nil else { return }
        let title = String(text.prefix(Self.titleLength))
        if let store {
            do {
                conversation = try await store.createConversation(title: title, now: Date())
                persisted = true
                return
            } catch {
                saveFailed = true
            }
        }
        // Kept in memory only; with a store, the next save creates it.
        let now = Date()
        conversation = ChatConversation(id: UUID(), title: title, createdAt: now, updatedAt: now)
        persisted = false
    }

    /// Tries again to store the messages an earlier save missed. Returns
    /// true when nothing is left unsaved, so the conversation can be left
    /// without losing any of it; false while a turn runs or the save fails.
    /// The session is busy while it saves; a second call meanwhile waits
    /// for the first and gets its answer.
    @discardableResult
    public func retrySave() async -> Bool {
        if let saving { return await saving.value }
        guard !isBusy else { return !saveFailed }
        let task = Task { () -> Bool in
            await self.saveUnsaved()
            return !self.saveFailed
        }
        saving = task
        let saved = await task.value
        saving = nil
        return saved
    }

    private func add(_ message: ChatMessage) async {
        messages.append(message)
        await saveUnsaved()
    }

    /// Saves every message not yet in the store, in order: the one just added
    /// and any an earlier save missed. The first failure stops it,
    /// so nothing after a missing message is stored; the next save retries.
    private func saveUnsaved() async {
        guard let store, var conversation else { return }
        if !persisted {
            // Retries creating a conversation the store did not take.
            do {
                conversation = try await store.createConversation(title: conversation.title, now: conversation.createdAt)
            } catch {
                saveFailed = true
                return
            }
            self.conversation = conversation
            persisted = true
            savedCount = 0
        }
        do {
            while savedCount < messages.count {
                try await store.append(messages[savedCount], to: conversation.id)
                savedCount += 1
            }
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}
