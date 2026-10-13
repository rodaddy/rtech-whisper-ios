import Foundation
import Synchronization
import Testing

@testable import RtechWhisperKit

// Snippets (issue #410): a spoken trigger expands to saved text by the
// desktop's rules, and the list syncs through the hub (protocol sections 6
// and 8) with the dictionary's merge rules.

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let lookback: TimeInterval = 60

private func expand(_ text: String, _ snippets: [(String, String)]) -> String {
    SnippetExpander(snippets.map { (trigger: $0.0, replacement: $0.1) }).expand(text)
}

// MARK: Expansion

@Suite("Snippet expansion")
struct SnippetExpansionTests {
    @Test("a trigger expands only as a whole word")
    func wordBoundary() {
        let snippets = [("sig", "Best, Rico")]
        #expect(expand("sig", snippets) == "Best, Rico")
        #expect(expand("Thanks. sig", snippets) == "Thanks. Best, Rico")
        #expect(expand("(sig) please", snippets) == "(Best, Rico) please")
        #expect(expand("sig, then more", snippets) == "Best, Rico, then more")
        #expect(expand("my signature and design", snippets) == "my signature and design")
        #expect(expand("resig", snippets) == "resig")
    }

    @Test("a trigger matches whatever its case in the text")
    func anyCase() {
        let snippets = [("Signoff", "Regards")]
        #expect(expand("SIGNOFF now", snippets) == "Regards now")
        #expect(expand("signoff now", snippets) == "Regards now")
        #expect(expand("SignOff now", snippets) == "Regards now")
    }

    @Test("several triggers expand in one pass, longest first, never twice")
    func severalTriggers() {
        let snippets = [
            ("ask", "a question"),
            // A prefix of "investor ask": only longest-first lets the longer one win.
            ("investor", "VC"),
            ("investor ask", "the Series A ask"),
            ("my cal", "cal.com/rico"),
            ("zoom link", "zoom.us/j/123 my cal"),
        ]
        #expect(expand("my cal and zoom link", snippets) == "cal.com/rico and zoom.us/j/123 my cal")
        #expect(expand("the investor ask, then ask", snippets) == "the the Series A ask, then a question")
        #expect(expand("my cal. My Cal!", snippets) == "cal.com/rico. cal.com/rico!")
        #expect(expand("an investor, an investor ask", snippets) == "an VC, an the Series A ask")
    }

    @Test("no snippets, or no trigger in the text, leaves the text as it is")
    func nothingToExpand() {
        #expect(expand("hello there", []) == "hello there")
        #expect(expand("hello there", [("   ", "x")]) == "hello there")
        #expect(expand("hello there", [("sig", "x")]) == "hello there")
    }

    @Test("dictation expands triggers in the cleaned text and keeps Whisper's words as raw")
    func postProcessorExpands() async {
        let processor = DictationPostProcessor(
            clean: { $0.replacingOccurrences(of: "um ", with: "") },
            expand: { expand($0, [("sig", "Best, Rico")]) })

        let processed = await processor.process("thanks um sig")

        #expect(processed.text == "thanks Best, Rico")
        #expect(processed.rawText == "thanks um sig")
    }
}

// MARK: Store

@MainActor
@Suite("Snippet store")
struct SnippetStoreTests {
    @Test("add trims, refuses blanks, long triggers, and case-insensitive duplicates")
    func addValidates() throws {
        let persistence = InMemorySnippetPersistence()
        let store = SnippetStore(persistence: persistence)
        try store.add(trigger: "  sig ", replacement: " Best, Rico\n")
        #expect(store.snippets.map(\.trigger) == ["sig"])
        #expect(store.snippets.map(\.replacement) == ["Best, Rico"])
        #expect(persistence.load().map(\.trigger) == ["sig"])

        #expect(throws: SnippetError.emptyTrigger) { try store.add(trigger: " ", replacement: "x") }
        #expect(throws: SnippetError.emptyReplacement) { try store.add(trigger: "x", replacement: " ") }
        #expect(throws: SnippetError.triggerTooLong) {
            try store.add(trigger: String(repeating: "a", count: SnippetStore.triggerLimit + 1), replacement: "x")
        }
        #expect(throws: SnippetError.duplicate("SIG")) { try store.add(trigger: "SIG", replacement: "x") }
        #expect(store.snippets.count == 1)
    }

    @Test("edit changes one snippet, and store.expand uses the live snippets")
    func editAndExpand() throws {
        let store = SnippetStore(persistence: InMemorySnippetPersistence())
        try store.add(trigger: "sig", replacement: "Best, Rico")
        try store.add(trigger: "addr", replacement: "1 Main St")
        let sig = try #require(store.snippets.first)
        #expect(throws: SnippetError.duplicate("addr")) { try store.edit(sig.clientId, trigger: "addr", replacement: "x") }
        try store.edit(sig.clientId, trigger: "signoff", replacement: "Cheers")

        #expect(store.expand("sig signoff addr") == "sig Cheers 1 Main St")
        #expect(store.triggers == ["signoff", "addr"])

        store.remove(atOffsets: IndexSet([1]))
        #expect(store.expand("signoff addr") == "Cheers addr")
    }

    @Test("the UserDefaults store round-trips every field")
    func userDefaultsRoundTrips() throws {
        let suite = "SnippetStore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsSnippetPersistence(defaults: defaults)
        #expect(persistence.load() == [])
        let entry = SnippetEntry(
            cloudId: "h1", trigger: "sig", replacement: "Best,\nRico", syncStatus: .error,
            cloudUpdatedAt: t0.addingTimeInterval(0.123), createdAt: t0, updatedAt: t0.addingTimeInterval(0.123))
        persistence.save([entry])
        #expect(persistence.load() == [entry])
    }
}

