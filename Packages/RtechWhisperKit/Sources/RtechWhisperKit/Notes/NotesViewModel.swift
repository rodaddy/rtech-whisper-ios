import Foundation
import Observation

/// What the Notes screens render and call: folders, notes, local search,
/// edits saved after a short pause, and sync with the hub through the
/// `SyncEngine`. Every edit lands in the local store first, so the screens
/// work offline and with no device key; sync catches up when it can.
@MainActor
@Observable
public final class NotesViewModel {
    public enum SyncState: Equatable, Sendable {
        /// No device key stored: notes stay on this phone.
        case off
        case idle
        case syncing
        /// The last pass failed. `nil` when the failure was not a hub error.
        case failed(HubError?)
    }

    /// The two answers to a conflict, as on the desktop: Keep or Refresh.
    public enum Resolution: Sendable {
        /// Push this phone's copy over the hub's.
        case keepMine
        /// Replace this phone's copy with the hub's.
        case takeHub
    }

    /// The name the desktop gives its default folder.
    public static let defaultFolderName = FolderRecord.defaultName

    public enum FolderError: Error, Equatable {
        /// The default folder ("Personal") cannot be deleted, as on the desktop.
        case cannotDeleteDefault
        /// A folder with that name already exists here.
        case nameTaken(String)
        /// A blank name.
        case emptyName
    }

    public private(set) var folders: [FolderRecord] = []
    public private(set) var conflicts: [SyncConflict] = []
    public private(set) var syncState: SyncState = .idle
    public private(set) var lastSyncedAt: Date?
    /// Notes (by client id) the hub rejected on the last push.
    public private(set) var noteErrors: [String: HubError] = [:]
    /// The folder the list shows; `nil` is every folder.
    public var selectedFolderId: String?
    public var searchText = ""
    /// Called with each note made here (`create` and `saveAsNote`). The app
    /// hands a note with content to the auto-titler.
    public var onCreated: (@MainActor (NoteRecord) -> Void)?

    private var storedNotes: [NoteRecord] = []
    /// Bumped by `move`, so views reading `orderedNotes` redraw.
    private var orderRevision = 0
    private var drafts: [String: Draft] = [:]
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private let store: NotesStore
    private let engine: SyncEngine
    private let canSync: @MainActor () -> Bool
    private let saveDelay: Duration
    private let syncDelay: Duration?
    private let now: () -> Date
    private let order: NoteOrderStore

    private struct Draft: Equatable {
        var title: String?
        var content: String?
    }

    /// - Parameters:
    ///   - canSync: whether a device key is stored; when false, sync stays off.
    ///   - saveDelay: the pause after the last keystroke before an edit is saved.
    ///   - syncDelay: the pause after a save before a sync pass; `nil` never
    ///     syncs on its own (tests call `syncNow`).
    public init(
        store: NotesStore, engine: SyncEngine, canSync: @escaping @MainActor () -> Bool,
        saveDelay: Duration = .milliseconds(500), syncDelay: Duration? = .seconds(2),
        now: @escaping () -> Date = Date.init, order: NoteOrderStore = NoteOrderStore()
    ) {
        self.order = order
        self.store = store
        self.engine = engine
        self.canSync = canSync
        self.saveDelay = saveDelay
        self.syncDelay = syncDelay
        self.now = now
    }

    // MARK: Reading

    /// Live notes, newest first, with unsaved edits applied.
    public var allNotes: [NoteRecord] {
        storedNotes.map(applyingDraft)
    }

    /// What the list shows: the selected folder, filtered by `searchText`.
    public var visibleNotes: [NoteRecord] {
        search(searchText, inFolder: selectedFolderId)
    }

    public func notes(inFolder folderClientId: String?) -> [NoteRecord] {
        guard let folderClientId else { return allNotes }
        return allNotes.filter { $0.folderClientId == folderClientId }
    }

    /// The folder's notes in the order the user dragged them into on this
    /// phone (`NoteOrder`); `nil` is every folder.
    public func orderedNotes(inFolder folderClientId: String?) -> [NoteRecord] {
        _ = orderRevision
        return NoteOrder.ordered(notes(inFolder: folderClientId), savedOrder: order.order(forFolder: folderClientId))
    }

