import Foundation
import Testing

@testable import RtechWhisperKit

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private let syncedAt = base.addingTimeInterval(1_000)

private func hubRow(_ id: String, clientNoteId: String, content: String, updatedAt: Date) -> HubNote {
    HubNote(
        id: id, clientNoteId: clientNoteId, title: "from the Mac", content: content,
        enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
        noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: nil, createdAt: base, updatedAt: updatedAt)
}

@MainActor
private struct ModelRig {
    let hub = FakeSyncHub()
    let store: NotesStore
    let engine: SyncEngine
    let model: NotesViewModel

    init(canSync: Bool = true, saveDelay: Duration = .seconds(60)) throws {
        store = try NotesStore.inMemory()
        engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore(), now: { base })
        model = NotesViewModel(
            store: store, engine: engine, canSync: { canSync },
            saveDelay: saveDelay, syncDelay: nil, now: { syncedAt })
    }

    func stored(_ clientId: String) async throws -> NoteRecord? {
        try await store.notes().first { $0.clientId == clientId }
    }

    /// A note the hub has, edited here to "mine" while the Mac wrote "theirs".
    func conflictedNote() async throws -> (NoteRecord, HubNote) {
        let note = try await model.create(content: "v1")
        await model.syncNow()
        model.edit(note.clientId, content: "mine")
        let theirs = hubRow("h-\(note.clientId)", clientNoteId: note.clientId, content: "theirs", updatedAt: base.addingTimeInterval(900))
        await hub.setConflictRow(theirs)
        await model.syncNow()
        await hub.setConflictRow(nil)
        return (note, theirs)
    }
}

@Suite("NotesViewModel")
@MainActor
struct NotesViewModelTests {
    @Test("create and edit mark the note pending, and syncNow pushes it")
    func createEditSync() async throws {
        let rig = try ModelRig()
        let note = try await rig.model.create(content: "first")
        #expect(rig.model.isWaitingToSync(note.clientId))
        #expect(try await rig.stored(note.clientId)?.syncStatus == .pending)

        await rig.model.syncNow()

        #expect(await rig.hub.noteCreates.map(\.content) == ["first"])
        #expect(try await rig.stored(note.clientId)?.syncStatus == .synced)
        #expect(!rig.model.isWaitingToSync(note.clientId))
        #expect(rig.model.lastSyncedAt == syncedAt)
        #expect(rig.model.syncState == .idle)

        rig.model.edit(note.clientId, title: "Title", content: "second")
        #expect(rig.model.isWaitingToSync(note.clientId))
        #expect(rig.model.note(note.clientId)?.content == "second")
        await rig.model.flushEdits()
        #expect(try await rig.stored(note.clientId)?.syncStatus == .pending)

        await rig.model.syncNow()

        let update = await rig.hub.noteUpdates.last
        #expect(update?.content == "second")
        #expect(update?.title == "Title")
        #expect(update?.baseUpdatedAt == FakeSyncHub.writeStamp)
        #expect(try await rig.stored(note.clientId)?.syncStatus == .synced)
    }

    @Test("an edit is saved on its own once typing pauses")
    func debouncedSave() async throws {
        let rig = try ModelRig(saveDelay: .milliseconds(20))
        let note = try await rig.model.create(content: "v1")

        rig.model.edit(note.clientId, content: "typed")
        #expect(try await rig.stored(note.clientId)?.content == "v1")
        try await Task.sleep(for: .milliseconds(300))

        #expect(try await rig.stored(note.clientId)?.content == "typed")
        #expect(!rig.model.hasUnsavedEdit(note.clientId))
    }

    @Test("search filters on title, content, and transcript, within a folder")
    func searchFilters() async throws {
        let rig = try ModelRig()
        let work = try await rig.store.createFolder(name: "Work")
        try await rig.model.create(title: "Apple pie", content: "recipe")
        try await rig.model.create(content: "buy APPLES")
        try await rig.model.create(content: "meeting", transcript: "we talked about apple", folderClientId: work.clientId)
        try await rig.model.create(content: "unrelated")

        #expect(rig.model.search("apple").count == 3)
        #expect(rig.model.search("  ").count == 4)
        #expect(rig.model.search("apple", inFolder: work.clientId).map(\.content) == ["meeting"])
        rig.model.searchText = "pie"
        #expect(rig.model.visibleNotes.map(\.title) == ["Apple pie"])
    }

    @Test("keepMine re-pushes with the hub's updated_at as the new base")
    func keepMineRepushes() async throws {
        let rig = try ModelRig()
        let (note, theirs) = try await rig.conflictedNote()
        #expect(rig.model.conflict(for: note.clientId)?.hub == theirs)

        await rig.model.resolve(note.clientId, .keepMine)

        let update = await rig.hub.noteUpdates.last
        #expect(update?.baseUpdatedAt == theirs.updatedAt)
        #expect(update?.content == "mine")
        #expect(rig.model.conflicts.isEmpty)
        #expect(try await rig.stored(note.clientId)?.syncStatus == .synced)
    }

    @Test("takeHub applies the hub copy")
    func takeHubApplies() async throws {
        let rig = try ModelRig()
        let (note, theirs) = try await rig.conflictedNote()
        let updatesBefore = await rig.hub.noteUpdates.count

        await rig.model.resolve(note.clientId, .takeHub)

        let stored = try await rig.stored(note.clientId)
        #expect(stored?.content == "theirs")
        #expect(stored?.title == "from the Mac")
        #expect(stored?.syncStatus == .synced)
        #expect(stored?.cloudUpdatedAt == theirs.updatedAt)
        #expect(rig.model.conflicts.isEmpty)
        #expect(await rig.hub.noteUpdates.count == updatesBefore)
    }

    @Test("deleting a synced note leaves a tombstone that syncNow sends")
    func deleteSendsTombstone() async throws {
        let rig = try ModelRig()
        let note = try await rig.model.create(content: "doomed")
        await rig.model.syncNow()

        try await rig.model.delete(note.clientId)

        #expect(rig.model.allNotes.isEmpty)
        #expect(try await rig.store.pendingNoteDeletes().map(\.clientId) == [note.clientId])

        await rig.model.syncNow()

        #expect(await rig.hub.log.contains("deleteNote"))
        #expect(try await rig.store.pendingNoteDeletes().isEmpty)
    }

    @Test("Save as note creates a note in the default folder")
    func saveAsNote() async throws {
        let rig = try ModelRig()
        try await rig.store.createFolder(name: "Work")

        let note = try await rig.model.saveAsNote("dictated words")

        let personal = try #require(rig.model.defaultFolder)
        #expect(personal.name == "Personal")
        #expect(note.folderClientId == personal.clientId)
        #expect(note.content == "dictated words")

        try await rig.model.saveAsNote("again")
        #expect(rig.model.folders.filter(\.isDefault).count == 1)
        #expect(rig.model.notes(inFolder: personal.clientId).count == 2)
    }

    @Test("with no device key, sync stays off and notes still save")
    func noKeyStaysLocal() async throws {
        let rig = try ModelRig(canSync: false)
        let note = try await rig.model.create(content: "offline")

        await rig.model.syncNow()

        #expect(rig.model.syncState == .off)
        #expect(await rig.hub.log.isEmpty)
        #expect(try await rig.stored(note.clientId)?.syncStatus == .pending)
    }
}
