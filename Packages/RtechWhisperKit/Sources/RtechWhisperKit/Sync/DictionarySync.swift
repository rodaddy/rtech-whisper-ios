import Foundation

/// The hub calls dictionary sync makes (protocol section 5). `HubSyncClient`
/// and `KeyedHubSync` are the real ones; tests use a stub.
public protocol DictionaryHubSyncing: Sendable {
    func listDictionary(since: Date?, sinceId: String?, limit: Int?) async throws(HubError) -> HubDictionaryPage
    func batchCreateDictionary(_ entries: [DictionaryCreateInput]) async throws(HubError) -> [HubDictionaryEntry]
    func updateDictionaryEntry(id: String, word: String?, source: String?) async throws(HubError) -> HubDictionaryEntry
    func deleteDictionaryEntry(id: String) async throws(HubError)
}

extension HubSyncClient: DictionaryHubSyncing {}

extension KeyedHubSync: DictionaryHubSyncing {
    public func listDictionary(since: Date?, sinceId: String?, limit: Int?) async throws(HubError) -> HubDictionaryPage {
        try await client().listDictionary(since: since, sinceId: sinceId, limit: limit)
    }

    public func batchCreateDictionary(_ entries: [DictionaryCreateInput]) async throws(HubError) -> [HubDictionaryEntry] {
        try await client().batchCreateDictionary(entries)
    }

    public func updateDictionaryEntry(id: String, word: String?, source: String?) async throws(HubError) -> HubDictionaryEntry {
        try await client().updateDictionaryEntry(id: id, word: word, source: source)
    }

    public func deleteDictionaryEntry(id: String) async throws(HubError) {
        try await client().deleteDictionaryEntry(id: id)
    }
}

/// Two-way sync of the custom dictionary with the hub, and so with the Mac
/// (protocol sections 5 and 8). Words are last-writer-wins; the merge rules
/// live in `DictionaryStore.applyFromHub`.
public actor DictionarySync {
    public static let cursorKey = "dictionary"
    /// The desktop's batch and page size for the dictionary.
    public static let pageSize = 200

    private let hub: any DictionaryHubSyncing
    private let store: DictionaryStore
    private let cursors: any CursorStore
    private let now: @Sendable () -> Date

    /// Entries (by client id) the last push could not write, with the hub's
    /// answer. They stay pending and are sent again next pass.
    public private(set) var errors: [String: HubError] = [:]

    public init(
        hub: any DictionaryHubSyncing, store: DictionaryStore, cursors: any CursorStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.hub = hub
        self.store = store
        self.cursors = cursors
        self.now = now
    }

    /// One pass: pull, then push. Pulling first lets a word this phone has
    /// never pushed take the hub id of the same word from the Mac, instead of
    /// doubling it on the hub (which has no unique index on the word).
    public func sync() async throws {
        try await pull()
        try await push()
    }

    /// Creates in batches, then updates, then deletes. A transient hub error
    /// aborts the pass; any other rejection is kept in `errors`. An update
    /// the hub answers `404` for is a row another device deleted: the pull
    /// brings its tombstone and removes it here.
    public func push() async throws {
        var failed: [String: HubError] = [:]

        let creates = await store.pendingCreates()
        var start = 0
        while start < creates.count {
            let batch = Array(creates[start..<min(start + Self.pageSize, creates.count)])
            start += Self.pageSize
            do {
                let rows = try await hub.batchCreateDictionary(batch.map(\.createInput))
                let byClientId = Dictionary(rows.map { ($0.clientDictId ?? "", $0) }, uniquingKeysWith: { first, _ in first })
                for pushed in batch {
                    guard let row = byClientId[pushed.clientId] else { continue }
                    await store.markCreated(pushed, as: row)
                }
            } catch {
                guard !SyncEngine.isTransient(error) else { throw error }
                for pushed in batch { failed[pushed.clientId] = error }
            }
        }

        for pushed in await store.pendingUpdates() {
            guard let cloudId = pushed.cloudId else { continue }
            do {
                let row = try await hub.updateDictionaryEntry(id: cloudId, word: pushed.word, source: pushed.source)
                await store.markUpdated(pushed, as: row)
            } catch .notFound {
                // Tombstoned on the hub; the next pull removes the local copy.
            } catch {
                guard !SyncEngine.isTransient(error) else { throw error }
                failed[pushed.clientId] = error
            }
        }

        for pushed in await store.pendingDeletes() {
            guard let cloudId = pushed.cloudId else { continue }
            do {
                try await hub.deleteDictionaryEntry(id: cloudId)
            } catch .notFound {
                // Already gone on the hub: done (protocol section 8, Deletes).
            } catch {
                guard !SyncEngine.isTransient(error) else { throw error }
                failed[pushed.clientId] = error
                continue
            }
            await store.markDeleted(clientId: pushed.clientId)
        }
        errors = failed
    }

    /// Paged delta ascending by (`updated_at`, `id`) from the stored cursor,
    /// or every row on the first run. `since_id` resumes a page inside this
    /// pass only. The cursor stored is this pass's start minus the lookback,
    /// with no id (protocol section 8, Cursors), so a row stamped before the
    /// pass but committed after it is read next pass; a re-served row this
    /// phone already applied is a no-op.
    public func pull() async throws {
        let passStart = now()
        var since = cursors.cursor(Self.cursorKey)
        var sinceId: String?

        while true {
            let page = try await hub.listDictionary(since: since, sinceId: sinceId, limit: Self.pageSize)
            for row in page.entries {
                await store.applyFromHub(row)
            }
            guard page.hasMore, let last = page.entries.last else { break }
            if last.updatedAt == since && last.id == sinceId {
                throw SyncEngineError.cursorStalled(last.updatedAt, last.id)
            }
            since = last.updatedAt
            sinceId = last.id
        }

        cursors.setCursor(passStart.addingTimeInterval(-SyncEngine.lookback), for: Self.cursorKey)
    }
}
