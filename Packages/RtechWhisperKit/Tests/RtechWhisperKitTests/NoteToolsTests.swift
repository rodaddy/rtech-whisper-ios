import Foundation
import Testing

@testable import RtechWhisperKit

@MainActor
private struct ToolRig {
    let store: NotesStore
    let notes: NotesViewModel
    let tools: [String: ChatTool]

    init(hub: FakeSyncHub = FakeSyncHub()) throws {
        store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore(), now: Date.init)
        notes = NotesViewModel(store: store, engine: engine, canSync: { true }, syncDelay: nil)
        tools = Dictionary(uniqueKeysWithValues: NoteTools.all(notes: notes).map { ($0.name, $0) })
    }

    func run(_ name: String, _ args: [String: JSONValue]) async throws -> ChatToolOutput {
        try await #require(tools[name]).run(args)
    }

    /// A note settled as synced, so a later write visibly marks it pending.
    func syncedNote(title: String, content: String, folder: String? = nil) async throws -> NoteRecord {
        let note = try await store.createNote(content: content, title: title, folderClientId: folder)
        try await store.markNoteSynced(
            clientId: note.clientId, cloudId: "hub-\(note.clientId)", cloudUpdatedAt: note.updatedAt,
            pushedUpdatedAt: note.updatedAt)
        await notes.reload()
        return try #require(notes.note(note.clientId))
    }
}

private func ids(_ value: JSONValue) -> [String] {
    guard case .array(let items) = value else { return [] }
    return items.compactMap { $0["id"]?.stringValue }
}

/// One `update_note` edit as the model sends it.
private func edit(_ old: String, _ new: String) -> JSONValue {
    .object(["old": .string(old), "new": .string(new)])
}

@MainActor
@Suite("Note tools")
struct NoteToolsTests {
    @Test func theToolsMatchTheDesktopNames() throws {
        let rig = try ToolRig()
        #expect(NoteTools.all(notes: rig.notes).map(\.name) == ["search_notes", "get_note", "create_note", "update_note", "list_folders"])
        #expect(NoteTools.all(notes: rig.notes).map(\.readOnly) == [true, true, false, false, true])
    }

    @Test func createNoteWritesAPendingNoteInTheDefaultFolder() async throws {
        let rig = try ToolRig()
        let output = try await rig.run("create_note", ["title": "Groceries", "content": "eggs, milk"])

        let id = try #require(output.data["id"]?.stringValue)
        let stored = try #require(try await rig.store.notes().first { $0.clientId == id })
        #expect(stored.title == "Groceries")
        #expect(stored.content == "eggs, milk")
        #expect(stored.syncStatus == .pending)
        #expect(try await rig.store.pendingNotes().map(\.clientId) == [id])
        let folder = try #require(rig.notes.folders.first { $0.clientId == stored.folderClientId })
        #expect(folder.name == "Personal")
        #expect(output.displayText == "Created note: \"Groceries\"")
    }

    @Test func createNoteFilesIntoAnExistingFolderIgnoringCase() async throws {
        let rig = try ToolRig()
        let stories = try await rig.notes.createFolder(name: "Stories")
        let output = try await rig.run("create_note", ["title": "t", "content": "c", "folder": "stories", "noteType": "meeting"])
        let stored = try #require(try await rig.store.notes().first { $0.clientId == output.data["id"]?.stringValue })
        #expect(stored.folderClientId == stories.clientId)
        #expect(stored.noteType == .meeting)
        #expect(rig.notes.folders.count { $0.name.lowercased() == "stories" } == 1)
    }

