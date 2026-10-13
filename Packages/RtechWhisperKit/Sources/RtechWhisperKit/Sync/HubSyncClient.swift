import Foundation

/// One row of `POST /api/notes/batch-create`'s answer: the hub id and
/// revision the hub gave the note sent with `clientNoteId`.
public struct HubNoteCreated: Codable, Sendable, Equatable {
    public var clientNoteId: String
    public var id: String
    public var updatedAt: Date

    public init(clientNoteId: String, id: String, updatedAt: Date) {
        self.clientNoteId = clientNoteId
        self.id = id
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientNoteId = "client_note_id"
        case id
        case updatedAt = "updated_at"
    }
}

/// The hub's sync endpoints (protocol sections 3-7), one call per endpoint.
/// Networking only: it keeps no state and decides nothing about what to sync.
/// The `URLSession` is injected so tests can answer with a stub `URLProtocol`.
public struct HubSyncClient: Sendable {
    public let baseURL: URL
    private let key: String
    private let session: URLSession

    public init(baseURL: URL = HubConfiguration.defaultBaseURL, key: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
    }

    // MARK: Folders (section 3)

    /// `GET /api/folders/list`: every folder changed after `since`, or all of
    /// them when `since` is `nil`. Tombstones included.
    public func listFolders(since: Date? = nil) async throws(HubError) -> [HubFolder] {
        let list: HubFolderList = try await send(.get, "api/folders/list", query: [
            ("since", since.map(HubDate.string(from:)))
        ])
        return list.folders
    }

    /// `POST /api/folders/batch-create`: the created rows, in input order.
    public func batchCreateFolders(_ folders: [FolderCreateInput]) async throws(HubError) -> [HubFolder] {
        let reply: Created<HubFolder> = try await send(.post, "api/folders/batch-create", body: ["folders": folders])
        return reply.created
    }

    public func createFolder(_ folder: FolderCreateInput) async throws(HubError) -> HubFolder {
        try await send(.post, "api/folders/create", body: folder)
    }

    public func updateFolder(_ update: FolderUpdateInput) async throws(HubError) -> HubFolder {
        try await send(.patch, "api/folders/update", body: update)
    }

    /// `404` (`HubError.notFound`) means the folder is already gone.
    public func deleteFolder(id: String) async throws(HubError) {
        try await delete("api/folders/delete", id: id)
    }

    // MARK: Notes (section 4)

    /// Snapshot page: notes by `created_at` descending, older than the
    /// (`before`, `beforeId`) cursor when one is given.
    public func listNotes(limit: Int, before: Date? = nil, beforeId: String? = nil) async throws(HubError) -> [HubNote] {
        let list: HubNoteList = try await send(.get, "api/notes/list", query: [
            ("limit", String(limit)),
            ("before", before.map(HubDate.string(from:))),
            ("before_id", beforeId)
        ])
        return list.notes
    }

    /// Delta page: notes by `updated_at` ascending, after (`since`, `sinceId`).
    /// Tombstones included.
    public func listNoteChanges(limit: Int, since: Date, sinceId: String? = nil) async throws(HubError) -> [HubNote] {
        let list: HubNoteList = try await send(.get, "api/notes/list", query: [
            ("limit", String(limit)),
            ("since", HubDate.string(from: since)),
            ("since_id", sinceId)
        ])
        return list.notes
    }

    public func batchCreateNotes(_ notes: [NoteCreateInput]) async throws(HubError) -> [HubNoteCreated] {
        let reply: Created<HubNoteCreated> = try await send(.post, "api/notes/batch-create", body: ["notes": notes])
        return reply.created
    }

    public func createNote(_ note: NoteCreateInput) async throws(HubError) -> HubNote {
        try await send(.post, "api/notes/create", body: note)
    }

    /// With `update.baseUpdatedAt` set, a newer hub row throws
    /// `HubError.noteVersionConflict(current:)`.
    public func updateNote(_ update: NoteUpdateInput) async throws(HubError) -> HubNote {
        try await send(.patch, "api/notes/update", body: update)
    }

    public func deleteNote(id: String) async throws(HubError) {
        try await delete("api/notes/delete", id: id)
    }

    // MARK: Dictionary (section 5)

    /// Entries by (`updated_at`, `id`) ascending, after (`since`, `sinceId`).
    public func listDictionary(since: Date? = nil, sinceId: String? = nil, limit: Int? = nil) async throws(HubError) -> HubDictionaryPage {
        try await send(.get, "api/dictionary/list", query: [
            ("since", since.map(HubDate.string(from:))),
            ("since_id", sinceId),
            ("limit", limit.map(String.init))
        ])
    }

    public func batchCreateDictionary(_ entries: [DictionaryCreateInput]) async throws(HubError) -> [HubDictionaryEntry] {
        let reply: Created<HubDictionaryEntry> = try await send(.post, "api/dictionary/batch-create", body: ["entries": entries])
        return reply.created
    }

    /// A `nil` field is left out, meaning unchanged.
    public func updateDictionaryEntry(id: String, word: String? = nil, source: String? = nil) async throws(HubError) -> HubDictionaryEntry {
        try await send(.patch, "api/dictionary/update", body: DictionaryUpdate(id: id, word: word, source: source))
    }

    public func deleteDictionaryEntry(id: String) async throws(HubError) {
        try await delete("api/dictionary/delete", id: id)
    }

    // MARK: Snippets (section 6)

