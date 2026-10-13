import Foundation
import Observation

/// One snippet on this phone: a spoken `trigger` that dictation replaces with
/// `replacement`, with the bookkeeping hub sync needs (protocol sections 6
/// and 8). The desktop's `snippets` row.
public struct SnippetEntry: Codable, Sendable, Equatable, Identifiable {
    /// Sent as `client_snippet_id`, so a retried create is deduplicated by the hub.
    public var clientId: String
    /// The hub's id, `nil` until the first push succeeds.
    public var cloudId: String?
    public var trigger: String
    public var replacement: String
    /// `error` when the hub refused the trigger because another live snippet
    /// uses it; the row is not sent again until it is edited.
    public var syncStatus: SyncStatus
    /// Local tombstone: set on delete until the hub accepts the delete.
    public var deletedAt: Date?
    /// The hub's `updated_at` this device last applied or was answered with.
    /// A re-served row with this stamp is a no-op (protocol section 8).
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { clientId }

    public init(
        clientId: String = UUID().uuidString, cloudId: String? = nil, trigger: String, replacement: String,
        syncStatus: SyncStatus = .pending, deletedAt: Date? = nil, cloudUpdatedAt: Date? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.clientId = clientId
        self.cloudId = cloudId
        self.trigger = trigger
        self.replacement = replacement
        self.syncStatus = syncStatus
        self.deletedAt = deletedAt
        self.cloudUpdatedAt = cloudUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isLive: Bool { deletedAt == nil }

    /// The `batch-create` row for this snippet.
    var createInput: SnippetCreateInput {
        SnippetCreateInput(
            clientSnippetId: clientId, trigger: trigger, replacement: replacement, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// True when `other` is this snippet as it was pushed: nothing changed
    /// locally while the request was in flight.
    func isUnchanged(since other: SnippetEntry) -> Bool {
        trigger == other.trigger && replacement == other.replacement && deletedAt == other.deletedAt
            && updatedAt == other.updatedAt
    }
}

/// Where snippets are kept between launches.
public protocol SnippetPersistence: Sendable {
    func load() -> [SnippetEntry]
    func save(_ entries: [SnippetEntry])
}

/// Snippets that live only as long as the process. For tests and previews.
public final class InMemorySnippetPersistence: SnippetPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SnippetEntry]

    public init(entries: [SnippetEntry] = []) {
        self.entries = entries
    }

    public func load() -> [SnippetEntry] { lock.withLock { entries } }
    public func save(_ entries: [SnippetEntry]) { lock.withLock { self.entries = entries } }
}

/// The real store: the snippets as JSON in `UserDefaults`.
public final class UserDefaultsSnippetPersistence: SnippetPersistence, @unchecked Sendable {
    public static let defaultKey = "snippetEntries"

    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsSnippetPersistence.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [SnippetEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SnippetEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [SnippetEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum SnippetError: Error, Equatable, Sendable {
    case emptyTrigger
    case emptyReplacement
    /// Longer than the desktop's 100-character trigger limit.
    case triggerTooLong
    /// Another snippet already uses this trigger (case-insensitively).
    case duplicate(String)
}

public typealias SnippetApplyResult = HubApplyResult<SnippetEntry, HubSnippetEntry>

/// The phone's snippets, synced with the Mac through the hub (protocol
/// section 6). The Snippets screen renders `snippets` and calls `add`,
/// `edit`, and `remove`; dictation calls `expand`; `SnippetSync` reads the
/// pending rows and reports back. Triggers are unique case-insensitively, as
/// on the desktop.
@MainActor
@Observable
public final class SnippetStore {
    /// The desktop's `MAX_SNIPPET_TRIGGER_LENGTH`.
    public nonisolated static let triggerLimit = 100

    /// Every row, local tombstones included, in the order snippets were added.
    public private(set) var entries: [SnippetEntry]

    private let persistence: any SnippetPersistence
    private let now: () -> Date

    public init(persistence: any SnippetPersistence, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        entries = persistence.load()
    }

    /// The live snippets, in order.
    public var snippets: [SnippetEntry] {
        entries.filter(\.isLive)
    }

    /// The live triggers: spelling hints for Whisper and cleanup, so a
    /// trigger survives both, as the desktop's `getDictionaryHintWords` adds them.
    public var triggers: [String] {
        snippets.map(\.trigger)
    }

    /// `text` with every trigger replaced by its snippet (see `SnippetExpander`).
    public func expand(_ text: String) -> String {
        SnippetExpander(snippets.map { ($0.trigger, $0.replacement) }).expand(text)
    }

    /// Adds a snippet. Both fields are trimmed; a blank field, a trigger over
    /// the limit, or a trigger another snippet uses throws and adds nothing.
    public func add(trigger: String, replacement: String) throws(SnippetError) {
        let (trigger, replacement) = try validated(trigger, replacement, except: nil)
        let stamp = now()
        entries.append(SnippetEntry(trigger: trigger, replacement: replacement, createdAt: stamp, updatedAt: stamp))
        save()
    }

    /// Changes the snippet with `clientId`. Unknown ids are a no-op; the
    /// fields are checked as for `add`.
    public func edit(_ clientId: String, trigger: String, replacement: String) throws(SnippetError) {
        guard let index = liveIndex(clientId) else { return }
        let (trigger, replacement) = try validated(trigger, replacement, except: index)
        guard trigger != entries[index].trigger || replacement != entries[index].replacement else { return }
        entries[index].trigger = trigger
        entries[index].replacement = replacement
        touch(index)
        save()
    }

    public func remove(_ clientId: String) {
        guard let index = liveIndex(clientId) else { return }
        delete(at: index)
        save()
    }

    /// Removes the snippets at `offsets` of `snippets`; the shape `onDelete` hands a list.
    public func remove(atOffsets offsets: IndexSet) {
        let live = snippets
        let doomed = offsets.compactMap { live.indices.contains($0) ? live[$0].clientId : nil }
        guard !doomed.isEmpty else { return }
        for clientId in doomed {
            if let index = liveIndex(clientId) { delete(at: index) }
        }
        save()
    }

    // MARK: Sync

    /// Live snippets the hub has never acknowledged.
    public func pendingCreates() -> [SnippetEntry] {
        entries.filter { $0.isLive && $0.cloudId == nil && $0.syncStatus == .pending }
    }

    /// Live snippets with a hub id and an edit the hub has not accepted.
    public func pendingUpdates() -> [SnippetEntry] {
        entries.filter { $0.isLive && $0.cloudId != nil && $0.syncStatus == .pending }
    }

    /// Local tombstones waiting for their hub delete.
    public func pendingDeletes() -> [SnippetEntry] {
        entries.filter { !$0.isLive && $0.cloudId != nil }
    }

    /// Records the hub's answer to a create, as `DictionaryStore.markCreated`
    /// does: the row settles only if nothing changed while the request was in
    /// flight, a row deleted meanwhile becomes a tombstone for the new hub id,
    /// and a hub row that is already a tombstone deletes this one.
    public func markCreated(_ pushed: SnippetEntry, as row: HubSnippetEntry) {
        guard let index = entries.firstIndex(where: { $0.clientId == pushed.clientId }) else {
            if row.deletedAt == nil {
                entries.append(SnippetEntry(
                    clientId: pushed.clientId, cloudId: row.id, trigger: row.trigger, replacement: row.replacement,
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
    public func markUpdated(_ pushed: SnippetEntry, as row: HubSnippetEntry) {
        guard let index = entries.firstIndex(where: { $0.clientId == pushed.clientId }) else { return }
        entries[index].cloudUpdatedAt = row.updatedAt
        if entries[index].isUnchanged(since: pushed) { entries[index].syncStatus = .synced }
        save()
    }

    /// The hub refused the trigger (`409`): another live snippet uses it.
    /// The row is not sent again until it is edited, so a doomed write is
    /// not repeated every pass.
    public func markTriggerTaken(_ pushed: SnippetEntry) {
        guard let index = entries.firstIndex(where: { $0.clientId == pushed.clientId }),
              entries[index].isUnchanged(since: pushed) else { return }
        entries[index].syncStatus = .error
        save()
    }

    /// Records an accepted hub delete: the local tombstone is dropped.
    public func markDeleted(clientId: String) {
        guard let index = entries.firstIndex(where: { $0.clientId == clientId }) else { return }
        entries.remove(at: index)
        save()
    }

    /// Merges one row from a hub pull, by the dictionary's rules (see
    /// `DictionaryStore.applyFromHub`): a re-served row is a no-op, a pending
    /// local edit or delete is never overwritten, a tombstone removes only
    /// the row it owns, and a row is never moved to another hub id by its
    /// trigger. A never-pushed local snippet with the same trigger takes the
    /// hub id instead, keeping its own text as a pending update.
    @discardableResult
    public func applyFromHub(_ row: HubSnippetEntry) -> SnippetApplyResult {
        let owner = entries.firstIndex { $0.cloudId == row.id }
            ?? entries.firstIndex { $0.cloudId == nil && row.clientSnippetId != nil && $0.clientId == row.clientSnippetId }

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
                entries[owner].trigger = row.trigger
                entries[owner].replacement = row.replacement
                entries[owner].cloudUpdatedAt = row.updatedAt
                entries[owner].updatedAt = row.updatedAt
                entries[owner].syncStatus = .synced
                save()
                return .applied
            }
            link(owner, to: row)
            return .applied
        }

        let trigger = row.trigger.lowercased()
        if let match = entries.firstIndex(where: { $0.isLive && $0.trigger.lowercased() == trigger }) {
            // Owned by another hub row: the trigger is here already.
            guard entries[match].cloudId == nil else { return .unchanged }
            link(match, to: row)
            return .applied
        }

        entries.append(SnippetEntry(
            clientId: row.clientSnippetId ?? UUID().uuidString, cloudId: row.id, trigger: row.trigger,
            replacement: row.replacement, syncStatus: .synced, cloudUpdatedAt: row.updatedAt,
            createdAt: row.createdAt, updatedAt: row.updatedAt))
        save()
        return .inserted
    }

    // MARK: Private

    private func link(_ index: Int, to row: HubSnippetEntry) {
        entries[index].cloudId = row.id
        entries[index].cloudUpdatedAt = row.updatedAt
        let local = entries[index]
        entries[index].syncStatus = local.trigger == row.trigger && local.replacement == row.replacement ? .synced : .pending
        save()
    }

    private func validated(_ trigger: String, _ replacement: String, except: Int?) throws(SnippetError) -> (String, String) {
        let trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { throw .emptyTrigger }
        guard !replacement.isEmpty else { throw .emptyReplacement }
        guard trigger.count <= Self.triggerLimit else { throw .triggerTooLong }
        let clash = entries.indices.contains {
            $0 != except && entries[$0].isLive && entries[$0].trigger.lowercased() == trigger.lowercased()
        }
        guard !clash else { throw .duplicate(trigger) }
        return (trigger, replacement)
    }

    private func liveIndex(_ clientId: String) -> Int? {
        entries.firstIndex { $0.isLive && $0.clientId == clientId }
    }

    private func touch(_ index: Int) {
        entries[index].updatedAt = now()
        entries[index].syncStatus = .pending
    }

    /// A snippet the hub has never seen is dropped at once; otherwise it
    /// becomes a tombstone until the hub accepts the delete.
    private func delete(at index: Int) {
        if entries[index].cloudId == nil {
            entries.remove(at: index)
        } else {
            entries[index].deletedAt = now()
            touch(index)
        }
    }

    private func save() {
        persistence.save(entries)
    }
}