    @Test func updateNoteEditsAndMovesAndMarksThePending() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "Old", content: "old body")
        #expect(note.syncStatus == .synced)

        let output = try await rig.run(
            "update_note", ["id": .string(note.clientId), "content": "new body", "old_content": "old body", "folder": "Work"])

        let stored = try #require(try await rig.store.notes().first { $0.clientId == note.clientId })
        #expect(stored.content == "new body")
        #expect(stored.title == "Old")
        #expect(stored.syncStatus == .pending)
        let work = try #require(rig.notes.folders.first { $0.name == "Work" })
        #expect(stored.folderClientId == work.clientId)
        #expect(work.syncStatus == .pending)
        #expect(output.data == .object([
            "id": .string(note.clientId), "title": "Old", "folder_id": .string(work.clientId), "folder": "Work",
            "result": "Note updated.",
        ]))
    }

    @Test func updateNoteRejectsAnEmptyChangeAndAnUnknownId() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "c")
        await #expect(throws: ChatToolError("At least one of title, content, edits, append, or folder must be provided")) {
            try await rig.run("update_note", ["id": .string(note.clientId)])
        }
        await #expect(throws: ChatToolError("Note with ID nope not found")) {
            try await rig.run("update_note", ["id": "nope", "title": "x", "old_title": "t"])
        }
        #expect(try await rig.store.pendingNotes().isEmpty)
    }

    @Test func anEmptyUpdateReturnsTheNoteUnchanged() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "c")
        let same = try await rig.notes.update(note.clientId)
        #expect(same.content == "c")
        #expect(same.syncStatus == .synced)
        await #expect(throws: NotesStoreError.noteNotFound("nope")) { try await rig.notes.update("nope") }
    }

    @Test func searchRanksWholeQueryThenWordCountThenNewest() async throws {
        let rig = try ToolRig()
        let oneWord = try await rig.syncedNote(title: "Shopping", content: "buy milk")
        let phrase = try await rig.syncedNote(title: "Weekly", content: "the grocery list for sunday")
        let bothWords = try await rig.syncedNote(title: "List", content: "grocery items, a list")
        _ = try await rig.syncedNote(title: "Unrelated", content: "car service")

        let output = try await rig.run("search_notes", ["query": "grocery list"])
        #expect(ids(output.data) == [phrase.clientId, bothWords.clientId])
        #expect(output.displayText == "Found 2 notes for \"grocery list\"")

        let limited = try await rig.run("search_notes", ["query": "milk grocery", "limit": 1])
        #expect(ids(limited.data).count == 1)
        #expect(!ids(try await rig.run("search_notes", ["query": "milk"]).data).isEmpty)
        #expect(ids(try await rig.run("search_notes", ["query": "milk"]).data) == [oneWord.clientId])
        #expect(try await rig.run("search_notes", ["query": "zebra"]).displayText == "No notes found for \"zebra\"")
    }

    @Test func searchPreviewsAreCutToTheDesktopLength() async throws {
        let rig = try ToolRig()
        _ = try await rig.syncedNote(title: "Long", content: String(repeating: "a", count: 900) + " needle")
        let output = try await rig.run("search_notes", ["query": "long"])
        guard case .array(let items) = output.data else { Issue.record("not an array"); return }
        #expect(items.first?["content"]?.stringValue?.count == NoteTools.previewLength)
    }

    @Test func getNoteReturnsTheWholeNoteOrAnError() async throws {
        let rig = try ToolRig()
        let folder = try await rig.notes.createFolder(name: "Ideas")
        let note = try await rig.syncedNote(title: "Idea", content: String(repeating: "x", count: 800), folder: folder.clientId)
        let output = try await rig.run("get_note", ["id": .string(note.clientId)])
        #expect(output.data["content"]?.stringValue?.count == 800)
        #expect(output.data["folder"] == "Ideas")
        #expect(output.data["title"] == "Idea")
        await #expect(throws: ChatToolError("Note with ID 42 not found")) {
            try await rig.run("get_note", ["id": .number(42)])
        }
        // A huge number must be an error for the model, not a crash.
        await #expect(throws: ChatToolError.self) {
            try await rig.run("get_note", ["id": .number(1e100)])
        }
    }

    @Test func listFoldersNamesEveryFolder() async throws {
        let rig = try ToolRig()
        #expect(try await rig.run("list_folders", [:]).displayText == "No folders")
        let a = try await rig.notes.createFolder(name: "Alpha")
        _ = try await rig.notes.createFolder(name: "Beta")
        let output = try await rig.run("list_folders", [:])
        #expect(output.displayText == "Folders: Alpha, Beta")
        #expect(ids(output.data).first == a.clientId)
    }

    @Test func aSessionDrivesAWriteThroughToAPendingNote() async throws {
        let rig = try ToolRig()
        let llm = FakeChatLLM([
            FakeChatLLM.call("create_note", #"{"title":"From chat","content":"hello"}"#),
            FakeChatLLM.text("Made it."),
        ])
        let session = ChatSession(llm: llm, tools: NoteTools.all(notes: rig.notes))
        #expect(await session.send("make a note saying hello") == .answered)
        let pending = try await rig.store.pendingNotes()
        #expect(pending.map(\.title) == ["From chat"])
        #expect(session.messages[2].displayText == "Created note: \"From chat\"")
    }
}

@MainActor
@Suite("Note tools review fixes")
struct NoteToolsReviewFixTests {
    @Test func aNewFolderWaitsForThePullSoItReusesTheMacsFolder() async throws {
        // The Mac made "Work" and this phone has never pulled: creating a
        // local "Work" would be refused by the hub (409) and never sync.
        let hub = FakeSyncHub()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        await hub.setFolders([HubFolder(
            id: "hub-work", clientFolderId: "mac-work", name: "Work", isDefault: false, sortOrder: 3,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: now, updatedAt: now)])
        let rig = try ToolRig(hub: hub)

        let output = try await rig.run("create_note", ["title": "t", "content": "c", "folder": "work"])

        let works = rig.notes.folders.filter { $0.name.lowercased() == "work" }
        #expect(works.count == 1)
        #expect(works.first?.cloudId == "hub-work")
        #expect(output.data["folder_id"]?.stringValue == works.first?.clientId)
    }

