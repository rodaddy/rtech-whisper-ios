import Foundation
import Testing

@testable import RtechWhisperKit

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func hubNote(
    id: String = "hub-1", clientNoteId: String? = "remote-1", content: String = "from hub",
    updatedAt: Date, deletedAt: Date? = nil
) -> HubNote {
    HubNote(
        id: id, clientNoteId: clientNoteId, title: "Hub title", content: content,
        enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
        noteType: .meeting, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: deletedAt, createdAt: t0, updatedAt: updatedAt)
}

private func hubFolder(id: String = "hub-f", name: String, updatedAt: Date, deletedAt: Date? = nil) -> HubFolder {
    HubFolder(
        id: id, clientFolderId: "remote-f", name: name, isDefault: false, sortOrder: 1,
        workspaceId: nil, spaceId: nil, deletedAt: deletedAt, createdAt: t0, updatedAt: updatedAt)
}

/// Creates a note and settles it as synced with hub id `cloudId` at `t0`.
private func syncedNote(_ store: NotesStore, cloudId: String = "c-1") async throws -> NoteRecord {
    let note = try await store.createNote(content: "hello")
    try await store.markNoteSynced(
        clientId: note.clientId, cloudId: cloudId, cloudUpdatedAt: t0, pushedUpdatedAt: note.updatedAt)
    return try #require(try await store.notes().first { $0.clientId == note.clientId })
}

@Suite struct NotesStoreTests {
    @Test func createGivesPending() async throws {
        let store = try NotesStore.inMemory()
        let note = try await store.createNote(content: "hello")
        #expect(note.syncStatus == .pending)
        #expect(note.cloudId == nil)
        #expect(try await store.pendingNotes().map(\.clientId) == [note.clientId])
    }

    @Test func deletingNeverSyncedNoteRemovesIt() async throws {
        let store = try NotesStore.inMemory()
        let note = try await store.createNote(content: "hello")
        try await store.softDeleteNote(clientId: note.clientId)
        #expect(try await store.notes().isEmpty)
        #expect(try await store.pendingNoteDeletes().isEmpty)
    }

    @Test func deletingSyncedNoteLeavesTombstone() async throws {
        let store = try NotesStore.inMemory()
        let note = try await syncedNote(store)
        try await store.softDeleteNote(clientId: note.clientId)
        let tombstones = try await store.pendingNoteDeletes()
        #expect(tombstones.map(\.clientId) == [note.clientId])
        #expect(tombstones.first?.deletedAt != nil)
        #expect(tombstones.first?.syncStatus == .pending)
    }

    @Test func markSyncedSettles() async throws {
        let store = try NotesStore.inMemory()
        let note = try await syncedNote(store)
        #expect(note.syncStatus == .synced)
        #expect(note.cloudId == "c-1")
        #expect(note.cloudUpdatedAt == t0)
        #expect(try await store.pendingNotes().isEmpty)
    }

    @Test func markSyncedStaysPendingAfterConcurrentEdit() async throws {
        let store = try NotesStore.inMemory()
        let snapshot = try await store.createNote(content: "v1")
        try await store.editNote(clientId: snapshot.clientId, content: "v2")
        try await store.markNoteSynced(
            clientId: snapshot.clientId, cloudId: "c-1", cloudUpdatedAt: t0,
            pushedUpdatedAt: snapshot.updatedAt)
        let pending = try await store.pendingNotes()
        #expect(pending.map(\.clientId) == [snapshot.clientId])
        #expect(pending.first?.cloudId == "c-1")
        #expect(pending.first?.content == "v2")
    }

    @Test func applyInsertsUnknownRow() async throws {
        let store = try NotesStore.inMemory()
        let result = try await store.applyFromHub(hubNote(updatedAt: t0))
        #expect(result == .inserted)
        let notes = try await store.notes()
        #expect(notes.count == 1)
        #expect(notes.first?.clientId == "remote-1")
        #expect(notes.first?.syncStatus == .synced)
        #expect(notes.first?.noteType == .meeting)
    }

