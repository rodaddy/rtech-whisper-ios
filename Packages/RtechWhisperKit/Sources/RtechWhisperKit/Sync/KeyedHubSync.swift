import Foundation

/// The real hub for the sync engine, reading the device key on every call so
/// a key pasted (or forgotten) later takes effect without a restart. With no
/// key stored every call throws `HubError.unauthorized`, which the engine
/// treats as transient.
public struct KeyedHubSync: HubSyncing {
    private let keys: any DeviceKeyStore
    private let configuration: HubConfiguration
    private let session: URLSession

    public init(keys: any DeviceKeyStore, configuration: HubConfiguration = HubConfiguration(), session: URLSession = .shared) {
        self.keys = keys
        self.configuration = configuration
        self.session = session
    }

    /// Whether a device key is stored, so sync can run at all.
    public var hasKey: Bool {
        (try? keys.load()) != nil
    }

    func client() throws(HubError) -> HubSyncClient {
        guard let key = try? keys.load() else { throw .unauthorized }
        return HubSyncClient(baseURL: configuration.baseURL, key: key, session: session)
    }

    public func listFolders(since: Date?) async throws(HubError) -> [HubFolder] {
        try await client().listFolders(since: since)
    }

    public func listNotes(limit: Int, before: Date?, beforeId: String?) async throws(HubError) -> [HubNote] {
        try await client().listNotes(limit: limit, before: before, beforeId: beforeId)
    }

    public func listNoteChanges(limit: Int, since: Date, sinceId: String?) async throws(HubError) -> [HubNote] {
        try await client().listNoteChanges(limit: limit, since: since, sinceId: sinceId)
    }

    public func batchCreateFolders(_ folders: [FolderCreateInput]) async throws(HubError) -> [HubFolder] {
        try await client().batchCreateFolders(folders)
    }

    public func createFolder(_ folder: FolderCreateInput) async throws(HubError) -> HubFolder {
        try await client().createFolder(folder)
    }

    public func updateFolder(_ update: FolderUpdateInput) async throws(HubError) -> HubFolder {
        try await client().updateFolder(update)
    }

    public func deleteFolder(id: String) async throws(HubError) {
        try await client().deleteFolder(id: id)
    }

    public func batchCreateNotes(_ notes: [NoteCreateInput]) async throws(HubError) -> [HubNoteCreated] {
        try await client().batchCreateNotes(notes)
    }

    public func updateNote(_ update: NoteUpdateInput) async throws(HubError) -> HubNote {
        try await client().updateNote(update)
    }

    public func deleteNote(id: String) async throws(HubError) {
        try await client().deleteNote(id: id)
    }
}
