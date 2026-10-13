import Foundation
import Testing

@testable import RtechWhisperKit

/// A scripted model: each request gets the next reply. A reply is the chunks
/// to stream, then an optional error, or `hang` to stream the chunks and
/// then wait until cancelled. Past the script, every request gets `fallback`.
final class FakeChatLLM: LLMChatStreaming, @unchecked Sendable {
    struct Reply: Sendable {
        var chunks: [LLMStreamChunk]
        var error: HubError?
        var hang = false
    }

    private let lock = NSLock()
    private var script: [Reply]
    private let fallback: Reply?
    private var seen: [LLMChatRequest] = []

    init(_ script: [Reply], fallback: Reply? = nil) {
        self.script = script
        self.fallback = fallback
    }

    var requests: [LLMChatRequest] { lock.withLock { seen } }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let reply = lock.withLock { () -> Reply? in
            seen.append(request)
            return script.isEmpty ? fallback : script.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let reply else {
                continuation.finish(throwing: HubError.network("no scripted reply"))
                return
            }
            for chunk in reply.chunks { continuation.yield(chunk) }
            if reply.hang { return }
            if let error = reply.error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    static func text(_ pieces: String...) -> Reply {
        Reply(chunks: pieces.map(LLMStreamChunk.content))
    }

    static func call(_ name: String, _ arguments: String, id: String = "c1") -> Reply {
        Reply(chunks: [.toolCall(LLMToolCallDelta(index: 0, id: id, name: name, arguments: arguments))])
    }
}

/// A tool that records the arguments it got and answers from `answer`.
@MainActor
final class RecordingTool {
    var calls: [[String: JSONValue]] = []
    var answer: ([String: JSONValue]) throws -> ChatToolOutput = { _ in ChatToolOutput(data: .object(["ok": true]), displayText: "ok") }

