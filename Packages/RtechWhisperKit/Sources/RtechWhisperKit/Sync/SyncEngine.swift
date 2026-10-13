import Foundation
import Synchronization

/// The hub calls the sync engine makes. `HubSyncClient` is the real one;
/// tests answer with a stub.
public protocol HubSyncing: Sendable {
    func listFolders(since: Date?) async throws(HubError) -> [HubFolder]
    func listNotes(limit: Int, before: Date?, beforeId: String?) async throws(HubError) -> [HubNote]
    func listNoteChanges(limit: Int, since: Date, sinceId: String?) async throws(HubError) -> [HubNote]
    func batchCreateFolders(_ folders: [FolderCreateInput]) async throws(HubError) -> [HubFolder]
    func createFolder(_ folder: FolderCreateInput) async throws(HubError) -> HubFolder
    func updateFolder(_ update: FolderUpdateInput) async throws(HubError) -> HubFolder
    func deleteFolder(id: String) async throws(HubError)
    func batchCreateNotes(_ notes: [NoteCreateInput]) async throws(HubError) -> [HubNoteCreated]
    func updateNote(_ update: NoteUpdateInput) async throws(HubError) -> HubNote
    func deleteNote(id: String) async throws(HubError)
}

extension HubSyncClient: HubSyncing {}

/// Where the engine keeps its delta cursors between passes.
public protocol CursorStore: Sendable {
    func cursor(_ key: String) -> Date?
    func setCursor(_ date: Date, for key: String)
}

/// Cursors in `UserDefaults`, written as hub timestamps so the millisecond
/// value survives exactly.
public final class UserDefaultsCursorStore: CursorStore, @unchecked Sendable {
    /// Cursor format. 1 (no version key) stored the raw pass start; 2 stores
    /// the pass start minus `SyncEngine.lookback`; 3 drops the folder and
    /// note cursors once so the next pull lists every folder tombstone and
    /// re-serves every note (ios#557).
    public static let formatVersion = 3
    /// Every delta cursor key the sync layer stores.
    static let deltaKeys = [
        SyncEngine.folderCursorKey, SyncEngine.noteCursorKey, TranscriptionSync.cursorKey, DictionarySync.cursorKey,
        SnippetSync.cursorKey,
    ]

    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "sync.cursor.") {
        self.defaults = defaults
        self.prefix = prefix
        migrate()
    }

    /// A cursor stored before the lookback is the raw pass start, so the first
    /// pass after the upgrade would read with no lookback and could lose a
    /// late-committing row for good. Rewind each one by the lookback, once.
    private func migrate() {
        let versionKey = prefix + "version"
        let version = defaults.integer(forKey: versionKey)
        guard version < Self.formatVersion else { return }
        if version < 2 {
            for key in Self.deltaKeys {
                if let stored = cursor(key) {
                    setCursor(stored.addingTimeInterval(-SyncEngine.lookback), for: key)
                }
            }
        }
        // Folder tombstones pulled before DeletedFolderId existed were never
        // recorded, so notes filed in them stay parked, and notes this device
        // held in them were left without a folder. A full list of folders and
        // notes once records every tombstone and each held note's hub folder,
        // so the pull refiles them.
        defaults.removeObject(forKey: prefix + SyncEngine.folderCursorKey)
        defaults.removeObject(forKey: prefix + SyncEngine.noteCursorKey)
        defaults.set(Self.formatVersion, forKey: versionKey)
    }

    public func cursor(_ key: String) -> Date? {
        defaults.string(forKey: prefix + key).flatMap(HubDate.date(from:))
    }

    public func setCursor(_ date: Date, for key: String) {
        defaults.set(HubDate.string(from: date), forKey: prefix + key)
    }
}

/// Cursors that live only in memory, for tests.
public final class InMemoryCursorStore: CursorStore {
    private let values = Mutex<[String: Date]>([:])

    public init() {}

    public func cursor(_ key: String) -> Date? {
        values.withLock { $0[key] }
    }

    public func setCursor(_ date: Date, for key: String) {
        values.withLock { $0[key] = date }
    }
}

/// A hub note newer than a local note with unpushed changes. Nothing was
/// written; the user chooses Keep or Refresh (protocol section 8).
public struct SyncConflict: Sendable, Equatable {
    public var clientId: String
    public var local: NoteRecord
    public var hub: HubNote
}

public enum SyncEngineError: Error, Equatable {
    /// A full page came back ending on the cursor it was asked from, so the
    /// next request would return the same page forever.
    case cursorStalled(Date, String)
}

