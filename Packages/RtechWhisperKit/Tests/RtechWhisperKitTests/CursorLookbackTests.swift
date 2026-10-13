import Foundation
import Synchronization
import Testing

@testable import RtechWhisperKit

// The hub stamps a row before its transaction commits, so a row stamped
// before a pass started can become visible only after the pass read the
// table. Every stored delta cursor therefore sits L = 60 s behind the pass
// clock, `since` is truncated to the millisecond, and a re-served row this
// device already holds is a no-op (issue #318, hub protocol section 8).

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
/// L, the lookback, as the contract states it.
private let lookback: TimeInterval = 60

private func hubNote(
    _ id: String, clientNoteId: String? = nil, folderId: String? = nil,
    updatedAt: Date = t0, deletedAt: Date? = nil
) -> HubNote {
    HubNote(
        id: id, clientNoteId: clientNoteId ?? "c-\(id)", title: nil, content: "content \(id)",
        enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
        noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: folderId, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: deletedAt, createdAt: t0, updatedAt: updatedAt)
}

private func hubFolder(_ id: String, updatedAt: Date = t0, deletedAt: Date? = nil) -> HubFolder {
    HubFolder(
        id: id, clientFolderId: "c-\(id)", name: "Folder \(id)", isDefault: false, sortOrder: 0,
        workspaceId: nil, spaceId: nil, deletedAt: deletedAt, createdAt: t0, updatedAt: updatedAt)
}

private final class LookbackClock: Sendable {
    private let value = Mutex(t0)
    func set(_ date: Date) { value.withLock { $0 = date } }
    func now() -> Date { value.withLock { $0 } }
}

private struct NotesRig {
    let hub = FakeSyncHub()
    let store: NotesStore
    let cursors = InMemoryCursorStore()
    let clock = LookbackClock()
    let engine: SyncEngine

    init() throws {
        store = try NotesStore.inMemory()
        let clock = clock
        engine = SyncEngine(hub: hub, store: store, cursors: cursors, now: { clock.now() })
    }
}

@Suite("Delta cursor lookback")
struct CursorLookbackTests {
    // MARK: L on every stored cursor

    @Test("folders and notes store the pass clock minus 60 s")
    func storedCursorsLookBack() async throws {
        let notes = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        notes.clock.set(pass)
        try await notes.engine.pull()
        #expect(notes.cursors.cursor(SyncEngine.folderCursorKey) == pass.addingTimeInterval(-lookback))
        #expect(notes.cursors.cursor(SyncEngine.noteCursorKey) == pass.addingTimeInterval(-lookback))

    }

    @Test("a folder stamped before the pass that commits after it is pulled next pass")
    func lateFolderIsPulled() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        rig.clock.set(pass)
        try await rig.engine.pull()

        // Stamped 5 s before the pass started, visible only after it read.
        await rig.hub.setFolders([hubFolder("late", updatedAt: pass.addingTimeInterval(-5))])
        rig.clock.set(pass.addingTimeInterval(10))
        try await rig.engine.pull()

