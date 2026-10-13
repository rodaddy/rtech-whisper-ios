import Foundation
import Testing

@testable import RtechWhisperKit

private func fresh() -> Result<Transcript, HubError> {
    .success(Transcript(text: "um so hello there", noSpeech: false))
}

/// A cleanup that answers from a script and can be held open by the test.
private final class GatedCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    let reply: String

    init(reply: String) { self.reply = reply }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func clean(_ raw: String) async -> String {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return reply
    }
}

@MainActor
@Suite("AI settings store")
struct AISettingsStoreTests {
    private func defaults() -> UserDefaults {
        let name = "AISettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchTheDesktopAllOn() {
        let store = AISettingsStore(defaults: defaults())
        #expect(store.useCleanupModel)
        #expect(store.removeFillerWords)
        #expect(store.autoGenerateTitle)
        #expect(store.model == "qwen3-4b-instruct")
        #expect(store.cleanupSettings() == CleanupSettings())
    }

    @Test func togglesPersistAcrossInstances() {
        let defaults = defaults()
        let store = AISettingsStore(defaults: defaults)
        store.useCleanupModel = false
        store.autoGenerateTitle = false
        let again = AISettingsStore(defaults: defaults)
        #expect(!again.useCleanupModel)
        #expect(again.removeFillerWords)
        #expect(!again.autoGenerateTitle)
        #expect(again.cleanupSettings() == CleanupSettings(useCleanupModel: false))
        again.removeFillerWords = false
        #expect(again.cleanupSettings() == CleanupSettings(useCleanupModel: false, removeFillerWords: false))
    }
}

@Suite("Dictation post-processor")
struct DictationPostProcessorTests {
    @Test func pairsTheCleanedTextWithTheRaw() async {
        let processor = DictationPostProcessor(clean: { _ in "Hello there." })
        let processed = await processor.process("um so hello there")
        #expect(processed == ProcessedDictation(text: "Hello there.", rawText: "um so hello there"))
        #expect(processed.wasCleaned)
    }

    @Test func anEmptyCleanupKeepsTheRawText() async {
        let processed = await DictationPostProcessor(clean: { _ in "" }).process("hello")
        #expect(processed.text == "hello")
        #expect(!processed.wasCleaned)
    }

    @Test func readsTheSettingsPerCall() async throws {
        let llm = FakeLLM(reply: "Cleaned")
        let box = SettingsBox(CleanupSettings())
        let processor = DictationPostProcessor(llm: llm, settings: { box.value })
        #expect(await processor.process("um hello").text == "Cleaned")
        box.value = CleanupSettings(useCleanupModel: false)
        #expect(await processor.process("um hello").text == "Hello")
        #expect(llm.requests.count == 1)
    }

    @Test func aModelFailureFallsBackToTheRawWithoutFillers() async {
        let processor = DictationPostProcessor(llm: FakeLLM(error: .unauthorized), settings: { CleanupSettings() })
        let processed = await processor.process("um, hello")
        #expect(processed == ProcessedDictation(text: "Hello", rawText: "um, hello", cleanupFailed: true))
    }
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CleanupSettings
    init(_ value: CleanupSettings) { stored = value }
    var value: CleanupSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
@Suite("Dictation cleanup in the controller")
struct DictationCleanupTests {
    private func controller(_ scratch: ScratchDirectory, transcriber: ScriptedTranscriber) -> DictationController {
        DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: transcriber.transcribe,
            requestMicrophone: { true }
        )
    }