    @Test func aNewFolderIsRefusedWhileTheHubCannotBeReached() async throws {
        // Never pulled and the pull fails: a local folder might clash with
        // the Mac's, so the tool refuses rather than leave it pending forever.
        let hub = FakeSyncHub()
        await hub.setListFoldersError(.network("offline"))
        let rig = try ToolRig(hub: hub)

        await #expect(throws: ChatToolError.self) {
            try await rig.run("create_note", ["title": "t", "content": "c", "folder": "Work"])
        }
        #expect(!rig.notes.folders.contains { $0.name == "Work" })
        #expect(rig.notes.allNotes.isEmpty)
    }

    @Test func anAppendThatLandedButCouldNotMoveSaysOnlyToMoveLater() async throws {
        // The append lands, then the new folder is refused because the hub
        // could not be checked. The reply must not also say "omit the
        // folder, then try again": an append has no proof, so a resend
        // without the folder would land it twice.
        let hub = FakeSyncHub()
        await hub.setListFoldersError(.network("offline"))
        let rig = try ToolRig(hub: hub)
        let note = try await rig.syncedNote(title: "Calls", content: "- call Ann")

        let error = await #expect(throws: ChatToolError.self) {
            try await rig.run("update_note", ["id": .string(note.clientId), "append": "- call Bob", "folder": "Calls"])
        }
        let message = try #require(error?.message)
        #expect(message.contains("was updated but not moved"))
        #expect(message.contains("Do not resend the change"))
        #expect(message.contains("call update_note with only id and folder"))
        #expect(!message.contains("omit the folder"))
        #expect(!message.contains("try again"))
        let stored = try #require(rig.notes.note(note.clientId))
        #expect(stored.content.components(separatedBy: "- call Bob").count == 2)
        #expect(!rig.notes.folders.contains { $0.name == "Calls" })
    }

    @Test func personalGoesToTheDefaultFolder() async throws {
        let rig = try ToolRig()
        let output = try await rig.run("create_note", ["title": "t", "content": "c", "folder": "personal"])
        let folder = try #require(rig.notes.folders.first { $0.clientId == output.data["folder_id"]?.stringValue })
        #expect(folder.isDefault)
        #expect(folder.name == "Personal")
    }
}

@MainActor
@Suite("Note tools r4 review fixes")
struct NoteToolsR4ReviewFixTests {
    private static func work(updatedAt: Date) -> HubFolder {
        HubFolder(
            id: "hub-work", clientFolderId: "mac-work", name: "Work", isDefault: false, sortOrder: 3,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: updatedAt, updatedAt: updatedAt)
    }

    @Test func aNewFolderPullsAgainAfterAnEarlierSyncSoItReusesTheMacsNewFolder() async throws {
        // The phone synced, then the Mac made "Work": the phone's folder
        // list is stale, so a local "Work" would be refused by the hub (409).
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        #expect(rig.notes.hubSeen)
        await hub.setFolders([Self.work(updatedAt: Date().addingTimeInterval(60))])

        let output = try await rig.run("create_note", ["title": "t", "content": "c", "folder": "work"])

        let works = rig.notes.folders.filter { $0.name.lowercased() == "work" }
        #expect(works.count == 1)
        #expect(works.first?.cloudId == "hub-work")
        #expect(output.data["folder_id"]?.stringValue == works.first?.clientId)
    }

    @Test func aNewFolderIsRefusedWhenTheHubIsUnreachableAfterAnEarlierSync() async throws {
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        #expect(rig.notes.hubSeen)
        await hub.setListFoldersError(.network("offline"))

        await #expect(throws: ChatToolError.self) {
            try await rig.run("create_note", ["title": "t", "content": "c", "folder": "Work"])
        }
        #expect(!rig.notes.folders.contains { $0.name == "Work" })
    }

    @Test func aFailingNotePullDoesNotBlockNewFoldersOnceFoldersPulled() async throws {
        // Folders pull, then the note step fails every pass: the whole pass
        // never succeeds, but the Mac's folders are local, so a new folder
        // is safe to make.
        let hub = FakeSyncHub()
        await hub.setListNotesError(.network("notes down"))
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        #expect(rig.notes.lastSyncedAt == nil)
        #expect(rig.notes.hubSeen)

        let output = try await rig.run("create_note", ["title": "t", "content": "c", "folder": "Work"])

        let work = try #require(rig.notes.folders.first { $0.name == "Work" })
        #expect(output.data["folder_id"]?.stringValue == work.clientId)
    }
}

@MainActor
@Suite("Note tools r5 review fixes")
struct NoteToolsR5ReviewFixTests {
    /// The hub's newer revision of a synced note: what the Mac saved since
    /// this phone last pulled.
    private static func macEdit(of note: NoteRecord, at updatedAt: Date) throws -> HubNote {
        HubNote(
            id: try #require(note.cloudId), clientNoteId: note.clientId, title: note.title, content: "mac v2",
            enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
            noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
            participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
            folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
            deletedAt: nil, createdAt: note.createdAt, updatedAt: updatedAt)
    }