    /// Saves a drag in the folder's list. Local only: never synced.
    public func move(inFolder folderClientId: String?, from offsets: IndexSet, to destination: Int) {
        let ids = orderedNotes(inFolder: folderClientId).map(\.clientId)
        order.setOrder(NoteOrder.moved(ids, from: offsets, to: destination), forFolder: folderClientId)
        orderRevision &+= 1
    }

    /// A case- and diacritic-insensitive match on title, content, and
    /// transcript. Blank text matches every note.
    public func search(_ text: String, inFolder folderClientId: String? = nil) -> [NoteRecord] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes(inFolder: folderClientId)
        guard !needle.isEmpty else { return notes }
        return notes.filter { note in
            [note.title, note.content, note.transcript].contains { field in
                field?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    public func note(_ clientId: String) -> NoteRecord? {
        storedNotes.first { $0.clientId == clientId }.map(applyingDraft)
    }

    public func conflict(for clientId: String) -> SyncConflict? {
        conflicts.first { $0.clientId == clientId }
    }

    /// True while a change to the note is saved on the phone but not on the hub.
    public func isWaitingToSync(_ clientId: String) -> Bool {
        drafts[clientId] != nil || note(clientId)?.syncStatus == .pending
    }

    /// True while an edit to the note has not reached the local store yet.
    public func hasUnsavedEdit(_ clientId: String) -> Bool {
        drafts[clientId] != nil
    }

    /// The desktop's default folder ("Personal"), else the default with the
    /// lowest sortOrder: the same rule the store refiles by.
    public var defaultFolder: FolderRecord? {
        FolderRecord.preferredDefault(in: folders)
    }

    /// Live notes in the folder, for the folder list's counts.
    public func noteCount(inFolder folderClientId: String) -> Int {
        allNotes.count { $0.folderClientId == folderClientId }
    }

    /// True when the folder can be deleted: every folder but the default.
    public func canDelete(_ folder: FolderRecord) -> Bool {
        !folder.isDefault
    }

    /// Re-reads folders and notes from the store.
    public func reload() async {
        do {
            folders = try await store.folders()
            storedNotes = try await store.notes()
        } catch {
            syncState = .failed(nil)
        }
        if let selectedFolderId, !folders.contains(where: { $0.clientId == selectedFolderId }) {
            self.selectedFolderId = nil
        }
    }

    // MARK: Writing

    /// A new note in `folderClientId`; `nil` files it in the selected folder,
    /// or the default folder when every folder is shown.
    @discardableResult
    public func create(
        title: String? = nil, content: String = "", transcript: String? = nil, noteType: HubNoteType = .personal,
        folderClientId: String? = nil, sourceFile: String? = nil, audioDurationSeconds: Double? = nil
    ) async throws -> NoteRecord {
        let folder: String? = if let folderClientId { folderClientId } else if let selectedFolderId { selectedFolderId } else { try await ensureDefaultFolder().clientId }
        let note = try await store.createNote(
            content: content, title: title, transcript: transcript, noteType: noteType, folderClientId: folder,
            sourceFile: sourceFile, audioDurationSeconds: audioDurationSeconds)
        await reload()
        scheduleSync()
        onCreated?(note)
        return note
    }

    /// Dictate's "Save as note": the text as a new note in the default folder.
    @discardableResult
    public func saveAsNote(_ text: String) async throws -> NoteRecord {
        try await create(content: text, transcript: text, folderClientId: try await ensureDefaultFolder().clientId)
    }

    /// Records an edit now and saves it once typing pauses for `saveDelay`.
    /// A `nil` field is left alone.
    public func edit(_ clientId: String, title: String? = nil, content: String? = nil) {
        var draft = drafts[clientId] ?? Draft()
        if let title { draft.title = title }
        if let content { draft.content = content }
        drafts[clientId] = draft
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.writeDrafts()
            self?.scheduleSync()
        }
    }

    /// Writes a change to the store now, with no typing pause: the chat's
    /// note tools. Waiting edits are saved first so they cannot land after
    /// this and undo it. A `nil` field is left alone; the note goes pending
    /// and syncs like any other edit. The title and content writes carry
    /// their own proof of what the caller read (`NotesStore.reviseNote`),
    /// checked against the stored text as the store writes; a failed check
    /// throws and nothing is changed, the folder included.
    @discardableResult
    public func update(
        _ clientId: String, retitle: (from: String, to: String)? = nil, content: NoteContentChange? = nil,
        folderClientId: String? = nil
    ) async throws -> NoteRecord {
        await flushEdits()
        var note: NoteRecord?
        if retitle != nil || content != nil {
            note = try await store.reviseNote(clientId: clientId, retitle: retitle, content: content)
        }
        if let folderClientId {
            note = try await store.moveNote(clientId: clientId, toFolder: folderClientId)
        }
        await reload()
        if let note {
            scheduleSync()
            return note
        }
        // Nothing to change: hand back the note as it stands.
        guard let current = storedNotes.first(where: { $0.clientId == clientId }) else {
            throw NotesStoreError.noteNotFound(clientId)
        }
        return current
    }

    /// Writes the note's enhancement (`nil` clears it) through
    /// `NotesStore.enhanceNote`, leaving `content` alone: the note actions.
    /// Waiting edits are saved first; the store refuses the write when the
    /// enhancement is not `expected` (or the content not `expectedContent`).
    @discardableResult
    public func enhance(
        _ clientId: String, to enhancement: NoteEnhancement?, expecting expected: NoteEnhancement?,
        expectedContent: String? = nil
    ) async throws -> NoteRecord {
        await flushEdits()
        let note = try await store.enhanceNote(
            clientId: clientId, to: enhancement, expecting: expected, expectedContent: expectedContent)
        await reload()
        scheduleSync()
        return note
    }

    /// Saves every waiting edit to the store now.
    public func flushEdits() async {
        saveTask?.cancel()
        saveTask = nil
        await writeDrafts()
    }

    /// Removes the note. A note the hub knows leaves a tombstone for the
    /// next sync; one it never saw is gone at once.
    public func delete(_ clientId: String) async throws {
        drafts[clientId] = nil
        try await store.softDeleteNote(clientId: clientId)
        await reload()
        scheduleSync()
    }

    // MARK: Folders

    /// True once a folder pull has succeeded in this run of the app. Set
    /// from the folder step alone, so a later step of the pass that fails
    /// (notes, dictation history) does not hold it back.
    private var foldersPulledOnce = false
    /// True when the last sync pass pulled folders.
    private var foldersPulledLastPass = false

    /// True when a seeded folder cannot clash with one only the hub has:
    /// sync is off, or one folder pull has succeeded, so the Mac's folders
    /// are local.
    var hubSeen: Bool { !canSync() || foldersPulledOnce }

    /// True when a new folder cannot clash with one the Mac made since an
    /// earlier pull: sync is off, or the last pass pulled folders.
    var foldersCurrent: Bool { !canSync() || foldersPulledLastPass }

    /// Seeds the desktop's three folders that are missing here, by name.
    /// "Personal" is always safe: pushed with `is_default`, the hub hands
    /// back its existing default row. "Meetings" and "Videos" would clash
    /// (`409 folder_name_taken`) if the Mac made them first, so with sync on
    /// they wait until one pull has succeeded and the Mac's copies are local.
    public func ensureDefaultFolders() async {
        await reload()
        var seeded = false
        for seed in DefaultFolder.missing(from: folders) where seed.isDefault || hubSeen {
            _ = try? await store.createFolder(name: seed.name, isDefault: seed.isDefault, sortOrder: seed.sortOrder)
            seeded = true
        }
        guard seeded else { return }
        await reload()
        scheduleSync()
    }

    /// A new folder after the last one in display order.
    @discardableResult
    public func createFolder(name: String) async throws -> FolderRecord {
        let name = try validFolderName(name, excluding: nil)
        let sortOrder = (folders.map(\.sortOrder).max() ?? -1) + 1
        let folder = try await store.createFolder(name: name, sortOrder: sortOrder)
        await reload()
        scheduleSync()
        return folder
    }

    @discardableResult
    public func renameFolder(_ clientId: String, to name: String) async throws -> FolderRecord {
        let name = try validFolderName(name, excluding: clientId)
        let folder = try await store.editFolder(clientId: clientId, name: name)
        await reload()
        scheduleSync()
        return folder
    }

    /// Removes the folder. Its notes move to the default folder first, as the
    /// hub contract asks (deletes do not cascade). The default folder itself
    /// cannot be deleted, as on the desktop.
    public func deleteFolder(_ clientId: String) async throws {
        await reload()
        guard let folder = folders.first(where: { $0.clientId == clientId }) else { return }
        guard canDelete(folder) else { throw FolderError.cannotDeleteDefault }
        let target = try await ensureDefaultFolder()
        try await store.refileNotes(fromFolder: clientId, toFolder: target.clientId)
        try await store.softDeleteFolder(clientId: clientId)
        if selectedFolderId == clientId { selectedFolderId = nil }
        await reload()
        scheduleSync()
    }

    private func validFolderName(_ raw: String, excluding clientId: String?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        let clash = folders.contains { $0.clientId != clientId && $0.name.lowercased() == name.lowercased() }
        guard !clash else { throw FolderError.nameTaken(name) }
        return name
    }

    // MARK: Sync

    /// Pulls the hub's folders alone, with no push and no note pull, and
    /// sets `foldersCurrent` from it: the chat's note tools, before making
    /// a folder. Leaving notes alone keeps a write the tool is about to make
    /// on the revision the model read. With a pass already running, nothing
    /// is pulled here and folders do not count as current.
    func refreshFolders() async {
        foldersPulledLastPass = false
        guard canSync(), syncState != .syncing else {
            await reload()
            return
        }
        do {
            try await engine.pullFolders()
            foldersPulledLastPass = await engine.foldersPulled
        } catch {
            foldersPulledLastPass = false
        }
        if foldersPulledLastPass {
            foldersPulledOnce = true
            await ensureDefaultFolders()
        } else {
            await reload()
        }
    }

    /// One sync pass now: save waiting edits, push, pull, refresh the list.
    /// A pass already running is not doubled.
    public func syncNow() async {
        syncTask?.cancel()
        syncTask = nil
        await runSync()
    }

    private func runSync() async {
        await flushEdits()
        guard canSync() else {
            syncState = .off
            await reload()
            return
        }
        // A pass already running is not this caller's pass: nothing it pulls
        // counts as current for this caller.
        foldersPulledLastPass = false
        guard syncState != .syncing else { return }
        syncState = .syncing
        do {
            try await engine.sync()
            lastSyncedAt = now()
            syncState = .idle
        } catch let error as HubError {
            syncState = .failed(error)
        } catch {
            syncState = .failed(nil)
        }
        foldersPulledLastPass = await engine.foldersPulled
        if foldersPulledLastPass { foldersPulledOnce = true }
        conflicts = await engine.conflicts
        noteErrors = await engine.noteErrors
        // The Mac's folders are local now: anything still missing is seeded
        // by name, so it never doubles a folder the hub already has.
        if foldersPulledLastPass { await ensureDefaultFolders() } else { await reload() }
    }

    /// Settles a conflict. Keep mine rebases the edit on the hub's revision
    /// and pushes it; take hub replaces the local copy with the hub's.
    public func resolve(_ clientId: String, _ resolution: Resolution) async {
        do {
            switch resolution {
            case .keepMine:
                await flushEdits()
                try await engine.keepMine(clientId)
            case .takeHub:
                drafts[clientId] = nil
                try await engine.takeHub(clientId)
            }
        } catch {
            syncState = .failed(nil)
        }
        conflicts = await engine.conflicts
        await reload()
        if resolution == .keepMine { await syncNow() }
    }

    // MARK: Private

    private func writeDrafts() async {
        let pending = drafts
        guard !pending.isEmpty else { return }
        for (clientId, draft) in pending {
            // A note deleted meanwhile (here or by a pull) has nothing to save.
            _ = try? await store.editNote(clientId: clientId, title: draft.title, content: draft.content)
        }
        await reload()
        // A draft stays visible until the store holds it; one typed over
        // during the write is newer and waits for its own save.
        for (clientId, draft) in pending where drafts[clientId] == draft {
            drafts[clientId] = nil
        }
    }

    private func scheduleSync() {
        guard let syncDelay else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: syncDelay)
            guard !Task.isCancelled else { return }
            // Not syncNow: cancelling this task would cancel its own requests.
            await self?.runSync()
        }
    }

    /// The default folder, made if it is missing. Internal for the chat's
    /// note tools, which file a note there when no folder is named.
    func ensureDefaultFolder() async throws -> FolderRecord {
        await reload()
        if let defaultFolder { return defaultFolder }
        // Pushed with is_default, the hub answers with its existing default
        // row if the Mac already made one.
        let folder = try await store.createFolder(name: Self.defaultFolderName, isDefault: true)
        await reload()
        return folder
    }

    private func applyingDraft(_ note: NoteRecord) -> NoteRecord {
        guard let draft = drafts[note.clientId] else { return note }
        var note = note
        if let title = draft.title { note.title = title }
        if let content = draft.content { note.content = content }
        return note
    }
}
