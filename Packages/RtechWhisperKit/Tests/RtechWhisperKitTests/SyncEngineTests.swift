import Foundation
import Synchronization
import Testing

@testable import RtechWhisperKit

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func note(
    _ id: String, clientNoteId: String? = nil, folderId: String? = nil,
    createdAt: Date = t0, updatedAt: Date = t0, deletedAt: Date? = nil
) -> HubNote {
    HubNote(
        id: id, clientNoteId: clientNoteId ?? "c-\(id)", title: nil, content: "content \(id)",
        enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
        noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: folderId, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: deletedAt, createdAt: createdAt, updatedAt: updatedAt)
}

private func folder(_ id: String, updatedAt: Date = t0) -> HubFolder {
    HubFolder(
        id: id, clientFolderId: "c-\(id)", name: "Folder \(id)", isDefault: false, sortOrder: 0,
        workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: t0, updatedAt: updatedAt)
}

/// A hub that answers list calls the way the protocol orders and filters them,
/// and records every request. Internal so NotesViewModelTests can share it.
actor FakeSyncHub: HubSyncing {
    struct NoteCall: Equatable {
        var since: Date?
        var sinceId: String?
        var before: Date?
        var beforeId: String?
    }

    var folders: [HubFolder] = []
    var notes: [HubNote] = []
    var folderCalls: [Date?] = []
    var noteCalls: [NoteCall] = []
    var served: [String] = []

    func setFolders(_ rows: [HubFolder]) { folders = rows }
    /// When set, `listFolders` fails with it, as an unreachable hub would.
    var listFoldersError: HubError?
    func setListFoldersError(_ error: HubError?) { listFoldersError = error }
    /// Runs inside every `listFolders`, before the hub answers.
    var duringListFolders: (@Sendable () async -> Void)?
    func setDuringListFolders(_ hook: (@Sendable () async -> Void)?) { duringListFolders = hook }
    /// When set, both note listings fail with it.
    var listNotesError: HubError?
    func setListNotesError(_ error: HubError?) { listNotesError = error }
    func setNotes(_ rows: [HubNote]) { notes = rows }
    func upsert(_ row: HubNote) {
        notes.removeAll { $0.id == row.id }
        notes.append(row)
    }
    func resetLog() {
        noteCalls = []
        served = []
    }

    func listFolders(since: Date?) async throws(HubError) -> [HubFolder] {
        folderCalls.append(since)
        log.append("listFolders")
        await duringListFolders?()
        if let listFoldersError { throw listFoldersError }
        return folders.filter { since == nil || $0.updatedAt > since! }
    }

    func listNotes(limit: Int, before: Date?, beforeId: String?) async throws(HubError) -> [HubNote] {
        noteCalls.append(NoteCall(before: before, beforeId: beforeId))
        log.append("listNotes")
        if let listNotesError { throw listNotesError }
        let page = notes
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .filter { row in
                guard let before else { return true }
                guard let beforeId else { return row.createdAt < before }
                return (row.createdAt, row.id) < (before, beforeId)
            }
            .prefix(limit)
        served += page.map(\.id)
        return Array(page)
    }

    func listNoteChanges(limit: Int, since: Date, sinceId: String?) async throws(HubError) -> [HubNote] {
        noteCalls.append(NoteCall(since: since, sinceId: sinceId))
        log.append("listNoteChanges")
        if let listNotesError { throw listNotesError }
        let page = notes
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
            .filter { row in
                guard let sinceId else { return row.updatedAt > since }
                return (row.updatedAt, row.id) > (since, sinceId)
            }
            .prefix(limit)
        served += page.map(\.id)
        return Array(page)
    }

    // MARK: Writes

    /// The `updated_at` the hub stamps on every write.
    static let writeStamp = t0.addingTimeInterval(500)

    var log: [String] = []
    var noteCreates: [NoteCreateInput] = []
    var noteUpdates: [NoteUpdateInput] = []
    /// When set, `updateNote` answers `409 note_version_conflict` with this row.
    var conflictRow: HubNote?
    /// When true, `deleteNote` answers `404`.
    var deleteNotFound = false
    /// Runs inside every note write, before the hub answers.
    var duringWrite: (@Sendable () async -> Void)?

    func setConflictRow(_ row: HubNote?) { conflictRow = row }
    func setDeleteNotFound(_ value: Bool) { deleteNotFound = value }
    func setDuringWrite(_ hook: (@Sendable () async -> Void)?) { duringWrite = hook }

    private func created(_ input: FolderCreateInput) -> HubFolder {
        HubFolder(
            id: "hf-\(input.clientFolderId)", clientFolderId: input.clientFolderId, name: input.name,
            isDefault: input.isDefault, sortOrder: input.sortOrder, workspaceId: nil, spaceId: nil,
            deletedAt: nil, createdAt: Self.writeStamp, updatedAt: Self.writeStamp)
    }

    func batchCreateFolders(_ folders: [FolderCreateInput]) async throws(HubError) -> [HubFolder] {
        log.append("batchCreateFolders")
        return folders.map(created)
    }

    func createFolder(_ folder: FolderCreateInput) async throws(HubError) -> HubFolder {
        log.append("createFolder")
        return created(folder)
    }

    func updateFolder(_ update: FolderUpdateInput) async throws(HubError) -> HubFolder {
        log.append("updateFolder")
        return HubFolder(
            id: update.id, clientFolderId: nil, name: update.name ?? "", isDefault: false,
            sortOrder: update.sortOrder ?? 0, workspaceId: nil, spaceId: nil, deletedAt: nil,
            createdAt: t0, updatedAt: Self.writeStamp)
    }

    func deleteFolder(id: String) async throws(HubError) {
        log.append("deleteFolder")
    }

    func batchCreateNotes(_ notes: [NoteCreateInput]) async throws(HubError) -> [HubNoteCreated] {
        log.append("batchCreateNotes")
        noteCreates += notes
        await duringWrite?()
        return notes.map { HubNoteCreated(clientNoteId: $0.clientNoteId, id: "h-\($0.clientNoteId)", updatedAt: Self.writeStamp) }
    }

    func updateNote(_ update: NoteUpdateInput) async throws(HubError) -> HubNote {
        log.append("updateNote")
        noteUpdates.append(update)
        await duringWrite?()
        if let conflictRow { throw .noteVersionConflict(current: conflictRow) }
        return note(update.id, updatedAt: Self.writeStamp.addingTimeInterval(1))
    }

    func deleteNote(id: String) async throws(HubError) {
        log.append("deleteNote")
        if deleteNotFound { throw .notFound }
    }
}