    @Test func aStaleWriteWithANewFolderStillPushesOnTheOldRevision() async throws {
        // get_note read v1, the Mac saved v2, then update_note sends v1 plus
        // an addition and a new folder. Making the folder must not pull v2
        // under the write: the push has to carry v1's base so the hub
        // raises a conflict instead of silently dropping the Mac's edit.
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        let base = try #require(note.cloudUpdatedAt)
        await hub.upsert(try Self.macEdit(of: note, at: Date().addingTimeInterval(60)))

        _ = try await rig.run(
            "update_note", ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1", "folder": "NewTopic"])
        await rig.notes.syncNow()

        let update = try #require(await hub.noteUpdates.last { $0.id == note.cloudId })
        #expect(update.baseUpdatedAt == base)
        #expect(update.content == "v1 plus")
    }

    @Test func aPullWhileTheNewFolderIsMadeCannotOverwriteTheLandedWrite() async throws {
        // A new folder is made only after the proof passed and the write
        // landed, so a pull during the folder check (a background pass)
        // meets a pending note: it is a conflict, not a silent overwrite,
        // and the write keeps the base it was proved against.
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        let base = try #require(note.cloudUpdatedAt)
        let macEdit = try Self.macEdit(of: note, at: Date().addingTimeInterval(60))
        let store = rig.store
        await hub.setDuringListFolders { _ = try? await store.applyFromHub(macEdit) }

        _ = try await rig.run(
            "update_note", ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1", "folder": "NewTopic"])

        let stored = try #require(try await rig.store.notes().first { $0.clientId == note.clientId })
        #expect(stored.content == "v1 plus")
        #expect(stored.syncStatus == .pending)
        #expect(stored.cloudUpdatedAt == base)
        #expect(stored.folderClientId == rig.notes.folders.first { $0.name == "NewTopic" }?.clientId)
    }
}

@MainActor
@Suite("Note tools r6 review fixes")
struct NoteToolsR6ReviewFixTests {
    private static func macEdit(of note: NoteRecord, at updatedAt: Date) throws -> HubNote {
        HubNote(
            id: try #require(note.cloudId), clientNoteId: note.clientId, title: note.title, content: "mac v2",
            enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
            noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
            participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
            folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
            deletedAt: nil, createdAt: note.createdAt, updatedAt: updatedAt)
    }

    @Test(arguments: [nil, "NewTopic"])
    func anUpdateAfterAPullOfTheMacsEditSinceGetNoteIsRefused(folder: String?) async throws {
        // get_note read v1; a pass (foreground, pull-to-refresh, the 2 s
        // sync after an earlier write) then pulled the Mac's v2 onto the
        // clean row. update_note's text is built from v1 and must not land
        // on v2's base, where the hub would accept it and drop the Mac's edit.
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        _ = try await rig.run("get_note", ["id": .string(note.clientId)])
        await hub.upsert(try Self.macEdit(of: note, at: Date().addingTimeInterval(60)))
        await rig.notes.syncNow()
        #expect(rig.notes.note(note.clientId)?.content == "mac v2")

        var args: [String: JSONValue] = ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1"]
        if let folder { args["folder"] = .string(folder) }
        await #expect {
            try await rig.run("update_note", args)
        } throws: { error in
            (error as? ChatToolError)?.message.contains("is not exactly the note's current text") == true
        }
        let stored = try #require(try await rig.store.notes().first { $0.clientId == note.clientId })
        #expect(stored.content == "mac v2")
        #expect(stored.syncStatus == .synced)
        #expect(stored.folderClientId == note.folderClientId)
        #expect(try await rig.store.folders().allSatisfy { $0.name != "NewTopic" })
    }

    @Test func anUpdateAfterSearchThenAPullIsRefused() async throws {
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        let note = try await rig.syncedNote(title: "Groceries", content: "v1 eggs")
        _ = try await rig.run("search_notes", ["query": "eggs"])
        try await rig.store.applyFromHub(try Self.macEdit(of: note, at: Date().addingTimeInterval(60)))

        await #expect(throws: ChatToolError.self) {
            try await rig.run("update_note", ["id": .string(note.clientId), "content": "v1 eggs, milk", "old_content": "v1 eggs"])
        }
        #expect(try await rig.store.notes().first { $0.clientId == note.clientId }?.content == "mac v2")
    }

    @Test func anUpdateAfterADraftTypedHereSinceGetNoteIsRefused() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        _ = try await rig.run("get_note", ["id": .string(note.clientId)])
        rig.notes.edit(note.clientId, content: "typed on the phone")

