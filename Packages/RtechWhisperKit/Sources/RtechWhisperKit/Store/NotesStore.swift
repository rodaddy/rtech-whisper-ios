import Foundation
import SwiftData

/// The phone's local notes and folders, with the sync bookkeeping the hub
/// contract needs (protocol section 8). It holds no network code: a sync
/// engine reads `pending*`, pushes, and reports back through `mark*Synced`
/// and `applyFromHub`.
@ModelActor
public actor NotesStore {
    public static let schema = Schema([LocalFolder.self, LocalNote.self, DeletedFolderId.self])

    /// A store backed by an on-disk container at the default location.
    public static func persistent() throws -> NotesStore {
        NotesStore(modelContainer: try ModelContainer(for: schema))
    }

    /// A store that lives only in memory, for tests and previews.
    public static func inMemory() throws -> NotesStore {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return NotesStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    // MARK: Notes

    @discardableResult
    public func createNote(
        content: String, title: String? = nil, transcript: String? = nil,
        noteType: HubNoteType = .personal, folderClientId: String? = nil,
        sourceFile: String? = nil, audioDurationSeconds: Double? = nil
    ) throws -> NoteRecord {
        let now = Date()
        let note = LocalNote(
            clientId: UUID().uuidString, folder: try folderClientId.map(requireFolder),
            title: title, content: content, transcript: transcript, noteType: noteType.rawValue,
            sourceFile: sourceFile, audioDurationSeconds: audioDurationSeconds,
            syncStatus: .pending, createdAt: now, updatedAt: now)
        modelContext.insert(note)
        try modelContext.save()
        return NoteRecord(note)
    }

    /// Changes the given fields, bumps `updatedAt`, and marks the note pending.
    /// A `nil` argument leaves that field alone. With `base`, a title or
    /// content write is refused (`noteChangedSinceRead`) when that field no
    /// longer holds what the writer read: the check and the write are one
    /// step on this actor, so no pull can land between them.
    @discardableResult
    public func editNote(
        clientId: String, title: String? = nil, content: String? = nil, transcript: String? = nil,
        noteType: HubNoteType? = nil, expecting base: NoteText? = nil
    ) throws -> NoteRecord {
        let note = try requireNote(clientId)
        if let base,
           (title != nil && note.title != base.title) || (content != nil && note.content != base.content) {
            throw NotesStoreError.noteChangedSinceRead(clientId)
        }
        if let title { note.title = title }
        if let content { note.content = content }
        if let transcript { note.transcript = transcript }
        if let noteType { note.noteType = noteType.rawValue }
        note.updatedAt = Self.bumped(note.updatedAt)
        note.syncStatus = .pending
        try modelContext.save()
        return NoteRecord(note)
    }

    /// A write that proves what it was built from, for the chat's note
    /// tools: `retitle` lands only if the stored title is exactly `from`
    /// (an untitled note's title is ""), and `content` is checked as its
    /// case says. Any failed check throws and writes nothing. The checks
    /// and the write are one step on this actor, so no pull or draft save
    /// can land between them.
    @discardableResult
    public func reviseNote(
        clientId: String, retitle: (from: String, to: String)? = nil, content change: NoteContentChange? = nil
    ) throws -> NoteRecord {
        let note = try requireNote(clientId)
        let stored = note.content
        var expected = stored
        let content: String?
        switch change {
        case nil:
            content = nil
        case .replace(let old, let new):
            expected = old
            content = new
        case .edits(let edits):
            content = try Self.applying(edits, to: stored, clientId: clientId)
        case .append(let text):
            content = stored + (stored.isEmpty || stored.hasSuffix("\n") ? "" : "\n") + text
        }
        if let retitle, (note.title ?? "") != retitle.from {
            throw NotesStoreError.noteChangedSinceRead(clientId)
        }
        return try editNote(
            clientId: clientId, title: retitle?.to, content: content,
            expecting: NoteText(title: note.title, content: expected))
    }

    /// Sets the note's enhancement (`nil` clears it) and leaves `content`
    /// alone. Refused (`noteChangedSinceRead`), writing nothing, when the
    /// stored enhancement is not `expected`, or, with `expectedContent`, when
    /// the content is not exactly that. Check and write are one step on this
    /// actor, as in `editNote`. The note goes pending and syncs.
    @discardableResult
    public func enhanceNote(
        clientId: String, to enhancement: NoteEnhancement?, expecting expected: NoteEnhancement?,
        expectedContent: String? = nil
    ) throws -> NoteRecord {
        let note = try requireNote(clientId)
        let current = NoteRecord(note)
        if current.enhancement != expected || (expectedContent != nil && note.content != expectedContent) {
            throw NotesStoreError.noteChangedSinceRead(clientId)
        }
        let written = enhancement ?? .cleared
        note.enhancedContent = written.content
        note.enhancementPrompt = written.prompt
        note.enhancedAtContentHash = written.contentHash
        note.updatedAt = Self.bumped(note.updatedAt)
        note.syncStatus = .pending
        try modelContext.save()
        return NoteRecord(note)
    }

    /// `text` with each edit applied in order. Each `old` must occur exactly
    /// once (overlaps count) in the stored text the caller read AND in the
    /// text left by the earlier edits: an earlier edit cannot consume the
    /// copy the caller saw and leave a later one aimed at an unseen
    /// duplicate. An empty, missing, or repeated `old` throws.
    private static func applying(_ edits: [NoteTextEdit], to stored: String, clientId: String) throws -> String {
        func onlyMatch(of edit: NoteTextEdit, index: Int, in text: String) throws -> Range<String.Index> {
            guard !edit.old.isEmpty, let first = text.range(of: edit.old) else {
                throw NotesStoreError.editTextNotFound(clientId, edit: index)
            }
            if first.lowerBound < text.endIndex,
               text.range(of: edit.old, range: text.index(after: first.lowerBound)..<text.endIndex) != nil {
                throw NotesStoreError.editTextNotUnique(clientId, edit: index)
            }
            return first
        }
        var text = stored
        for (index, edit) in edits.enumerated() {
            _ = try onlyMatch(of: edit, index: index, in: stored)
            text.replaceSubrange(try onlyMatch(of: edit, index: index, in: text), with: edit.new)
        }
        return text
    }

    /// Moves a note to a folder (`nil` for none), as an edit.
    @discardableResult
    public func moveNote(clientId: String, toFolder folderClientId: String?) throws -> NoteRecord {
        let note = try requireNote(clientId)
        note.folder = try folderClientId.map(requireFolder)
        note.updatedAt = Self.bumped(note.updatedAt)
        note.syncStatus = .pending
        try modelContext.save()
        return NoteRecord(note)
    }

    /// Tombstones a synced note for the next push. A note the hub has never
    /// seen (`cloudId == nil`) is hard-deleted at once: never-synced rows stay
    /// local (protocol section 8, Deletes).
    public func softDeleteNote(clientId: String) throws {
        let note = try requireNote(clientId)
        if note.cloudId == nil {
            modelContext.delete(note)
        } else {
            let now = Date()
            note.deletedAt = now
            note.updatedAt = Self.bumped(note.updatedAt, now: now)
            note.syncStatus = .pending
        }
        try modelContext.save()
    }

    /// Live notes with unpushed changes.
    public func pendingNotes() throws -> [NoteRecord] {
        let pending = SyncStatus.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.syncStatusRaw == pending && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt)]
        )).map(NoteRecord.init)
    }

    /// Local tombstones waiting for their hub `DELETE`.
    public func pendingNoteDeletes() throws -> [NoteRecord] {
        let pending = SyncStatus.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.syncStatusRaw == pending && $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.updatedAt)]
        )).map(NoteRecord.init)
    }

    /// Records a successful push. `pushedUpdatedAt` is the `updatedAt` of the
    /// snapshot the push sent. The hub ids are always stored; the row settles
    /// to synced only if nobody edited it since that snapshot, otherwise it
    /// stays pending so the newer edit goes out on the next pass. A settled
    /// tombstone is hard-deleted.
    public func markNoteSynced(
        clientId: String, cloudId: String, cloudUpdatedAt: Date, pushedUpdatedAt: Date
    ) throws {
        guard let note = try note(clientId) else { return }
        note.cloudId = cloudId
        note.cloudUpdatedAt = cloudUpdatedAt
        if note.updatedAt == pushedUpdatedAt {
            if note.deletedAt != nil {
                modelContext.delete(note)
            } else {
                note.syncStatus = .synced
                note.hubFolderId = note.folder?.cloudId
            }
        }
        try modelContext.save()
    }

    /// Marks a note whose push failed permanently.
    public func markNoteError(clientId: String) throws {
        let note = try requireNote(clientId)
        note.syncStatus = .error
        try modelContext.save()
    }

    /// Merges one row from a hub pull.
    @discardableResult
    public func applyFromHub(_ hub: HubNote, refileOrphan: Bool = false) throws -> NoteApplyResult {
        let local = try note(cloudId: hub.id) ?? hub.clientNoteId.flatMap { try? note($0) }
        if hub.deletedAt != nil {
            guard let local else { return .unchanged }
            modelContext.delete(local)
            try modelContext.save()
            return .deleted
        }
        guard let local else {
            let note = LocalNote(
                clientId: hub.clientNoteId ?? UUID().uuidString, cloudId: hub.id,
                folder: try hub.folderId.flatMap { try folder(cloudId: $0) },
                title: hub.title, content: hub.content, transcript: hub.transcript,
                noteType: hub.noteType.rawValue, sourceFile: hub.sourceFile,
                audioDurationSeconds: hub.audioDurationSeconds, enhancedContent: hub.enhancedContent,
                enhancementPrompt: hub.enhancementPrompt, enhancedAtContentHash: hub.enhancedAtContentHash,
                syncStatus: .synced,
                cloudUpdatedAt: hub.updatedAt, createdAt: hub.createdAt, updatedAt: hub.updatedAt)
            note.hubFolderId = hub.folderId
            modelContext.insert(note)
            if refileOrphan { try refile(note, to: defaultFolder()) }
            try modelContext.save()
            return .inserted
        }
        guard hub.updatedAt > (local.cloudUpdatedAt ?? .distantPast) else {
            // A re-served row at the revision this device holds records its
            // hub folder, which rows from older builds never stored.
            if hub.updatedAt == local.cloudUpdatedAt, local.hubFolderId != hub.folderId {
                local.hubFolderId = hub.folderId
                try modelContext.save()
            }
            return .unchanged
        }
        guard local.syncStatus == .synced else {
            return .conflict(local: NoteRecord(local), hub: hub)
        }
        local.hubFolderId = hub.folderId
        local.cloudId = hub.id
        local.title = hub.title
        local.content = hub.content
        local.transcript = hub.transcript
        local.noteType = hub.noteType.rawValue
        local.sourceFile = hub.sourceFile
        local.audioDurationSeconds = hub.audioDurationSeconds
        local.enhancedContent = hub.enhancedContent
        local.enhancementPrompt = hub.enhancementPrompt
        local.enhancedAtContentHash = hub.enhancedAtContentHash
        local.folder = try hub.folderId.flatMap { try folder(cloudId: $0) }
        local.cloudUpdatedAt = hub.updatedAt
        local.updatedAt = hub.updatedAt
        if refileOrphan { try refile(local, to: defaultFolder()) }
        try modelContext.save()
        return .applied
    }

    /// True when applying the live row `hub` would be `.unchanged`: this
    /// device holds the note at that hub revision or a later one. The sync
    /// engine asks before its folder gate, so a re-served row it already
    /// holds is a no-op even when its folder is gone here.
    public func holdsCurrent(_ hub: HubNote) throws -> Bool {
        let local = try note(cloudId: hub.id) ?? hub.clientNoteId.flatMap { try? note($0) }
        guard let seen = local?.cloudUpdatedAt else { return false }
        return hub.updatedAt <= seen
    }

    /// Conflict resolution "Keep mine": the local edit stays pending, now
    /// based on the hub revision the user has seen, so the next push
    /// overwrites the hub copy instead of conflicting again.
    @discardableResult
    public func rebaseNote(clientId: String, onto hub: HubNote) throws -> NoteRecord {
        let note = try requireNote(clientId)
        note.cloudId = hub.id
        note.cloudUpdatedAt = hub.updatedAt
        note.hubFolderId = hub.folderId
        note.updatedAt = Self.bumped(note.updatedAt)
        note.syncStatus = .pending
        if note.folder == nil, try isDeletedFolder(hub.folderId) { note.folder = try defaultFolder() }
        try modelContext.save()
        return NoteRecord(note)
    }

    /// Conflict resolution "Use the hub's": the hub copy replaces the local
    /// row, unpushed edits included, and the row settles to synced. A hub
    /// tombstone removes the local row.
    public func replaceWithHub(clientId: String, _ hub: HubNote) throws {
        let note = try requireNote(clientId)
        if hub.deletedAt != nil {
            modelContext.delete(note)
        } else {
            note.cloudId = hub.id
            note.title = hub.title
            note.content = hub.content
            note.transcript = hub.transcript
            note.noteType = hub.noteType.rawValue
            note.sourceFile = hub.sourceFile
            note.audioDurationSeconds = hub.audioDurationSeconds
            note.enhancedContent = hub.enhancedContent
            note.enhancementPrompt = hub.enhancementPrompt
            note.enhancedAtContentHash = hub.enhancedAtContentHash
            note.folder = try hub.folderId.flatMap { try folder(cloudId: $0) }
            note.deletedAt = nil
            note.hubFolderId = hub.folderId
            note.cloudUpdatedAt = hub.updatedAt
            note.updatedAt = hub.updatedAt
            note.syncStatus = .synced
            if note.folder == nil, try isDeletedFolder(hub.folderId) { try refile(note, to: defaultFolder()) }
        }
        try modelContext.save()
    }

    /// Live notes, newest first. `nil` lists every folder.
    public func notes(inFolder folderClientId: String? = nil) throws -> [NoteRecord] {
        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let live = try modelContext.fetch(descriptor)
        guard let folderClientId else { return live.map(NoteRecord.init) }
        return live.filter { $0.folder?.clientId == folderClientId }.map(NoteRecord.init)
    }

    // MARK: Folders

    @discardableResult
    public func createFolder(name: String, isDefault: Bool = false, sortOrder: Int = 0) throws -> FolderRecord {
        let now = Date()
        let folder = LocalFolder(
            clientId: UUID().uuidString, name: name, isDefault: isDefault, sortOrder: sortOrder,
            syncStatus: .pending, createdAt: now, updatedAt: now)
        modelContext.insert(folder)
        try modelContext.save()
        return FolderRecord(folder)
    }

    @discardableResult
    public func editFolder(clientId: String, name: String? = nil, sortOrder: Int? = nil) throws -> FolderRecord {
        let folder = try requireFolder(clientId)
        if let name { folder.name = name }
        if let sortOrder { folder.sortOrder = sortOrder }
        folder.updatedAt = Self.bumped(folder.updatedAt)
        folder.syncStatus = .pending
        try modelContext.save()
        return FolderRecord(folder)
    }

    /// Moves every live note in `fromClientId` to `toClientId`, each as an
    /// edit, so the hub learns the new `folder_id`. Returns how many moved.
    /// Deleting a folder calls this first: the hub does not cascade, and the
    /// contract files orphaned notes into the default folder.
    @discardableResult
    public func refileNotes(fromFolder fromClientId: String, toFolder toClientId: String) throws -> Int {
        let target = try requireFolder(toClientId)
        let live = try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil }))
        let moving = live.filter { $0.folder?.clientId == fromClientId }
        for note in moving {
            note.folder = target
            note.updatedAt = Self.bumped(note.updatedAt)
            note.syncStatus = .pending
        }
        if !moving.isEmpty { try modelContext.save() }
        return moving.count
    }

    /// Same rule as `softDeleteNote`. Notes in the folder keep their rows; a
    /// hard delete clears their folder link (the hub does not cascade either).
    public func softDeleteFolder(clientId: String) throws {
        let folder = try requireFolder(clientId)
        if folder.cloudId == nil {
            modelContext.delete(folder)
        } else {
            let now = Date()
            folder.deletedAt = now
            folder.updatedAt = Self.bumped(folder.updatedAt, now: now)
            folder.syncStatus = .pending
        }
        try modelContext.save()
    }

    public func pendingFolders() throws -> [FolderRecord] {
        let pending = SyncStatus.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.syncStatusRaw == pending && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt)]
        )).map(FolderRecord.init)
    }

    public func pendingFolderDeletes() throws -> [FolderRecord] {
        let pending = SyncStatus.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.syncStatusRaw == pending && $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.updatedAt)]
        )).map(FolderRecord.init)
    }

    /// Same rule as `markNoteSynced`.
    public func markFolderSynced(
        clientId: String, cloudId: String, cloudUpdatedAt: Date, pushedUpdatedAt: Date
    ) throws {
        guard let folder = try folder(clientId) else { return }
        folder.cloudId = cloudId
        folder.cloudUpdatedAt = cloudUpdatedAt
        if folder.updatedAt == pushedUpdatedAt {
            if folder.deletedAt != nil {
                rememberDeletedFolder(cloudId)
                modelContext.delete(folder)
            } else {
                folder.syncStatus = .synced
            }
        }
        try modelContext.save()
    }

    public func markFolderError(clientId: String) throws {
        let folder = try requireFolder(clientId)
        folder.syncStatus = .error
        try modelContext.save()
    }

    /// Same branches as the note overload. Folders are last-writer-wins on the
    /// hub, but a pull still never overwrites unpushed local changes.
    @discardableResult
    public func applyFromHub(_ hub: HubFolder) throws -> FolderApplyResult {
        let local = try folder(cloudId: hub.id) ?? hub.clientFolderId.flatMap { try? folder($0) }
        if hub.deletedAt != nil {
            rememberDeletedFolder(hub.id)
            guard let local else {
                try modelContext.save()
                return .unchanged
            }
            // The contract files a deleted folder's notes into the default
            // folder; the desktop does not refile them, so this device does.
            // A pending note is refiled now. A synced one is left without a
            // folder and refiled by `refileNotesInDeletedFolders` once the
            // note pull is done, so a newer hub row that moved it elsewhere
            // wins instead of meeting a pending refile as a conflict.
            let target = try defaultFolder(excluding: local.clientId)
            let held = try modelContext.fetch(FetchDescriptor<LocalNote>(predicate: #Predicate { $0.deletedAt == nil }))
            for note in held where note.folder?.clientId == local.clientId {
                if note.syncStatus == .synced {
                    note.folder = nil
                    note.hubFolderId = hub.id
                } else {
                    refile(note, to: target)
                }
            }
            modelContext.delete(local)
            try modelContext.save()
            return .deleted
        }
        // The hub's default folder while this device holds its own unpushed
        // default: adopt the hub's identity instead of adding a second
        // default (protocol section 3), which a later push would then bind
        // to the same hub row.
        if local == nil, hub.isDefault, let mine = try unpushedDefaultFolder() {
            mine.cloudId = hub.id
            mine.name = hub.name
            mine.sortOrder = hub.sortOrder
            mine.cloudUpdatedAt = hub.updatedAt
            mine.updatedAt = hub.updatedAt
            mine.syncStatus = .synced
            try modelContext.save()
            return .applied
        }
        guard let local else {
            modelContext.insert(LocalFolder(
                clientId: hub.clientFolderId ?? UUID().uuidString, cloudId: hub.id, name: hub.name,
                isDefault: hub.isDefault, sortOrder: hub.sortOrder, syncStatus: .synced,
                cloudUpdatedAt: hub.updatedAt, createdAt: hub.createdAt, updatedAt: hub.updatedAt))
            try modelContext.save()
            return .inserted
        }
        guard hub.updatedAt > (local.cloudUpdatedAt ?? .distantPast) else { return .unchanged }
        guard local.syncStatus == .synced else {
            return .conflict(local: FolderRecord(local), hub: hub)
        }
        local.cloudId = hub.id
        local.name = hub.name
        local.isDefault = hub.isDefault
        local.sortOrder = hub.sortOrder
        local.cloudUpdatedAt = hub.updatedAt
        local.updatedAt = hub.updatedAt
        try modelContext.save()
        return .applied
    }

    /// Live folders in display order.
    public func folders() throws -> [FolderRecord] {
        try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )).map(FolderRecord.init)
    }

    /// The hub ids of every local folder the hub knows, local tombstones
    /// included. A pulled note whose `folderId` is not in here would lose its
    /// folder on apply, so the sync engine parks it instead.
    public func folderCloudIds() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<LocalFolder>()).compactMap(\.cloudId))
    }

    /// Hub ids of folders this device saw deleted for good, so a pulled note
    /// still pointing at one is refiled instead of parked.
    public func deletedFolderCloudIds() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<DeletedFolderId>()).map(\.cloudId))
    }

    /// Files `note` into `target` (none if there is no default) as a pending
    /// edit, so the next push moves it on the hub too. The contract files
    /// notes whose folder is gone into the default folder (protocol section
    /// 8: deletes do not cascade to notes). Unsaved; the caller saves.
    private func refile(_ note: LocalNote, to target: LocalFolder?) {
        note.folder = target
        note.updatedAt = Self.bumped(note.updatedAt)
        note.syncStatus = .pending
    }

    /// The live default folder `FolderRecord.preferredDefault` picks.
    private func defaultFolder(excluding clientId: String? = nil) throws -> LocalFolder? {
        let live = try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.isDefault && $0.deletedAt == nil })).filter { $0.clientId != clientId }
        let pick = FolderRecord.preferredDefault(in: live.map(FolderRecord.init))
        return live.first { $0.clientId == pick?.clientId }
    }

    /// Files into the default folder every synced live note with no local
    /// folder whose hub folder this device saw deleted, as pending edits.
    /// The sync engine calls it after a note pull, so it only catches notes
    /// no newer hub row moved; `excluding` is the pass's parked hub ids.
    public func refileNotesInDeletedFolders(excluding parked: Set<String> = []) throws {
        let synced = SyncStatus.synced.rawValue
        let orphans = try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.deletedAt == nil && $0.syncStatusRaw == synced }))
            .filter { $0.folder == nil && $0.hubFolderId != nil }
        guard !orphans.isEmpty else { return }
        let deleted = try deletedFolderCloudIds()
        let due = orphans.filter { note in
            note.hubFolderId.map(deleted.contains) == true && !(note.cloudId.map(parked.contains) ?? false)
        }
        guard !due.isEmpty else { return }
        let target = try defaultFolder()
        for note in due { refile(note, to: target) }
        try modelContext.save()
    }

    private func isDeletedFolder(_ cloudId: String?) throws -> Bool {
        guard let cloudId else { return false }
        return try modelContext.fetchCount(FetchDescriptor<DeletedFolderId>(
            predicate: #Predicate { $0.cloudId == cloudId })) > 0
    }

    /// Unsaved; the caller saves.
    private func rememberDeletedFolder(_ cloudId: String) {
        let known = (try? modelContext.fetchCount(FetchDescriptor<DeletedFolderId>(
            predicate: #Predicate { $0.cloudId == cloudId }))) ?? 0
        if known == 0 { modelContext.insert(DeletedFolderId(cloudId: cloudId)) }
    }

    // MARK: Lookup

    private func note(_ clientId: String) throws -> LocalNote? {
        try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.clientId == clientId })).first
    }

    private func note(cloudId: String) throws -> LocalNote? {
        try modelContext.fetch(FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.cloudId == cloudId })).first
    }

    private func requireNote(_ clientId: String) throws -> LocalNote {
        guard let note = try note(clientId) else { throw NotesStoreError.noteNotFound(clientId) }
        return note
    }

    private func folder(_ clientId: String) throws -> LocalFolder? {
        try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.clientId == clientId })).first
    }

    private func folder(cloudId: String) throws -> LocalFolder? {
        try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.cloudId == cloudId })).first
    }

    /// A live local default folder the hub has never seen.
    private func unpushedDefaultFolder() throws -> LocalFolder? {
        try modelContext.fetch(FetchDescriptor<LocalFolder>(
            predicate: #Predicate { $0.isDefault && $0.cloudId == nil && $0.deletedAt == nil })).first
    }

    private func requireFolder(_ clientId: String) throws -> LocalFolder {
        guard let folder = try folder(clientId) else { throw NotesStoreError.folderNotFound(clientId) }
        return folder
    }

    /// A new `updatedAt` strictly after `old`, so two edits in the same clock
    /// tick still compare as different snapshots.
    private static func bumped(_ old: Date, now: Date = Date()) -> Date {
        max(now, old.addingTimeInterval(0.001))
    }
}
