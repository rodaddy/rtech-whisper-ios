import Foundation
import Testing

@testable import RtechWhisperKit

/// Holds each completion until `release()` (or until the calling task is
/// cancelled), then answers `reply`. Records the requests.
private final class GatedLLM: LLMCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [LLMChatRequest] = []
    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    let reply: String

    init(reply: String) {
        self.reply = reply
        (gate, opener) = AsyncStream.makeStream()
    }

    var requests: [LLMChatRequest] { lock.withLock { sent } }

    func release() { opener.yield() }

    func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        lock.withLock { sent.append(request) }
        for await _ in gate { break }
        return LLMChatCompletion(content: reply, finishReason: "stop")
    }
}

@MainActor
private struct ActionRig {
    let hub = FakeSyncHub()
    let store: NotesStore
    let notes: NotesViewModel
    let runner: NoteActionRunner

    init(llm: any LLMCompleting) throws {
        store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore())
        notes = NotesViewModel(store: store, engine: engine, canSync: { true }, syncDelay: nil)
        runner = NoteActionRunner(notes: notes, llm: llm, model: "test-model")
    }

    func stored(_ clientId: String) async throws -> NoteRecord? {
        try await store.notes().first { $0.clientId == clientId }
    }
}

/// Lets the runner's task reach the relay call.
@MainActor
private func waitForRequest(_ llm: GatedLLM) async {
    while llm.requests.isEmpty { await Task.yield() }
}

@Suite("Note actions")
@MainActor
struct NoteActionTests {
    private let raw = "um so the plan is ship friday and uh tell sam"

