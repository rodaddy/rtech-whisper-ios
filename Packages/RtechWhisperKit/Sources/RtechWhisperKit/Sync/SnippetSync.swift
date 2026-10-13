import Foundation

/// The hub calls snippet sync makes (protocol section 6). `HubSyncClient` and
/// `KeyedHubSync` are the real ones; tests use a stub.
public protocol SnippetHubSyncing: Sendable {
    func listSnippets(cursor: Date?, cursorId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage
    func listSnippetChanges(since: Date, sinceId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage
    func batchCreateSnippets(_ entries: [SnippetCreateInput]) async throws(HubError) -> [HubSnippetEntry]
    func updateSnippet(id: String, trigger: String?, replacement: String?) async throws(HubError) -> HubSnippetEntry
    func deleteSnippet(id: String) async throws(HubError)
}

extension HubSyncClient: SnippetHubSyncing {}

extension KeyedHubSync: SnippetHubSyncing {
    public func listSnippets(cursor: Date?, cursorId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage {
        try await client().listSnippets(cursor: cursor, cursorId: cursorId, limit: limit)
    }

    public func listSnippetChanges(since: Date, sinceId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage {
        try await client().listSnippetChanges(since: since, sinceId: sinceId, limit: limit)
    }

    public func batchCreateSnippets(_ entries: [SnippetCreateInput]) async throws(HubError) -> [HubSnippetEntry] {
        try await client().batchCreateSnippets(entries)
    }

    public func updateSnippet(id: String, trigger: String?, replacement: String?) async throws(HubError) -> HubSnippetEntry {
        try await client().updateSnippet(id: id, trigger: trigger, replacement: replacement)
    }

    public func deleteSnippet(id: String) async throws(HubError) {
        try await client().deleteSnippet(id: id)
    }
}

/// Two-way sync of the snippets with the hub, and so with the Mac (protocol
/// sections 6 and 8), in the dictionary's shape (`DictionarySync`). The
/// merge rules live in `SnippetStore.applyFromHub`.
public actor SnippetSync {
    public static let cursorKey = "snippets"
    /// The desktop's batch and page size for snippets.
    public static let pageSize = 200

    private let hub: any SnippetHubSyncing
    private let store: SnippetStore
    private let cursors: any CursorStore
    private let now: @Sendable () -> Date

    /// Snippets (by client id) the last push could not write, with the hub's
    /// answer. A `snippetTriggerTaken` one waits for an edit; the rest are
    /// sent again next pass.
    public private(set) var errors: [String: HubError] = [:]

    public init(
        hub: any SnippetHubSyncing, store: SnippetStore, cursors: any CursorStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.hub = hub
        self.store = store
        self.cursors = cursors
        self.now = now
    }

    /// One pass: pull, then push, for the dictionary's reason: a snippet this
    /// phone has never pushed takes the hub id of the Mac's snippet with the
    /// same trigger instead of being refused as a clash.
    public func sync() async throws {
        try await pull()
        try await push()
    }

    /// Deletes, then updates, then creates in batches. The hub checks a
    /// trigger against live rows only, so a trigger this phone deleted or
    /// renamed away is freed before a write that reuses it. A batch is
    /// all-or-nothing on the hub, so one trigger clash fails it; the batch is
    /// then sent one snippet at a time to find the clash. A transient hub
    /// error aborts the pass.
    public func push() async throws {
        var failed: [String: HubError] = [:]

        for pushed in await store.pendingDeletes() {
            guard let cloudId = pushed.cloudId else { continue }
            do {
                try await hub.deleteSnippet(id: cloudId)
            } catch .notFound {
                // Already gone on the hub: done (protocol section 8, Deletes).
            } catch {
                guard !SyncEngine.isTransient(error) else { throw error }
                failed[pushed.clientId] = error
                continue
            }
            await store.markDeleted(clientId: pushed.clientId)
        }

        for pushed in await store.pendingUpdates() {
            guard let cloudId = pushed.cloudId else { continue }
            do {
                let row = try await hub.updateSnippet(id: cloudId, trigger: pushed.trigger, replacement: pushed.replacement)
                await store.markUpdated(pushed, as: row)
            } catch .notFound {
                // Tombstoned on the hub; the next pull removes the local copy.
            } catch {
                try await record(error, for: pushed, into: &failed)
            }
        }

        let creates = await store.pendingCreates()
        var start = 0
        while start < creates.count {
            let batch = Array(creates[start..<min(start + Self.pageSize, creates.count)])
            start += Self.pageSize
            do {
                await settle(batch, with: try await hub.batchCreateSnippets(batch.map(\.createInput)))
            } catch .snippetTriggerTaken {
                for pushed in batch {
                    do {
                        await settle([pushed], with: try await hub.batchCreateSnippets([pushed.createInput]))
                    } catch {
                        try await record(error, for: pushed, into: &failed)
                    }
                }
            } catch {
                guard !SyncEngine.isTransient(error) else { throw error }
                for pushed in batch { failed[pushed.clientId] = error }
            }
        }
        errors = failed
    }

    /// The first run reads a snapshot, paged by (`cursor`, `cursor_id`); later
    /// runs read the delta ascending by (`updated_at`, `id`), paged by
    /// `since_id` inside the pass. The cursor stored is this pass's start
    /// minus the lookback, with no id (protocol section 8, Cursors).
    public func pull() async throws {
        let passStart = now()
        let since = cursors.cursor(Self.cursorKey)
        var cursor = since
        var cursorId: String?

        while true {
            let page: HubSnippetPage
            if let since {
                page = try await hub.listSnippetChanges(since: cursor ?? since, sinceId: cursorId, limit: Self.pageSize)
            } else {
                page = try await hub.listSnippets(cursor: cursor, cursorId: cursorId, limit: Self.pageSize)
            }
            for row in page.entries {
                await store.applyFromHub(row)
            }
            guard page.hasMore, let last = page.entries.last else { break }
            let next = since == nil ? last.createdAt : last.updatedAt
            if next == cursor && last.id == cursorId {
                throw SyncEngineError.cursorStalled(next, last.id)
            }
            cursor = next
            cursorId = last.id
        }

        cursors.setCursor(passStart.addingTimeInterval(-SyncEngine.lookback), for: Self.cursorKey)
    }

    private func settle(_ batch: [SnippetEntry], with rows: [HubSnippetEntry]) async {
        let byClientId = Dictionary(rows.map { ($0.clientSnippetId ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        for pushed in batch {
            guard let row = byClientId[pushed.clientId] else { continue }
            await store.markCreated(pushed, as: row)
        }
    }

    /// A trigger clash parks the snippet until it is edited; any other
    /// non-transient rejection is kept for the next pass. Transient errors abort.
    private func record(_ error: HubError, for pushed: SnippetEntry, into failed: inout [String: HubError]) async throws {
        guard !SyncEngine.isTransient(error) else { throw error }
        if error == .snippetTriggerTaken { await store.markTriggerTaken(pushed) }
        failed[pushed.clientId] = error
    }
}
