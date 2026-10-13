import Foundation
import Observation

/// One dictionary word on this phone, with the bookkeeping hub sync needs
/// (protocol sections 5 and 8). The desktop's `custom_dictionary` row.
public struct DictionaryEntry: Codable, Sendable, Equatable {
    /// Sent as `client_dict_id`, so a retried create is deduplicated by the hub.
    public var clientId: String
    /// The hub's id, `nil` until the first push succeeds.
    public var cloudId: String?
    public var word: String
    /// `manual` or `learned` (protocol section 5). Words typed here are manual.
    public var source: String
    public var syncStatus: SyncStatus
    /// Local tombstone: set on delete until the hub accepts the delete.
    public var deletedAt: Date?
    /// The hub's `updated_at` this device last applied or was answered with.
    /// A re-served row with this stamp is a no-op (protocol section 8).
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        clientId: String = UUID().uuidString, cloudId: String? = nil, word: String,
        source: String = DictionaryEntry.manual, syncStatus: SyncStatus = .pending,
        deletedAt: Date? = nil, cloudUpdatedAt: Date? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.clientId = clientId
        self.cloudId = cloudId
        self.word = word
        self.source = source
        self.syncStatus = syncStatus
        self.deletedAt = deletedAt
        self.cloudUpdatedAt = cloudUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let manual = "manual"
    public static let learned = "learned"

    var isLive: Bool { deletedAt == nil }

    /// The `batch-create` row for this entry.
    var createInput: DictionaryCreateInput {
        DictionaryCreateInput(clientDictId: clientId, word: word, source: source, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// True when `other` is this entry as it was pushed: nothing changed
    /// locally while the request was in flight.
    func isUnchanged(since other: DictionaryEntry) -> Bool {
        word == other.word && source == other.source && deletedAt == other.deletedAt && updatedAt == other.updatedAt
    }
}

/// Where the dictionary is kept between launches.
public protocol DictionaryPersistence: Sendable {
    func load() -> [DictionaryEntry]
    func save(_ entries: [DictionaryEntry])
}

/// Entries that live only as long as the process. For tests and previews.
public final class InMemoryDictionaryPersistence: DictionaryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    /// Words this phone has never pushed, as a dictionary from before sync holds them.
    public convenience init(words: [String]) {
        let now = Date()
        self.init(entries: words.map { DictionaryEntry(word: $0, createdAt: now, updatedAt: now) })
    }

    public func load() -> [DictionaryEntry] { lock.withLock { entries } }
    public func save(_ entries: [DictionaryEntry]) { lock.withLock { self.entries = entries } }
}

/// The real store: the entries as JSON in `UserDefaults`. A phone that kept
/// the dictionary before sync (a plain word list under `customDictionary`,
/// as the desktop's settings store did) has those words read once as
/// never-pushed entries, so the first sync sends them.
public final class UserDefaultsDictionaryPersistence: DictionaryPersistence, @unchecked Sendable {
    public static let defaultKey = "dictionaryEntries"
    public static let legacyKey = "customDictionary"

    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String