/// Pushes local changes to the hub and pulls hub changes into the
/// `NotesStore` (protocol section 8).
public actor SyncEngine {
    public static let folderCursorKey = "folders"
    public static let noteCursorKey = "notes"
    public static let pageSize = 50
    /// L, the lookback (protocol section 8). The hub stamps a row before its
    /// write commits, so a row stamped before a pass started can become
    /// visible only after that pass read the table. Every stored delta cursor
    /// sits this far behind the pass clock so the next pass re-reads that
    /// window; a re-served row this device already holds is a no-op.
    public static let lookback: TimeInterval = 60

    private let hub: any HubSyncing
    private let store: NotesStore
    private let cursors: any CursorStore
    private let now: @Sendable () -> Date

    /// Notes whose hub row is newer than an unpushed local edit, one per note.
    public private(set) var conflicts: [SyncConflict] = []
    /// Hub ids of rows the last pull could not apply. They hold their cursor
    /// back, so the next pull sees them again.
    public private(set) var parkedFolderIds: [String] = []
    public private(set) var parkedNoteIds: [String] = []
    /// Local folders (by client id) the last push could not write, with the
    /// hub's answer. A `folderNameTaken` folder stays pending until renamed.
    public private(set) var folderErrors: [String: HubError] = [:]
    /// Local notes (by client id) the last push marked as errored.
    public private(set) var noteErrors: [String: HubError] = [:]
    /// True when the last `sync` pass pulled folders and applied every row,
    /// so the hub's folders were all local as of that pass, whatever later
    /// steps of the pass did.
    public private(set) var foldersPulled = false

    /// The dictation-history step, run after notes when set.
    public let transcriptions: TranscriptionSync?
    /// The custom-dictionary step, run after transcriptions when set.
    public let dictionary: DictionarySync?
    /// The snippets step, run last when set.
    public let snippets: SnippetSync?

    public init(
        hub: any HubSyncing, store: NotesStore, cursors: any CursorStore,
        transcriptions: TranscriptionSync? = nil, dictionary: DictionarySync? = nil,
        snippets: SnippetSync? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.hub = hub
        self.store = store
        self.cursors = cursors
        self.transcriptions = transcriptions
        self.dictionary = dictionary
        self.snippets = snippets
        self.now = now
    }

    /// One full pass in the desktop's order: push folders, push notes, pull,
    /// then transcriptions (push only), then the
    /// dictionary and the snippets (each pull, then push).
    public func sync() async throws {
        foldersPulled = false
        try await pushFolders()
        try await pushNotes()
        try await pull()
        try await transcriptions?.sync()
        try await dictionary?.sync()
        try await snippets?.sync()
    }

    // MARK: Conflicts

    /// Keep mine: rebase the local edit on the hub revision in the conflict,
    /// so the next push sends it with that `base_updated_at` and wins.
    public func keepMine(_ clientId: String) async throws {
        guard let conflict = conflicts.first(where: { $0.clientId == clientId }) else { return }
        try await store.rebaseNote(clientId: clientId, onto: conflict.hub)
        conflicts.removeAll { $0.clientId == clientId }
    }

    /// Use the hub's: the hub copy in the conflict replaces the local row.
    public func takeHub(_ clientId: String) async throws {
        guard let conflict = conflicts.first(where: { $0.clientId == clientId }) else { return }
        try await store.replaceWithHub(clientId: clientId, conflict.hub)
        conflicts.removeAll { $0.clientId == clientId }
    }

    // MARK: Push

    /// Creates, updates, then deletes pending folders. Folders are
    /// last-writer-wins, so no base is sent. A transient hub error aborts the
    /// pass; a per-folder rejection is recorded in `folderErrors`.
    public func pushFolders() async throws {
        var errors: [String: HubError] = [:]
        let pending = try await store.pendingFolders()

        let creates = pending.filter { $0.cloudId == nil }
        if !creates.isEmpty {
            let inputs = creates.map {
                FolderCreateInput(name: $0.name, clientFolderId: $0.clientId, isDefault: $0.isDefault, sortOrder: $0.sortOrder)
            }
            do {
                // In input order; a default folder may come back as the
                // hub's existing default row, so match by position.
                let rows = try await hub.batchCreateFolders(inputs)
                for (local, row) in zip(creates, rows) {
                    try await settle(local, with: row)
                }
            } catch HubError.folderNameTaken {
                // One clash fails the batch; retry singly to find it.
                for (local, input) in zip(creates, inputs) {
                    do {
                        try await settle(local, with: try await hub.createFolder(input))
                    } catch let error as HubError {
                        try await record(error, forFolder: local, into: &errors)
                    }
                }
            }
        }

        for local in pending where local.cloudId != nil {
            do {
                let row = try await hub.updateFolder(FolderUpdateInput(id: local.cloudId!, name: local.name, sortOrder: local.sortOrder))
                try await settle(local, with: row)
            } catch let error as HubError {
                try await record(error, forFolder: local, into: &errors)
            }
        }

        for local in try await store.pendingFolderDeletes() {
            guard let cloudId = local.cloudId else { continue }
            do {
                try await hub.deleteFolder(id: cloudId)
            } catch HubError.notFound {
                // Already gone on the hub: done (protocol section 8, Deletes).
            }
            try await store.markFolderSynced(
                clientId: local.clientId, cloudId: cloudId,
                cloudUpdatedAt: local.cloudUpdatedAt ?? local.updatedAt, pushedUpdatedAt: local.updatedAt)
        }
        folderErrors = errors
    }

    /// Creates (batched), updates with a base, then deletes pending notes. Run
    /// after `pushFolders`: a note whose folder has no hub id yet stays
    /// pending for a later pass. Every success settles only the snapshot that
    /// was sent, so an edit made during the push stays pending.
    public func pushNotes() async throws {
        var errors: [String: HubError] = [:]
        let folderIds = try await folderCloudIdsByClientId()
        var creates: [(NoteRecord, NoteCreateInput)] = []
        var updates: [(NoteRecord, NoteUpdateInput)] = []

        for local in try await store.pendingNotes() {
            var folderId: String?
            if let folderClientId = local.folderClientId {
                guard let id = folderIds[folderClientId] else { continue }
                folderId = id
            }
            if let cloudId = local.cloudId {
                updates.append((local, NoteUpdateInput(
                    id: cloudId, baseUpdatedAt: local.cloudUpdatedAt, title: local.title,
                    content: local.content, enhancedContent: local.enhancedContent,
                    enhancementPrompt: local.enhancementPrompt, enhancedAtContentHash: local.enhancedAtContentHash,
                    noteType: local.noteType, transcript: local.transcript,
                    folderId: folderId, fullPayload: true)))
            } else {
                creates.append((local, NoteCreateInput(
                    clientNoteId: local.clientId, createdAt: local.createdAt, title: local.title,
                    content: local.content, enhancedContent: local.enhancedContent,
                    enhancementPrompt: local.enhancementPrompt, enhancedAtContentHash: local.enhancedAtContentHash,
                    noteType: local.noteType, sourceFile: local.sourceFile,
                    audioDurationSeconds: local.audioDurationSeconds, transcript: local.transcript,
                    folderId: folderId)))
            }
        }

        var start = 0
        while start < creates.count {
            let batch = creates[start..<min(start + Self.pageSize, creates.count)]
            start += Self.pageSize
            let created = try await hub.batchCreateNotes(batch.map(\.1))
            let byClientId = Dictionary(created.map { ($0.clientNoteId, $0) }, uniquingKeysWith: { first, _ in first })
            for (local, _) in batch {
                guard let row = byClientId[local.clientId] else { continue }
                try await store.markNoteSynced(
                    clientId: local.clientId, cloudId: row.id, cloudUpdatedAt: row.updatedAt,
                    pushedUpdatedAt: local.updatedAt)
            }
        }

        for (local, input) in updates {
            do {
                let row = try await hub.updateNote(input)
                try await store.markNoteSynced(
                    clientId: local.clientId, cloudId: row.id, cloudUpdatedAt: row.updatedAt,
                    pushedUpdatedAt: local.updatedAt)
                conflicts.removeAll { $0.clientId == local.clientId }
            } catch HubError.noteVersionConflict(let current) {
                // The hub moved on: keep the edit pending, let the user choose.
                addConflict(SyncConflict(clientId: local.clientId, local: local, hub: current))
            } catch HubError.notFound {
                // Tombstoned on the hub; the next pull removes the local copy.
            } catch let error as HubError {
                guard !Self.isTransient(error) else { throw error }
                try await store.markNoteError(clientId: local.clientId)
                errors[local.clientId] = error
            }
        }

        for local in try await store.pendingNoteDeletes() {
            guard let cloudId = local.cloudId else { continue }
            do {
                try await hub.deleteNote(id: cloudId)
            } catch HubError.notFound {
                // Already gone on the hub: done.
            }
            try await store.markNoteSynced(
                clientId: local.clientId, cloudId: cloudId,
                cloudUpdatedAt: local.cloudUpdatedAt ?? local.updatedAt, pushedUpdatedAt: local.updatedAt)
        }
        noteErrors = errors
    }

    private func settle(_ local: FolderRecord, with row: HubFolder) async throws {
        try await store.markFolderSynced(
            clientId: local.clientId, cloudId: row.id, cloudUpdatedAt: row.updatedAt,
            pushedUpdatedAt: local.updatedAt)
    }

    /// A name clash leaves the folder pending (the user renames it); any other
    /// non-transient rejection marks it errored. Transient errors abort.
    private func record(_ error: HubError, forFolder local: FolderRecord, into errors: inout [String: HubError]) async throws {
        if Self.isTransient(error) { throw error }
        if error != .folderNameTaken {
            try await store.markFolderError(clientId: local.clientId)
        }
        errors[local.clientId] = error
    }

    private func folderCloudIdsByClientId() async throws -> [String: String] {
        let all = try await store.folders() + store.pendingFolderDeletes()
        return Dictionary(all.compactMap { f in f.cloudId.map { (f.clientId, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Errors a retry on the next pass can fix without a user change.
    static func isTransient(_ error: HubError) -> Bool {
        switch error {
        case .network, .rateLimited, .upstreamUnavailable, .unauthorized, .malformedKey, .decoding:
            true
        default:
            false
        }
    }

    private func addConflict(_ conflict: SyncConflict) {
        if let index = conflicts.firstIndex(where: { $0.clientId == conflict.clientId }) {
            conflicts[index] = conflict
        } else {
            conflicts.append(conflict)
        }
    }

    // MARK: Pull

    /// Folders then notes, so a note's folder is known before the note lands.
    public func pull() async throws {
        try await pullFolders()
        try await pullNotes()
    }

    /// One delta request by the stored cursor, or a full snapshot on the first
    /// run. The cursor moves to this pass's start time minus the lookback only
    /// when every row applied; a row that fails is parked and the cursor stays
    /// put.
    public func pullFolders() async throws {
        let key = Self.folderCursorKey
        let passStart = now()
        let rows = try await hub.listFolders(since: cursors.cursor(key))
        var parked: [String] = []
        for row in rows {
            do {
                // A conflict here is an unpushed local edit; folders are
                // last-writer-wins, so the push settles it.
                try await store.applyFromHub(row)
            } catch {
                parked.append(row.id)
            }
        }
        parkedFolderIds = parked
        if parked.isEmpty { cursors.setCursor(passStart.addingTimeInterval(-Self.lookback), for: key) }
        foldersPulled = parked.isEmpty
    }

    /// Paged delta by (`since`, `since_id`) ascending, or on the first run a
    /// snapshot paged by (`before`, `before_id`) descending. Stops on a short
    /// page. A note whose folder is unknown here (and that this device does
    /// not already hold at that revision), or that fails to apply, is parked
    /// and holds the cursor back. Only the date is stored, minus the
    /// lookback; `since_id` breaks ties between pages of one pass only.
    public func pullNotes() async throws {
        let key = Self.noteCursorKey
        let passStart = now()
        let since = cursors.cursor(key)
        let knownFolders = try await store.folderCloudIds()
        let deletedFolders = try await store.deletedFolderCloudIds()
        var cursor: Date? = since
        var cursorId: String?
        var parked: [String] = []

        while true {
            let page: [HubNote]
            // Delta or snapshot is decided once per pass, by the stored cursor.
            if since != nil, let cursor {
                page = try await hub.listNoteChanges(limit: Self.pageSize, since: cursor, sinceId: cursorId)
            } else {
                page = try await hub.listNotes(limit: Self.pageSize, before: cursor, beforeId: cursorId)
            }

            for row in page {
                // A row this device already holds is a no-op even when its
                // folder is gone here, so it must not hold the cursor back.
                // A folder known deleted refiles the note to the default
                // folder; a folder not seen yet parks it until it arrives.
                var refile = false
                if row.deletedAt == nil, let folderId = row.folderId, !knownFolders.contains(folderId),
                   try await !store.holdsCurrent(row) {
                    guard deletedFolders.contains(folderId) else {
                        parked.append(row.id)
                        continue
                    }
                    refile = true
                }
                do {
                    let result = try await store.applyFromHub(row, refileOrphan: refile)
                    record(result, for: row)
                } catch {
                    parked.append(row.id)
                }
            }

            guard page.count == Self.pageSize, let last = page.last else { break }
            let next = since == nil ? last.createdAt : last.updatedAt
            if next == cursor && last.id == cursorId {
                throw SyncEngineError.cursorStalled(next, last.id)
            }
            cursor = next
            cursorId = last.id
        }

        // Only now, with every newer hub row applied: a note the hub moved
        // out of a deleted folder this pass must not be refiled over the move.
        try await store.refileNotesInDeletedFolders(excluding: Set(parked))
        parkedNoteIds = parked
        if parked.isEmpty { cursors.setCursor(passStart.addingTimeInterval(-Self.lookback), for: key) }
    }

    private func record(_ result: NoteApplyResult, for row: HubNote) {
        switch result {
        case .conflict(let local, let hub):
            addConflict(SyncConflict(clientId: local.clientId, local: local, hub: hub))
        case .applied, .deleted:
            // The hub row won over a clean local row, so an older conflict
            // for this note is moot.
            conflicts.removeAll { $0.hub.id == row.id }
        case .inserted, .unchanged:
            break
        }
    }
}
