import Foundation
import Testing

@testable import RtechWhisperKit

private func fixtureText(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name).json")
    return try String(contentsOf: url, encoding: .utf8)
}

/// A sync client whose hub always answers `status` with `body`.
private func stubbedSync(_ status: Int, _ body: String) -> (client: HubSyncClient, host: String) {
    let (session, baseURL, host) = StubHub.register(.init(status: status, body: body))
    return (HubSyncClient(baseURL: baseURL, key: goodKey, session: session), host)
}

/// The one request sent to `host`, its query as a dictionary, and its JSON body.
private func sent(to host: String) throws -> (request: URLRequest, query: [String: String], body: [String: Any]?) {
    let request = try #require(StubHub.requests(to: host).first)
    let url = try #require(request.url)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    let data = try #require(StubHub.bodies(to: host).first)
    let body = data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (request, query, body)
}

private let t1 = HubDate.date(from: "2026-09-29T10:15:30.123Z")!
private let t2 = HubDate.date(from: "2026-09-29T11:00:00.007Z")!

private let folderJSON = #"""
{"id":"f-1","client_folder_id":"local-f-1","name":"Work","is_default":false,"sort_order":2,
 "workspace_id":null,"space_id":null,"deleted_at":null,
 "created_at":"2026-09-29T09:00:00.000Z","updated_at":"2026-09-29T10:15:30.123Z"}
"""#

private let snippetJSON = #"""
{"id":"s-1","client_snippet_id":"local-s-1","trigger":";sig","replacement":"Rico",
 "deleted_at":null,"created_at":"2026-09-29T09:00:00.000Z","updated_at":"2026-09-29T10:15:30.123Z"}