    public init(
        defaults: UserDefaults = .standard, key: String = UserDefaultsDictionaryPersistence.defaultKey,
        legacyKey: String = UserDefaultsDictionaryPersistence.legacyKey
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    public func load() -> [DictionaryEntry] {
        guard let data = defaults.data(forKey: key) else {
            let now = Date()
            return (defaults.stringArray(forKey: legacyKey) ?? []).map {
                DictionaryEntry(word: $0, createdAt: now, updatedAt: now)
            }
        }
        return (try? JSONDecoder().decode([DictionaryEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [DictionaryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum DictionaryError: Error, Equatable, Sendable {
    /// A blank word.
    case emptyWord
    /// Another entry already spells this word (case-insensitively).
    case duplicate(String)
}

public typealias DictionaryApplyResult = HubApplyResult<DictionaryEntry, HubDictionaryEntry>

/// The custom dictionary: words Whisper should know how to spell, synced
/// with the Mac through the hub (protocol section 5). The Dictionary screen
/// renders `words` and calls `add`, `edit`, and `remove`; transcription asks
/// for `promptHint`; `DictionarySync` reads the pending rows and reports back.
///
/// Membership is case-insensitive, as on the desktop's `DictionaryView`: a
/// word that differs only by case from a stored one is the same entry.
@MainActor
@Observable
public final class DictionaryStore {
    /// The hub caps `prompt` at 1000 characters (protocol section 10.1).
    public static let promptLimit = 1000

    /// Every row, local tombstones included, in the order words were added.
    public private(set) var entries: [DictionaryEntry]

    private let persistence: any DictionaryPersistence
    private let now: () -> Date

    public init(persistence: any DictionaryPersistence, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        entries = Self.normalized(persistence.load())
    }

    /// The live words, one per spelling (case-insensitively), in order.
    public var words: [String] {
        var seen = Set<String>()
        return entries.filter { $0.isLive && seen.insert($0.word.lowercased()).inserted }.map(\.word)
    }

    /// Splits pasted text into words: one per line or per comma, trimmed,
    /// blanks dropped, duplicates within the text collapsed.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Adds every new word in `text` (see `parse`). Returns how many were
    /// added; words already in the dictionary are skipped, as on the desktop.
    /// A word deleted here and added again is a new row: the old one's
    /// delete still goes to the hub.
    @discardableResult
    public func add(_ text: String) -> Int {
        let existing = Set(words.map { $0.lowercased() })
        let fresh = Self.parse(text).filter { !existing.contains($0.lowercased()) }
        guard !fresh.isEmpty else { return 0 }
        let stamp = now()
        entries.append(contentsOf: fresh.map { DictionaryEntry(word: $0, createdAt: stamp, updatedAt: stamp) })
        save()
        return fresh.count
    }

    /// Replaces `word` with `replacement`. Unknown `word` is a no-op; a blank
    /// or clashing replacement throws and changes nothing.
    public func edit(_ word: String, to replacement: String) throws(DictionaryError) {
        guard let index = liveIndex(of: word) else { return }
        let trimmed = replacement.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyWord }
        if trimmed == word { return }
        let clash = entries.indices.contains {
            $0 != index && entries[$0].isLive && entries[$0].word.lowercased() == trimmed.lowercased()
        }
        guard !clash else { throw .duplicate(trimmed) }
        entries[index].word = trimmed
        touch(index)
        save()
    }

    /// Removes `word` and every other live row that spells it: two hub rows
    /// can hold one word, and `words` shows it once.
    public func remove(_ word: String) {
        guard liveIndex(of: word) != nil else { return }
        deleteAll(spelling: word)
        save()
    }

    /// Removes the words at `offsets` of `words`; the shape `onDelete` hands a list.
    public func remove(atOffsets offsets: IndexSet) {
        let live = words
        let doomed = Set(offsets.compactMap { live.indices.contains($0) ? live[$0] : nil })
        guard !doomed.isEmpty else { return }
        for word in doomed {
            deleteAll(spelling: word)
        }
        save()
    }

    /// The words as the relay's `prompt` field, comma-separated as the
    /// desktop's `appendDictionarySuffix` sends them, cut at a whole word to
    /// fit `maxLength`. `nil` when the dictionary is empty.
    public func promptHint(maxLength: Int = DictionaryStore.promptLimit) -> String? {
        Self.promptHint(words, maxLength: maxLength)
    }

    /// `words` as the relay's `prompt`, by the rules of `promptHint(maxLength:)`.
    public static func promptHint(_ words: [String], maxLength: Int = DictionaryStore.promptLimit) -> String? {
        var hint = ""
        for word in words {
            let candidate = hint.isEmpty ? word : hint + ", " + word
            // The hub measures `prompt.length` in JavaScript: UTF-16 units.
            guard candidate.utf16.count <= maxLength else { break }
            hint = candidate
        }
        return hint.isEmpty ? nil : hint
    }

    // MARK: Sync

    /// Live words the hub has never acknowledged.
    public func pendingCreates() -> [DictionaryEntry] {
        entries.filter { $0.isLive && $0.cloudId == nil && $0.syncStatus == .pending }
    }

    /// Live words with a hub id and an edit the hub has not accepted.
    public func pendingUpdates() -> [DictionaryEntry] {
        entries.filter { $0.isLive && $0.cloudId != nil && $0.syncStatus == .pending }
    }

    /// Local tombstones waiting for their hub delete.
    public func pendingDeletes() -> [DictionaryEntry] {
        entries.filter { !$0.isLive && $0.cloudId != nil }
    }

    /// Records the hub's answer to a create. The row settles only if nothing
    /// changed while the request was in flight; otherwise it keeps its
    /// pending edit or delete, now against the hub id. A row deleted here in
    /// the meantime comes back as a tombstone for that id, so the hub copy is
    /// deleted rather than orphaned. A hub row that is already a tombstone
    /// (a retried create another device has since deleted) deletes this one.
    public func markCreated(_ pushed: DictionaryEntry, as row: HubDictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.clientId == pushed.clientId }) else {
            if row.deletedAt == nil {
                entries.append(DictionaryEntry(
                    clientId: pushed.clientId, cloudId: row.id, word: row.word, source: row.source,
                    deletedAt: now(), cloudUpdatedAt: row.updatedAt, createdAt: row.createdAt, updatedAt: now()))
                save()
            }
            return
        }
        if row.deletedAt != nil {
            entries.remove(at: index)
        } else {
            entries[index].cloudId = row.id
            entries[index].cloudUpdatedAt = row.updatedAt
            if entries[index].isUnchanged(since: pushed) { entries[index].syncStatus = .synced }
        }
        save()
    }

    /// Records the hub's answer to an update; an edit made meanwhile stays pending.
    public func markUpdated(_ pushed: DictionaryEntry, as row: HubDictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.clientId == pushed.clientId }) else { return }
        entries[index].cloudUpdatedAt = row.updatedAt
        if entries[index].isUnchanged(since: pushed) { entries[index].syncStatus = .synced }
        save()
    }

    /// Records an accepted hub delete: the local tombstone is dropped.
    public func markDeleted(clientId: String) {
        guard let index = entries.firstIndex(where: { $0.clientId == clientId }) else { return }
        entries.remove(at: index)
        save()
    }

    /// Merges one row from a hub pull, as the desktop does:
    /// - a re-served row whose stamp this device already applied is a no-op;
    /// - a local row with an unpushed edit or delete is never overwritten;
    /// - a tombstone removes only the row it owns (same hub id, or the
    ///   never-acknowledged create that made it), never another row that
    ///   happens to spell the word;
    /// - a row is never moved from one hub id to another by its word. A new
    ///   hub row whose word a never-pushed local word already spells is
    ///   adopted by that word instead of doubled on the hub.
    @discardableResult
    public func applyFromHub(_ row: HubDictionaryEntry) -> DictionaryApplyResult {
        let owner = entries.firstIndex { $0.cloudId == row.id }
            ?? entries.firstIndex { $0.cloudId == nil && row.clientDictId != nil && $0.clientId == row.clientDictId }

        if row.deletedAt != nil {
            guard let owner else { return .unchanged }
            entries.remove(at: owner)
            save()
            return .deleted
        }

        if let owner {
            let local = entries[owner]
            if local.cloudId != nil {
                if let seen = local.cloudUpdatedAt, row.updatedAt <= seen { return .unchanged }
                guard local.syncStatus != .pending else { return .unchanged }
                entries[owner].word = row.word
                entries[owner].source = Self.mergedSource(local.source, row.source)
                entries[owner].cloudUpdatedAt = row.updatedAt
                entries[owner].updatedAt = row.updatedAt
                entries[owner].syncStatus = .synced
                save()
                return .applied
            }
            link(owner, to: row)
            return .applied
        }

        let spelling = row.word.lowercased()
        if let match = entries.firstIndex(where: { $0.isLive && $0.cloudId == nil && $0.word.lowercased() == spelling }) {
            link(match, to: row)
            return .applied
        }

        // A live word owned by another hub row does not stop this one being
        // tracked: the Mac may have made this row before deleting that one
        // (it pushes creates before deletes), and `words` shows one spelling.
        entries.append(DictionaryEntry(
            clientId: row.clientDictId ?? UUID().uuidString, cloudId: row.id, word: row.word,
            source: row.source, syncStatus: .synced, cloudUpdatedAt: row.updatedAt,
            createdAt: row.createdAt, updatedAt: row.updatedAt))
        save()
        return .inserted
    }

    // MARK: Private

    /// Gives a never-pushed local row the hub id of `row`. It settles when
    /// it already matches the hub; otherwise its local spelling stays
    /// pending and is pushed as an update.
    private func link(_ index: Int, to row: HubDictionaryEntry) {
        entries[index].cloudId = row.id
        entries[index].cloudUpdatedAt = row.updatedAt
        let local = entries[index]
        if local.word == row.word && local.source == Self.mergedSource(local.source, row.source) {
            entries[index].syncStatus = .synced
        } else {
            entries[index].source = Self.mergedSource(local.source, row.source)
            entries[index].syncStatus = .pending
        }
        save()
    }

    /// Manual is sticky: a pull never demotes a manual word to learned.
    private static func mergedSource(_ local: String, _ hub: String) -> String {
        local == DictionaryEntry.manual || hub == DictionaryEntry.manual ? DictionaryEntry.manual : DictionaryEntry.learned
    }

    private func liveIndex(of word: String) -> Int? {
        entries.firstIndex { $0.isLive && $0.word == word }
    }

    private func touch(_ index: Int) {
        entries[index].updatedAt = now()
        entries[index].syncStatus = .pending
    }

    /// A word the hub has never seen is dropped at once (never-synced rows
    /// stay local); otherwise it becomes a tombstone until the hub accepts
    /// the delete.
    private func delete(at index: Int) {
        if entries[index].cloudId == nil {
            entries.remove(at: index)
        } else {
            entries[index].deletedAt = now()
            touch(index)
        }
    }

    private func deleteAll(spelling word: String) {
        let spelling = word.lowercased()
        while let index = entries.firstIndex(where: { $0.isLive && $0.word.lowercased() == spelling }) {
            delete(at: index)
        }
    }

    private func save() {
        persistence.save(entries)
    }

    /// Trims every word and drops blank ones. A never-pushed live word that
    /// an earlier live word already spells is dropped; a row with a hub id
    /// is kept, so its hub row is never lost track of.
    private static func normalized(_ stored: [DictionaryEntry]) -> [DictionaryEntry] {
        var seen = Set<String>()
        return stored.compactMap { entry in
            var entry = entry
            entry.word = entry.word.trimmingCharacters(in: .whitespaces)
            guard !entry.word.isEmpty else { return nil }
            if entry.isLive, !seen.insert(entry.word.lowercased()).inserted, entry.cloudId == nil { return nil }
            return entry
        }
    }
}