private final class EngineClock: Sendable {
    private let value = Mutex(t0)
    func set(_ date: Date) { value.withLock { $0 = date } }
    func now() -> Date { value.withLock { $0 } }
}

private struct EngineRig {
    let hub = FakeSyncHub()
    let store: NotesStore
    let cursors = InMemoryCursorStore()
    let clock = EngineClock()
    let engine: SyncEngine

    init() throws {
        store = try NotesStore.inMemory()
        let clock = clock
        engine = SyncEngine(hub: hub, store: store, cursors: cursors, now: { clock.now() })
    }
}

@Suite("SyncEngine pull")
struct SyncEngineTests {
    @Test("the first run snapshots and sets the cursor")
    func firstRunSnapshots() async throws {
        let rig = try EngineRig()
        await rig.hub.setFolders([folder("f1")])
        await rig.hub.setNotes([note("n1", folderId: "f1"), note("n2")])
        let start = t0.addingTimeInterval(100)
        rig.clock.set(start)

        try await rig.engine.pull()

        #expect(await rig.hub.folderCalls == [nil])
        #expect(await rig.hub.noteCalls == [.init()])
        #expect(try await rig.store.notes().count == 2)
        #expect(try await rig.store.folders().map(\.cloudId) == ["f1"])
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == start.addingTimeInterval(-SyncEngine.lookback))
        #expect(rig.cursors.cursor(SyncEngine.folderCursorKey) == start.addingTimeInterval(-SyncEngine.lookback))
    }

    @Test("the second run sends since and since_id")
    func secondRunSendsSince() async throws {
        let rig = try EngineRig()
        let first = t0.addingTimeInterval(100)
        rig.clock.set(first)
        try await rig.engine.pull()

        let later = (0..<60).map { note(String(format: "n%02d", $0), updatedAt: first.addingTimeInterval(Double($0 + 1))) }
        await rig.hub.setNotes(later)
        await rig.hub.resetLog()
        rig.clock.set(first.addingTimeInterval(1000))
        try await rig.engine.pull()

        let calls = await rig.hub.noteCalls
        #expect(calls.count == 2)
        #expect(calls[0] == .init(since: first.addingTimeInterval(-SyncEngine.lookback)))
        #expect(calls[1] == .init(since: later[49].updatedAt, sinceId: "n49"))
        #expect(await rig.hub.folderCalls.last == first.addingTimeInterval(-SyncEngine.lookback))
        #expect(try await rig.store.notes().count == 60)
    }

    @Test("a hub tombstone removes the local row")
    func tombstoneRemoves() async throws {
        let rig = try EngineRig()
        await rig.hub.setNotes([note("n1")])
        rig.clock.set(t0.addingTimeInterval(10))
        try await rig.engine.pull()
        #expect(try await rig.store.notes().count == 1)

        await rig.hub.upsert(note("n1", updatedAt: t0.addingTimeInterval(20), deletedAt: t0.addingTimeInterval(20)))
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        #expect(try await rig.store.notes().isEmpty)
    }

    @Test("a hub row newer than a pending local row gives a SyncConflict and does not overwrite")
    func conflictDoesNotOverwrite() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "mine")
        await rig.hub.setNotes([note("n1", clientNoteId: local.clientId, updatedAt: t0.addingTimeInterval(50))])
        rig.clock.set(t0.addingTimeInterval(60))

        try await rig.engine.pull()

        let conflicts = await rig.engine.conflicts
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.clientId == local.clientId)
        #expect(conflicts.first?.local.content == "mine")
        #expect(conflicts.first?.hub.id == "n1")
        let stored = try await rig.store.notes()
        #expect(stored.map(\.content) == ["mine"])
        #expect(stored.first?.syncStatus == .pending)
    }

    @Test("paging across a tied timestamp pulls every row exactly once")
    func tiedTimestampPaging() async throws {
        let rig = try EngineRig()
        let tied = (0..<120).map { note(String(format: "s%03d", $0)) }
        await rig.hub.setNotes(tied)
        rig.clock.set(t0.addingTimeInterval(10))
        try await rig.engine.pull()
        #expect(await rig.hub.served.sorted() == tied.map(\.id))
        #expect(try await rig.store.notes().count == 120)

        let stamp = t0.addingTimeInterval(20)
        let changed = (0..<120).map { note(String(format: "d%03d", $0), updatedAt: stamp) }
        await rig.hub.setNotes(changed)
        await rig.hub.resetLog()
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        #expect(await rig.hub.served.sorted() == changed.map(\.id))
        #expect(try await rig.store.notes().count == 240)
    }

    @Test("an unknown folder parks the note and holds the cursor")
    func unknownFolderParks() async throws {
        let rig = try EngineRig()
        await rig.hub.setNotes([note("n1", folderId: "f-missing"), note("n2")])
        rig.clock.set(t0.addingTimeInterval(10))

        try await rig.engine.pull()

        #expect(try await rig.store.notes().map(\.cloudId) == ["n2"])
        #expect(await rig.engine.parkedNoteIds == ["n1"])
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == nil)
        #expect(rig.cursors.cursor(SyncEngine.folderCursorKey) != nil)

        await rig.hub.setFolders([folder("f-missing", updatedAt: t0.addingTimeInterval(15))])
        rig.clock.set(t0.addingTimeInterval(20))
        try await rig.engine.pull()

        let filed = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(filed?.folderClientId == "c-f-missing")
        #expect(await rig.engine.parkedNoteIds.isEmpty)
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == t0.addingTimeInterval(20 - SyncEngine.lookback))
    }

    /// Hub default folder "fd" plus folder "f1" holding note "n1", all pulled.
    private func orphanRig() async throws -> EngineRig {
        let rig = try EngineRig()
        let fd = HubFolder(
            id: "fd", clientFolderId: "c-fd", name: "Notes", isDefault: true, sortOrder: 0,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: t0, updatedAt: t0)
        await rig.hub.setFolders([fd, folder("f1")])
        await rig.hub.setNotes([note("n1", folderId: "f1")])
        rig.clock.set(t0.addingTimeInterval(10))
        try await rig.engine.pull()
        return rig
    }

    @Test("a note edited remotely whose folder was hard-deleted here is refiled to the default folder")
    func deletedFolderRefilesToDefault() async throws {
        let rig = try await orphanRig()
        try await rig.store.softDeleteFolder(clientId: "c-f1")
        try await rig.engine.pushFolders()
        #expect(try await rig.store.folderCloudIds() == ["fd"])

        await rig.hub.setFolders([])
        await rig.hub.upsert(note("n1", folderId: "f1", updatedAt: t0.addingTimeInterval(20)))
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        let refiled = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(refiled?.folderClientId == "c-fd")
        #expect(refiled?.syncStatus == .pending)
        #expect(await rig.engine.parkedNoteIds.isEmpty)
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == t0.addingTimeInterval(30 - SyncEngine.lookback))

        try await rig.engine.pushNotes()
        #expect(await rig.hub.noteUpdates.last?.folderId == "fd")
    }

    @Test("a note whose folder the hub tombstoned is refiled to the default folder")
    func hubTombstonedFolderRefilesToDefault() async throws {
        let rig = try await orphanRig()
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(15))
        gone.deletedAt = t0.addingTimeInterval(15)
        await rig.hub.setFolders([gone])
        await rig.hub.upsert(note("n1", folderId: "f1", updatedAt: t0.addingTimeInterval(20)))
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        let refiled = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(refiled?.folderClientId == "c-fd")
        #expect(await rig.engine.parkedNoteIds.isEmpty)
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == t0.addingTimeInterval(30 - SyncEngine.lookback))
    }

    @Test("a note whose folder id was never seen still parks")
    func unseenFolderStillParks() async throws {
        let rig = try await orphanRig()
        await rig.hub.upsert(note("n2", folderId: "f-later", updatedAt: t0.addingTimeInterval(20)))
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        #expect(await rig.engine.parkedNoteIds == ["n2"])
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == t0.addingTimeInterval(10 - SyncEngine.lookback))
    }

    private func defaultFolder(_ id: String, name: String, sortOrder: Int) -> HubFolder {
        HubFolder(
            id: id, clientFolderId: "c-\(id)", name: name, isDefault: true, sortOrder: sortOrder,
            workspaceId: nil, spaceId: nil, deletedAt: nil, createdAt: t0, updatedAt: t0)
    }

    @Test("an install upgraded past a pulled folder tombstone catches up once")
    func upgradeCatchesUpDeletedFolders() async throws {
        let defaults = try #require(UserDefaults(suiteName: "Catchup-\(UUID().uuidString)"))
        defaults.set(2, forKey: "sync.cursor.version")
        let hub = FakeSyncHub()
        let store = try NotesStore.inMemory()
        let clock = EngineClock()
        let old = SyncEngine(hub: hub, store: store, cursors: UserDefaultsCursorStore(defaults: defaults), now: { clock.now() })
        await hub.setFolders([defaultFolder("fd", name: "Notes", sortOrder: 0)])
        clock.set(t0.addingTimeInterval(200))
        try await old.pull()
        // Pulled by the old build: behind the folder cursor, never recorded.
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(10))
        gone.deletedAt = t0.addingTimeInterval(10)
        await hub.setFolders([defaultFolder("fd", name: "Notes", sortOrder: 0), gone])
        await hub.setNotes([note("n1", folderId: "f1", updatedAt: t0.addingTimeInterval(300))])
        clock.set(t0.addingTimeInterval(400))
        try await old.pull()
        #expect(await old.parkedNoteIds == ["n1"])

        defaults.set(2, forKey: "sync.cursor.version")
        let cursors = UserDefaultsCursorStore(defaults: defaults)
        let upgraded = SyncEngine(hub: hub, store: store, cursors: cursors, now: { clock.now() })
        clock.set(t0.addingTimeInterval(500))
        try await upgraded.pull()

        let refiled = try await store.notes().first { $0.cloudId == "n1" }
        #expect(refiled?.folderClientId == "c-fd")
        #expect(await upgraded.parkedNoteIds.isEmpty)
        #expect(cursors.cursor(SyncEngine.noteCursorKey) == t0.addingTimeInterval(500 - SyncEngine.lookback))
    }

    @Test("a pulled folder tombstone moves the notes held in it to the default folder")
    func tombstoneMovesHeldNotes() async throws {
        let rig = try await orphanRig()
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(15))
        gone.deletedAt = t0.addingTimeInterval(15)
        await rig.hub.setFolders([gone])
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        let held = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(held?.folderClientId == "c-fd")
        #expect(held?.syncStatus == .pending)
        try await rig.engine.pushNotes()
        #expect(await rig.hub.noteUpdates.last?.folderId == "fd")
    }

    @Test("apply and refile are one store call: the note never lands synced without a folder")
    func applyRefilesInOneSave() async throws {
        let rig = try await orphanRig()
        let result = try await rig.store.applyFromHub(note("n9", folderId: "f-gone"), refileOrphan: true)
        #expect(result == .inserted)
        let filed = try await rig.store.notes().first { $0.cloudId == "n9" }
        #expect(filed?.folderClientId == "c-fd")
        #expect(filed?.syncStatus == .pending)
    }

    @Test("with several default folders a refile picks Personal, else the lowest sortOrder")
    func refilePicksOneDefault() async throws {
        let cases: [([HubFolder], String)] = [
            ([defaultFolder("fv", name: "Videos", sortOrder: 2), defaultFolder("fm", name: "Meetings", sortOrder: 1),
              defaultFolder("fp", name: "Personal", sortOrder: 3)], "c-fp"),
            ([defaultFolder("fv", name: "Videos", sortOrder: 2), defaultFolder("fm", name: "Meetings", sortOrder: 1)], "c-fm"),
        ]
        for (folders, expected) in cases {
            let rig = try EngineRig()
            await rig.hub.setFolders(folders + [folder("f1")])
            await rig.hub.setNotes([note("n1", folderId: "f1")])
            rig.clock.set(t0.addingTimeInterval(10))
            try await rig.engine.pull()
            var gone = folder("f1", updatedAt: t0.addingTimeInterval(15))
            gone.deletedAt = t0.addingTimeInterval(15)
            await rig.hub.setFolders([gone])
            rig.clock.set(t0.addingTimeInterval(30))
            try await rig.engine.pull()
            #expect(try await rig.store.notes().first?.folderClientId == expected)
            #expect(FolderRecord.preferredDefault(in: try await rig.store.folders())?.clientId == expected)
        }
    }

    @Test("Use the hub's on a note whose hub folder is deleted files it in the default folder")
    func takeHubRefilesDeletedFolder() async throws {
        let rig = try await orphanRig()
        try await rig.store.editNote(clientId: "c-n1", content: "mine")
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(15))
        gone.deletedAt = t0.addingTimeInterval(15)
        await rig.hub.setFolders([gone])
        await rig.hub.upsert(note("n1", folderId: "f1", updatedAt: t0.addingTimeInterval(20)))
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()
        #expect(await rig.engine.conflicts.count == 1)

        try await rig.engine.takeHub("c-n1")
        let taken = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(taken?.folderClientId == "c-fd")
        #expect(taken?.syncStatus == .pending)
    }

    @Test("the upgrade refiles a note an older build left without a folder when it pulled the tombstone")
    func upgradeRefilesHeldNoteLeftFolderless() async throws {
        let defaults = try #require(UserDefaults(suiteName: "Catchup-\(UUID().uuidString)"))
        let store = try NotesStore.inMemory()
        // What an older build left: n1 synced at its hub revision, no local
        // folder (f1's delete nullified it), f1's tombstone not recorded, and
        // both cursors past every row.
        try await store.applyFromHub(defaultFolder("fd", name: "Notes", sortOrder: 0))
        try await store.applyFromHub(note("n1", updatedAt: t0.addingTimeInterval(10)))
        let past = HubDate.string(from: t0.addingTimeInterval(100))
        defaults.set(past, forKey: "sync.cursor.\(SyncEngine.folderCursorKey)")
        defaults.set(past, forKey: "sync.cursor.\(SyncEngine.noteCursorKey)")
        defaults.set(2, forKey: "sync.cursor.version")

        let hub = FakeSyncHub()
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(5))
        gone.deletedAt = t0.addingTimeInterval(5)
        await hub.setFolders([defaultFolder("fd", name: "Notes", sortOrder: 0), gone])
        await hub.setNotes([note("n1", folderId: "f1", updatedAt: t0.addingTimeInterval(10))])
        let clock = EngineClock()
        clock.set(t0.addingTimeInterval(500))
        let engine = SyncEngine(
            hub: hub, store: store, cursors: UserDefaultsCursorStore(defaults: defaults), now: { clock.now() })
        try await engine.pull()

        let refiled = try await store.notes().first { $0.cloudId == "n1" }
        #expect(refiled?.folderClientId == "c-fd")
        #expect(refiled?.syncStatus == .pending)
        try await engine.pushNotes()
        #expect(await hub.noteUpdates.last?.folderId == "fd")
    }

    @Test("a note the hub moved out of a folder before deleting it takes the move, with no conflict")
    func tombstoneDoesNotRefileOverHubMove() async throws {
        let rig = try await orphanRig()
        // Offline here: the desktop moves n1 from f1 into f2, then deletes f1.
        var gone = folder("f1", updatedAt: t0.addingTimeInterval(20))
        gone.deletedAt = t0.addingTimeInterval(20)
        let fd = defaultFolder("fd", name: "Notes", sortOrder: 0)
        await rig.hub.setFolders([fd, folder("f2", updatedAt: t0.addingTimeInterval(12)), gone])
        await rig.hub.setNotes([note("n1", folderId: "f2", updatedAt: t0.addingTimeInterval(15))])
        rig.clock.set(t0.addingTimeInterval(30))
        try await rig.engine.pull()

        #expect(await rig.engine.conflicts.isEmpty)
        let moved = try await rig.store.notes().first { $0.cloudId == "n1" }
        #expect(moved?.folderClientId == "c-f2")
        #expect(moved?.syncStatus == .synced)
        #expect(try await rig.store.pendingNotes().isEmpty)
    }
}