    @Test func applyOverwritesSyncedRowWhenHubIsNewer() async throws {
        let store = try NotesStore.inMemory()
        let note = try await syncedNote(store)
        let hub = hubNote(id: "c-1", content: "newer", updatedAt: t0.addingTimeInterval(60))
        #expect(try await store.applyFromHub(hub) == .applied)
        let after = try #require(try await store.notes().first { $0.clientId == note.clientId })
        #expect(after.content == "newer")
        #expect(after.cloudUpdatedAt == t0.addingTimeInterval(60))
        #expect(after.syncStatus == .synced)
        // Same revision again changes nothing.
        #expect(try await store.applyFromHub(hub) == .unchanged)
    }

    @Test func applyReturnsConflictForPendingRow() async throws {
        let store = try NotesStore.inMemory()
        let note = try await syncedNote(store)
        try await store.editNote(clientId: note.clientId, content: "local edit")
        let hub = hubNote(id: "c-1", content: "remote edit", updatedAt: t0.addingTimeInterval(60))
        guard case .conflict(let local, let remote) = try await store.applyFromHub(hub) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(local.content == "local edit")
        #expect(remote == hub)
        let after = try #require(try await store.notes().first)
        #expect(after.content == "local edit")
        #expect(after.syncStatus == .pending)
    }

    @Test func applyTombstoneHardDeletes() async throws {
        let store = try NotesStore.inMemory()
        _ = try await syncedNote(store)
        let hub = hubNote(id: "c-1", updatedAt: t0.addingTimeInterval(60), deletedAt: t0.addingTimeInterval(60))
        #expect(try await store.applyFromHub(hub) == .deleted)
        #expect(try await store.notes().isEmpty)
        #expect(try await store.pendingNoteDeletes().isEmpty)
    }

    @Test func notesListExcludesDeletedRows() async throws {
        let store = try NotesStore.inMemory()
        let folder = try await store.createFolder(name: "Work")
        let kept = try await store.createNote(content: "keep", folderClientId: folder.clientId)
        let gone = try await store.createNote(content: "gone", folderClientId: folder.clientId)
        try await store.markNoteSynced(
            clientId: gone.clientId, cloudId: "c-2", cloudUpdatedAt: t0, pushedUpdatedAt: gone.updatedAt)
        try await store.softDeleteNote(clientId: gone.clientId)
        _ = try await store.createNote(content: "elsewhere")
        #expect(try await store.notes(inFolder: folder.clientId).map(\.clientId) == [kept.clientId])
        #expect(try await store.notes().count == 2)
    }

    @Test func foldersFollowTheSameRules() async throws {
        let store = try NotesStore.inMemory()
        let local = try await store.createFolder(name: "Draft")
        #expect(local.syncStatus == .pending)
        try await store.softDeleteFolder(clientId: local.clientId)
        #expect(try await store.folders().isEmpty)

        let synced = try await store.createFolder(name: "Work")
        try await store.markFolderSynced(
            clientId: synced.clientId, cloudId: "f-1", cloudUpdatedAt: t0, pushedUpdatedAt: synced.updatedAt)
        #expect(try await store.applyFromHub(hubFolder(id: "f-1", name: "Work 2", updatedAt: t0.addingTimeInterval(1))) == .applied)
        #expect(try await store.folders().map(\.name) == ["Work 2"])

        try await store.editFolder(clientId: synced.clientId, name: "Mine")
        guard case .conflict = try await store.applyFromHub(hubFolder(id: "f-1", name: "Theirs", updatedAt: t0.addingTimeInterval(2))) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(try await store.applyFromHub(hubFolder(name: "New", updatedAt: t0)) == .inserted)
        #expect(try await store.applyFromHub(hubFolder(id: "f-1", name: "x", updatedAt: t0.addingTimeInterval(3), deletedAt: t0)) == .deleted)
        #expect(try await store.folders().map(\.name) == ["New"])
    }
}