    func tool(_ name: String, readOnly: Bool = true) -> ChatTool {
        ChatTool(name: name, description: "test tool", parameters: .object(["type": "object"]), readOnly: readOnly) { [self] args in
            calls.append(args)
            return try answer(args)
        }
    }
}

@MainActor
@Suite("Chat session")
struct ChatSessionTests {
    @Test func theToolLoopRunsTheToolTheModelNamedWithItsArguments() async throws {
        let llm = FakeChatLLM([
            FakeChatLLM.call("get_note", #"{"id": "n-7"}"#),
            FakeChatLLM.text("It says ", "hi."),
        ])
        let other = RecordingTool()
        let target = RecordingTool()
        target.answer = { _ in ChatToolOutput(data: .object(["content": "hi"]), displayText: "Retrieved") }
        let session = ChatSession(llm: llm, tools: [other.tool("search_notes"), target.tool("get_note")])

        let end = await session.send("what does n-7 say")

        #expect(end == .answered)
        #expect(target.calls == [["id": .string("n-7")]])
        #expect(other.calls.isEmpty)
        #expect(session.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(session.messages[1].toolCalls == [LLMToolCall(id: "c1", name: "get_note", arguments: #"{"id": "n-7"}"#)])
        #expect(session.messages[2].toolCallId == "c1")
        #expect(session.messages[2].displayText == "Retrieved")
        #expect(session.messages[3].content == "It says hi.")
        #expect(session.status == .idle)

        // The second request hands the call and its result back to the model.
        let second = try #require(llm.requests.last)
        #expect(second.messages.first == .system(session.systemPrompt))
        #expect(second.messages.suffix(2) == [
            LLMMessage(role: .assistant, content: "", toolCalls: [LLMToolCall(id: "c1", name: "get_note", arguments: #"{"id": "n-7"}"#)]),
            LLMMessage(role: .tool, content: #"{"content":"hi"}"#, toolCallId: "c1"),
        ])
        #expect(second.tools?.map(\.name) == ["search_notes", "get_note"])
    }

    @Test func theLoopStopsAtFiveModelCalls() async throws {
        let llm = FakeChatLLM([], fallback: FakeChatLLM.call("search_notes", #"{"query":"x"}"#))
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("search_notes")])

        let end = await session.send("loop forever")

        #expect(end == .stepLimit)
        #expect(ChatSession.maxSteps == 5)
        #expect(llm.requests.count == 5)
        // The fifth call is not run; it is answered as not run, so the
        // history the next turn sends stays valid.
        #expect(tool.calls.count == 4)
        let last = try #require(session.messages.last)
        #expect(last.role == .tool)
        #expect(last.isError)
        #expect(last.content.contains("limit of 5 tool steps"))
        #expect(session.status == .idle)
    }

    @Test func aToolErrorIsHandedToTheModel() async throws {
        let llm = FakeChatLLM([FakeChatLLM.call("get_note", #"{"id":"gone"}"#), FakeChatLLM.text("Not found, dumdum.")])
        let tool = RecordingTool()
        tool.answer = { _ in throw ChatToolError("Note with ID gone not found") }
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")])

        #expect(await session.send("open gone") == .answered)

        let result = try #require(llm.requests.last?.messages.last)
        #expect(result.role == .tool)
        #expect(result.content == #"{"error":"Note with ID gone not found"}"#)
        #expect(session.messages[2].isError)
        #expect(session.messages.last?.content == "Not found, dumdum.")
    }

    @Test func anUnknownToolAndBadArgumentsAreErrorsForTheModel() async throws {
        let llm = FakeChatLLM([
            Reply(chunks: [
                .toolCall(LLMToolCallDelta(index: 0, id: "a", name: "delete_everything", arguments: "{}")),
                .toolCall(LLMToolCallDelta(index: 1, id: "b", name: "get_note", arguments: "not json")),
            ]),
            FakeChatLLM.text("ok"),
        ])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")])

        #expect(await session.send("go") == .answered)

        #expect(tool.calls.isEmpty)
        let results = try #require(llm.requests.last?.messages.filter { $0.role == .tool })
        #expect(results.map(\.toolCallId) == ["a", "b"])
        #expect(results[0].content == #"{"error":"Unknown tool: delete_everything"}"#)
        #expect(results[1].content.contains("not a JSON object"))
    }

    @Test func streamedDeltasAssembleInTheAssistantMessage() async throws {
        let llm = FakeChatLLM([FakeChatLLM.text("Ugh", ", fine", ". Done.")])
        let session = ChatSession(llm: llm)

        #expect(await session.send("  hello  ") == .answered)

        #expect(session.messages.map(\.content) == ["hello", "Ugh, fine. Done."])
        #expect(llm.requests.first?.tools == nil)
    }

    @Test func cancelStopsTheTurnAndKeepsWhatStreamed() async throws {
        let llm = FakeChatLLM([Reply(chunks: [.content("Half an ans")], hang: true)])
        let session = ChatSession(llm: llm)

        let turn = Task { await session.send("long one") }
        while session.messages.last?.content != "Half an ans" { await Task.yield() }
        #expect(session.isBusy)
        session.cancel()

        #expect(await turn.value == .cancelled)
        #expect(session.messages.map(\.content) == ["long one", "Half an ans"])
        #expect(session.status == .idle)
        #expect(!session.isBusy)
    }

    @Test func aStreamErrorFailsTheTurn() async throws {
        let llm = FakeChatLLM([Reply(chunks: [.content("par")], error: .upstreamUnavailable(status: 504))])
        let session = ChatSession(llm: llm)

        #expect(await session.send("hi") == .failed)

        #expect(session.status == .failed(.upstreamUnavailable(status: 504)))
        #expect(session.messages.map(\.content) == ["hi"])
    }

    @Test func blankTextSendsNothing() async throws {
        let llm = FakeChatLLM([])
        let session = ChatSession(llm: llm)
        #expect(await session.send("   ") == nil)
        #expect(llm.requests.isEmpty)
        #expect(session.messages.isEmpty)
    }

    @Test func aConversationRoundTripsThroughTheStore() async throws {
        let store = try ChatStore.inMemory()
        let llm = FakeChatLLM([FakeChatLLM.call("get_note", #"{"id":"n1"}"#), FakeChatLLM.text("Found it.")])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")], store: store)
        await session.send("find n1")
        let id = try #require(session.conversation?.id)

        let reopened = ChatSession(llm: FakeChatLLM([]), tools: [tool.tool("get_note")], store: store)
        try await reopened.open(id)

        #expect(reopened.messages == session.messages)
        #expect(reopened.conversation?.title == "find n1")
        #expect(try await store.conversations().map(\.id) == [id])
        #expect(!session.saveFailed)
    }

    @Test func aSavedCallWithNoResultIsAnsweredBeforeTheNextRequest() async throws {
        // The app quit after the assistant's tool call was saved and before
        // its result was: reopening must not send the call unanswered.
        let store = try ChatStore.inMemory()
        let id = try await store.createConversation(title: "t").id
        let call = LLMToolCall(id: "c9", name: "get_note", arguments: "{}")
        try await store.append(ChatMessage(role: .user, content: "open it"), to: id)
        try await store.append(ChatMessage(role: .assistant, content: "", toolCalls: [call]), to: id)
        let llm = FakeChatLLM([FakeChatLLM.text("ok")])
        let session = ChatSession(llm: llm, store: store)
        try await session.open(id)

        #expect(await session.send("again") == .answered)

        let sent = try #require(llm.requests.first?.messages)
        #expect(sent.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(sent[3].toolCallId == "c9")
        #expect(sent[3].content.contains("Outcome unknown"))
        #expect(!sent[3].content.contains("Not run"))
    }

    @Test func historyLeavesAnsweredCallsAlone() {
        let call = LLMToolCall(id: "a", name: "x", arguments: "{}")
        let messages = [
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "{}", toolCallId: "a", toolName: "x"),
            ChatMessage(role: .assistant, content: "done"),
        ]
        #expect(ChatSession.history(messages) == messages.map(\.llmMessage))
    }

    @Test func theDefaultPromptIsTheDesktopPersonaWithToolLines() {
        let prompt = ChatPrompt.system(tools: ["search_notes", "list_folders"])
        #expect(prompt.hasPrefix("You are Skippy the Magnificent"))
        #expect(prompt.hasPrefix(ChatPrompt.persona + "\n\nYou have access to tools. Use search_notes"))
        #expect(prompt.hasSuffix(ChatPrompt.toolInstructions["list_folders"]!))
        #expect(ChatPrompt.system(tools: []) == ChatPrompt.persona)
    }
}

/// A chat store whose createConversation fails while `failCreates` is above
/// zero, and whose append calls fail when their number (0-based) is in
/// `failAppends` or at least `failAppendsFrom`; everything else goes to a
/// real in-memory store.
final class FlakyChatStore: ChatPersisting, @unchecked Sendable {
    let base: ChatStore
    private let lock = NSLock()
    private var failCreates: Int
    private let failAppends: Set<Int>
    private let failAppendsFrom: Int
    private var appends = 0

    init(failCreates: Int = 0, failAppends: Set<Int> = [], failAppendsFrom: Int = .max) throws {
        base = try ChatStore.inMemory()
        self.failCreates = failCreates
        self.failAppends = failAppends
        self.failAppendsFrom = failAppendsFrom
    }

    func createConversation(title: String, now: Date) async throws -> ChatConversation {
        let fail = lock.withLock { () -> Bool in
            defer { failCreates -= 1 }
            return failCreates > 0
        }
        if fail { throw ChatStoreError.conversationNotFound(UUID()) }
        return try await base.createConversation(title: title, now: now)
    }

    func conversation(_ id: UUID) async throws -> ChatConversation? { try await base.conversation(id) }
    func messages(in id: UUID) async throws -> [ChatMessage] { try await base.messages(in: id) }
    func append(_ message: ChatMessage, to id: UUID) async throws {
        let fail = lock.withLock { () -> Bool in
            defer { appends += 1 }
            return failAppends.contains(appends) || appends >= failAppendsFrom
        }
        if fail { throw ChatStoreError.saveFailed }
        try await base.append(message, to: id)
    }
}

@MainActor
@Suite("Chat session limits and recovery")
struct ChatSessionReviewFixTests {
    @Test func aFailedCreateIsRetriedAndTheWholeConversationIsSaved() async throws {
        // Fails the create and both saves of the first turn.
        let store = try FlakyChatStore(failCreates: 3)
        let llm = FakeChatLLM([FakeChatLLM.text("one"), FakeChatLLM.text("two")])
        let session = ChatSession(llm: llm, store: store)

        await session.send("first")
        #expect(session.saveFailed)

        await session.send("second")
        let id = try #require(session.conversation?.id)
        #expect(try await store.base.conversation(id)?.title == "first")
        #expect(try await store.base.messages(in: id).map(\.content) == ["first", "one", "second", "two"])
        #expect(!session.saveFailed)
    }

    @Test func aNewConversationClearsSaveFailed() async throws {
        let store = try FlakyChatStore(failCreates: 5)
        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("ok")]), store: store)
        await session.send("hi")
        #expect(session.saveFailed)
        session.startNewConversation()
        #expect(!session.saveFailed)
    }

    @Test func theUnsentDraftStaysWithItsConversation() async throws {
        let store = try ChatStore.inMemory()
        let first = try await store.createConversation(title: "first")
        let second = try await store.createConversation(title: "second")
        let session = ChatSession(llm: FakeChatLLM([]), store: store)

        try await session.open(first.id)
        session.draft = "half a thought"
        // Back and in again to the same chat: the screen is new, the text is not.
        try await session.open(first.id)
        #expect(session.draft == "half a thought")

        try await session.open(second.id)
        #expect(session.draft == "")
        session.draft = "for nobody"
        session.startNewConversation()
        #expect(session.draft == "")
    }

    @Test func aTakeThatFinishesInAnotherChatIsDropped() async throws {
        let store = try ChatStore.inMemory()
        let first = try await store.createConversation(title: "first")
        let second = try await store.createConversation(title: "second")
        let session = ChatSession(llm: FakeChatLLM([]), store: store)

        // Same chat, even after Back and in again: the take is appended.
        try await session.open(first.id)
        session.draft = "typed"
        var generation = session.draftGeneration
        try await session.open(first.id)
        #expect(session.appendDictation("spoken", generation: generation))
        #expect(session.draft == "typed spoken")

        // Recorded in the first chat, finished after the second opened.
        generation = session.draftGeneration
        try await session.open(second.id)
        #expect(!session.appendDictation("for first", generation: generation))
        #expect(session.draft == "")

        // Recorded in a new chat, finished after another new chat started.
        session.startNewConversation()
        generation = session.draftGeneration
        session.startNewConversation()
        #expect(!session.appendDictation("for the old new one", generation: generation))
        #expect(session.draft == "")
    }

    @Test func fitDropsOldToolResultsBeforeWholeExchanges() {
        let big = String(repeating: "x", count: 5_000)
        let call = LLMToolCall(id: "a", name: "get_note", arguments: "{}")
        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: "open it"),
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: big, toolCallId: "a"),
            LLMMessage(role: .assistant, content: "done"),
            LLMMessage(role: .user, content: "and now?"),
        ]
        let fitted = ChatSession.fit(history, budget: 1_000)
        #expect(fitted.count == history.count)
        #expect(fitted[2].content == ChatSession.droppedResult)
        #expect(fitted[2].toolCallId == "a")
        #expect(ChatSession.fit(history, budget: 100_000) == history)
    }

    @Test func fitDropsOldestExchangesAtAUserMessage() {
        let long = String(repeating: "y", count: 2_000)
        let call = LLMToolCall(id: "a", name: "x", arguments: "{}")
        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: long),
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: "{}", toolCallId: "a"),
            LLMMessage(role: .assistant, content: long),
            LLMMessage(role: .user, content: "latest"),
        ]
        #expect(ChatSession.fit(history, budget: 500) == [LLMMessage(role: .user, content: "latest")])
    }

