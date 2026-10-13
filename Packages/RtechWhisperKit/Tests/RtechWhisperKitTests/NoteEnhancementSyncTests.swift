import Foundation
import Testing

@testable import RtechWhisperKit

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func hubNote(updatedAt: Date, enhanced: String?) -> HubNote {
    HubNote(
        id: "hub-e", clientNoteId: "remote-e", title: nil, content: "raw words",
        enhancedContent: enhanced, enhancementPrompt: enhanced.map { _ in "Make notes" },
        enhancedAtContentHash: enhanced.map { _ in "10-raw words\n" },
        noteType: .personal, sourceFile: nil, audioDurationSeconds: nil, transcript: nil,
        participants: nil, calendarEventId: nil, diarizationEnabled: nil, expectedSpeakerCount: nil,
        folderId: nil, workspaceId: nil, spaceId: nil, userId: nil, updatedByUserId: nil,
        deletedAt: nil, createdAt: t0, updatedAt: updatedAt)
}

@Suite("Note enhancement sync")
struct NoteEnhancementSyncTests {
    @Test func aPullStoresTheMacsEnhancement() async throws {
        let store = try NotesStore.inMemory()
        #expect(try await store.applyFromHub(hubNote(updatedAt: t0, enhanced: "- Notes")) == .inserted)
        var local = try #require(try await store.notes().first)
        #expect(local.content == "raw words")
        #expect(local.enhancement == NoteEnhancement(content: "- Notes", prompt: "Make notes", contentHash: "10-raw words\n"))
        #expect(!local.enhancementIsOutdated)

        let later = t0.addingTimeInterval(10)
        #expect(try await store.applyFromHub(hubNote(updatedAt: later, enhanced: "- Newer")) == .applied)
        local = try #require(try await store.notes().first)
        #expect(local.enhancedContent == "- Newer")

        _ = try await store.editNote(clientId: local.clientId, content: "mine")
        try await store.replaceWithHub(clientId: local.clientId, hubNote(updatedAt: later, enhanced: nil))
        local = try #require(try await store.notes().first)
        #expect(local.enhancement == nil)
    }

    @Test func enhancingChecksWhatTheWriterRead() async throws {
        let store = try NotesStore.inMemory()
        let note = try await store.createNote(content: "raw")
        let first = NoteEnhancement(content: "one", prompt: "p", contentHash: "h")
        _ = try await store.enhanceNote(clientId: note.clientId, to: first, expecting: nil, expectedContent: "raw")

        // Stale base: the enhancement is no longer nil, or the text moved on.
        await #expect(throws: NotesStoreError.noteChangedSinceRead(note.clientId)) {
            try await store.enhanceNote(clientId: note.clientId, to: nil, expecting: nil)
        }
        await #expect(throws: NotesStoreError.noteChangedSinceRead(note.clientId)) {
            try await store.enhanceNote(clientId: note.clientId, to: nil, expecting: first, expectedContent: "other")
        }
        let stored = try await store.enhanceNote(clientId: note.clientId, to: nil, expecting: first)
        #expect(stored.content == "raw")
        #expect(stored.enhancement == nil)
        #expect(stored.syncStatus == .pending)
    }

    @Test func aPhoneEditLeavesTheHubsEnhancementAlone() throws {
        // A note pulled before the phone stored enhanced_* holds nil here;
        // the PATCH must leave those keys out, not send null.
        let input = NoteUpdateInput(id: "h", title: nil, content: "x", fullPayload: true)
        let json = try #require(String(data: JSONEncoder().encode(input), encoding: .utf8))
        #expect(!json.contains("enhanced_content"))
        #expect(!json.contains("enhancement_prompt"))
    }
}
