import Foundation
import Testing

@testable import RtechWhisperKit

private let base = Date(timeIntervalSince1970: 1_790_000_000)

private func hubUploadNote(id: String, clientNoteId: String?, updatedAt: Date) -> HubNote {
    HubNote(
        id: id, clientNoteId: clientNoteId, title: "Standup", content: "from the Mac",
        enhancedContent: nil, enhancementPrompt: nil, enhancedAtContentHash: nil,
        noteType: .upload, sourceFile: "standup.m4a", audioDurationSeconds: 61.5, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: nil, createdAt: base, updatedAt: updatedAt)
}

@Suite struct UploadNoteMappingTests {
    @Test func titleIsTheFirstSixWordsElseTheFileName() {
        #expect(UploadNote.title(text: "one two three", fileName: "a.m4a") == "one two three")
        #expect(UploadNote.title(text: "one two three four five six", fileName: "a.m4a") == "one two three four five six")
        #expect(UploadNote.title(text: "one  two\nthree four five six seven", fileName: "a.m4a") == "one two three four five six...")
        #expect(UploadNote.title(text: "   ", fileName: "Team standup.m4a") == "Team standup")
        #expect(UploadNote.title(text: "", fileName: "noext") == "noext")
    }

    @Test func durationKeepsOnlyAFinitePositiveLength() {
        #expect(UploadNote.durationSeconds(12.5) == 12.5)
        #expect(UploadNote.durationSeconds(0) == nil)
        #expect(UploadNote.durationSeconds(-1) == nil)
        #expect(UploadNote.durationSeconds(.nan) == nil)
        #expect(UploadNote.durationSeconds(.infinity) == nil)
        #expect(UploadNote.durationSeconds(nil) == nil)
    }
}

@Suite struct UploadNoteStoreTests {
    @Test func createKeepsTheUploadFields() async throws {
        let store = try NotesStore.inMemory()
        let note = try await store.createNote(
            content: "text", title: "t", noteType: .upload, sourceFile: "standup.m4a", audioDurationSeconds: 61.5)
        let stored = try #require(try await store.notes().first)
        #expect(note.noteType == .upload)
        #expect(stored.sourceFile == "standup.m4a")
        #expect(stored.audioDurationSeconds == 61.5)
        let plain = try await store.createNote(content: "plain")
        #expect(plain.sourceFile == nil)
        #expect(plain.audioDurationSeconds == nil)
    }

    @Test func pullCarriesTheUploadFieldsIn() async throws {
        let store = try NotesStore.inMemory()
        #expect(try await store.applyFromHub(hubUploadNote(id: "h-1", clientNoteId: nil, updatedAt: base)) == .inserted)
        let inserted = try #require(try await store.notes().first)
        #expect(inserted.sourceFile == "standup.m4a")
        #expect(inserted.audioDurationSeconds == 61.5)

        let mine = try await store.createNote(content: "local")
        try await store.markNoteSynced(clientId: mine.clientId, cloudId: "h-2", cloudUpdatedAt: base, pushedUpdatedAt: mine.updatedAt)
        let newer = hubUploadNote(id: "h-2", clientNoteId: mine.clientId, updatedAt: base.addingTimeInterval(10))
        #expect(try await store.applyFromHub(newer) == .applied)
        let applied = try #require(try await store.notes().first { $0.clientId == mine.clientId })
        #expect(applied.sourceFile == "standup.m4a")
        #expect(applied.audioDurationSeconds == 61.5)
    }
}

@MainActor
@Suite struct SaveUploadNoteTests {
    private func makeModel() throws -> (NotesViewModel, NotesStore, FakeSyncHub) {
        let hub = FakeSyncHub()
        let store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: hub, store: store, cursors: InMemoryCursorStore(), now: { base })
        let model = NotesViewModel(
            store: store, engine: engine, canSync: { true },
            saveDelay: .seconds(60), syncDelay: nil, now: { base })
        return (model, store, hub)
    }

    @Test func saveUploadNoteMatchesTheDesktopUploadNote() async throws {
        let (model, _, hub) = try makeModel()
        let result = UploadResult(
            fileName: "Team standup.m4a", text: "we shipped the relay and the queue drained fine",
            durationSeconds: 61.5, noSpeech: false)

        let note = try await model.saveUploadNote(result)

        #expect(note.title == "we shipped the relay and the...")
        #expect(note.content == result.text)
        #expect(note.transcript == result.text)
        #expect(note.noteType == .upload)
        #expect(note.sourceFile == "Team standup.m4a")
        #expect(note.audioDurationSeconds == 61.5)
        #expect(note.folderClientId == model.defaultFolder?.clientId)
        #expect(note.syncStatus == .pending)

        await model.syncNow()
        let sent = try #require(await hub.noteCreates.first)
        #expect(sent.noteType == .upload)
        #expect(sent.sourceFile == "Team standup.m4a")
        #expect(sent.audioDurationSeconds == 61.5)
        #expect(sent.transcript == result.text)
    }

    @Test func saveUploadNoteLeavesAnUnknownDurationOut() async throws {
        let (model, _, _) = try makeModel()
        let result = UploadResult(fileName: "clip.wav", text: "short", durationSeconds: 0, noSpeech: false)
        let note = try await model.saveUploadNote(result)
        #expect(note.title == "short")
        #expect(note.audioDurationSeconds == nil)
        #expect(note.sourceFile == "clip.wav")
    }
}