    @Test func aRequestAfterAHugeNoteStaysUnderTheBudget() async throws {
        let body = String(repeating: "z", count: 50_000)
        let llm = FakeChatLLM([
            FakeChatLLM.call("get_note", #"{"id":"n"}"#), FakeChatLLM.text("read it"), FakeChatLLM.text("sure"),
        ])
        let tool = RecordingTool()
        tool.answer = { _ in ChatToolOutput(data: .object(["content": .string(body)]), displayText: "Retrieved") }
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")], systemPrompt: "s", requestBudget: 10_000)

        #expect(await session.send("open n") == .answered)
        #expect(await session.send("thanks") == .answered)

        for request in llm.requests {
            let bytes = request.messages.reduce(0) { $0 + $1.content.utf8.count }
            #expect(bytes <= 10_000)
        }
        // The model still sees every call answered.
        // The step that reads the note sees its start, cut short, not an error.
        let reading = try #require(llm.requests.dropFirst().first?.messages.last)
        #expect(reading.role == .tool)
        #expect(reading.content != ChatSession.droppedResult)
        #expect(reading.content.contains("\"original_length\""))
        #expect(reading.content.contains(String(repeating: "z", count: 1_000)))
        let last = try #require(llm.requests.last)
        #expect(last.messages.filter { $0.role == .tool }.map(\.toolCallId) == ["c1"])
    }
}

private typealias Reply = FakeChatLLM.Reply

/// A chat store whose `conversation(_:)` waits until `release()` is called,
/// so a test can act while `ChatSession.open` is suspended on it.
final class GatedChatStore: ChatPersisting, @unchecked Sendable {
    let base: ChatStore
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation

