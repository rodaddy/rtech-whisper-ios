import Foundation
import Testing

@testable import RtechWhisperKit

/// JSON fixtures written from the protocol's shapes, next to this file.
private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name).json")
    return try Data(contentsOf: url)
}

/// Parses JSON into Foundation objects so two documents compare by content,
/// not by key order or whitespace.
private func jsonObject(_ data: Data) throws -> NSObject {
    try #require(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
}

/// Decodes `name` as `T`, encodes it back, and checks the JSON is identical.
@discardableResult
private func roundTrip<T: Codable>(_ type: T.Type, _ name: String) throws -> T {
    let original = try fixture(name)
    let value = try HubDate.decoder().decode(T.self, from: original)
    let encoded = try HubDate.encoder().encode(value)
    #expect(try jsonObject(encoded) == jsonObject(original))
    return value
}

private func encodedKeys(_ value: some Encodable) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: HubDate.encoder().encode(value))
    return Set(try #require(object as? [String: Any]).keys)
}

@Suite("Hub sync models")
struct SyncModelTests {
    @Test func folderListRoundTrips() throws {
        let list = try roundTrip(HubFolderList.self, "folders-list")
        #expect(list.folders.count == 2)
        #expect(list.folders[0].isDefault)
        #expect(list.folders[0].clientFolderId == "local-folder-personal")
        #expect(list.folders[1].clientFolderId == nil)
        #expect(list.folders[1].deletedAt.map(HubDate.string) == "2026-09-29T11:00:00.001Z")
    }

    @Test func noteListRoundTrips() throws {
        let note = try #require(try roundTrip(HubNoteList.self, "notes-list").notes.first)
        #expect(note.noteType == .meeting)
        #expect(note.audioDurationSeconds == 754.5)
        #expect(note.diarizationEnabled == 1)
        #expect(note.folderId == "6f1c2a8e-0d4b-4c1e-9a55-2f7b3c9d1e01")
        #expect(note.enhancedContent == nil)
    }

    @Test func dictionaryPageRoundTrips() throws {
        let page = try roundTrip(HubDictionaryPage.self, "dictionary-page")
        #expect(page.hasMore)
        #expect(page.entries.first?.word == "Webpack")
        #expect(page.entries.first?.clientDictId == "local-dict-1")
    }

    @Test func snippetPageRoundTrips() throws {
        let page = try roundTrip(HubSnippetPage.self, "snippets-page")
        #expect(!page.hasMore)
        #expect(page.entries.first?.clientSnippetId == "local-snippet-1")
    }

    @Test func transcriptionListRoundTrips() throws {
        let row = try #require(try roundTrip(HubTranscriptionList.self, "transcriptions-list").transcriptions.first)
        #expect(row.audioDurationMs == 2350)
        #expect(row.rawText == "hello from the phone")
    }

    @Test func versionConflictCarriesTheHubNote() throws {
        let body = try roundTrip(HubAPIError.self, "note-version-conflict")
        #expect(body.code == HubAPIError.noteVersionConflict)
        #expect(body.error.message.hasPrefix("The note changed"))
        let note = try #require(body.data?.note)
        #expect(note.content == "Edited on the Mac.")
        #expect(note.updatedAt == HubDate.date(from: "2026-09-29T10:20:00.456Z"))
    }

    @Test func errorWithoutDataDecodes() throws {
        let json = #"{"error":{"message":"Name taken"},"code":"folder_name_taken"}"#
        let body = try HubDate.decoder().decode(HubAPIError.self, from: Data(json.utf8))
        #expect(body.code == HubAPIError.folderNameTaken)
        #expect(body.data == nil)
    }

