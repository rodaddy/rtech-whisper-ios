import Foundation
import Testing

@testable import RtechWhisperKit

private let base = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
private func makeModel(canSync: Bool) throws -> (NotesViewModel, NotesStore, FakeSyncHub) {
    let hub = FakeSyncHub()
    let store = try NotesStore.inMemory()
    let engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore(), now: { base })
    let model = NotesViewModel(
        store: store, engine: engine, canSync: { canSync },
        saveDelay: .seconds(60), syncDelay: nil, now: { base })
    return (model, store, hub)
}

@Suite("Note presentation")
struct NotePresentationTests {
    @Test("blank title reads as the desktop's Untitled Note")
    func untitled() async throws {
        let store = try NotesStore.inMemory()
        let blank = try await store.createNote(content: "body", title: "  ")
        let named = try await store.createNote(content: "body", title: "Standup")
        #expect(blank.displayTitle == "Untitled Note")
        #expect(named.displayTitle == "Standup")
    }

    @Test("preview folds lines and spaces and cuts at the limit")
    func preview() async throws {
        let store = try NotesStore.inMemory()
        let note = try await store.createNote(content: "first line\n\n  second   line\nthird")
        #expect(note.preview() == "first line second line third")
        #expect(note.preview(limit: 10) == "first line")
        let empty = try await store.createNote(content: "")
        #expect(empty.preview() == "")
    }

    @Test("default folder seeds are the desktop's three, matched by name")
    func seeds() async throws {
        #expect(DefaultFolder.all.map(\.name) == ["Personal", "Meetings", "Videos"])
        #expect(DefaultFolder.all.map(\.sortOrder) == [0, 1, 2])
        #expect(DefaultFolder.all.map(\.isDefault) == [true, false, false])
        let store = try NotesStore.inMemory()
        try await store.createFolder(name: "personal", isDefault: true)
        try await store.createFolder(name: "Videos")
        let missing = DefaultFolder.missing(from: try await store.folders())
        #expect(missing.map(\.name) == ["Meetings"])
    }
}

@Suite("Notes parity: folders")
@MainActor
struct NotesFolderTests {
    @Test("with sync off, all three default folders are seeded once")
    func seedOffline() async throws {
        let (model, _, _) = try makeModel(canSync: false)
        await model.ensureDefaultFolders()
        await model.ensureDefaultFolders()
        #expect(model.folders.map(\.name) == ["Personal", "Meetings", "Videos"])
        #expect(model.folders.map(\.sortOrder) == [0, 1, 2])
        #expect(model.defaultFolder?.name == "Personal")
    }

    @Test("with sync on, only Personal is seeded before the first pull; the rest after")
    func seedAfterPull() async throws {
        let (model, store, _) = try makeModel(canSync: true)
        await model.ensureDefaultFolders()
        #expect(model.folders.map(\.name) == ["Personal"])
        // The Mac already has Meetings: it arrives with the pull and is not doubled.
        _ = try await store.applyFromHub(HubFolder(
            id: "f-mac", clientFolderId: nil, name: "Meetings", isDefault: false, sortOrder: 1,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: base, updatedAt: base))
        await model.syncNow()
        #expect(model.folders.map(\.name) == ["Personal", "Meetings", "Videos"])
        #expect(model.folders.count { $0.name == "Meetings" } == 1)
        #expect(model.folders.first { $0.name == "Meetings" }?.cloudId == "f-mac")
    }

    @Test("create, rename, and the name rules")
    func createRename() async throws {
        let (model, _, _) = try makeModel(canSync: false)
        await model.ensureDefaultFolders()
        let work = try await model.createFolder(name: "  Work ")
        #expect(work.name == "Work")
        #expect(work.sortOrder == 3)
        await #expect(throws: NotesViewModel.FolderError.nameTaken("work")) {
            try await model.createFolder(name: "work")
        }
        await #expect(throws: NotesViewModel.FolderError.emptyName) {
            try await model.createFolder(name: "   ")
        }
        let renamed = try await model.renameFolder(work.clientId, to: "Clients")
        #expect(renamed.name == "Clients")
        #expect(model.folders.map(\.name) == ["Personal", "Meetings", "Videos", "Clients"])
    }

    @Test("delete refiles the folder's notes to Personal; the default cannot go")
    func deleteRefiles() async throws {
        let (model, store, _) = try makeModel(canSync: false)
        await model.ensureDefaultFolders()
        let personal = try #require(model.defaultFolder)
        let videos = try #require(model.folders.first { $0.name == "Videos" })
        let a = try await model.create(content: "a", folderClientId: videos.clientId)
        let b = try await model.create(content: "b", folderClientId: videos.clientId)
        let elsewhere = try await model.create(content: "c", folderClientId: personal.clientId)
        #expect(model.noteCount(inFolder: videos.clientId) == 2)

        try await model.deleteFolder(videos.clientId)
        #expect(model.folders.map(\.name) == ["Personal", "Meetings"])
        #expect(model.noteCount(inFolder: personal.clientId) == 3)
        for id in [a.clientId, b.clientId, elsewhere.clientId] {
            let stored = try #require(try await store.notes().first { $0.clientId == id })
            #expect(stored.folderClientId == personal.clientId)
            #expect(stored.syncStatus == .pending)
        }

        #expect(!model.canDelete(personal))
        await #expect(throws: NotesViewModel.FolderError.cannotDeleteDefault) {
            try await model.deleteFolder(personal.clientId)
        }
        #expect(model.folders.map(\.name) == ["Personal", "Meetings"])
    }

    @Test("notes list newest first and search matches title or content")
    func listAndSearch() async throws {
        let (model, store, _) = try makeModel(canSync: false)
        await model.ensureDefaultFolders()
        let personal = try #require(model.defaultFolder)
        let old = try await model.create(title: "Apples", content: "green", folderClientId: personal.clientId)
        let new = try await model.create(title: "Pears", content: "an apple a day", folderClientId: personal.clientId)
        #expect(model.notes(inFolder: personal.clientId).map(\.clientId) == [new.clientId, old.clientId])
        try await store.editNote(clientId: old.clientId, content: "green and red")
        await model.reload()
        #expect(model.notes(inFolder: personal.clientId).map(\.clientId) == [old.clientId, new.clientId])
        #expect(model.search("APPLE", inFolder: personal.clientId).count == 2)
        #expect(model.search("pears", inFolder: personal.clientId).map(\.clientId) == [new.clientId])
        #expect(model.search("red", inFolder: personal.clientId).map(\.clientId) == [old.clientId])
    }
}