    init() throws {
        base = try ChatStore.inMemory()
        (entered, enteredContinuation) = AsyncStream.makeStream()
        (gate, gateContinuation) = AsyncStream.makeStream()
    }

    func release() { gateContinuation.yield() }

    func createConversation(title: String, now: Date) async throws -> ChatConversation {
        try await base.createConversation(title: title, now: now)
    }

    func conversation(_ id: UUID) async throws -> ChatConversation? {
        enteredContinuation.yield()
        for await _ in gate { break }
        return try await base.conversation(id)
    }

    func messages(in id: UUID) async throws -> [ChatMessage] { try await base.messages(in: id) }
    func append(_ message: ChatMessage, to id: UUID) async throws { try await base.append(message, to: id) }
}

@MainActor
@Suite("Chat session sol review fixes")
struct ChatSessionSolReviewFixTests {
    @Test func fitKeepsAFreshResultWhenAnOldExchangeIsWhatIsOver() {
        let long = String(repeating: "y", count: 2_000)
        let fresh = String(repeating: "r", count: 300)
        let call = LLMToolCall(id: "b", name: "get_note", arguments: "{}")
        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: long),
            LLMMessage(role: .assistant, content: long),
            LLMMessage(role: .user, content: "open it"),
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: fresh, toolCallId: "b"),
        ]
        let fitted = ChatSession.fit(history, budget: 1_000)
        #expect(fitted == Array(history[2...]))
    }

    @Test func fitCutsAHugeLatestResultShortInsteadOfDroppingIt() throws {
        let body = String(repeating: "é", count: 40_000)
        let call = LLMToolCall(id: "a", name: "get_note", arguments: "{}")
        let history: [LLMMessage] = [
            LLMMessage(role: .user, content: "open it"),
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: body, toolCallId: "a"),
        ]
        let fitted = ChatSession.fit(history, budget: 5_000)
        let total = fitted.reduce(0) { total, message in
            total + message.content.utf8.count
                + (message.toolCalls ?? []).reduce(0) { $0 + $1.id.utf8.count + $1.name.utf8.count + $1.arguments.utf8.count }
        }
        #expect(total <= 5_000)
        #expect(fitted.count == 3)
        let result = fitted[2]
        #expect(result.toolCallId == "a")
        #expect(result.content != ChatSession.droppedResult)
        let parsed = try JSONValue(parsing: result.content)
        guard case .object(let object) = parsed, case .string(let partial)? = object["partial_result"] else {
            Issue.record("not a truncation marker: \(result.content)")
            return
        }
        #expect(object["original_length"] == .number(Double(body.utf8.count)))
        #expect(partial.count > 1_000)
        #expect(body.hasPrefix(partial))
    }

    @Test func aSendWhileOpenIsLoadingDoesNothing() async throws {
        let store = try GatedChatStore()
        let saved = try await store.base.createConversation(title: "saved", now: Date())
        try await store.base.append(ChatMessage(role: .user, content: "old"), to: saved.id)
        let llm = FakeChatLLM([], fallback: FakeChatLLM.text("reply"))
        let session = ChatSession(llm: llm, store: store)

        let opening = Task { try await session.open(saved.id) }
        for await _ in store.entered { break }
        #expect(session.isBusy)
        #expect(await session.send("new") == nil)
        store.release()
        try await opening.value

        #expect(session.conversation?.id == saved.id)
        #expect(session.messages.map(\.content) == ["old"])
        #expect(llm.requests.isEmpty)
        #expect(!session.isBusy)
    }
}

