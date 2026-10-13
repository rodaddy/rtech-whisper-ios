import Foundation
import Synchronization
import Testing

@testable import RtechWhisperKit

// Dictionary sync with the Mac through the hub (protocol sections 5 and 8,
// issue #409). Merge rules match desktop main: a pending local edit is never
// overwritten, a re-served unchanged row writes nothing, and a tombstone
// removes only the row it owns.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
/// L, the lookback, as the contract states it.
private let lookback: TimeInterval = 60

private func hubEntry(
    _ id: String, word: String, clientId: String? = nil, source: String = "manual",
    updatedAt: Date = t0, deletedAt: Date? = nil
) -> HubDictionaryEntry {
    HubDictionaryEntry(
        id: id, clientDictId: clientId ?? "c-\(id)", word: word, source: source, deletedAt: deletedAt,
        createdAt: t0, updatedAt: updatedAt)
}

/// A hub that serves the dictionary the way the protocol orders and filters
/// it (ascending by `updated_at`, `id`; `since_id` only with `since`), keeps
/// its rows across calls, and records every request.
actor FakeDictionaryHub: DictionaryHubSyncing {
    struct ListCall: Equatable {
        var since: Date?
        var sinceId: String?
    }

    var rows: [HubDictionaryEntry] = []
    var listCalls: [ListCall] = []
    var creates: [[DictionaryCreateInput]] = []
    var updates: [(id: String, word: String?)] = []
    var deletes: [String] = []
    private var clock = t0.addingTimeInterval(500)

    func setRows(_ value: [HubDictionaryEntry]) { rows = value }
    func upsert(_ row: HubDictionaryEntry) {
        rows.removeAll { $0.id == row.id }
        rows.append(row)
    }
    /// Runs inside every write, before the hub answers.
    var duringWrite: (@Sendable () async -> Void)?
    func setDuringWrite(_ hook: (@Sendable () async -> Void)?) { duringWrite = hook }

    /// Every write stamps a later `updated_at`, as the hub does.
    private func stamp() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    func listDictionary(since: Date?, sinceId: String?, limit: Int?) async throws(HubError) -> HubDictionaryPage {
        listCalls.append(ListCall(since: since, sinceId: sinceId))
        let limit = limit ?? 200
        let matching = rows
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
            .filter { row in
                guard let since else { return true }
                guard let sinceId else { return row.updatedAt > since }
                return (row.updatedAt, row.id) > (since, sinceId)
            }
        return HubDictionaryPage(entries: Array(matching.prefix(limit)), hasMore: matching.count > limit)
    }

    func batchCreateDictionary(_ entries: [DictionaryCreateInput]) async throws(HubError) -> [HubDictionaryEntry] {
        creates.append(entries)
        await duringWrite?()
        return entries.map { input in
            // A retried create (same client id) returns the row the first try made.
            if let existing = rows.first(where: { $0.clientDictId == input.clientDictId }) { return existing }
            let row = HubDictionaryEntry(
                id: "h-\(input.clientDictId)", clientDictId: input.clientDictId, word: input.word,
                source: input.source, deletedAt: nil, createdAt: input.createdAt, updatedAt: stamp())
            rows.append(row)
            return row
        }
    }

    func updateDictionaryEntry(id: String, word: String?, source: String?) async throws(HubError) -> HubDictionaryEntry {
        updates.append((id, word))
        await duringWrite?()
        guard let index = rows.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw .notFound }
        rows[index].word = word ?? rows[index].word
        rows[index].source = source ?? rows[index].source
        rows[index].updatedAt = stamp()
        return rows[index]
    }

    func deleteDictionaryEntry(id: String) async throws(HubError) {
        deletes.append(id)
        guard let index = rows.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw .notFound }
        let now = stamp()
        rows[index].deletedAt = now
        rows[index].updatedAt = now
    }
}

/// Counts every write, so a no-op can be told from a write of the same value.
private final class CountingDictionaryPersistence: DictionaryPersistence, @unchecked Sendable {
    private let inner: InMemoryDictionaryPersistence
    private let count = Mutex(0)
    var saves: Int { count.withLock { $0 } }

    init(entries: [DictionaryEntry] = []) {
        inner = InMemoryDictionaryPersistence(entries: entries)
    }

    func load() -> [DictionaryEntry] { inner.load() }
    func save(_ entries: [DictionaryEntry]) {
        count.withLock { $0 += 1 }
        inner.save(entries)
    }
}

private final class DictionaryClock: Sendable {
    private let value = Mutex(t0.addingTimeInterval(1000))
    func set(_ date: Date) { value.withLock { $0 = date } }
    func now() -> Date { value.withLock { $0 } }
}