    @Test(arguments: [
        "2026-09-29T10:15:30.123Z",
        "2026-09-29T10:15:30.999Z",
        "2026-09-29T10:15:30.001Z",
        "2026-09-29T10:15:30.000Z",
        "1969-12-31T23:59:59.999Z",
    ])
    func millisecondTimestampSurvivesExactly(_ stamp: String) throws {
        let date = try #require(HubDate.date(from: stamp))
        #expect(HubDate.string(from: date) == stamp)

        let json = Data(#"{"at":"\#(stamp)"}"#.utf8)
        struct Box: Codable { let at: Date }
        let box = try HubDate.decoder().decode(Box.self, from: json)
        #expect(String(decoding: try HubDate.encoder().encode(box), as: UTF8.self) == #"{"at":"\#(stamp)"}"#)
    }

    @Test func timestampWithoutZoneIsRejected() {
        #expect(HubDate.date(from: "2026-09-29T10:15:30.123") == nil)
        #expect(HubDate.date(from: "2026-09-29T10:15:30.12xZ") == nil)
    }

    @Test func unknownNoteTypeDecodesAndSurvives() throws {
        let json = String(decoding: try fixture("notes-list"), as: UTF8.self)
            .replacingOccurrences(of: #""note_type": "meeting""#, with: #""note_type": "voice_memo""#)
        let list = try HubDate.decoder().decode(HubNoteList.self, from: Data(json.utf8))
        #expect(list.notes.first?.noteType == .other("voice_memo"))
        let again = try jsonObject(HubDate.encoder().encode(list))
        #expect(again == (try jsonObject(Data(json.utf8))))
    }

    @Test func noteCreateInputCarriesNoUpdateStamps() throws {
        let input = NoteCreateInput(
            clientNoteId: "local-note-2",
            createdAt: try #require(HubDate.date(from: "2026-09-29T12:00:00.042Z")),
            content: "New on the phone.",
            noteType: .personal
        )
        let keys = try encodedKeys(input)
        #expect(keys == ["client_note_id", "created_at", "content", "note_type"])
        let decoded = try HubDate.decoder().decode(NoteCreateInput.self, from: HubDate.encoder().encode(input))
        #expect(decoded == input)
    }

    @Test func noteUpdateInputSendsBaseOnlyWhenSet() throws {
        let lastWriterWins = NoteUpdateInput(id: "n1", content: "x")
        #expect(try encodedKeys(lastWriterWins) == ["id", "content"])

        let base = try #require(HubDate.date(from: "2026-09-29T10:15:30.999Z"))
        let guarded = NoteUpdateInput(id: "n1", baseUpdatedAt: base, content: "x")
        let object = try #require(
            JSONSerialization.jsonObject(with: HubDate.encoder().encode(guarded)) as? [String: Any])
        #expect(object["base_updated_at"] as? String == "2026-09-29T10:15:30.999Z")
    }

    @Test func fullPayloadUpdateWritesEveryModeledFieldWithExplicitNulls() throws {
        let folderless = NoteUpdateInput(id: "n1", content: "x", noteType: .personal, fullPayload: true)
        let object = try #require(
            JSONSerialization.jsonObject(with: HubDate.encoder().encode(folderless)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "title", "content", "note_type", "transcript", "folder_id"])
        #expect(object["folder_id"] is NSNull)
        #expect(object["title"] is NSNull)

        let base = try #require(HubDate.date(from: "2026-09-29T10:15:30.999Z"))
        let edit = NoteUpdateInput(
            id: "n1", baseUpdatedAt: base, title: "T", content: "x", noteType: .personal,
            transcript: "t", folderId: "f1", fullPayload: true)
        let full = try #require(
            JSONSerialization.jsonObject(with: HubDate.encoder().encode(edit)) as? [String: Any])
        #expect(full["folder_id"] as? String == "f1")
        #expect(full["title"] as? String == "T")
        #expect(full["transcript"] as? String == "t")
        #expect(full["base_updated_at"] as? String == "2026-09-29T10:15:30.999Z")
    }

    @Test func createInputsUseSnakeCaseKeys() throws {
        let at = try #require(HubDate.date(from: "2026-09-29T12:00:00.000Z"))
        #expect(try encodedKeys(FolderCreateInput(name: "Work", clientFolderId: "f", isDefault: false, sortOrder: 1))
            == ["name", "client_folder_id", "is_default", "sort_order"])
        #expect(try encodedKeys(DictionaryCreateInput(clientDictId: "d", word: "w", source: "learned", createdAt: at, updatedAt: at))
            == ["client_dict_id", "word", "source", "created_at", "updated_at"])
        #expect(try encodedKeys(SnippetCreateInput(clientSnippetId: "s", trigger: "t", replacement: "r", createdAt: at, updatedAt: at))
            == ["client_snippet_id", "trigger", "replacement", "created_at", "updated_at"])
        #expect(try encodedKeys(TranscriptionCreateInput(clientTranscriptionId: "t", text: "hi", audioDurationMs: 900, status: "completed", createdAt: at))
            == ["client_transcription_id", "text", "audio_duration_ms", "status", "created_at"])
        #expect(try encodedKeys(FolderUpdateInput(id: "f", name: "Renamed")) == ["id", "name"])
    }
}