@Suite("SyncEngine push")
struct SyncEnginePushTests {
    @Test("a new note is batch-created without a base and adopts its hub id")
    func newNoteCreates() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "hello")

        try await rig.engine.pushNotes()

        let sent = await rig.hub.noteCreates
        #expect(sent.map(\.clientNoteId) == [local.clientId])
        #expect(sent.first?.content == "hello")
        let stored = try await rig.store.notes()
        #expect(stored.first?.cloudId == "h-\(local.clientId)")
        #expect(stored.first?.cloudUpdatedAt == FakeSyncHub.writeStamp)
        #expect(stored.first?.syncStatus == .synced)
    }

    @Test("an edit pushes with the last hub revision as its base")
    func editPushesBase() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "v1")
        try await rig.engine.pushNotes()
        try await rig.store.editNote(clientId: local.clientId, content: "v2")

        try await rig.engine.pushNotes()

        let update = await rig.hub.noteUpdates.last
        #expect(update?.id == "h-\(local.clientId)")
        #expect(update?.baseUpdatedAt == FakeSyncHub.writeStamp)
        #expect(update?.content == "v2")
        #expect(try await rig.store.notes().first?.syncStatus == .synced)
    }

    @Test("an update body carries the full payload with folder_id null for a folderless note")
    func editSendsFullPayload() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "v1")
        try await rig.engine.pushNotes()
        try await rig.store.editNote(clientId: local.clientId, content: "v2")

        try await rig.engine.pushNotes()

        let update = try #require(await rig.hub.noteUpdates.last)
        let body = try #require(String(data: HubDate.encoder().encode(update), encoding: .utf8))
        #expect(body.contains("\"folder_id\":null"))
        let object = try #require(
            JSONSerialization.jsonObject(with: HubDate.encoder().encode(update)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "base_updated_at", "title", "content", "note_type", "transcript", "folder_id"])
    }

    @Test("a stale base gives a SyncConflict and the note stays pending")
    func staleBaseConflicts() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "v1")
        try await rig.engine.pushNotes()
        try await rig.store.editNote(clientId: local.clientId, content: "mine")
        let hubRow = note("h-\(local.clientId)", clientNoteId: local.clientId, updatedAt: t0.addingTimeInterval(900))
        await rig.hub.setConflictRow(hubRow)

        try await rig.engine.pushNotes()

        let conflicts = await rig.engine.conflicts
        #expect(conflicts.map(\.clientId) == [local.clientId])
        #expect(conflicts.first?.hub == hubRow)
        let stored = try await rig.store.notes().first
        #expect(stored?.content == "mine")
        #expect(stored?.syncStatus == .pending)
        #expect(stored?.cloudUpdatedAt == FakeSyncHub.writeStamp)
    }

    @Test("an edit made during the push stays pending")
    func editDuringPushStaysPending() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "v1")
        let store = rig.store
        await rig.hub.setDuringWrite {
            _ = try? await store.editNote(clientId: local.clientId, content: "typed meanwhile")
        }

        try await rig.engine.pushNotes()

        let stored = try await rig.store.notes().first
        #expect(stored?.cloudId == "h-\(local.clientId)")
        #expect(stored?.content == "typed meanwhile")
        #expect(stored?.syncStatus == .pending)
    }

    @Test("a note in an unsynced folder waits for the folder")
    func noteWaitsForFolder() async throws {
        let rig = try EngineRig()
        let folder = try await rig.store.createFolder(name: "Work")
        let local = try await rig.store.createNote(content: "filed", folderClientId: folder.clientId)

        try await rig.engine.pushNotes()
        #expect(await rig.hub.noteCreates.isEmpty)
        #expect(try await rig.store.notes().first?.syncStatus == .pending)

        try await rig.engine.pushFolders()
        try await rig.engine.pushNotes()

        let sent = await rig.hub.noteCreates
        #expect(sent.map(\.clientNoteId) == [local.clientId])
        #expect(sent.first?.folderId == "hf-\(folder.clientId)")
        #expect(try await rig.store.notes().first?.syncStatus == .synced)
    }

    @Test("a delete the hub answers with 404 hard-deletes locally")
    func delete404HardDeletes() async throws {
        let rig = try EngineRig()
        let local = try await rig.store.createNote(content: "doomed")
        try await rig.engine.pushNotes()
        try await rig.store.softDeleteNote(clientId: local.clientId)
        await rig.hub.setDeleteNotFound(true)

        try await rig.engine.pushNotes()

        #expect(await rig.hub.log.contains("deleteNote"))
        #expect(try await rig.store.pendingNoteDeletes().isEmpty)
        #expect(try await rig.store.notes().isEmpty)
    }

    @Test("sync pushes folders, then notes, then pulls")
    func syncOrder() async throws {
        let rig = try EngineRig()
        let folder = try await rig.store.createFolder(name: "Work")
        try await rig.store.createNote(content: "filed", folderClientId: folder.clientId)
        rig.clock.set(t0.addingTimeInterval(10))

        try await rig.engine.sync()

        #expect(await rig.hub.log == ["batchCreateFolders", "batchCreateNotes", "listFolders", "listNotes"])
    }
}