        await #expect(throws: ChatToolError.self) {
            try await rig.run("update_note", ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1"])
        }
        #expect(try await rig.store.notes().first { $0.clientId == note.clientId }?.content == "typed on the phone")
    }

    @Test func theModelCanUpdateANoteAgainOnItsOwnWrite() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        _ = try await rig.run("get_note", ["id": .string(note.clientId)])
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "content": "v2", "old_content": "v1", "folder": "Work"])
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "content": "v3", "old_content": "v2"])

        let created = try await rig.run("create_note", ["title": "n", "content": "a"])
        let newId = try #require(created.data["id"]?.stringValue)
        _ = try await rig.run("update_note", ["id": .string(newId), "content": "b", "old_content": "a"])

        #expect(try await rig.store.notes().first { $0.clientId == note.clientId }?.content == "v3")
        #expect(try await rig.store.notes().first { $0.clientId == newId }?.content == "b")
    }

    @Test func aTitleWriteIsNotRefusedWhenOnlyTheContentChanged() async throws {
        // A title-only write does not replace the content, so the Mac's
        // content edit survives it: no refusal is needed.
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        _ = try await rig.run("get_note", ["id": .string(note.clientId)])
        try await rig.store.applyFromHub(try Self.macEdit(of: note, at: Date().addingTimeInterval(60)))

        _ = try await rig.run("update_note", ["id": .string(note.clientId), "title": "Renamed", "old_title": "t"])

        let stored = try #require(try await rig.store.notes().first { $0.clientId == note.clientId })
        #expect(stored.title == "Renamed")
        #expect(stored.content == "mac v2")
    }

    @Test func aFolderRefreshAdoptsTheHubsDefaultInsteadOfDoublingIt() async throws {
        // Personal was seeded here while the first pass failed; the hub's
        // default Personal (made by the Mac) carries another client id. A
        // folder-only pull must adopt the hub's row, not add a second
        // default that the next push would bind to the same hub row.
        let hub = FakeSyncHub()
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        await hub.setFolders([HubFolder(
            id: "hub-personal", clientFolderId: "mac-personal", name: "Personal", isDefault: true, sortOrder: 0,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: t, updatedAt: t)])
        let rig = try ToolRig(hub: hub)
        let mine = try await rig.store.createFolder(name: "Personal", isDefault: true)
        let filed = try await rig.store.createNote(content: "filed", folderClientId: mine.clientId)

        await rig.notes.refreshFolders()
        await rig.notes.syncNow()

        let defaults = try await rig.store.folders().filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.clientId == mine.clientId)
        #expect(defaults.first?.cloudId == "hub-personal")
        #expect(try await rig.store.notes().first { $0.clientId == filed.clientId }?.folderClientId == mine.clientId)
    }
}

/// #234: every chat write carries its own proof of what the model read
/// (the exact current title or content, or text found exactly once in it),
/// checked by the store against the stored text as it writes.
@MainActor
@Suite("Note tools proof of read (#234)")
struct NoteToolsProofOfReadTests {
    private static func macEdit(of note: NoteRecord, content: String, at updatedAt: Date) throws -> HubNote {
        HubNote(
            id: try #require(note.cloudId), clientNoteId: note.clientId, title: note.title, content: content,
            enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
            noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
            participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
            folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
            deletedAt: nil, createdAt: note.createdAt, updatedAt: updatedAt)
    }

    private static func stored(_ rig: ToolRig, _ id: String) async throws -> NoteRecord {
        try #require(try await rig.store.notes().first { $0.clientId == id })
    }

    private static func refusal(_ rig: ToolRig, _ args: [String: JSONValue]) async -> String? {
        do {
            _ = try await rig.run("update_note", args)
            return nil
        } catch let error as ChatToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    /// A tool call delta as a model streams it, for replies with several calls.
    private static func call(_ index: Int, _ name: String, _ args: [String: JSONValue]) -> LLMStreamChunk {
        .toolCall(LLMToolCallDelta(index: index, id: "c\(index)-\(name)", name: name, arguments: JSONValue.object(args).jsonString))
    }

    @Test func getNoteThenAFullRewriteWithMatchingOldContentLands() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "line one\nline two")
        let read = try await rig.run("get_note", ["id": .string(note.clientId)])
        let seen = try #require(read.data["content"]?.stringValue)

        let output = try await rig.run(
            "update_note", ["id": .string(note.clientId), "content": "rewritten", "old_content": .string(seen)])