    @Test func showsCleaningThenTheCleanedTextAndReportsBoth() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, transcriber: ScriptedTranscriber([fresh()]))
        let gate = GatedCleanup(reply: "Hello there.")
        controller.postProcessor = DictationPostProcessor(clean: gate.clean)
        var reported: [QueuedDictation] = []
        controller.onTranscribed = { reported.append($0) }

        await controller.record()
        let stopping = Task { await controller.stop() }
        for _ in 0..<200 where controller.state != .cleaning {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.state == .cleaning)
        #expect(reported.isEmpty)
        gate.open()
        await stopping.value

        #expect(controller.state == .done)
        #expect(controller.latestText == "Hello there.")
        let item = try #require(reported.first)
        #expect(reported.count == 1)
        #expect(item.cleanedText == "Hello there.")
        #expect(item.whisperText == "um so hello there")
        #expect(item.wasCleaned)
        #expect(item.text == "Hello there.")
    }

    @Test func unchangedCleanupLeavesWhisperAsIs() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, transcriber: ScriptedTranscriber([fresh()]))
        controller.postProcessor = DictationPostProcessor(clean: { $0 })
        var reported: [QueuedDictation] = []
        controller.onTranscribed = { reported.append($0) }
        await controller.record()
        await controller.stop()
        #expect(controller.state == .done)
        #expect(controller.latestText == "um so hello there")
        #expect(reported.first?.cleanedText == nil)
    }

    // #101
    @Test func aTrimOnlyCleanupStoresTheTrimmedText() async throws {
        let scratch = ScratchDirectory()
        let transcript = Transcript(text: "  hello world  ", noSpeech: false)
        let controller = controller(scratch, transcriber: ScriptedTranscriber([.success(transcript)]))
        controller.postProcessor = DictationPostProcessor(clean: { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var reported: [QueuedDictation] = []
        controller.onTranscribed = { reported.append($0) }
        await controller.record()
        await controller.stop()
        #expect(controller.state == .done)
        #expect(controller.latestText == "hello world")
        #expect(reported.first?.cleanedText == "hello world")
        #expect(reported.first?.text == "hello world")
        #expect(reported.first?.wasCleaned == false)
    }

    @Test func withoutAPostProcessorNothingChanges() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, transcriber: ScriptedTranscriber([fresh()]))
        await controller.record()
        await controller.stop()
        #expect(controller.state == .done)
        #expect(controller.latestText == "um so hello there")
    }

    @Test func aPersonsEditStillWinsOverTheCleanedText() async throws {
        let scratch = ScratchDirectory()
        let transcriber = ScriptedTranscriber([.failure(.network("offline")), fresh()])
        let controller = controller(scratch, transcriber: transcriber)
        controller.postProcessor = DictationPostProcessor(clean: { _ in "Hello there." })
        await controller.record()
        await controller.stop()
        #expect(controller.state == .queued)
        await controller.edit("typed by me").value
        await controller.retry()
        #expect(controller.state == .done)
        #expect(controller.latestText == "typed by me")
        #expect(controller.latest?.cleanedText == "Hello there.")
        #expect(controller.latest?.whisperText == "um so hello there")
    }

    @Test func theCleanedTextSurvivesARelaunch() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let id = try await queue.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2])).id
        _ = await queue.drain(using: ScriptedTranscriber([fresh()]).transcribe)
        await queue.setCleaned(id, text: "Hello there.")
        let reloaded = DictationQueue(directory: scratch.url)
        let item = try #require(await reloaded.items().first)
        #expect(item.cleanedText == "Hello there.")
        #expect(item.text == "Hello there.")
        #expect(item.whisperText == "um so hello there")
    }

    @Test func cleanedIsOnlyRecordedForAFinishedItem() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let id = try await queue.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2])).id
        await queue.setCleaned(id, text: "nope")
        #expect(await queue.items().first?.cleanedText == nil)
    }
}

@Suite("Note titling rules")
struct NoteTitlingTests {
    @Test(arguments: [
        (nil, "some content", true),
        ("", "some content", true),
        ("   ", "some content", true),
        ("Untitled Note", "some content", true),
        (" Untitled Note ", "some content", true),
        ("My title", "some content", false),
        (nil, "", false),
        (nil, "  \n ", false),
        ("Untitled Note", "", false)
    ])
    func needsTitle(_ title: String?, _ content: String, _ expected: Bool) {
        #expect(NoteTitling.needsTitle(title: title, content: content) == expected)
    }
}

/// A title generator that answers from a script, can be held open, and
/// records what it was asked.
private final class ScriptedTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var asked: [String] = []
    let reply: String

    init(reply: String, held: Bool = false) {
        self.reply = reply
        opened = !held
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func generate(_ content: String) async -> String {
        lock.withLock { asked.append(content) }
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return reply
    }
}

@MainActor
private struct TitlerRig {
    let store: NotesStore
    let notes: NotesViewModel
    let titles: ScriptedTitles
    let titler: NoteAutoTitler

    init(reply: String = "Weekly Standup Notes", held: Bool = false, idleDelay: Duration = .seconds(60)) throws {
        store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: FakeSyncHub(), store: store, cursors: InMemoryCursorStore())
        notes = NotesViewModel(store: store, engine: engine, canSync: { false }, saveDelay: .milliseconds(1), syncDelay: nil)
        titles = ScriptedTitles(reply: reply, held: held)
        let flag = FlagBox(true)
        self.flag = flag
        titler = NoteAutoTitler(notes: notes, generate: titles.generate, isEnabled: { flag.value }, idleDelay: idleDelay)
    }

    private let flag: FlagBox
    func setEnabled(_ value: Bool) { flag.value = value }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor
