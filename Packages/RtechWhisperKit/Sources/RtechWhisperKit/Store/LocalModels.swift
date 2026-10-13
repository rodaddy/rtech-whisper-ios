import Foundation
import SwiftData

/// Where a local row stands against the hub. Mirrors the desktop's
/// `sync_status` column.
public enum SyncStatus: String, Codable, Sendable {
    /// Local changes the hub has not accepted yet.
    case pending
    /// The row matches what the hub last acknowledged.
    case synced
    /// The last push failed in a way a retry will not fix by itself.
    case error
}

/// A folder on this phone. `clientId` is this device's id for the row;
/// `cloudId` is the hub's, `nil` until the first push succeeds.
@Model
public final class LocalFolder {
    @Attribute(.unique) public var clientId: String
    public var cloudId: String?
    public var name: String
    public var isDefault: Bool
    public var sortOrder: Int
    /// `SyncStatus` raw value, stored as a string so predicates can use it.
    public var syncStatusRaw: String
    /// Local tombstone: set on delete until the hub accepts it.
    public var deletedAt: Date?
    /// The hub's `updated_at` this device last saw; the base for "is the hub newer".
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .nullify, inverse: \LocalNote.folder)
    public var notes: [LocalNote] = []

    public var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }

    public init(
        clientId: String, cloudId: String? = nil, name: String, isDefault: Bool, sortOrder: Int,
        syncStatus: SyncStatus, deletedAt: Date? = nil, cloudUpdatedAt: Date? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.clientId = clientId
        self.cloudId = cloudId
        self.name = name
        self.isDefault = isDefault
        self.sortOrder = sortOrder
        self.syncStatusRaw = syncStatus.rawValue
        self.deletedAt = deletedAt
        self.cloudUpdatedAt = cloudUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A note on this phone. `cloudUpdatedAt` is the hub revision this device
/// last saw, sent as `base_updated_at` on the next PATCH (protocol section 8).
@Model
public final class LocalNote {
    @Attribute(.unique) public var clientId: String
    public var cloudId: String?
    public var folder: LocalFolder?
    public var title: String?
    public var content: String
    public var transcript: String?
    /// `HubNoteType` raw value.
    public var noteType: String
    /// The uploaded file's name, for an `upload` note (desktop `source_file`).
    public var sourceFile: String?
    /// The uploaded audio's length, for an `upload` note.
    public var audioDurationSeconds: Double?
    /// An AI action's result, kept apart from `content` (desktop "Enhanced"
    /// tab; hub `enhanced_content`). `nil` when this device never saw one;
    /// `""` when it was cleared here (see `NoteEnhancement.cleared`).
    public var enhancedContent: String? = nil
    /// The action prompt that produced `enhancedContent`.
    public var enhancementPrompt: String? = nil
    /// `NoteEnhancement.contentHash` of the note when it was enhanced.
    public var enhancedAtContentHash: String? = nil
    /// The hub `folder_id` as of `cloudUpdatedAt`, kept apart from `folder`
    /// so a note whose hub folder was deleted (and so has no local folder)
    /// can still be refiled at the end of a pull.
    public var hubFolderId: String? = nil
    public var syncStatusRaw: String
    public var deletedAt: Date?
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }

    public init(
        clientId: String, cloudId: String? = nil, folder: LocalFolder? = nil, title: String? = nil,
        content: String, transcript: String? = nil, noteType: String, sourceFile: String? = nil,
        audioDurationSeconds: Double? = nil, enhancedContent: String? = nil, enhancementPrompt: String? = nil,
        enhancedAtContentHash: String? = nil, syncStatus: SyncStatus,
        deletedAt: Date? = nil, cloudUpdatedAt: Date? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.clientId = clientId
        self.cloudId = cloudId
        self.folder = folder
        self.title = title
        self.content = content
        self.transcript = transcript
        self.noteType = noteType
        self.sourceFile = sourceFile
        self.audioDurationSeconds = audioDurationSeconds
        self.enhancedContent = enhancedContent
        self.enhancementPrompt = enhancementPrompt
        self.enhancedAtContentHash = enhancedAtContentHash
        self.syncStatusRaw = syncStatus.rawValue
        self.deletedAt = deletedAt
        self.cloudUpdatedAt = cloudUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A `Sendable` copy of a `LocalFolder`, safe to hand out of the store actor.
public struct FolderRecord: Sendable, Equatable {
    public var clientId: String
    public var cloudId: String?
    public var name: String
    public var isDefault: Bool
    public var sortOrder: Int
    public var syncStatus: SyncStatus
    public var deletedAt: Date?
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    init(_ folder: LocalFolder) {
        clientId = folder.clientId
        cloudId = folder.cloudId
        name = folder.name
        isDefault = folder.isDefault
        sortOrder = folder.sortOrder
        syncStatus = folder.syncStatus
        deletedAt = folder.deletedAt
        cloudUpdatedAt = folder.cloudUpdatedAt
        createdAt = folder.createdAt
        updatedAt = folder.updatedAt
    }

    /// The desktop's default folder name.
    public static let defaultName = "Personal"

    /// The one default folder notes land in: the default named "Personal",
    /// else the default with the lowest sortOrder, else none. The desktop
    /// seeds several defaults (Personal, Meetings, Videos).
    public static func preferredDefault(in folders: [FolderRecord]) -> FolderRecord? {
        let defaults = folders.filter(\.isDefault)
        return defaults.first { $0.name == defaultName }
            ?? defaults.min { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}

/// A `Sendable` copy of a `LocalNote`. `updatedAt` is the snapshot a push
/// hands back to `markNoteSynced`.
public struct NoteRecord: Sendable, Equatable {
    public var clientId: String
    public var cloudId: String?
    public var folderClientId: String?
    public var title: String?
    public var content: String
    public var transcript: String?
    public var noteType: HubNoteType
    public var sourceFile: String?
    public var audioDurationSeconds: Double?
    public var enhancedContent: String?
    public var enhancementPrompt: String?
    public var enhancedAtContentHash: String?
    public var syncStatus: SyncStatus
    public var deletedAt: Date?
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    init(_ note: LocalNote) {
        clientId = note.clientId
        cloudId = note.cloudId
        folderClientId = note.folder?.clientId
        title = note.title
        content = note.content
        transcript = note.transcript
        noteType = HubNoteType(rawValue: note.noteType)
        sourceFile = note.sourceFile
        audioDurationSeconds = note.audioDurationSeconds
        enhancedContent = note.enhancedContent
        enhancementPrompt = note.enhancementPrompt
        enhancedAtContentHash = note.enhancedAtContentHash
        syncStatus = note.syncStatus
        deletedAt = note.deletedAt
        cloudUpdatedAt = note.cloudUpdatedAt
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

extension NoteRecord {
    /// The note's AI-enhanced version, `nil` when it has none (never
    /// enhanced, or cleared).
    public var enhancement: NoteEnhancement? {
        guard let enhancedContent, !enhancedContent.isEmpty else { return nil }
        return NoteEnhancement(
            content: enhancedContent, prompt: enhancementPrompt ?? "", contentHash: enhancedAtContentHash ?? "")
    }

    /// True when the note's text changed after it was enhanced, so the
    /// enhanced version no longer reflects it (the desktop's "outdated").
    public var enhancementIsOutdated: Bool {
        guard let enhancement else { return false }
        return enhancement.contentHash != NoteEnhancement.contentHash(content: content, transcript: transcript)
    }
}

/// An AI action's result for a note, as the hub carries it: the synced
/// `enhanced_content`, `enhancement_prompt`, and `enhanced_at_content_hash`.
/// It sits beside the note's `content`, which an action never replaces.
public struct NoteEnhancement: Sendable, Equatable {
    public var content: String
    public var prompt: String
    public var contentHash: String

    public init(content: String, prompt: String, contentHash: String) {
        self.content = content
        self.prompt = prompt
        self.contentHash = contentHash
    }

    /// The fields written to clear an enhancement. Empty strings, not
    /// `nil`: a `nil` field is left out of the hub PATCH (unchanged), and
    /// the desktop treats empty enhanced content as none.
    static let cleared = NoteEnhancement(content: "", prompt: "", contentHash: "")

    /// The desktop's `makeContentHash` over `content + "\n" + transcript`
    /// (`PersonalNotesView.tsx`): the UTF-16 length, a dash, and the first
    /// 50 UTF-16 units, so both apps agree on when an enhancement is outdated.
    public static func contentHash(content: String, transcript: String?) -> String {
        let units = Array("\(content)\n\(transcript ?? "")".utf16)
        return "\(units.count)-" + String(decoding: units.prefix(50), as: UTF16.self)
    }
}

/// What `applyFromHub` did with one hub row.
public enum HubApplyResult<Local: Sendable & Equatable, Hub: Sendable & Equatable>: Sendable, Equatable {
    /// The row was unknown here and was inserted as synced.
    case inserted
    /// The local row was synced and the hub's was newer; the hub's won.
    case applied
    /// The hub row is not newer than what this device last saw.
    case unchanged
    /// The local row has unpushed changes and the hub's is newer. Nothing was
    /// written; the caller decides (Keep or Refresh for notes).
    case conflict(local: Local, hub: Hub)
    /// The hub sent a tombstone and the local copy was hard-deleted.
    case deleted
}

public typealias NoteApplyResult = HubApplyResult<NoteRecord, HubNote>
public typealias FolderApplyResult = HubApplyResult<FolderRecord, HubFolder>

/// The title and content of a note as someone read them: the base a
/// whole-field write was made from. `NotesStore.editNote(expecting:)`
/// refuses the write when the note no longer holds it.
public struct NoteText: Sendable, Equatable {
    public var title: String?
    public var content: String

    public init(title: String?, content: String) {
        self.title = title
        self.content = content
    }

    public init(_ note: NoteRecord) {
        self.init(title: note.title, content: note.content)
    }
}

/// One partial edit: `old` must occur exactly once in the note's content,
/// and is replaced by `new`.
public struct NoteTextEdit: Sendable, Equatable {
    public var old: String
    public var new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

/// A content write that carries its own proof of what the writer read,
/// checked against the stored content by `NotesStore.reviseNote`.
public enum NoteContentChange: Sendable, Equatable {
    /// The whole content becomes `content`; refused unless the stored
    /// content is exactly `expected`.
    case replace(expected: String, content: String)
    /// Each edit in order, on the text the ones before it left; refused
    /// unless every `old` occurs exactly once.
    case edits([NoteTextEdit])
    /// `text` added at the end, after a newline if the content does not
    /// already end with one. Overwrites nothing, so it needs no proof.
    case append(String)
}

public enum NotesStoreError: Error, Equatable {
    case noteNotFound(String)
    case folderNotFound(String)
    /// A field being written changed since the writer read the note (a
    /// pull of another device's edit, or a draft typed here).
    case noteChangedSinceRead(String)
    /// Edit number `edit` (from 0): its `old` text is not in the stored
    /// content, or not in the text left by the earlier edits.
    case editTextNotFound(String, edit: Int)
    /// Edit number `edit` (from 0): its `old` text occurs more than once in
    /// the stored content or in the text left by the earlier edits.
    case editTextNotUnique(String, edit: Int)
}

/// The hub id of a folder this phone saw deleted for good: a hub tombstone
/// pulled, or a local delete the hub accepted. It outlives the folder row, so
/// a later pull can tell a note whose folder is gone from one whose folder
/// has not arrived yet, and refile only the first (protocol section 8).
@Model
public final class DeletedFolderId {
    @Attribute(.unique) public var cloudId: String

    public init(cloudId: String) { self.cloudId = cloudId }
}
