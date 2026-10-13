import Foundation

// The row types the hub returns (protocol sections 3-7). Decode and encode
// them with `HubDate.decoder()` / `HubDate.encoder()`.
//
// Each row writes its optional fields as explicit `null`, as the hub sends
// them, so a row round-trips to the JSON it came from.

/// `Folder` (protocol section 3).
public struct HubFolder: Codable, Sendable, Equatable {
    public var id: String
    public var clientFolderId: String?
    public var name: String
    public var isDefault: Bool
    public var sortOrder: Int
    public var workspaceId: String?
    public var spaceId: String?
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientFolderId = "client_folder_id"
        case name
        case isDefault = "is_default"
        case sortOrder = "sort_order"
        case workspaceId = "workspace_id"
        case spaceId = "space_id"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientFolderId, forKey: .clientFolderId)
        try c.encode(name, forKey: .name)
        try c.encode(isDefault, forKey: .isDefault)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(spaceId, forKey: .spaceId)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// A note's `note_type`. Values this build does not know decode as `.other`
/// and encode back unchanged, so a newer desktop cannot break a pull.
public enum HubNoteType: Codable, Sendable, Equatable, Hashable {
    case personal
    case meeting
    case upload
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "personal": self = .personal
        case "meeting": self = .meeting
        case "upload": self = .upload
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .personal: "personal"
        case .meeting: "meeting"
        case .upload: "upload"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// `Note` (protocol section 4). `folderId` is the folder's hub id.
public struct HubNote: Codable, Sendable, Equatable {
    public var id: String
    public var clientNoteId: String?
    public var title: String?
    public var content: String
    public var enhancedContent: String?
    public var enhancementPrompt: String?
    public var enhancedAtContentHash: String?
    public var noteType: HubNoteType
    public var sourceFile: String?
    public var audioDurationSeconds: Double?
    public var transcript: String?
    /// The desktop stores this as a JSON string; it is carried through as-is.
    public var participants: String?
    public var calendarEventId: String?
    /// `0`/`1`, or `null` when the user never chose.
    public var diarizationEnabled: Int?
    public var expectedSpeakerCount: Int?
    public var folderId: String?
    public var workspaceId: String?
    public var spaceId: String?
    public var userId: String?
    public var updatedByUserId: String?
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientNoteId = "client_note_id"
        case title
        case content
        case enhancedContent = "enhanced_content"
        case enhancementPrompt = "enhancement_prompt"
        case enhancedAtContentHash = "enhanced_at_content_hash"
        case noteType = "note_type"
        case sourceFile = "source_file"
        case audioDurationSeconds = "audio_duration_seconds"
        case transcript
        case participants
        case calendarEventId = "calendar_event_id"
        case diarizationEnabled = "diarization_enabled"
        case expectedSpeakerCount = "expected_speaker_count"
        case folderId = "folder_id"
        case workspaceId = "workspace_id"
        case spaceId = "space_id"
        case userId = "user_id"
        case updatedByUserId = "updated_by_user_id"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientNoteId, forKey: .clientNoteId)
        try c.encode(title, forKey: .title)
        try c.encode(content, forKey: .content)
        try c.encode(enhancedContent, forKey: .enhancedContent)
        try c.encode(enhancementPrompt, forKey: .enhancementPrompt)
        try c.encode(enhancedAtContentHash, forKey: .enhancedAtContentHash)
        try c.encode(noteType, forKey: .noteType)
        try c.encode(sourceFile, forKey: .sourceFile)
        try c.encode(audioDurationSeconds, forKey: .audioDurationSeconds)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(participants, forKey: .participants)
        try c.encode(calendarEventId, forKey: .calendarEventId)
        try c.encode(diarizationEnabled, forKey: .diarizationEnabled)
        try c.encode(expectedSpeakerCount, forKey: .expectedSpeakerCount)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(spaceId, forKey: .spaceId)
        try c.encode(userId, forKey: .userId)
        try c.encode(updatedByUserId, forKey: .updatedByUserId)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// `DictionaryEntry` (protocol section 5). `source` is `manual` or `learned`.
public struct HubDictionaryEntry: Codable, Sendable, Equatable {
    public var id: String
    public var clientDictId: String?
    public var word: String
    public var source: String
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientDictId = "client_dict_id"
        case word
        case source
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientDictId, forKey: .clientDictId)
        try c.encode(word, forKey: .word)
        try c.encode(source, forKey: .source)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// `SnippetEntry` (protocol section 6).
public struct HubSnippetEntry: Codable, Sendable, Equatable {
    public var id: String
    public var clientSnippetId: String?
    public var trigger: String
    public var replacement: String
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientSnippetId = "client_snippet_id"
        case trigger
        case replacement
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientSnippetId, forKey: .clientSnippetId)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// `Transcription`, one dictation-history row (protocol section 7).
public struct HubTranscription: Codable, Sendable, Equatable {
    public var id: String
    public var clientTranscriptionId: String?
    public var text: String
    public var rawText: String?
    public var provider: String?
    public var model: String?
    public var audioDurationMs: Int?
    public var status: String
    public var deletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case clientTranscriptionId = "client_transcription_id"
        case text
        case rawText = "raw_text"
        case provider
        case model
        case audioDurationMs = "audio_duration_ms"
        case status
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(clientTranscriptionId, forKey: .clientTranscriptionId)
        try c.encode(text, forKey: .text)
        try c.encode(rawText, forKey: .rawText)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(audioDurationMs, forKey: .audioDurationMs)
        try c.encode(status, forKey: .status)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
