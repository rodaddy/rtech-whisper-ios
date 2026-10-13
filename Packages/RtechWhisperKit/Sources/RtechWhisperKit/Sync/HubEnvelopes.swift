import Foundation

/// `GET /api/folders/list`: `{ folders }`, tombstones included.
public struct HubFolderList: Codable, Sendable, Equatable {
    public var folders: [HubFolder]
}

/// `GET /api/notes/list`: `{ notes }`, tombstones included.
public struct HubNoteList: Codable, Sendable, Equatable {
    public var notes: [HubNote]
}

/// `GET /api/dictionary/list`: `{ entries, hasMore }`. `hasMore` is
/// camelCase on the wire.
public struct HubDictionaryPage: Codable, Sendable, Equatable {
    public var entries: [HubDictionaryEntry]
    public var hasMore: Bool
}

/// `GET /api/snippets/list`: `{ entries, hasMore }`.
public struct HubSnippetPage: Codable, Sendable, Equatable {
    public var entries: [HubSnippetEntry]
    public var hasMore: Bool
}

/// `GET /api/transcriptions/list`: `{ transcriptions }`.
public struct HubTranscriptionList: Codable, Sendable, Equatable {
    public var transcriptions: [HubTranscription]
}

/// The body of every non-2xx answer except `401` and `503`:
/// `{ error: { message }, code, data }` (protocol section 1).
public struct HubAPIError: Codable, Sendable, Equatable, Error {
    public struct Message: Codable, Sendable, Equatable {
        public var message: String
    }

    /// Extra detail some codes carry. For `note_version_conflict` (`409`),
    /// `note` is the hub's current row.
    public struct Detail: Codable, Sendable, Equatable {
        public var note: HubNote?
    }

    public static let noteVersionConflict = "note_version_conflict"
    public static let folderNameTaken = "folder_name_taken"
    /// Not named by the protocol, which gives a snippet trigger clash a bare
    /// `409`; `HubSyncClient` maps any `409` on a snippet write to
    /// `HubError.snippetTriggerTaken` as well.
    public static let snippetTriggerTaken = "snippet_trigger_taken"

    public var error: Message
    public var code: String?
    public var data: Detail?
}