@MainActor
@Suite("Chat session r3 review fixes")
struct ChatSessionR3ReviewFixTests {
    @Test func aReplyCutOffAtTheLengthLimitIsMarkedAndItsCallsAreNotRun() async throws {
        let llm = FakeChatLLM([Reply(chunks: [
            .content("The answer is"),
            .toolCall(LLMToolCallDelta(index: 0, id: "c1", name: "get_note", arguments: #"{"id":"n"}"#)),
            .finish(reason: "length"),
        ])])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")])

        #expect(await session.send("tell me") == .truncated)

        #expect(tool.calls.isEmpty)
        #expect(llm.requests.count == 1)
        let reply = try #require(session.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.toolCalls.isEmpty)
        #expect(reply.content == "The answer is\n\n" + ChatSession.truncationMarker)
        #expect(session.status == .truncated)
    }

    @Test func aNormalFinishReasonStillAnswers() async throws {
        let llm = FakeChatLLM([Reply(chunks: [.content("Done."), .finish(reason: "stop")])])
        let session = ChatSession(llm: llm)
        #expect(await session.send("hi") == .answered)
        #expect(session.messages.last?.content == "Done.")
        #expect(session.status == .idle)
    }

    @Test func aWriteWhoseResultWasNeverSavedIsNotReportedAsNotRun() async throws {
        // create_note ran, then every save from its result on failed; the
        // reopened conversation must not tell the model the note was never made.
        let store = try FlakyChatStore(failAppendsFrom: 2)
        let llm = FakeChatLLM([FakeChatLLM.call("create_note", #"{"title":"t","content":"c"}"#), FakeChatLLM.text("Made it.")])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("create_note", readOnly: false)], store: store)
        #expect(await session.send("make a note") == .answered)
        #expect(tool.calls.count == 1)
        #expect(session.saveFailed)
        let id = try #require(session.conversation?.id)
        #expect(try await store.base.messages(in: id).map(\.role) == [.user, .assistant])

        let next = FakeChatLLM([FakeChatLLM.text("ok")])
        let reopened = ChatSession(llm: next, tools: [tool.tool("create_note", readOnly: false)], store: store.base)
        try await reopened.open(id)
        #expect(await reopened.send("again") == .answered)

        let sent = try #require(next.requests.first?.messages)
        #expect(sent.map(\.role) == [.system, .user, .assistant, .tool, .user])
        #expect(sent[3].content.contains("Outcome unknown"))
        #expect(sent[3].content.contains("search_notes"))
        #expect(!sent[3].content.contains("Not run"))
    }

    @Test func historyDropsAToolResultWhoseCallIsMissing() {
        let call = LLMToolCall(id: "a", name: "x", arguments: "{}")
        let messages = [
            ChatMessage(role: .user, content: "u"),
            ChatMessage(role: .tool, content: "{}", toolCallId: "lost", toolName: "x"),
            ChatMessage(role: .assistant, content: "", toolCalls: [call]),
            ChatMessage(role: .tool, content: "{}", toolCallId: "a", toolName: "x"),
            ChatMessage(role: .tool, content: "{}", toolCallId: "stray", toolName: "x"),
            ChatMessage(role: .assistant, content: "done"),
        ]
        #expect(ChatSession.history(messages) == [messages[0], messages[2], messages[3], messages[5]].map(\.llmMessage))
    }

    @Test func aFailedAppendIsRetriedInOrderSoNoMessageIsLost() async throws {
        // Creating fails twice, then the first append after the create fails:
        // the store still ends with every message, in order.
        let store = try FlakyChatStore(failCreates: 2, failAppends: [1])
        let llm = FakeChatLLM([FakeChatLLM.text("one"), FakeChatLLM.text("two")])
        let session = ChatSession(llm: llm, store: store)

        await session.send("first")
        #expect(session.saveFailed)
        await session.send("second")

        let id = try #require(session.conversation?.id)
        #expect(try await store.base.messages(in: id).map(\.content) == ["first", "one", "second", "two"])
        #expect(!session.saveFailed)
    }

    @Test func aLostToolCallMessageDoesNotLeaveAnOrphanResultAfterReopen() async throws {
        // The assistant message carrying the tool call fails to save; its
        // result must not be stored ahead of it.
        let store = try FlakyChatStore(failAppends: [1])
        let llm = FakeChatLLM([FakeChatLLM.call("get_note", #"{"id":"n"}"#), FakeChatLLM.text("Read it.")])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("get_note")], store: store)
        #expect(await session.send("read n") == .answered)
        let id = try #require(session.conversation?.id)

        let next = FakeChatLLM([FakeChatLLM.text("ok")])
        let reopened = ChatSession(llm: next, tools: [tool.tool("get_note")], store: store.base)
        try await reopened.open(id)
        #expect(await reopened.send("and?") == .answered)

        let sent = try #require(next.requests.first?.messages)
        #expect(sent.map(\.role) == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(sent[2].toolCalls?.map(\.id) == ["c1"])
        #expect(sent[3].toolCallId == "c1")
    }
}

@MainActor
@Suite("Chat session r4 review fixes")
struct ChatSessionR4ReviewFixTests {
    @Test func aWriteWhoseRequestWasNotSavedIsNotRun() async throws {
        // The assistant message carrying create_note fails to save: running
        // it would leave a note the reopened conversation knows nothing of.
        let store = try FlakyChatStore(failAppends: [1])
        let llm = FakeChatLLM([FakeChatLLM.call("create_note", #"{"title":"t","content":"c"}"#), FakeChatLLM.text("Could not.")])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("create_note", readOnly: false)], store: store)
        #expect(await session.send("make a note") == .answered)
        #expect(tool.calls.isEmpty)
        let result = try #require(session.messages.first { $0.role == .tool })
        #expect(result.isError)
        #expect(result.content.contains("Not run: the request could not be saved"))
    }

    @Test func aWriteRunsWithNoStore() async throws {
        let llm = FakeChatLLM([FakeChatLLM.call("create_note", #"{"title":"t","content":"c"}"#), FakeChatLLM.text("Made it.")])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("create_note", readOnly: false)])
        #expect(await session.send("make a note") == .answered)
        #expect(tool.calls.count == 1)
    }
}

@MainActor
@Suite("Chat session D16 fixes")
struct ChatSessionD16Tests {
    @Test func retryRerunsAFailedTurnWithoutAnotherUserMessage() async throws {
        let store = try ChatStore.inMemory()
        let llm = FakeChatLLM([Reply(chunks: [], error: .network("offline")), FakeChatLLM.text("Hello.")])
        let session = ChatSession(llm: llm, store: store)
        #expect(await session.send("hi") == .failed)

        #expect(await session.retry() == .answered)

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages.map(\.content) == ["hi", "Hello."])
        let id = try #require(session.conversation?.id)
        #expect(try await store.messages(in: id).map(\.content) == ["hi", "Hello."])
        #expect(llm.requests.last?.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func aFailedStepKeepsNoPartialReply() async throws {
        let store = try ChatStore.inMemory()
        let llm = FakeChatLLM([Reply(chunks: [.content("Here is a summ")], error: .network("offline"))])
        let session = ChatSession(llm: llm, store: store)

        #expect(await session.send("hi") == .failed)

        #expect(session.messages.map(\.content) == ["hi"])
        let id = try #require(session.conversation?.id)
        #expect(try await store.messages(in: id).map(\.content) == ["hi"])
        #expect(!session.saveFailed)
    }

    @Test func retryAfterAPartialReplyGivesOneUserMessageAndOneReply() async throws {
        let store = try ChatStore.inMemory()
        let llm = FakeChatLLM([
            Reply(chunks: [.content("Here is a summ")], error: .network("offline")),
            FakeChatLLM.text("Here is a summary."),
        ])
        let session = ChatSession(llm: llm, store: store)
        #expect(await session.send("hi") == .failed)
        #expect(session.messages.map(\.role) == [.user])

        #expect(await session.retry() == .answered)

        #expect(session.messages.map(\.role) == [.user, .assistant])
        #expect(session.messages.map(\.content) == ["hi", "Here is a summary."])
        let id = try #require(session.conversation?.id)
        #expect(try await store.messages(in: id).map(\.content) == ["hi", "Here is a summary."])
        let sent = try #require(llm.requests.last?.messages)
        #expect(!sent.contains { $0.role == .assistant })
    }

    @Test func aFailureAfterAToolStepKeepsTheMessageWithTheToolCalls() async throws {
        let store = try ChatStore.inMemory()
        let llm = FakeChatLLM([
            FakeChatLLM.call("search_notes", #"{"query":"x"}"#),
            Reply(chunks: [.content("Found it, the note s")], error: .network("offline")),
            FakeChatLLM.text("Found it."),
        ])
        let tool = RecordingTool()
        let session = ChatSession(llm: llm, tools: [tool.tool("search_notes")], store: store)

        #expect(await session.send("find x") == .failed)

        #expect(session.messages.map(\.role) == [.user, .assistant, .tool])
        #expect(session.messages[1].toolCalls.map(\.name) == ["search_notes"])
        let id = try #require(session.conversation?.id)
        let stored = try await store.messages(in: id)
        #expect(stored.map(\.role) == [.user, .assistant, .tool])
        #expect(stored[1].toolCalls.map(\.name) == ["search_notes"])

        #expect(await session.retry() == .answered)
        #expect(tool.calls.count == 1)
        #expect(session.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(try await store.messages(in: id).map(\.role) == [.user, .assistant, .tool, .assistant])
    }

    @Test func aSecondRetrySaveWaitsForTheFirst() async throws {
        let store = try SlowAppendChatStore()
        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("ok")]), store: store)
        await session.send("hi")
        #expect(session.saveFailed)
        store.slowDown()

        let first = Task { await session.retrySave() }
        while store.waiting == 0 { await Task.yield() }
        #expect(session.isBusy)
        let second = Task { await session.retrySave() }
        for _ in 0..<200 { await Task.yield() }
        store.release()

        #expect(await first.value)
        #expect(await second.value)
        #expect(!session.saveFailed)
        #expect(!session.isBusy)
        let id = try #require(session.conversation?.id)
        #expect(try await store.base.messages(in: id).map(\.content) == ["hi", "ok"])
    }

    @Test func retryDoesNothingUnlessTheLastTurnFailed() async throws {
        let llm = FakeChatLLM([FakeChatLLM.text("Hello.")])
        let session = ChatSession(llm: llm)
        #expect(await session.retry() == nil)
        await session.send("hi")
        #expect(await session.retry() == nil)
        #expect(llm.requests.count == 1)
    }

    @Test func retrySaveStoresTheUnsavedTail() async throws {
        // The user message's append fails, then its retry after the reply.
        let store = try FlakyChatStore(failAppends: [0, 1])
        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("ok")]), store: store)
        await session.send("hi")
        #expect(session.saveFailed)

        #expect(await session.retrySave())

        #expect(!session.saveFailed)
        let id = try #require(session.conversation?.id)
        #expect(try await store.base.messages(in: id).map(\.content) == ["hi", "ok"])
    }

    @Test func retrySaveReportsAStoreThatStillFails() async throws {
        let store = try FlakyChatStore(failAppendsFrom: 0)
        let session = ChatSession(llm: FakeChatLLM([FakeChatLLM.text("ok")]), store: store)
        await session.send("hi")

        #expect(await session.retrySave() == false)
        #expect(session.saveFailed)
    }
}

/// A chat store whose appends fail until `slowDown()`, then wait until
/// `release()`, so a test can act while a save is suspended on the store.
final class SlowAppendChatStore: ChatPersisting, @unchecked Sendable {
    let base: ChatStore
    private let lock = NSLock()
    private var failing = true
    private var held = false
    private var released = false
    private var inAppend = 0

    init() throws { base = try ChatStore.inMemory() }

    /// Appends waiting on `release()` right now.
    var waiting: Int { lock.withLock { inAppend } }
    func slowDown() { lock.withLock { failing = false; held = true } }
    func release() { lock.withLock { released = true } }

    func createConversation(title: String, now: Date) async throws -> ChatConversation {
        try await base.createConversation(title: title, now: now)
    }
    func conversation(_ id: UUID) async throws -> ChatConversation? { try await base.conversation(id) }
    func messages(in id: UUID) async throws -> [ChatMessage] { try await base.messages(in: id) }
    func append(_ message: ChatMessage, to id: UUID) async throws {
        let (fail, hold) = lock.withLock { (failing, held) }
        if fail { throw ChatStoreError.saveFailed }
        if hold {
            lock.withLock { inAppend += 1 }
            while !lock.withLock({ released }) { await Task.yield() }
            lock.withLock { inAppend -= 1 }
        }
        try await base.append(message, to: id)
    }
}