        #expect(try await rig.store.folders().map(\.cloudId) == ["late"])
    }

    @Test("a note stamped before the pass that commits after it is pulled next pass")
    func lateNoteIsPulled() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        rig.clock.set(pass)
        try await rig.engine.pull()

        await rig.hub.setNotes([hubNote("late", updatedAt: pass.addingTimeInterval(-5))])
        rig.clock.set(pass.addingTimeInterval(10))
        try await rig.engine.pull()

        #expect(try await rig.store.notes().map(\.cloudId) == ["late"])
    }

    // MARK: Truncation

    @Test("since is truncated to the millisecond, never rounded up")
    func sinceIsTruncated() async throws {
        let late = Date(timeIntervalSince1970: 1_790_000_000.1238)
        #expect(HubDate.string(from: late) == "2026-09-21T14:13:20.123Z")
        #expect(HubDate.string(from: Date(timeIntervalSince1970: -0.0004)) == "1969-12-31T23:59:59.999Z")

        let (session, baseURL, host) = StubHub.register(.init(status: 200, body: #"{"notes":[]}"#))
        let client = HubSyncClient(baseURL: baseURL, key: goodKey, session: session)
        _ = try await client.listNoteChanges(limit: 50, since: late)
        let url = try #require(StubHub.requests(to: host).first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "since" }?.value == "2026-09-21T14:13:20.123Z")
    }

    // MARK: Idempotent re-pull

    @Test("a re-served folder and note this device holds unchanged change nothing")
    func rePulledNotesAreNoOps() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        await rig.hub.setFolders([hubFolder("f1", updatedAt: pass.addingTimeInterval(-10))])
        await rig.hub.setNotes([hubNote("n1", folderId: "f1", updatedAt: pass.addingTimeInterval(-10))])
        rig.clock.set(pass)
        try await rig.engine.pull()
        let folders = try await rig.store.folders()
        let notes = try await rig.store.notes()

        await rig.hub.resetLog()
        rig.clock.set(pass.addingTimeInterval(10))
        try await rig.engine.pull()

        // The lookback re-served both rows ...
        #expect(await rig.hub.served == ["n1"])
        #expect(await rig.hub.folderCalls.last == pass.addingTimeInterval(-lookback))
        // ... and nothing moved: no write, no duplicate, nothing to push, no conflict.
        #expect(try await rig.store.folders() == folders)
        #expect(try await rig.store.notes() == notes)
        #expect(try await rig.store.pendingFolders().isEmpty)
        #expect(try await rig.store.pendingNotes().isEmpty)
        #expect(await rig.engine.conflicts.isEmpty)
        #expect(await rig.engine.parkedNoteIds.isEmpty)
    }

    @Test("a re-served note this device holds does not park when its folder was deleted inside the lookback")
    func rePulledNoteInDeletedFolderDoesNotPark() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        await rig.hub.setFolders([hubFolder("f1", updatedAt: pass.addingTimeInterval(-20))])
        await rig.hub.setNotes([hubNote("n1", folderId: "f1", updatedAt: pass.addingTimeInterval(-10))])
        rig.clock.set(pass)
        try await rig.engine.pull()
        let notes = try await rig.store.notes()

        // f1 is deleted inside the lookback; the hub does not cascade, so it
        // still serves n1, unchanged, with folder_id f1.
        let deleted = pass.addingTimeInterval(5)
        await rig.hub.setFolders([hubFolder("f1", updatedAt: deleted, deletedAt: deleted)])
        let second = pass.addingTimeInterval(10)
        rig.clock.set(second)
        try await rig.engine.pull()
        #expect(try await rig.store.folderCloudIds().isEmpty)

        await rig.hub.resetLog()
        let third = pass.addingTimeInterval(20)
        rig.clock.set(third)
        try await rig.engine.pull()

        #expect(await rig.hub.served == ["n1"])
        #expect(await rig.engine.parkedNoteIds.isEmpty)
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == third.addingTimeInterval(-lookback))
        #expect(try await rig.store.notes().map(\.clientId) == notes.map(\.clientId))
        // The tombstone refiled the held note as a pending edit (ios#553).
        #expect(try await rig.store.pendingNotes().map(\.clientId) == notes.map(\.clientId))
    }

    @Test("a held note that comes back newer in a folder this device does not know parks")
    func newerHeldNoteInUnknownFolderParks() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        let u1 = pass.addingTimeInterval(-20)
        await rig.hub.setFolders([hubFolder("f1", updatedAt: u1)])
        await rig.hub.setNotes([hubNote("n1", folderId: "f1", updatedAt: u1)])
        rig.clock.set(pass)
        try await rig.engine.pull()
        let cursor = rig.cursors.cursor(SyncEngine.noteCursorKey)

        // Another device moved n1 into f2, which has not landed here yet.
        let u2 = pass.addingTimeInterval(5)
        await rig.hub.setNotes([hubNote("n1", folderId: "f2", updatedAt: u2)])
        rig.clock.set(pass.addingTimeInterval(10))
        try await rig.engine.pull()

        #expect(await rig.engine.parkedNoteIds == ["n1"])
        #expect(rig.cursors.cursor(SyncEngine.noteCursorKey) == cursor)
        let local = try #require(try await rig.store.notes().first)
        #expect(local.cloudUpdatedAt == u1)
        #expect(local.folderClientId == "c-f1")
    }

    @Test("a re-served row a pending edit is based on is not a conflict and does not overwrite")
    func rePulledBaseOfPendingEdit() async throws {
        let rig = try NotesRig()
        let pass = t0.addingTimeInterval(1000)
        let row = hubNote("n1", updatedAt: pass.addingTimeInterval(-10))
        await rig.hub.setNotes([row])
        rig.clock.set(pass)
        try await rig.engine.pull()
        let local = try #require(try await rig.store.notes().first)
        let edited = try await rig.store.editNote(clientId: local.clientId, content: "mine")

        rig.clock.set(pass.addingTimeInterval(10))
        try await rig.engine.pull()

        #expect(await rig.engine.conflicts.isEmpty)
        #expect(try await rig.store.notes() == [edited])
        #expect(try await rig.store.pendingNotes().map(\.content) == ["mine"])
    }

    @Test("store apply of an identical row or a repeated tombstone is unchanged")
    func applyIdenticalIsUnchanged() async throws {
        let store = try NotesStore.inMemory()
        let folder = hubFolder("f1")
        #expect(try await store.applyFromHub(folder) == .inserted)
        #expect(try await store.applyFromHub(folder) == .unchanged)

        let note = hubNote("n1")
        #expect(try await store.applyFromHub(note) == .inserted)
        #expect(try await store.applyFromHub(note) == .unchanged)
        let gone = hubNote("n1", updatedAt: t0.addingTimeInterval(1), deletedAt: t0.addingTimeInterval(1))
        #expect(try await store.applyFromHub(gone) == .deleted)
        #expect(try await store.applyFromHub(gone) == .unchanged)
        #expect(try await store.notes().isEmpty)
    }

    // MARK: Upgrade from raw-clock cursors

    @Test("stored cursors are rewound by the lookback exactly once")
    func migrationRewindsOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "CursorLookback-\(UUID().uuidString)"))
        let s = t0.addingTimeInterval(1000)
        let keys = [TranscriptionSync.cursorKey, DictionarySync.cursorKey]
        // Folder and note cursors are dropped once instead (ios#557, ios#566).
        let dropped = [SyncEngine.folderCursorKey, SyncEngine.noteCursorKey]
        for key in keys + dropped {
            defaults.set(HubDate.string(from: s), forKey: "sync.cursor.\(key)")
        }

        let first = UserDefaultsCursorStore(defaults: defaults)
        for key in keys {
            #expect(first.cursor(key) == s.addingTimeInterval(-lookback))
        }
        for key in dropped {
            #expect(first.cursor(key) == nil)
        }

        let again = UserDefaultsCursorStore(defaults: defaults)
        for key in keys {
            #expect(again.cursor(key) == s.addingTimeInterval(-lookback))
        }
    }

    @Test("a fresh install has no cursors to rewind and stays in snapshot mode")
    func freshInstallHasNoCursors() throws {
        let defaults = try #require(UserDefaults(suiteName: "CursorLookback-\(UUID().uuidString)"))
        let store = UserDefaultsCursorStore(defaults: defaults)
        #expect(store.cursor(SyncEngine.noteCursorKey) == nil)
        #expect(store.cursor(TranscriptionSync.cursorKey) == nil)
        #expect(defaults.integer(forKey: "sync.cursor.version") == 3)
    }
}