@MainActor
private struct Rig {
    let hub = FakeDictionaryHub()
    let persistence: CountingDictionaryPersistence
    let store: DictionaryStore
    let cursors = InMemoryCursorStore()
    let clock = DictionaryClock()
    let sync: DictionarySync

    init(entries: [DictionaryEntry] = []) {
        persistence = CountingDictionaryPersistence(entries: entries)
        let clock = clock
        store = DictionaryStore(persistence: persistence, now: { clock.now() })
        sync = DictionarySync(hub: hub, store: store, cursors: cursors, now: { clock.now() })
    }

    /// One synced word, as a pull of `row` leaves it.
    static func synced(_ row: HubDictionaryEntry) -> DictionaryEntry {
        DictionaryEntry(
            clientId: row.clientDictId!, cloudId: row.id, word: row.word, source: row.source, syncStatus: .synced,
            cloudUpdatedAt: row.updatedAt, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }
}

@MainActor
@Suite("Dictionary sync")
struct DictionarySyncTests {
    // MARK: Pull

    @Test("the first pull reads every row, and the cursor is the pass start minus L with no id")
    func firstPull() async throws {
        let rig = Rig()
        await rig.hub.setRows([hubEntry("h1", word: "Proxmox"), hubEntry("h2", word: "Caddy", updatedAt: t0.addingTimeInterval(1))])
        let pass = t0.addingTimeInterval(1000)
        rig.clock.set(pass)

        try await rig.sync.pull()

        #expect(rig.store.words == ["Proxmox", "Caddy"])
        #expect(rig.store.pendingCreates().isEmpty && rig.store.pendingUpdates().isEmpty)
        #expect(await rig.hub.listCalls == [.init(since: nil, sinceId: nil)])
        #expect(rig.cursors.cursor(DictionarySync.cursorKey) == pass.addingTimeInterval(-lookback))

        rig.clock.set(pass.addingTimeInterval(30))
        try await rig.sync.pull()
        #expect(await rig.hub.listCalls.last == .init(since: pass.addingTimeInterval(-lookback), sinceId: nil))
    }

    @Test("a pull pages with since_id inside the pass and stores no id")
    func pagesInsidePass() async throws {
        let rig = Rig()
        // One stamp for every row: only since_id can page past a tie.
        let rows = (0..<(DictionarySync.pageSize + 5)).map { hubEntry(String(format: "h%03d", $0), word: "w\($0)") }
        await rig.hub.setRows(rows)

        try await rig.sync.pull()

        #expect(rig.store.words.count == rows.count)
        let calls = await rig.hub.listCalls
        #expect(calls == [.init(since: nil, sinceId: nil), .init(since: t0, sinceId: rows[DictionarySync.pageSize - 1].id)])
    }

    @Test("a hub edit to a clean word applies; a pending local edit is never overwritten")
    func pendingEditSurvives() async throws {
        let base = hubEntry("h1", word: "Proxmox")
        let other = hubEntry("h2", word: "Caddy")
        let rig = Rig(entries: [Rig.synced(base), Rig.synced(other)])
        try rig.store.edit("Proxmox", to: "Proxmox VE")

        // The Mac renamed both words after this phone last pulled.
        await rig.hub.setRows([
            hubEntry("h1", word: "PVE", updatedAt: t0.addingTimeInterval(10)),
            hubEntry("h2", word: "Caddy2", updatedAt: t0.addingTimeInterval(10)),
        ])
        try await rig.sync.pull()

        #expect(rig.store.words == ["Proxmox VE", "Caddy2"])
        #expect(rig.store.pendingUpdates().map(\.word) == ["Proxmox VE"])

        // The push then sends the local edit, and it settles.
        try await rig.sync.push()
        #expect(await rig.hub.updates.map(\.word) == ["Proxmox VE"])
        #expect(await rig.hub.rows.first { $0.id == "h1" }?.word == "Proxmox VE")
        #expect(rig.store.pendingUpdates().isEmpty)
    }

    @Test("a re-served row with the stamp this phone applied writes nothing, whatever the local copy holds")
    func reServeIsANoOp() async throws {
        // Stamped inside the lookback of the next pass, so that pass re-serves it.
        let row = hubEntry("h1", word: "Proxmox", updatedAt: t0.addingTimeInterval(990))
        let rig = Rig()
        await rig.hub.setRows([row])
        try await rig.sync.pull()
        let clean = rig.store.entries
        let saves = rig.persistence.saves

        // The lookback re-serves the same row: no write at all.
        rig.clock.set(t0.addingTimeInterval(1010))
        try await rig.sync.pull()
        #expect(rig.store.entries == clean)
        #expect(rig.persistence.saves == saves)

        // A local edit since that pull keeps its pending push.
        try rig.store.edit("Proxmox", to: "Proxmox VE")
        let edited = rig.store.entries
        #expect(rig.store.applyFromHub(row) == .unchanged)
        #expect(rig.store.entries == edited)
        #expect(rig.store.pendingUpdates().map(\.word) == ["Proxmox VE"])
    }