        #expect(try await Self.stored(rig, note.clientId).content == "rewritten")
        #expect(output.data["content"] == nil)
        #expect(output.data["result"] == "Note updated.")
    }

    @Test func aRewriteFromASearchPreviewIsRefused() async throws {
        let rig = try ToolRig()
        let body = "groceries " + String(repeating: "x", count: 600) + " the unseen tail"
        let note = try await rig.syncedNote(title: "List", content: body)
        let search = try await rig.run("search_notes", ["query": "groceries"])
        guard case .array(let hits) = search.data else { Issue.record("not an array"); return }
        let preview = try #require(hits.first?["content"]?.stringValue)
        #expect(preview.count == NoteTools.previewLength)

        let message = await Self.refusal(
            rig, ["id": .string(note.clientId), "content": .string(preview + " eggs"), "old_content": .string(preview)])

        #expect(message?.contains("is not exactly the note's current text") == true)
        #expect(try await Self.stored(rig, note.clientId).content == body)
    }

    @Test func aRewriteFromAFitTruncatedGetNoteIsRefused() async throws {
        let rig = try ToolRig()
        let body = String(repeating: "k", count: 20_000) + " the unseen tail"
        let note = try await rig.syncedNote(title: "Long", content: body)
        let llm = FakeChatLLM([
            FakeChatLLM.call("get_note", JSONValue.object(["id": .string(note.clientId)]).jsonString),
            FakeChatLLM.text("read it"),
        ])
        let session = ChatSession(llm: llm, tools: NoteTools.all(notes: rig.notes), systemPrompt: "s", requestBudget: 5_000)
        #expect(await session.send("open it") == .answered)

        // What the model was shown: get_note's result cut to fit the budget.
        let shown = try #require(llm.requests.last?.messages.last)
        #expect(shown.role == .tool)
        let partial = try #require(try JSONValue(parsing: shown.content)["partial_result"]?.stringValue)
        let lead = #"{"content":""#
        #expect(partial.hasPrefix(lead))
        let visible = String(partial.dropFirst(lead.count))
        #expect(!visible.isEmpty && visible.count < body.count && body.hasPrefix(visible))

        let message = await Self.refusal(
            rig, ["id": .string(note.clientId), "content": .string(visible + " edited"), "old_content": .string(visible)])

        #expect(message?.contains("is not exactly the note's current text") == true)
        #expect(try await Self.stored(rig, note.clientId).content == body)
    }

    @Test func aPullBetweenGetNoteAndUpdateIsRefused() async throws {
        let hub = FakeSyncHub()
        let rig = try ToolRig(hub: hub)
        await rig.notes.syncNow()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        let read = try await rig.run("get_note", ["id": .string(note.clientId)])
        let seen = try #require(read.data["content"]?.stringValue)
        await hub.upsert(try Self.macEdit(of: note, content: "v1 and the Mac's line", at: Date().addingTimeInterval(60)))
        await rig.notes.syncNow()
        #expect(rig.notes.note(note.clientId)?.content == "v1 and the Mac's line")

        let message = await Self.refusal(
            rig, ["id": .string(note.clientId), "content": "v1 plus mine", "old_content": .string(seen)])

        #expect(message?.contains("is not exactly the note's current text") == true)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.content == "v1 and the Mac's line")
        #expect(stored.syncStatus == .synced)
    }

    @Test func anOldContentFromTheModelsOwnEarlierWriteIsRefusedAfterTheUserUndidIt() async throws {
        // The model read X and wrote Y; the note went back to X (the user
        // undid it). The model still believes Y: its old_content is Y, the
        // store holds X, so the write is refused.
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "X")
        _ = try await rig.run("get_note", ["id": .string(note.clientId)])
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "content": "Y", "old_content": "X"])
        rig.notes.edit(note.clientId, content: "X")
        await rig.notes.flushEdits()
        #expect(try await Self.stored(rig, note.clientId).content == "X")

        let message = await Self.refusal(rig, ["id": .string(note.clientId), "content": "Y and eggs", "old_content": "Y"])

        #expect(message?.contains("old_title or old_content is not exactly the note's current text") == true)
        #expect(try await Self.stored(rig, note.clientId).content == "X")
    }

    @Test func editsWithAUniqueOldStringLand() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "eggs, milk, bread")
        _ = try await rig.run("update_note", [
            "id": .string(note.clientId),
            "edits": .array([edit("milk", "oat milk"), edit("bread", "rye bread")]),
        ])
        #expect(try await Self.stored(rig, note.clientId).content == "eggs, oat milk, rye bread")
    }

    @Test(arguments: [
        (["old": "eggs", "new": "EGGS"], ["old": "cheese", "new": "brie"], "is not in the note's current text"),
        (["old": "eggs", "new": "EGGS"], ["old": "milk", "new": "oat milk"], "occurs more than once"),
        (["old": "eggs", "new": "EGGS"], ["old": "", "new": "x"], "needs a non-empty old"),
    ] as [([String: String], [String: String], String)])
    func editsWithAMissingOrDuplicatedOldStringAreRefusedAndNothingIsWritten(
        first: [String: String], second: [String: String], reason: String
    ) async throws {
        let rig = try ToolRig()
        let body = "eggs, milk, more milk"
        let note = try await rig.syncedNote(title: "t", content: body)
        let edits: [JSONValue] = [first, second].map { .object($0.mapValues(JSONValue.string)) }

        let message = await Self.refusal(rig, ["id": .string(note.clientId), "edits": .array(edits)])

        #expect(message?.contains(reason) == true)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.content == body)
        #expect(stored.syncStatus == .synced)
    }

    @Test func appendLands() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "eggs")
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "append": "milk"])
        #expect(try await Self.stored(rig, note.clientId).content == "eggs\nmilk")
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "append": "bread\n"])
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "append": "jam"])
        #expect(try await Self.stored(rig, note.clientId).content == "eggs\nmilk\nbread\njam")
    }

    @Test func aRenameThenAContentEditInOneConversationBothLandWithinMaxSteps() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "Shopping", content: "eggs, milk")
        let id = JSONValue.string(note.clientId)
        let llm = FakeChatLLM([
            FakeChatLLM.call("get_note", JSONValue.object(["id": id]).jsonString),
            FakeChatLLM.call("update_note", JSONValue.object(["id": id, "title": "Groceries", "old_title": "Shopping"]).jsonString),
            FakeChatLLM.call("update_note", JSONValue.object(["id": id, "edits": .array([edit("milk", "oat milk")])]).jsonString),
            FakeChatLLM.text("Done."),
        ])
        let session = ChatSession(llm: llm, tools: NoteTools.all(notes: rig.notes), systemPrompt: "s")

        #expect(await session.send("rename it Groceries and make the milk oat milk") == .answered)

        #expect(llm.requests.count <= ChatSession.maxSteps)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.title == "Groceries")
        #expect(stored.content == "eggs, oat milk")
        #expect(!session.messages.contains { $0.isError })
    }

    @Test func twoUpdateCallsInOneReplyBothLand() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "Shopping", content: "eggs, milk")
        let id = JSONValue.string(note.clientId)
        let llm = FakeChatLLM([
            FakeChatLLM.call("get_note", JSONValue.object(["id": id]).jsonString),
            FakeChatLLM.Reply(chunks: [
                Self.call(0, "update_note", ["id": id, "title": "Groceries", "old_title": "Shopping"]),
                Self.call(1, "update_note", ["id": id, "edits": .array([edit("eggs", "a dozen eggs")])]),
            ]),
            FakeChatLLM.text("Done."),
        ])
        let session = ChatSession(llm: llm, tools: NoteTools.all(notes: rig.notes), systemPrompt: "s")

        #expect(await session.send("rename and fix the eggs") == .answered)

        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.title == "Groceries")
        #expect(stored.content == "a dozen eggs, milk")
        #expect(!session.messages.contains { $0.isError })
    }

    @Test func createNoteThenAnEditOnTheContentItWroteLands() async throws {
        let rig = try ToolRig()
        let created = try await rig.run("create_note", ["title": "Plan", "content": "step one\nstep two"])
        #expect(created.data["content"] == nil)
        #expect(created.data["result"] == "Note created.")
        let id = try #require(created.data["id"]?.stringValue)

        _ = try await rig.run("update_note", ["id": .string(id), "edits": .array([edit("step two", "step 2")])])
        _ = try await rig.run(
            "update_note", ["id": .string(id), "content": "all new", "old_content": "step one\nstep 2"])

        #expect(try await Self.stored(rig, id).content == "all new")
    }

    @Test func anUnsavedPhoneDraftIsSavedBeforeTheCompare() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        rig.notes.edit(note.clientId, content: "v1 typed on the phone")
        #expect(rig.notes.hasUnsavedEdit(note.clientId))
        #expect(try await Self.stored(rig, note.clientId).content == "v1")

        // Built from the text before the draft: the draft is saved first, so
        // the stored text no longer matches and the draft survives.
        let stale = await Self.refusal(rig, ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1"])
        #expect(stale != nil)
        #expect(try await Self.stored(rig, note.clientId).content == "v1 typed on the phone")

        rig.notes.edit(note.clientId, content: "v1 typed again")
        let read = try await rig.run("get_note", ["id": .string(note.clientId)])
        let seen = try #require(read.data["content"]?.stringValue)
        #expect(seen == "v1 typed again")
        _ = try await rig.run("update_note", ["id": .string(note.clientId), "content": "merged", "old_content": .string(seen)])
        #expect(try await Self.stored(rig, note.clientId).content == "merged")
        #expect(!rig.notes.hasUnsavedEdit(note.clientId))
    }

    @Test(arguments: [
        ["content": "a", "old_content": "c", "edits": .array([edit("c", "d")])],
        ["content": "a", "old_content": "c", "append": "b"],
        ["edits": .array([edit("c", "d")]), "append": "b"],
    ] as [[String: JSONValue]])
    func contentEditsAndAppendAreMutuallyExclusive(args: [String: JSONValue]) async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "c")
        var args = args
        args["id"] = .string(note.clientId)

        let message = await Self.refusal(rig, args)

        #expect(message?.hasPrefix("Send only one of content") == true)
        #expect(try await Self.stored(rig, note.clientId).content == "c")
    }

    @Test func aTitleOrContentWithoutItsOldTextIsRefused() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "c")
        let noTitle = await Self.refusal(rig, ["id": .string(note.clientId), "title": "New"])
        let noContent = await Self.refusal(rig, ["id": .string(note.clientId), "content": "new"])
        let wrongTitle = await Self.refusal(rig, ["id": .string(note.clientId), "title": "New", "old_title": "T"])
        #expect(noTitle?.hasPrefix("old_title is required") == true)
        #expect(noContent?.hasPrefix("old_content is required") == true)
        #expect(wrongTitle != nil)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.title == "t" && stored.content == "c" && stored.syncStatus == .synced)

        // An untitled note shows its title as null; "" or null names it.
        let untitled = try await rig.store.createNote(content: "body")
        _ = try await rig.run("update_note", ["id": .string(untitled.clientId), "title": "Named", "old_title": .null])
        #expect(try await Self.stored(rig, untitled.clientId).title == "Named")
    }
}