@Suite("Auto note titles")
struct NoteAutoTitlerTests {
    @Test func titlesAnUntitledNoteWhenItCloses() async throws {
        let rig = try TitlerRig()
        let note = try await rig.notes.create(content: "we talked about the standup")
        await rig.titler.noteClosed(note.clientId).value
        #expect(rig.notes.note(note.clientId)?.title == "Weekly Standup Notes")
        #expect(rig.titles.asked == ["we talked about the standup"])
        await rig.notes.flushEdits()
        #expect(try await rig.store.notes().first?.title == "Weekly Standup Notes")
    }

    @Test func theDefaultTitleCountsAsUntitled() async throws {
        let rig = try TitlerRig()
        let note = try await rig.notes.create(title: NoteRecord.untitled, content: "body")
        await rig.titler.titleIfNeeded(note.clientId)
        #expect(rig.notes.note(note.clientId)?.title == "Weekly Standup Notes")
    }

    @Test func neverReplacesATypedTitleOrTitlesAnEmptyNote() async throws {
        let rig = try TitlerRig()
        let titled = try await rig.notes.create(title: "Mine", content: "body")
        let empty = try await rig.notes.create()
        await rig.titler.titleIfNeeded(titled.clientId)
        await rig.titler.titleIfNeeded(empty.clientId)
        #expect(rig.notes.note(titled.clientId)?.title == "Mine")
        #expect(rig.notes.note(empty.clientId)?.title == nil)
        #expect(rig.titles.asked.isEmpty)
    }

    @Test func aTitleTypedWhileTheModelThinksWins() async throws {
        let rig = try TitlerRig(held: true)
        let note = try await rig.notes.create(content: "body")
        let run = rig.titler.noteClosed(note.clientId)
        for _ in 0..<200 where !rig.titler.isGenerating(note.clientId) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.titler.isGenerating(note.clientId))
        rig.notes.edit(note.clientId, title: "Typed meanwhile")
        rig.titles.open()
        await run.value
        #expect(!rig.titler.isGenerating(note.clientId))
        #expect(rig.notes.note(note.clientId)?.title == "Typed meanwhile")
    }

    @Test func theFallbackAnswerIsNotWritten() async throws {
        let rig = try TitlerRig(reply: TitleService.fallback)
        let note = try await rig.notes.create(content: "body")
        await rig.titler.titleIfNeeded(note.clientId)
        #expect(rig.notes.note(note.clientId)?.title == nil)
    }

    @Test func theSettingOffSkipsTheModel() async throws {
        let rig = try TitlerRig()
        rig.setEnabled(false)
        let note = try await rig.notes.create(content: "body")
        await rig.titler.titleIfNeeded(note.clientId)
        #expect(rig.notes.note(note.clientId)?.title == nil)
        #expect(rig.titles.asked.isEmpty)
    }

    @Test func typingPausesThenATitleArrives() async throws {
        let rig = try TitlerRig(idleDelay: .milliseconds(20))
        let note = try await rig.notes.create(content: "")
        rig.notes.edit(note.clientId, content: "first draft")
        rig.titler.noteChanged(note.clientId)
        rig.notes.edit(note.clientId, content: "first draft, longer")
        rig.titler.noteChanged(note.clientId)
        for _ in 0..<200 where rig.notes.note(note.clientId)?.title == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.notes.note(note.clientId)?.title == "Weekly Standup Notes")
        // The reset timer means only the settled text was sent.
        #expect(rig.titles.asked == ["first draft, longer"])
    }

    @Test func aRunInFlightIsNotDoubled() async throws {
        let rig = try TitlerRig(held: true)
        let note = try await rig.notes.create(content: "body")
        let first = rig.titler.noteClosed(note.clientId)
        let second = rig.titler.noteClosed(note.clientId)
        for _ in 0..<200 where !rig.titler.isGenerating(note.clientId) {
            try await Task.sleep(for: .milliseconds(5))
        }
        rig.titles.open()
        await first.value
        await second.value
        #expect(rig.titles.asked.count == 1)
        #expect(rig.notes.note(note.clientId)?.title == "Weekly Standup Notes")
    }

    @Test func saveAsNoteHandsTheNewNoteToTheTitler() async throws {
        let rig = try TitlerRig()
        var created: [String] = []
        rig.notes.onCreated = { created.append($0.clientId) }
        let note = try await rig.notes.saveAsNote("dictated words")
        #expect(created == [note.clientId])
    }
}