    // MARK: Tombstones

    @Test("a tombstone removes its own row; a re-served tombstone is a no-op")
    func tombstoneRemovesOwnRow() async throws {
        let rig = Rig(entries: [Rig.synced(hubEntry("h1", word: "Proxmox")), Rig.synced(hubEntry("h2", word: "Caddy"))])
        await rig.hub.setRows([hubEntry("h1", word: "Proxmox", updatedAt: t0.addingTimeInterval(990), deletedAt: t0.addingTimeInterval(990))])

        try await rig.sync.pull()
        #expect(rig.store.words == ["Caddy"])
        #expect(rig.store.entries.count == 1)

        let saves = rig.persistence.saves
        rig.clock.set(t0.addingTimeInterval(1010))
        try await rig.sync.pull()
        #expect(await rig.hub.listCalls.last?.since == t0.addingTimeInterval(940))
        #expect(rig.store.words == ["Caddy"])
        #expect(rig.persistence.saves == saves)
    }

    @Test("a tombstone never removes another row that spells the same word")
    func tombstoneLeavesOtherRows() async throws {
        // This phone holds the word under h2 (the Mac deleted h1 and made it again).
        let rig = Rig(entries: [Rig.synced(hubEntry("h2", word: "Proxmox", updatedAt: t0.addingTimeInterval(3)))])
        await rig.hub.setRows([
            hubEntry("h1", word: "Proxmox", updatedAt: t0.addingTimeInterval(9), deletedAt: t0.addingTimeInterval(9)),
            hubEntry("h2", word: "Proxmox", updatedAt: t0.addingTimeInterval(3)),
        ])

        try await rig.sync.pull()

        #expect(rig.store.words == ["Proxmox"])
        #expect(rig.store.entries.map(\.cloudId) == ["h2"])
    }

    @Test("a word owned by one hub row is never moved to another hub row by its spelling")
    func noNaturalKeyRehoming() async throws {
        let rig = Rig(entries: [Rig.synced(hubEntry("h1", word: "Proxmox"))])
        await rig.hub.setRows([hubEntry("h9", word: "proxmox", updatedAt: t0.addingTimeInterval(20))])

        try await rig.sync.pull()

        // h1 keeps its word; h9 is tracked as its own row, shown once.
        #expect(rig.store.entries.map(\.cloudId) == ["h1", "h9"])
        #expect(rig.store.words == ["Proxmox"])

        // Removing the word removes both rows, and both deletes reach the hub.
        rig.store.remove("Proxmox")
        #expect(rig.store.words.isEmpty)
        #expect(Set(rig.store.pendingDeletes().compactMap(\.cloudId)) == ["h1", "h9"])
    }

    @Test("the Mac re-adding a word before deleting the old row leaves the word on the phone")
    func macRecaseBetweenSyncs() async throws {
        // The Mac pushes creates before deletes: live h2 is stamped before tombstone h1.
        let rig = Rig(entries: [Rig.synced(hubEntry("h1", word: "proxmox"))])
        await rig.hub.setRows([
            hubEntry("h2", word: "Proxmox", updatedAt: t0.addingTimeInterval(10)),
            hubEntry("h1", word: "proxmox", updatedAt: t0.addingTimeInterval(11), deletedAt: t0.addingTimeInterval(11)),
        ])

        try await rig.sync.pull()

        #expect(rig.store.words == ["Proxmox"])
        #expect(rig.store.entries.map(\.cloudId) == ["h2"])
    }

    // MARK: Push

    @Test("a new word is created on the hub and settles; a re-pull of it is a no-op")
    func pushCreates() async throws {
        let rig = Rig()
        rig.store.add("Proxmox, Caddy")
        // The pass starts before the hub stamps the creates (t0 + 501 on), so
        // the next pass re-serves them.
        rig.clock.set(t0.addingTimeInterval(480))

        try await rig.sync.sync()

        let created = await rig.hub.creates
        #expect(created.count == 1)
        #expect(created[0].map(\.word) == ["Proxmox", "Caddy"])
        #expect(rig.store.pendingCreates().isEmpty)
        #expect(rig.store.entries.allSatisfy { $0.syncStatus == .synced && $0.cloudId != nil })

        let saves = rig.persistence.saves
        rig.clock.set(t0.addingTimeInterval(520))
        try await rig.sync.sync()
        #expect(await rig.hub.listCalls.last?.since == t0.addingTimeInterval(420))
        #expect(await rig.hub.creates.count == 1)
        #expect(rig.persistence.saves == saves)
    }