@MainActor
@Suite("Note tools proof of read, follow-ups (#284 #213 #286 #287 #290)")
struct NoteToolsProofOfReadFollowUpTests {
    private static func stored(_ rig: ToolRig, _ id: String) async throws -> NoteRecord {
        try #require(try await rig.store.notes().first { $0.clientId == id })
    }

    private static func refusal(_ rig: ToolRig, _ args: [String: JSONValue]) async -> String? {
        do {
            _ = try await rig.run("update_note", args)
            return nil
        } catch let error as ChatToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test func aLaterEditCannotReachADuplicateTheModelNeverAimedAt() async throws {
        // "foo" occurs twice in the stored text; the first edit consumes the
        // copy the model saw, which would leave the unseen tail copy unique.
        let rig = try ToolRig()
        let body = "foo bar, then a long middle the model skimmed, and a tail foo"
        let note = try await rig.syncedNote(title: "t", content: body)

        let message = await Self.refusal(rig, [
            "id": .string(note.clientId), "edits": .array([edit("foo bar", "qux"), edit("foo", "zap")]),
        ])

        #expect(message?.contains("edits[1].old occurs more than once") == true)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.content == body)
        #expect(stored.syncStatus == .synced)
    }

    @Test func anOverlappingMatchCountsAsASecondOccurrence() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "aaa")

