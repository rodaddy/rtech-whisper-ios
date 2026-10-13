import Foundation

// Request bodies the client sends (protocol sections 3-7). Unlike the rows,
// an input leaves a `nil` field out of the JSON entirely: for a PATCH an
// absent field means "unchanged".

/// One folder for `POST /api/folders/create` or `batch-create`.
public struct FolderCreateInput: Codable, Sendable, Equatable {
    public var name: String
    public var clientFolderId: String
    public var isDefault: Bool
    public var sortOrder: Int

    public init(name: String, clientFolderId: String, isDefault: Bool, sortOrder: Int) {
        self.name = name
        self.clientFolderId = clientFolderId
        self.isDefault = isDefault
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case name
        case clientFolderId = "client_folder_id"
        case isDefault = "is_default"
        case sortOrder = "sort_order"
    }
}

/// `PATCH /api/folders/update`.
public struct FolderUpdateInput: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var sortOrder: Int?

    public init(id: String, name: String? = nil, sortOrder: Int? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
    }
}

/// One note for `POST /api/notes/create` or `batch-create`. It carries no
/// `updated_at` and no `base_updated_at`: the hub stamps the row itself.
public struct NoteCreateInput: Codable, Sendable, Equatable {
    public var clientNoteId: String
    public var createdAt: Date
    public var title: String?
    public var content: String
    public var enhancedContent: String?
    public var enhancementPrompt: String?
    public var enhancedAtContentHash: String?
    public var noteType: HubNoteType?
    public var sourceFile: String?
    public var audioDurationSeconds: Double?
    public var transcript: String?
    public var participants: String?
    public var calendarEventId: String?
    public var diarizationEnabled: Int?
    public var expectedSpeakerCount: Int?
    public var folderId: String?

    public init(
        clientNoteId: String, createdAt: Date, title: String? = nil, content: String,
        enhancedContent: String? = nil, enhancementPrompt: String? = nil,
        enhancedAtContentHash: String? = nil, noteType: HubNoteType? = nil,
        sourceFile: String? = nil, audioDurationSeconds: Double? = nil, transcript: String? = nil,
        participants: String? = nil, calendarEventId: String? = nil, diarizationEnabled: Int? = nil,
        expectedSpeakerCount: Int? = nil, folderId: String? = nil
    ) {
        self.clientNoteId = clientNoteId
        self.createdAt = createdAt
        self.title = title
        self.content = content
        self.enhancedContent = enhancedContent
        self.enhancementPrompt = enhancementPrompt
        self.enhancedAtContentHash = enhancedAtContentHash
        self.noteType = noteType
        self.sourceFile = sourceFile
        self.audioDurationSeconds = audioDurationSeconds
        self.transcript = transcript
        self.participants = participants
        self.calendarEventId = calendarEventId
        self.diarizationEnabled = diarizationEnabled
        self.expectedSpeakerCount = expectedSpeakerCount
        self.folderId = folderId
    }

    enum CodingKeys: String, CodingKey {
        case clientNoteId = "client_note_id"
        case createdAt = "created_at"
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
    }
}

/// `PATCH /api/notes/update`. With `baseUpdatedAt` set, the hub answers `409
/// note_version_conflict` when its row is newer; without it the write is
/// last-writer-wins (protocol section 8).
public struct NoteUpdateInput: Codable, Sendable, Equatable {
    public var id: String
    public var baseUpdatedAt: Date?
    public var title: String?
    public var content: String?
    public var enhancedContent: String?
    public var enhancementPrompt: String?
    public var enhancedAtContentHash: String?
    public var noteType: HubNoteType?
    public var sourceFile: String?
    public var audioDurationSeconds: Double?
    public var transcript: String?
    public var participants: String?
    public var calendarEventId: String?
    public var diarizationEnabled: Int?
    public var expectedSpeakerCount: Int?
    public var folderId: String?
    /// When true, the fields this app models (title, content, note_type,
    /// transcript, folder_id) are always written, as explicit `null` when nil,
    /// so the hub clears them: a folderless note must send `"folder_id": null`
    /// or it never leaves its old folder. Mirrors the desktop's
    /// `buildNoteUpdatePayload`. Fields the phone does not model
    /// (participants, ...) stay omitted so a phone edit never wipes them.
    /// The enhanced_* fields are sent only when set: a note pulled before the
    /// phone stored them holds `nil` here while the hub may hold the Mac's
    /// enhancement, so `nil` must mean "unchanged"; clearing sends `""`.
    public var fullPayload = false