"""#

@Suite("Hub sync client requests")
struct HubSyncClientRequestTests {
    @Test func folderUpdateIsAPatchWithTheChangedFields() async throws {
        let (client, host) = stubbedSync(200, folderJSON)
        let folder = try await client.updateFolder(FolderUpdateInput(id: "f-1", name: "Work", sortOrder: 2))
        #expect(folder.id == "f-1")
        let (request, query, body) = try sent(to: host)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/folders/update")
        #expect(query.isEmpty)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body?["id"] as? String == "f-1")
        #expect(body?["name"] as? String == "Work")
        #expect(body?["sort_order"] as? Int == 2)
    }

    @Test func noteSnapshotListSendsTheBeforeCursor() async throws {
        let (client, host) = stubbedSync(200, try fixtureText("notes-list"))
        let notes = try await client.listNotes(limit: 50, before: t1, beforeId: "n-9")
        #expect(!notes.isEmpty)
        let (request, query, body) = try sent(to: host)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/notes/list")
        #expect(query == ["limit": "50", "before": "2026-09-29T10:15:30.123Z", "before_id": "n-9"])
        #expect(body == nil)
    }

    @Test func dictionaryBatchCreateWrapsEntriesWithMillisecondTimestamps() async throws {
        let (client, host) = stubbedSync(200, #"{"created":[]}"#)
        let created = try await client.batchCreateDictionary([
            DictionaryCreateInput(clientDictId: "d-1", word: "Webpack", source: "manual", createdAt: t1, updatedAt: t2)
        ])
        #expect(created.isEmpty)
        let (request, _, body) = try sent(to: host)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/dictionary/batch-create")
        let entries = try #require(body?["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["client_dict_id"] as? String == "d-1")
        #expect(entries[0]["created_at"] as? String == "2026-09-29T10:15:30.123Z")
        #expect(entries[0]["updated_at"] as? String == "2026-09-29T11:00:00.007Z")
    }

    @Test func snippetUpdateLeavesOutUnchangedFields() async throws {
        let (client, host) = stubbedSync(200, snippetJSON)
        let snippet = try await client.updateSnippet(id: "s-1", trigger: ";sig")
        #expect(snippet.trigger == ";sig")
        let (request, _, body) = try sent(to: host)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/snippets/update")
        #expect(body?.keys.sorted() == ["id", "trigger"])
    }

    @Test func transcriptionBatchDeletePostsTheIds() async throws {
        let (client, host) = stubbedSync(200, #"{"deleted":["t-1","t-2"]}"#)
        let deleted = try await client.batchDeleteTranscriptions(ids: ["t-1", "t-2"])
        #expect(deleted == ["t-1", "t-2"])
        let (request, _, body) = try sent(to: host)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/transcriptions/batch-delete")
        #expect(body?["ids"] as? [String] == ["t-1", "t-2"])
    }

    @Test func deleteCarriesTheIdAsAJSONBody() async throws {
        let (client, host) = stubbedSync(200, "{}")
        try await client.deleteNote(id: "n-1")
        let (request, query, body) = try sent(to: host)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/notes/delete")
        #expect(query.isEmpty)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body?.keys.sorted() == ["id"])
        #expect(body?["id"] as? String == "n-1")
    }

    @Test func deltaListSendsSinceAndSinceIdInMilliseconds() async throws {
        let (client, host) = stubbedSync(200, try fixtureText("snippets-page"))
        _ = try await client.listSnippetChanges(since: t2, sinceId: "s-4", limit: 50)
        let (request, query, _) = try sent(to: host)
        #expect(request.url?.path == "/api/snippets/list")
        #expect(query == ["since": "2026-09-29T11:00:00.007Z", "since_id": "s-4", "limit": "50"])
    }

    @Test func noteDeltaListSendsSinceAndSinceId() async throws {
        let (client, host) = stubbedSync(200, try fixtureText("notes-list"))
        _ = try await client.listNoteChanges(limit: 50, since: t1, sinceId: "n-2")
        let (_, query, _) = try sent(to: host)
        #expect(query == ["limit": "50", "since": "2026-09-29T10:15:30.123Z", "since_id": "n-2"])
    }
}

@Suite("Hub sync client errors")
struct HubSyncClientErrorTests {
    @Test func noteVersionConflictCarriesTheHubsNote() async throws {
        let body = try fixtureText("note-version-conflict")
        let expected = try #require(
            try HubDate.decoder().decode(HubAPIError.self, from: Data(body.utf8)).data?.note)
        let (client, _) = stubbedSync(409, body)
        await #expect(throws: HubError.noteVersionConflict(current: expected)) {
            try await client.updateNote(NoteUpdateInput(id: expected.id, baseUpdatedAt: t1, content: "Mine"))
        }
    }

    @Test func folderNameTakenMaps() async {
        let (client, _) = stubbedSync(409, #"{"error":{"message":"taken"},"code":"folder_name_taken","data":null}"#)
        await #expect(throws: HubError.folderNameTaken) {
            try await client.createFolder(FolderCreateInput(name: "Work", clientFolderId: "f", isDefault: false, sortOrder: 0))
        }
    }

    @Test func bare409OnASnippetWriteIsATriggerClash() async {
        let (client, _) = stubbedSync(409, #"{"error":{"message":"trigger in use"},"code":"conflict"}"#)
        await #expect(throws: HubError.snippetTriggerTaken) {
            try await client.updateSnippet(id: "s-1", trigger: ";sig")
        }
    }

    @Test func status404MapsToNotFound() async {
        let (client, _) = stubbedSync(404, #"{"error":{"message":"no such folder"},"code":"not_found"}"#)
        await #expect(throws: HubError.notFound) {
            try await client.deleteFolder(id: "gone")
        }
    }

    @Test func status401MapsToUnauthorized() async {
        let (client, _) = stubbedSync(401, unauthorizedBody)
        await #expect(throws: HubError.unauthorized) {
            try await client.listFolders()
        }
    }

    @Test func status400CarriesTheMessage() async {
        let (client, _) = stubbedSync(400, #"{"error":{"message":"limit too large"},"code":"invalid_request"}"#)
        await #expect(throws: HubError.invalidRequest(message: "limit too large")) {
            try await client.listTranscriptions(limit: 10_000)
        }
    }

    @Test func otherStatusesStillMapToServer() async {
        let (client, _) = stubbedSync(500, #"{"error":{"message":"boom"},"code":"internal"}"#)
        await #expect(throws: HubError.server(status: 500, code: "internal", message: "boom")) {
            try await client.listFolders()
        }
    }
}