        let message = await Self.refusal(rig, ["id": .string(note.clientId), "edits": .array([edit("aa", "b")])])

        #expect(message?.contains("edits[0].old occurs more than once") == true)
        #expect(try await Self.stored(rig, note.clientId).content == "aaa")
    }

    @Test func aLaterEditThatNeedsAnEarlierEditsTextSaysToMergeThem() async throws {
        let rig = try ToolRig()
        let body = "eggs, milk, bread"
        let note = try await rig.syncedNote(title: "t", content: body)

        let message = await Self.refusal(rig, [
            "id": .string(note.clientId),
            "edits": .array([edit("milk", "oat milk"), edit("oat milk, bread", "oat milk, rye bread")]),
        ])

        let text = try #require(message)
        #expect(text.contains("edits[1].old is not in the note's current text, or not after applying edits[0..<1] in order"))
        #expect(text.contains("merge them into one edit"))
        #expect(try await Self.stored(rig, note.clientId).content == body)
    }

    @Test func aFirstEditNotFoundKeepsThePlainMessage() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "eggs")

        let message = await Self.refusal(rig, ["id": .string(note.clientId), "edits": .array([edit("milk", "oat milk")])])

        #expect(message?.contains("edits[0].old is not in the note's current text. Call get_note") == true)
    }

    @Test(arguments: [
        ["title": "New", "old_title": "wrong"],
        ["content": "v1 plus", "old_content": "wrong"],
        ["edits": "missing"],
    ] as [[String: String]])
    func aRefusedUpdateWithANewFolderLeavesNoFolderBehind(change: [String: String]) async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")
        var args: [String: JSONValue] = ["id": .string(note.clientId), "folder": "NewTopic"]
        for (key, value) in change {
            args[key] = key == "edits" ? .array([edit(value, "x")]) : .string(value)
        }

        #expect(await Self.refusal(rig, args) != nil)

        await rig.notes.reload()
        #expect(!rig.notes.folders.contains { $0.name == "NewTopic" })
        #expect(try await rig.store.folders().allSatisfy { $0.name != "NewTopic" })
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.content == "v1")
        #expect(stored.folderClientId == note.folderClientId)
    }

    @Test func anUpdateWithANewFolderLandsAndMoves() async throws {
        let rig = try ToolRig()
        let note = try await rig.syncedNote(title: "t", content: "v1")

        let output = try await rig.run(
            "update_note", ["id": .string(note.clientId), "content": "v1 plus", "old_content": "v1", "folder": "NewTopic"])

        let folder = try #require(rig.notes.folders.first { $0.name == "NewTopic" })
        #expect(output.data["folder_id"]?.stringValue == folder.clientId)
        let stored = try await Self.stored(rig, note.clientId)
        #expect(stored.content == "v1 plus")
        #expect(stored.folderClientId == folder.clientId)
    }
}