// MARK: Sync

private func hubSnippet(
    _ id: String, trigger: String, replacement: String = "text", createdAt: Date = t0,
    updatedAt: Date = t0, deletedAt: Date? = nil
) -> HubSnippetEntry {
    HubSnippetEntry(
        id: id, clientSnippetId: "c-\(id)", trigger: trigger, replacement: replacement, deletedAt: deletedAt,
        createdAt: createdAt, updatedAt: updatedAt)
}

/// A hub that serves snippets the way the protocol does: a snapshot of live
/// rows by (`created_at`, `id`) descending, or a delta by (`updated_at`,
/// `id`) ascending with tombstones; a batch create that fails whole on a
/// trigger clash; and a `409` on a rename onto a live trigger.
actor FakeSnippetHub: SnippetHubSyncing {
    enum Call: Equatable {
        case snapshot(cursor: Date?, cursorId: String?)
        case delta(since: Date, sinceId: String?)
    }

    var rows: [HubSnippetEntry] = []
    var calls: [Call] = []
    var createBatches: [[String]] = []
    var updates: [String] = []
    var deletes: [String] = []
    private var clock = t0.addingTimeInterval(500)

    func setRows(_ value: [HubSnippetEntry]) { rows = value }

    private func stamp() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    private func triggerInUse(_ trigger: String, except id: String? = nil) -> Bool {
        rows.contains { $0.trigger == trigger && $0.deletedAt == nil && $0.id != id }
    }

    func listSnippets(cursor: Date?, cursorId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage {
        calls.append(.snapshot(cursor: cursor, cursorId: cursorId))
        let limit = limit ?? 200
        let matching = rows
            .filter { $0.deletedAt == nil }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .filter { row in
                guard let cursor else { return true }
                guard let cursorId else { return row.createdAt < cursor }
                return (row.createdAt, row.id) < (cursor, cursorId)
            }
        return HubSnippetPage(entries: Array(matching.prefix(limit)), hasMore: matching.count > limit)
    }

    func listSnippetChanges(since: Date, sinceId: String?, limit: Int?) async throws(HubError) -> HubSnippetPage {
        calls.append(.delta(since: since, sinceId: sinceId))
        let limit = limit ?? 200
        let matching = rows
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
            .filter { row in
                guard let sinceId else { return row.updatedAt > since }
                return (row.updatedAt, row.id) > (since, sinceId)
            }
        return HubSnippetPage(entries: Array(matching.prefix(limit)), hasMore: matching.count > limit)
    }

    func batchCreateSnippets(_ entries: [SnippetCreateInput]) async throws(HubError) -> [HubSnippetEntry] {
        createBatches.append(entries.map(\.trigger))
        var made: [HubSnippetEntry] = []
        for input in entries {
            if let existing = rows.first(where: { $0.clientSnippetId == input.clientSnippetId }) {
                made.append(existing)
                continue
            }
            // All-or-nothing: one clash rolls the whole batch back.
            if triggerInUse(input.trigger) || made.contains(where: { $0.trigger == input.trigger }) {
                throw .snippetTriggerTaken
            }
            let now = stamp()
            made.append(HubSnippetEntry(
                id: "h-\(input.clientSnippetId)", clientSnippetId: input.clientSnippetId, trigger: input.trigger,
                replacement: input.replacement, deletedAt: nil, createdAt: input.createdAt, updatedAt: now))
        }
        rows += made.filter { row in !rows.contains { $0.id == row.id } }
        return made
    }

    func updateSnippet(id: String, trigger: String?, replacement: String?) async throws(HubError) -> HubSnippetEntry {
        updates.append(id)
        guard let index = rows.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw .notFound }
        if let trigger, triggerInUse(trigger, except: id) { throw .snippetTriggerTaken }
        rows[index].trigger = trigger ?? rows[index].trigger
        rows[index].replacement = replacement ?? rows[index].replacement
        rows[index].updatedAt = stamp()
        return rows[index]
    }

    func deleteSnippet(id: String) async throws(HubError) {
        deletes.append(id)
        guard let index = rows.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw .notFound }
        let now = stamp()
        rows[index].deletedAt = now
        rows[index].updatedAt = now
    }
}

