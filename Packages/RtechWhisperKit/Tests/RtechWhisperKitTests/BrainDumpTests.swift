import Foundation
import Testing

@testable import RtechWhisperKit

@Suite("Brain dump")
@MainActor
struct BrainDumpTests {
    private func rig() throws -> (NotesViewModel, BrainDumpViewModel) {
        let store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: FakeSyncHub(), store: store, cursors: InMemoryCursorStore())
        let notes = NotesViewModel(store: store, engine: engine, canSync: { false }, syncDelay: nil)
        return (notes, BrainDumpViewModel(notes: notes))
    }

    @Test("the title is the first non-blank line, at most 60 characters")
    func title() {
        #expect(BrainDumpViewModel.title(for: "\n  buy milk  \nand eggs") == "buy milk")
        let long = String(repeating: "a", count: 80)
        #expect(BrainDumpViewModel.title(for: long) == String(repeating: "a", count: 60))
    }

    @Test("a saved dump lands in Brain dumps with its title, and the folder is made once")
    func saveReusesFolder() async throws {
        let (notes, dumps) = try rig()
        let first = try #require(try await dumps.save("first idea\nmore"))
        _ = try await dumps.save("second idea")
        let named = notes.folders.filter { $0.name == BrainDumpViewModel.folderName }
        #expect(named.count == 1)
        #expect(first.folderClientId == named.first?.clientId)
        #expect(first.title == "first idea")
        #expect(first.content == "first idea\nmore")
    }

    @Test("blank text saves nothing")
    func blank() async throws {
        let (notes, dumps) = try rig()
        #expect(try await dumps.save("  \n ") == nil)
        #expect(notes.allNotes.isEmpty)
    }

    @Test("the list is Brain dumps only, newest first, without Processed or other folders")
    func list() async throws {
        let (notes, dumps) = try rig()
        let older = try #require(try await dumps.save("older"))
        try await Task.sleep(for: .milliseconds(20))
        let newer = try #require(try await dumps.save("newer"))
        let processed = try await notes.createFolder(name: BrainDumpViewModel.processedFolderName)
        try await notes.create(content: "done", folderClientId: processed.clientId)
        try await notes.create(content: "elsewhere", folderClientId: try await notes.ensureDefaultFolder().clientId)
        #expect(dumps.dumps.map(\.clientId) == [newer.clientId, older.clientId])
    }

    private func syncingRig(_ hub: FakeSyncHub) throws -> (NotesViewModel, BrainDumpViewModel) {
        let store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore(), now: Date.init)
        let notes = NotesViewModel(store: store, engine: engine, canSync: { true }, syncDelay: nil)
        return (notes, BrainDumpViewModel(notes: notes))
    }

    @Test("a hub-only Brain dumps is pulled and reused, not made again locally (review ios-pr-501)")
    func reusesHubFolder() async throws {
        let hub = FakeSyncHub()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        await hub.setFolders([HubFolder(
            id: "hub-dumps", clientFolderId: "mac-dumps", name: "brain dumps", isDefault: false, sortOrder: 3,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: now, updatedAt: now)])
        let (notes, dumps) = try syncingRig(hub)

        let saved = try #require(try await dumps.save("idea"))

        let named = notes.folders.filter { $0.name.lowercased() == "brain dumps" }
        #expect(named.count == 1)
        #expect(named.first?.cloudId == "hub-dumps")
        #expect(saved.folderClientId == named.first?.clientId)
        #expect(dumps.dumps.map(\.clientId) == [saved.clientId])
    }

    @Test("with the hub unreachable and no local Brain dumps, Save refuses rather than make a clashing folder")
    func refusesWhenHubUnchecked() async throws {
        let hub = FakeSyncHub()
        await hub.setListFoldersError(.network("offline"))
        let (notes, dumps) = try syncingRig(hub)

        await #expect(throws: BrainDumpError.hubUnchecked) { try await dumps.save("idea") }
        #expect(!notes.folders.contains { $0.name.lowercased() == "brain dumps" })
        #expect(notes.allNotes.isEmpty)
    }

    @Test("mic text is appended after the box's text")
    func append() {
        #expect(BrainDumpViewModel.appending(" heard ", to: "") == "heard")
        #expect(BrainDumpViewModel.appending("heard", to: "typed") == "typed heard")
        #expect(BrainDumpViewModel.appending("heard", to: "typed\n") == "typed\nheard")
        #expect(BrainDumpViewModel.appending("", to: "typed") == "typed")
    }
}

@MainActor
@Suite("Voice draft, on-device first")
struct VoiceDraftOnDeviceFirstTests {
    @Test("with Transcribe on this iPhone on, the phone's text is used and the hub is not called")
    func onDeviceFirst() async {
        let transcriber = ScriptedTranscriber([.success(Transcript(text: "hub words", noSpeech: false))])
        let draft = VoiceDraft(
            recorder: FakeRecorder(), transcribe: transcriber.transcribe,
            onDevice: FakeOnDevice(.success("phone words")), requestMicrophone: { true },
            transcribeOnDevice: { true })
        await draft.record()
        #expect(await draft.stop() == "phone words")
        #expect(transcriber.sent.isEmpty)
    }
}