    /// Snapshot page by `created_at`, after the (`cursor`, `cursorId`) cursor.
    public func listSnippets(cursor: Date? = nil, cursorId: String? = nil, limit: Int? = nil) async throws(HubError) -> HubSnippetPage {
        try await send(.get, "api/snippets/list", query: [
            ("cursor", cursor.map(HubDate.string(from:))),
            ("cursor_id", cursorId),
            ("limit", limit.map(String.init))
        ])
    }

    /// Delta page by `updated_at`, after (`since`, `sinceId`). Tombstones included.
    public func listSnippetChanges(since: Date, sinceId: String? = nil, limit: Int? = nil) async throws(HubError) -> HubSnippetPage {
        try await send(.get, "api/snippets/list", query: [
            ("since", HubDate.string(from: since)),
            ("since_id", sinceId),
            ("limit", limit.map(String.init))
        ])
    }

    public func batchCreateSnippets(_ entries: [SnippetCreateInput]) async throws(HubError) -> [HubSnippetEntry] {
        let reply: Created<HubSnippetEntry> = try await snippetWrite(.post, "api/snippets/batch-create", body: ["entries": entries])
        return reply.created
    }

    /// A `nil` field is left out, meaning unchanged. A trigger another live
    /// snippet uses throws `HubError.snippetTriggerTaken`.
    public func updateSnippet(id: String, trigger: String? = nil, replacement: String? = nil) async throws(HubError) -> HubSnippetEntry {
        try await snippetWrite(.patch, "api/snippets/update", body: SnippetUpdate(id: id, trigger: trigger, replacement: replacement))
    }

    public func deleteSnippet(id: String) async throws(HubError) {
        try await delete("api/snippets/delete", id: id)
    }

    // MARK: Transcriptions (section 7)

    /// Snapshot page by `created_at` descending, older than `before`.
    public func listTranscriptions(limit: Int, before: Date? = nil) async throws(HubError) -> [HubTranscription] {
        let list: HubTranscriptionList = try await send(.get, "api/transcriptions/list", query: [
            ("limit", String(limit)),
            ("before", before.map(HubDate.string(from:)))
        ])
        return list.transcriptions
    }

    /// Delta page: rows changed after `since`. Tombstones included.
    public func listTranscriptionChanges(limit: Int, since: Date) async throws(HubError) -> [HubTranscription] {
        let list: HubTranscriptionList = try await send(.get, "api/transcriptions/list", query: [
            ("limit", String(limit)),
            ("since", HubDate.string(from: since))
        ])
        return list.transcriptions
    }

    public func batchCreateTranscriptions(_ rows: [TranscriptionCreateInput]) async throws(HubError) -> [HubTranscription] {
        let reply: Created<HubTranscription> = try await send(.post, "api/transcriptions/batch-create", body: ["transcriptions": rows])
        return reply.created
    }

    public func createTranscription(_ row: TranscriptionCreateInput) async throws(HubError) -> HubTranscription {
        try await send(.post, "api/transcriptions/create", body: row)
    }

    /// `POST /api/transcriptions/batch-delete`: the ids the hub deleted.
    public func batchDeleteTranscriptions(ids: [String]) async throws(HubError) -> [String] {
        struct Deleted: Decodable { let deleted: [String] }
        let reply: Deleted = try await send(.post, "api/transcriptions/batch-delete", body: ["ids": ids])
        return reply.deleted
    }

    // MARK: Transport

    enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    private struct Created<Row: Decodable>: Decodable {
        let created: [Row]
    }

    private struct Empty: Decodable {}

    private struct IDBody: Encodable {
        let id: String
    }

    private struct DictionaryUpdate: Encodable {
        let id: String
        let word: String?
        let source: String?
    }

    private struct SnippetUpdate: Encodable {
        let id: String
        let trigger: String?
        let replacement: String?
    }

    /// The protocol gives a snippet trigger clash a bare `409`, so any `409`
    /// on a snippet write is that clash.
    private func snippetWrite<Response: Decodable>(
        _ method: Method, _ path: String, body: some Encodable
    ) async throws(HubError) -> Response {
        do {
            return try await send(method, path, body: body)
        } catch .server(status: 409, _, _) {
            throw .snippetTriggerTaken
        }
    }

    /// `DELETE` with a JSON `{ id }` body (protocol section 1).
    private func delete(_ path: String, id: String) async throws(HubError) {
        let _: Empty = try await send(.delete, path, body: IDBody(id: id))
    }

    private func send<Response: Decodable>(
        _ method: Method, _ path: String, query: [(String, String?)] = []
    ) async throws(HubError) -> Response {
        try await perform(method, path, query: query, body: nil)
    }

    private func send<Response: Decodable>(
        _ method: Method, _ path: String, body: some Encodable
    ) async throws(HubError) -> Response {
        let data: Data
        do {
            data = try HubDate.encoder().encode(body)
        } catch {
            throw .decoding("Could not encode the request: \(error)")
        }
        return try await perform(method, path, query: [], body: data)
    }

    private func perform<Response: Decodable>(
        _ method: Method, _ path: String, query: [(String, String?)], body: Data?
    ) async throws(HubError) -> Response {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }
        var url = baseURL.appending(path: path)
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { url.append(queryItems: items) }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .network("The hub answered without an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.from(
                status: http.statusCode,
                body: data,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        do {
            return try HubDate.decoder().decode(Response.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }
}