private final class CountingSnippetPersistence: SnippetPersistence, @unchecked Sendable {
    private let inner: InMemorySnippetPersistence
    private let count = Mutex(0)
    var saves: Int { count.withLock { $0 } }

    init(entries: [SnippetEntry] = []) {
        inner = InMemorySnippetPersistence(entries: entries)
    }

    func load() -> [SnippetEntry] { inner.load() }
    func save(_ entries: [SnippetEntry]) {
        count.withLock { $0 += 1 }
        inner.save(entries)
    }
}

private final class SnippetClock: Sendable {
    private let value = Mutex(t0.addingTimeInterval(1000))
    func set(_ date: Date) { value.withLock { $0 = date } }
    func now() -> Date { value.withLock { $0 } }
}

@MainActor
private struct Rig {
    let hub = FakeSnippetHub()
    let persistence: CountingSnippetPersistence
    let store: SnippetStore
    let cursors = InMemoryCursorStore()
    let clock = SnippetClock()
    let sync: SnippetSync

    init(entries: [SnippetEntry] = []) {
        persistence = CountingSnippetPersistence(entries: entries)
        let clock = clock
        store = SnippetStore(persistence: persistence, now: { clock.now() })
        sync = SnippetSync(hub: hub, store: store, cursors: cursors, now: { clock.now() })
    }

    static func synced(_ row: HubSnippetEntry) -> SnippetEntry {
        SnippetEntry(
            clientId: row.clientSnippetId!, cloudId: row.id, trigger: row.trigger, replacement: row.replacement,
            syncStatus: .synced, cloudUpdatedAt: row.updatedAt, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }
}

@MainActor
@Suite("Snippet sync")
struct SnippetSyncTests {
    @Test("the first pull reads the snapshot; later pulls read the delta from the pass start minus L, no id")
    func snapshotThenDelta() async throws {
        let rig = Rig()
        await rig.hub.setRows([
            hubSnippet("h1", trigger: "sig", replacement: "Best, Rico"),
            hubSnippet("h2", trigger: "addr", replacement: "1 Main St", createdAt: t0.addingTimeInterval(1)),
        ])
        let pass = t0.addingTimeInterval(1000)
        rig.clock.set(pass)

        try await rig.sync.pull()

        #expect(Set(rig.store.triggers) == ["sig", "addr"])
        #expect(await rig.hub.calls == [.snapshot(cursor: nil, cursorId: nil)])
        #expect(rig.cursors.cursor(SnippetSync.cursorKey) == pass.addingTimeInterval(-lookback))

        rig.clock.set(pass.addingTimeInterval(30))
        try await rig.sync.pull()
        #expect(await rig.hub.calls.last == .delta(since: pass.addingTimeInterval(-lookback), sinceId: nil))
    }

    @Test("a new snippet is created on the hub and settles; the re-served copy is a no-op")
    func pushCreates() async throws {
        let rig = Rig()
        try rig.store.add(trigger: "sig", replacement: "Best, Rico")
        rig.clock.set(t0.addingTimeInterval(480))

        try await rig.sync.sync()
        #expect(await rig.hub.createBatches == [["sig"]])
        #expect(rig.store.entries.map(\.syncStatus) == [.synced])

        let saves = rig.persistence.saves
        rig.clock.set(t0.addingTimeInterval(520))
        try await rig.sync.sync()
        #expect(await rig.hub.calls.last == .delta(since: t0.addingTimeInterval(420), sinceId: nil))
        #expect(await rig.hub.createBatches.count == 1)
        #expect(rig.persistence.saves == saves)
    }

    @Test("a pending local edit survives a newer hub copy, then wins on push")
    func pendingEditSurvives() async throws {
        let row = hubSnippet("h1", trigger: "sig", replacement: "Best, Rico")
        let rig = Rig(entries: [Rig.synced(row)])
        rig.cursors.setCursor(t0.addingTimeInterval(-60), for: SnippetSync.cursorKey)
        try rig.store.edit("c-h1", trigger: "sig", replacement: "Cheers, Rico")
        await rig.hub.setRows([hubSnippet("h1", trigger: "sig", replacement: "Thanks, R", updatedAt: t0.addingTimeInterval(10))])

        try await rig.sync.pull()
        #expect(rig.store.snippets.map(\.replacement) == ["Cheers, Rico"])
        #expect(rig.store.pendingUpdates().count == 1)

        try await rig.sync.push()
        #expect(await rig.hub.rows.first?.replacement == "Cheers, Rico")
        #expect(rig.store.pendingUpdates().isEmpty)
    }