    @Test func theCatalogIsTheDesktopBuiltIn() {
        #expect(NoteAction.builtIn.map(\.name) == ["Generate Notes"])
        #expect(NoteAction.generateNotes.systemPrompt.hasPrefix("You are a note enhancement assistant."))
        #expect(NoteAction.generateNotes.systemPrompt.contains(
            "Bias toward brevity.\n\nInstructions: Transform the provided content into clean, well-structured notes in markdown."))
    }

    @Test func sendsTheDesktopPromptAndTheNoteText() async throws {
        let llm = FakeLLM(reply: "The plan")
        let rig = try ActionRig(llm: llm)
        let note = try await rig.notes.create(content: raw)
        await rig.runner.run(.generateNotes, on: note.clientId)?.value

        let request = try #require(llm.requests.first)
        #expect(llm.requests.count == 1)
        #expect(request.model == "test-model")
        #expect(request.temperature == 0.3)
        #expect(request.messages == [.system(NoteAction.generateNotes.systemPrompt), .user(raw)])
    }

    @Test func theAnswerGoesToTheSyncedEnhancementAndTheTextStays() async throws {
        let rig = try ActionRig(llm: FakeLLM(reply: "<think>hmm</think>\n- Ship Friday\n- Tell Sam\n"))
        let note = try await rig.notes.create(content: raw, transcript: "the take")
        await rig.notes.syncNow()
        #expect(try await rig.stored(note.clientId)?.syncStatus == .synced)

        await rig.runner.run(.generateNotes, on: note.clientId)?.value

        let stored = try #require(try await rig.stored(note.clientId))
        #expect(stored.content == raw)
        #expect(stored.enhancement == NoteEnhancement(
            content: "- Ship Friday\n- Tell Sam", prompt: NoteAction.generateNotes.prompt,
            contentHash: NoteEnhancement.contentHash(content: raw, transcript: "the take")))
        #expect(!stored.enhancementIsOutdated)
        #expect(stored.syncStatus == .pending)
        #expect(rig.runner.state == .idle)
        #expect(rig.runner.lastApplied?.previous == nil)

        // It reaches the hub as the note's enhanced fields, content unchanged.
        await rig.notes.syncNow()
        let pushed = try #require(await rig.hub.noteUpdates.last)
        #expect(pushed.content == raw)
        #expect(pushed.enhancedContent == "- Ship Friday\n- Tell Sam")
        #expect(pushed.enhancementPrompt == NoteAction.generateNotes.prompt)
        #expect(pushed.enhancedAtContentHash == stored.enhancedAtContentHash)
    }

    @Test func undoClearsTheEnhancementAndSyncsTheClear() async throws {
        let rig = try ActionRig(llm: FakeLLM(reply: "- Ship Friday"))
        let note = try await rig.notes.create(content: raw)
        await rig.notes.syncNow()
        await rig.runner.run(.generateNotes, on: note.clientId)?.value
        #expect(rig.runner.canUndo(note.clientId))

        try await rig.runner.undo()

        let stored = try #require(try await rig.stored(note.clientId))
        #expect(stored.content == raw)
        #expect(stored.enhancement == nil)
        #expect(!rig.runner.canUndo(note.clientId))
        // A clear goes out as empty fields: a nil field is left out of the PATCH.
        await rig.notes.syncNow()
        let pushed = try #require(await rig.hub.noteUpdates.last)
        #expect(pushed.enhancedContent == "")
    }

    @Test func undoPutsThePreviousEnhancementBack() async throws {
        let rig = try ActionRig(llm: FakeLLM(reply: "- Ship Friday"))
        let note = try await rig.notes.create(content: raw)
        let earlier = NoteEnhancement(content: "from the Mac", prompt: "p", contentHash: "h")
        _ = try await rig.notes.enhance(note.clientId, to: earlier, expecting: nil)
        await rig.runner.run(.generateNotes, on: note.clientId)?.value
        #expect(try await rig.stored(note.clientId)?.enhancement?.content == "- Ship Friday")

        try await rig.runner.undo()

        #expect(try await rig.stored(note.clientId)?.enhancement == earlier)
    }

    @Test func editingTheTextKeepsUndoAndMarksTheEnhancementOutdated() async throws {
        let rig = try ActionRig(llm: FakeLLM(reply: "- Ship Friday"))
        let note = try await rig.notes.create(content: raw)
        await rig.runner.run(.generateNotes, on: note.clientId)?.value
        rig.notes.edit(note.clientId, content: raw + " and book the room")
        await rig.notes.flushEdits()

        #expect(rig.runner.canUndo(note.clientId))
        #expect(try await rig.stored(note.clientId)?.enhancementIsOutdated == true)
        try await rig.runner.undo()
        let stored = try #require(try await rig.stored(note.clientId))
        #expect(stored.content == raw + " and book the room")
        #expect(stored.enhancement == nil)
    }

    @Test func undoAfterANewerEnhancementChangesNothing() async throws {
        let rig = try ActionRig(llm: FakeLLM(reply: "- Ship Friday"))
        let note = try await rig.notes.create(content: raw)
        await rig.runner.run(.generateNotes, on: note.clientId)?.value
        let applied = try #require(rig.runner.lastApplied?.applied)
        let mac = NoteEnhancement(content: "the Mac's", prompt: "p", contentHash: "h")
        _ = try await rig.store.enhanceNote(clientId: note.clientId, to: mac, expecting: applied)
        await rig.notes.reload()
        #expect(!rig.runner.canUndo(note.clientId))

        await #expect(throws: NoteActionError.noteChanged) { try await rig.runner.undo() }
        #expect(try await rig.stored(note.clientId)?.enhancement == mac)
    }

    @Test func theContentHashIsTheDesktops() {
        // makeContentHash(`${content}\n${transcript}`): UTF-16 length, "-", first 50 units.
        #expect(NoteEnhancement.contentHash(content: "abc", transcript: nil) == "4-abc\n")
        #expect(NoteEnhancement.contentHash(content: "hi", transcript: "yo") == "5-hi\nyo")
        let long = String(repeating: "x", count: 60)
        #expect(NoteEnhancement.contentHash(content: long, transcript: nil) == "61-" + String(repeating: "x", count: 50))
        #expect(NoteEnhancement.contentHash(content: "é😀", transcript: nil) == "4-é😀\n")
    }

    @Test func cancelLeavesTheNoteUnchanged() async throws {
        let llm = GatedLLM(reply: "- Ship Friday")
        let rig = try ActionRig(llm: llm)
        let note = try await rig.notes.create(content: raw)
        let run = rig.runner.run(.generateNotes, on: note.clientId)
        await waitForRequest(llm)
        #expect(rig.runner.state == .running(clientId: note.clientId, actionName: "Generate Notes"))

        rig.runner.cancel()
        llm.release()
        await run?.value

        #expect(try await rig.stored(note.clientId)?.content == raw)
        #expect(try await rig.stored(note.clientId)?.enhancement == nil)
        #expect(rig.runner.state == .idle)
        #expect(rig.runner.lastApplied == nil)
    }

    @Test func aNoteChangedDuringTheRunIsNotOverwritten() async throws {
        let llm = GatedLLM(reply: "- Ship Friday")
        let rig = try ActionRig(llm: llm)
        let note = try await rig.notes.create(content: raw)
        let run = rig.runner.run(.generateNotes, on: note.clientId)
        await waitForRequest(llm)
        // Another device's edit lands while the model works.
        _ = try await rig.store.editNote(clientId: note.clientId, content: "edited on the Mac")

        llm.release()
        await run?.value

        #expect(try await rig.stored(note.clientId)?.content == "edited on the Mac")
        #expect(try await rig.stored(note.clientId)?.enhancement == nil)
        #expect(rig.runner.state == .failed(clientId: note.clientId, .noteChanged))
    }

    @Test func aRelayFailureOrACutOffAnswerLeavesTheNote() async throws {
        for llm in [FakeLLM(error: .upstreamUnavailable(status: 502)), FakeLLM(reply: "- Ship", finishReason: "length"), FakeLLM(reply: "  ")] {
            let rig = try ActionRig(llm: llm)
            let note = try await rig.notes.create(content: raw)
            await rig.runner.run(.generateNotes, on: note.clientId)?.value
            #expect(try await rig.stored(note.clientId)?.content == raw)
            #expect(try await rig.stored(note.clientId)?.enhancement == nil)
            #expect(rig.runner.lastApplied == nil)
            guard case .failed = rig.runner.state else {
                Issue.record("expected a failure, got \(rig.runner.state)")
                continue
            }
        }
    }

    @Test func anEmptyNoteNeverCallsTheRelay() async throws {
        let llm = FakeLLM(reply: "made up")
        let rig = try ActionRig(llm: llm)
        let note = try await rig.notes.create(content: "  \n")
        await rig.runner.run(.generateNotes, on: note.clientId)?.value
        #expect(llm.requests.isEmpty)
        #expect(rig.runner.state == .failed(clientId: note.clientId, .emptyNote))
    }
}