    @Test("a never-pushed word the Mac already has takes its hub id instead of doubling it")
    func firstSyncAdoptsHubWord() async throws {
        let rig = Rig()
        rig.store.add("Proxmox")
        await rig.hub.setRows([hubEntry("h1", word: "Proxmox")])

        try await rig.sync.sync()

        #expect(await rig.hub.creates.isEmpty)
        #expect(rig.store.entries.map(\.cloudId) == ["h1"])
        #expect(rig.store.entries.map(\.syncStatus) == [.synced])
    }

    @Test("a delete goes to the hub and then the local tombstone is dropped")
    func pushDeletes() async throws {
        let row = hubEntry("h1", word: "Proxmox")
        let rig = Rig(entries: [Rig.synced(row)])
        await rig.hub.setRows([row])
        rig.store.remove("Proxmox")
        #expect(rig.store.words.isEmpty)
        #expect(rig.store.pendingDeletes().map(\.cloudId) == ["h1"])

        try await rig.sync.push()

        #expect(await rig.hub.deletes == ["h1"])
        #expect(rig.store.entries.isEmpty)
        #expect(await rig.hub.rows.first?.deletedAt != nil)
    }

    @Test("a pending local delete is not undone by a newer hub copy")
    func pendingDeleteSurvivesPull() async throws {
        let rig = Rig(entries: [Rig.synced(hubEntry("h1", word: "Proxmox"))])
        rig.store.remove("Proxmox")
        await rig.hub.setRows([hubEntry("h1", word: "Proxmox!", updatedAt: t0.addingTimeInterval(10))])

        try await rig.sync.pull()

        #expect(rig.store.words.isEmpty)
        #expect(rig.store.pendingDeletes().map(\.cloudId) == ["h1"])
    }

    @Test("a word deleted while its create was in flight is deleted on the hub too")
    func deleteDuringCreate() async throws {
        let rig = Rig()
        rig.store.add("Proxmox")
        let store = rig.store
        await rig.hub.setDuringWrite { await MainActor.run { store.remove("Proxmox") } }

        try await rig.sync.push()

        #expect(await rig.hub.deletes.count == 1)
        #expect(await rig.hub.rows.allSatisfy { $0.deletedAt != nil })
        #expect(rig.store.entries.isEmpty)
    }

    @Test("an edit made while its update was in flight stays pending")
    func editDuringUpdate() async throws {
        let row = hubEntry("h1", word: "Proxmox")
        let rig = Rig(entries: [Rig.synced(row)])
        await rig.hub.setRows([row])
        try rig.store.edit("Proxmox", to: "Proxmox VE")
        let store = rig.store
        await rig.hub.setDuringWrite { await MainActor.run { try? store.edit("Proxmox VE", to: "PVE") } }

        try await rig.sync.push()

        #expect(rig.store.pendingUpdates().map(\.word) == ["PVE"])
    }

    // MARK: Wiring and storage

    @Test("the sync engine's pass runs the dictionary step")
    func engineRunsDictionary() async throws {
        let rig = Rig()
        rig.store.add("Proxmox")
        let engine = SyncEngine(
            hub: FakeSyncHub(), store: try NotesStore.inMemory(), cursors: rig.cursors, dictionary: rig.sync)

        try await engine.sync()

        #expect(await rig.hub.creates.count == 1)
        #expect(rig.store.pendingCreates().isEmpty)
    }

    @Test("a dictionary cursor stored before the lookback is rewound once")
    func legacyCursorRewound() throws {
        let defaults = try #require(UserDefaults(suiteName: "DictionarySync-\(UUID().uuidString)"))
        let s = t0.addingTimeInterval(1000)
        defaults.set(HubDate.string(from: s), forKey: "sync.cursor.\(DictionarySync.cursorKey)")

        #expect(UserDefaultsCursorStore(defaults: defaults).cursor(DictionarySync.cursorKey) == s.addingTimeInterval(-lookback))
        #expect(UserDefaultsCursorStore(defaults: defaults).cursor(DictionarySync.cursorKey) == s.addingTimeInterval(-lookback))
    }

    @Test("words kept before sync are read once as never-pushed entries")
    func legacyWordsBecomePendingCreates() throws {
        let suite = "DictionarySync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Proxmox", "Caddy"], forKey: UserDefaultsDictionaryPersistence.legacyKey)

        let store = DictionaryStore(persistence: UserDefaultsDictionaryPersistence(defaults: defaults))
        #expect(store.words == ["Proxmox", "Caddy"])
        #expect(store.pendingCreates().map(\.word) == ["Proxmox", "Caddy"])

        store.remove("Caddy")
        let reloaded = DictionaryStore(persistence: UserDefaultsDictionaryPersistence(defaults: defaults))
        #expect(reloaded.words == ["Proxmox"])
    }
}