    @Test("a re-served row with the stamp already applied writes nothing, even over a local edit")
    func reServeIsANoOp() async throws {
        let row = hubSnippet("h1", trigger: "sig", replacement: "Best, Rico", updatedAt: t0.addingTimeInterval(990))
        let rig = Rig(entries: [Rig.synced(row)])
        try rig.store.edit("c-h1", trigger: "sig", replacement: "Cheers")
        let edited = rig.store.entries
        let saves = rig.persistence.saves

        #expect(rig.store.applyFromHub(row) == .unchanged)
        #expect(rig.store.entries == edited)
        #expect(rig.persistence.saves == saves)
    }

    @Test("a tombstone removes its own row and never another row with the same trigger")
    func tombstoneOwnRowOnly() async throws {
        let rig = Rig(entries: [
            Rig.synced(hubSnippet("h1", trigger: "sig")),
            Rig.synced(hubSnippet("h3", trigger: "addr", updatedAt: t0.addingTimeInterval(3))),
        ])
        rig.cursors.setCursor(t0.addingTimeInterval(-60), for: SnippetSync.cursorKey)
        await rig.hub.setRows([
            hubSnippet("h1", trigger: "sig", updatedAt: t0.addingTimeInterval(9), deletedAt: t0.addingTimeInterval(9)),
            // The Mac deleted an old "addr" row (h2); this phone holds h3.
            hubSnippet("h2", trigger: "addr", updatedAt: t0.addingTimeInterval(9), deletedAt: t0.addingTimeInterval(9)),
        ])

        try await rig.sync.pull()

        #expect(rig.store.snippets.map(\.cloudId) == ["h3"])
    }

    @Test("a trigger clash fails the batch; the rest are created and the clash waits for an edit")
    func triggerClash() async throws {
        let rig = Rig()
        try rig.store.add(trigger: "sig", replacement: "Best, Rico")
        try rig.store.add(trigger: "addr", replacement: "1 Main St")
        // Another device made "sig" on the hub after this phone pulled.
        await rig.hub.setRows([hubSnippet("h9", trigger: "sig", createdAt: t0.addingTimeInterval(2000), updatedAt: t0.addingTimeInterval(2000))])

        try await rig.sync.push()

        #expect(await rig.hub.createBatches == [["sig", "addr"], ["sig"], ["addr"]])
        #expect(rig.store.entries.map(\.syncStatus) == [.error, .synced])
        #expect(await rig.sync.errors == [rig.store.entries[0].clientId: .snippetTriggerTaken])

        // Not sent again until edited.
        try await rig.sync.push()
        #expect(await rig.hub.createBatches.count == 3)
    }

    @Test("a trigger this phone deleted or renamed away is freed on the hub before a write reuses it")
    func ownTriggerReuse() async throws {
        // (1) Delete synced "sig", then add a new "sig".
        let sig = hubSnippet("h1", trigger: "sig", replacement: "Best, Rico")
        // (2) Rename "brb" to "brb2", then add a new "brb".
        let brb = hubSnippet("h2", trigger: "brb")
        // (3) Delete "addr", then rename "home" onto "addr".
        let addr = hubSnippet("h3", trigger: "addr")
        let home = hubSnippet("h4", trigger: "home")
        let rig = Rig(entries: [sig, brb, addr, home].map(Rig.synced))
        await rig.hub.setRows([sig, brb, addr, home])

        rig.store.remove("c-h1")
        try rig.store.add(trigger: "sig", replacement: "Cheers, Rico")
        try rig.store.edit("c-h2", trigger: "brb2", replacement: "text")
        try rig.store.add(trigger: "brb", replacement: "be right back")
        rig.store.remove("c-h3")
        try rig.store.edit("c-h4", trigger: "addr", replacement: "text")

        try await rig.sync.push()

        #expect(await rig.sync.errors.isEmpty)
        #expect(rig.store.entries.allSatisfy { $0.syncStatus == .synced && $0.cloudId != nil })
        let live = await rig.hub.rows.filter { $0.deletedAt == nil }
        #expect(Set(live.map(\.trigger)) == ["sig", "brb2", "brb", "addr"])
        #expect(live.first { $0.trigger == "sig" }?.replacement == "Cheers, Rico")
    }

    @Test("the sync engine's pass runs the snippet step")
    func engineRunsSnippets() async throws {
        let rig = Rig()
        try rig.store.add(trigger: "sig", replacement: "Best, Rico")
        let engine = SyncEngine(hub: FakeSyncHub(), store: try NotesStore.inMemory(), cursors: rig.cursors, snippets: rig.sync)

        try await engine.sync()

        #expect(await rig.hub.createBatches == [["sig"]])
        #expect(rig.store.pendingCreates().isEmpty)
    }
}