    public init(
        id: String, baseUpdatedAt: Date? = nil, title: String? = nil, content: String? = nil,
        enhancedContent: String? = nil, enhancementPrompt: String? = nil,
        enhancedAtContentHash: String? = nil, noteType: HubNoteType? = nil,
        sourceFile: String? = nil, audioDurationSeconds: Double? = nil, transcript: String? = nil,
        participants: String? = nil, calendarEventId: String? = nil, diarizationEnabled: Int? = nil,
        expectedSpeakerCount: Int? = nil, folderId: String? = nil, fullPayload: Bool = false
    ) {
        self.id = id
        self.fullPayload = fullPayload
        self.baseUpdatedAt = baseUpdatedAt
        self.title = title
        self.content = content
        self.enhancedContent = enhancedContent
        self.enhancementPrompt = enhancementPrompt
        self.enhancedAtContentHash = enhancedAtContentHash
        self.noteType = noteType
        self.sourceFile = sourceFile
        self.audioDurationSeconds = audioDurationSeconds
        self.transcript = transcript
        self.participants = participants
        self.calendarEventId = calendarEventId
        self.diarizationEnabled = diarizationEnabled
        self.expectedSpeakerCount = expectedSpeakerCount
        self.folderId = folderId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case baseUpdatedAt = "base_updated_at"
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
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(baseUpdatedAt, forKey: .baseUpdatedAt)
        if fullPayload {
            try c.encode(title, forKey: .title)
            try c.encode(content, forKey: .content)
            try c.encode(noteType, forKey: .noteType)
            try c.encode(transcript, forKey: .transcript)
            try c.encode(folderId, forKey: .folderId)
        } else {
            try c.encodeIfPresent(title, forKey: .title)
            try c.encodeIfPresent(content, forKey: .content)
            try c.encodeIfPresent(noteType, forKey: .noteType)
            try c.encodeIfPresent(transcript, forKey: .transcript)
            try c.encodeIfPresent(folderId, forKey: .folderId)
        }
        try c.encodeIfPresent(enhancedContent, forKey: .enhancedContent)
        try c.encodeIfPresent(enhancementPrompt, forKey: .enhancementPrompt)
        try c.encodeIfPresent(enhancedAtContentHash, forKey: .enhancedAtContentHash)
        try c.encodeIfPresent(sourceFile, forKey: .sourceFile)
        try c.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
        try c.encodeIfPresent(participants, forKey: .participants)
        try c.encodeIfPresent(calendarEventId, forKey: .calendarEventId)
        try c.encodeIfPresent(diarizationEnabled, forKey: .diarizationEnabled)
        try c.encodeIfPresent(expectedSpeakerCount, forKey: .expectedSpeakerCount)
    }
}

/// One entry for `POST /api/dictionary/batch-create`.
public struct DictionaryCreateInput: Codable, Sendable, Equatable {
    public var clientDictId: String
    public var word: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(clientDictId: String, word: String, source: String, createdAt: Date, updatedAt: Date) {
        self.clientDictId = clientDictId
        self.word = word
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientDictId = "client_dict_id"
        case word
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One entry for `POST /api/snippets/batch-create`.
public struct SnippetCreateInput: Codable, Sendable, Equatable {
    public var clientSnippetId: String
    public var trigger: String
    public var replacement: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(clientSnippetId: String, trigger: String, replacement: String, createdAt: Date, updatedAt: Date) {
        self.clientSnippetId = clientSnippetId
        self.trigger = trigger
        self.replacement = replacement
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case clientSnippetId = "client_snippet_id"
        case trigger
        case replacement
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// One row for `POST /api/transcriptions/create` or `batch-create`.
public struct TranscriptionCreateInput: Codable, Sendable, Equatable {
    public var clientTranscriptionId: String
    public var text: String
    public var rawText: String?
    public var provider: String?
    public var model: String?
    public var audioDurationMs: Int?
    public var status: String
    public var createdAt: Date

    public init(
        clientTranscriptionId: String, text: String, rawText: String? = nil, provider: String? = nil,
        model: String? = nil, audioDurationMs: Int? = nil, status: String, createdAt: Date
    ) {
        self.clientTranscriptionId = clientTranscriptionId
        self.text = text
        self.rawText = rawText
        self.provider = provider
        self.model = model
        self.audioDurationMs = audioDurationMs
        self.status = status
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case clientTranscriptionId = "client_transcription_id"
        case text
        case rawText = "raw_text"
        case provider
        case model
        case audioDurationMs = "audio_duration_ms"
        case status
        case createdAt = "created_at"
    }
}
