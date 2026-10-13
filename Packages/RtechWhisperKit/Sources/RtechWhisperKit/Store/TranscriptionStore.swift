import Foundation
import SwiftData

/// One dictation on this phone, the desktop's `transcriptions` row. Rows are
/// append-only (protocol section 7): after the first push the only change a
/// row can take is a delete.
@Model
public final class LocalTranscription {
    /// Sent as `client_transcription_id`, so a retried create is deduplicated
    /// by the hub.
    @Attribute(.unique) public var clientId: String
    /// The hub's id, `nil` until the first push succeeds.
    public var cloudId: String?
    public var text: String
    public var rawText: String?
    public var provider: String?
    public var model: String?
    public var audioDurationMs: Int?
    public var status: String
    /// `SyncStatus` raw value, stored as a string so predicates can use it.
    public var syncStatusRaw: String
    /// Local tombstone left by older builds, which sent deletes to
    /// the hub. Nothing sets it now; retention hard-deletes such rows.
    public var deletedAt: Date?
    /// The hub's `updated_at` this device last saw.
    public var cloudUpdatedAt: Date?
    public var createdAt: Date
    /// Added under a caller's `clientId` (an upload's checkpoint id), which a
    /// finish replayed after a kill sends again. Only such a row leaves a
    /// `RemovedTranscriptionId` when it is removed.
    public var replayable: Bool = false

    public var syncStatus: SyncStatus {
        get { SyncStatus(rawValue: syncStatusRaw) ?? .pending }
        set { syncStatusRaw = newValue.rawValue }
    }

    public init(
        clientId: String, cloudId: String? = nil, text: String, rawText: String? = nil,
        provider: String? = nil, model: String? = nil, audioDurationMs: Int? = nil,
        status: String, syncStatus: SyncStatus, deletedAt: Date? = nil,
        cloudUpdatedAt: Date? = nil, createdAt: Date, replayable: Bool = false
    ) {
        self.clientId = clientId
        self.replayable = replayable
        self.cloudId = cloudId
        self.text = text
        self.rawText = rawText
        self.provider = provider
        self.model = model
        self.audioDurationMs = audioDurationMs
        self.status = status
        self.syncStatusRaw = syncStatus.rawValue
        self.deletedAt = deletedAt
        self.cloudUpdatedAt = cloudUpdatedAt
        self.createdAt = createdAt
    }
}

/// The `clientId` of a replayable transcription (an upload's) this phone
/// removed for good: a user delete or a retention trim. Dictations leave none. It outlives the row, so a finish replayed after the row is gone (an upload
/// kept across a kill) cannot bring the deleted transcription back.
@Model
public final class RemovedTranscriptionId {
    @Attribute(.unique) public var clientId: String

    public init(clientId: String) { self.clientId = clientId }
}

/// A `Sendable` copy of a `LocalTranscription`.
public struct TranscriptionRecord: Sendable, Equatable {
    public var clientId: String
    public var cloudId: String?
    public var text: String
    public var rawText: String?
    public var provider: String?
    public var model: String?
    public var audioDurationMs: Int?
    public var status: String
    public var syncStatus: SyncStatus
    public var deletedAt: Date?
    public var cloudUpdatedAt: Date?
    public var createdAt: Date

    init(_ row: LocalTranscription) {
        clientId = row.clientId
        cloudId = row.cloudId
        text = row.text
        rawText = row.rawText
        provider = row.provider
        model = row.model
        audioDurationMs = row.audioDurationMs
        status = row.status
        syncStatus = row.syncStatus
        deletedAt = row.deletedAt
        cloudUpdatedAt = row.cloudUpdatedAt
        createdAt = row.createdAt
    }

    /// The `batch-create` row for this transcription.
    public var createInput: TranscriptionCreateInput {
        TranscriptionCreateInput(
            clientTranscriptionId: clientId, text: text, rawText: rawText, provider: provider,
            model: model, audioDurationMs: audioDurationMs, status: status, createdAt: createdAt)
    }
}

/// The phone's dictation history, with the sync bookkeeping the push needs
/// (protocol section 7). It holds no network code: `TranscriptionSync` reads
/// `pending`, pushes, and reports back through `markSynced`. Deletes and
/// retention are local only.
@ModelActor
public actor TranscriptionStore {
    public static let schema = Schema([LocalTranscription.self, RemovedTranscriptionId.self])

    /// A store backed by its own on-disk file, separate from the notes store.
    public static func persistent() throws -> TranscriptionStore {
        let config = ModelConfiguration("transcriptions", schema: schema)
        return TranscriptionStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// A store that lives only in memory, for tests and previews.
    public static func inMemory() throws -> TranscriptionStore {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return TranscriptionStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// Records a finished dictation, pending its first push. A `clientId`
    /// this store has seen adds nothing, so a caller that replays the same
    /// item after a kill never adds it twice or brings back its delete: a row
    /// still held (live, synced, or a pending tombstone) is returned as it
    /// is, and one removed for good (`RemovedTranscriptionId`) is returned as
    /// a tombstone that is not stored, so it shows in no list and syncs nothing.
    @discardableResult
    public func add(
        text: String, rawText: String? = nil, provider: String? = nil, model: String? = nil,
        durationMs: Int? = nil, status: String = "completed", createdAt: Date = Date(), clientId: String? = nil
    ) throws -> TranscriptionRecord {
        if let clientId {
            if let existing = try self.row(clientId) { return TranscriptionRecord(existing) }
            if try wasRemoved(clientId) {
                return TranscriptionRecord(LocalTranscription(
                    clientId: clientId, text: text, rawText: rawText, provider: provider, model: model,
                    audioDurationMs: durationMs, status: status, syncStatus: .synced, deletedAt: Date(),
                    createdAt: createdAt))
            }
        }
        let row = LocalTranscription(
            clientId: clientId ?? UUID().uuidString, text: text, rawText: rawText, provider: provider,
            model: model, audioDurationMs: durationMs, status: status, syncStatus: .pending,
            createdAt: createdAt, replayable: clientId != nil)
        modelContext.insert(row)
        try modelContext.save()
        return TranscriptionRecord(row)
    }

    /// Live transcriptions, newest first. `limit` caps the count.
    public func list(limit: Int? = nil) throws -> [TranscriptionRecord] {
        var descriptor = FetchDescriptor<LocalTranscription>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(TranscriptionRecord.init)
    }

    /// Removes a transcription from this phone for good. Nothing is sent to
    /// the hub; a row still pending its first push is never pushed. Unknown
    /// ids are a no-op.
    public func delete(clientId: String) throws {
        guard let row = try row(clientId) else { return }
        remove(row)
        try modelContext.save()
    }

    /// Trims the history to `retention`, on this phone only. Rows pending
    /// their first push are always kept and do not count toward a limit;
    /// tombstones left by older builds are removed. Returns how many rows went.
    @discardableResult
    public func applyRetention(_ retention: HistoryRetention, now: Date = Date()) throws -> Int {
        let pending = SyncStatus.pending.rawValue
        var doomed = try modelContext.fetch(FetchDescriptor<LocalTranscription>(
            predicate: #Predicate { $0.deletedAt != nil }))
        let pushed = try modelContext.fetch(FetchDescriptor<LocalTranscription>(
            predicate: #Predicate { $0.deletedAt == nil && $0.syncStatusRaw != pending },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        if let count = retention.keepCount {
            doomed += pushed.dropFirst(count)
        } else if let cutoff = retention.cutoff(now: now) {
            doomed += pushed.filter { $0.createdAt < cutoff }
        }
        for row in doomed {
            remove(row)
        }
        try modelContext.save()
        return doomed.count
    }

    /// Live rows the hub has not received yet, oldest first.
    public func pending() throws -> [TranscriptionRecord] {
        let pending = SyncStatus.pending.rawValue
        return try modelContext.fetch(FetchDescriptor<LocalTranscription>(
            predicate: #Predicate { $0.syncStatusRaw == pending && $0.deletedAt == nil && $0.cloudId == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )).map(TranscriptionRecord.init)
    }

    /// Records a successful create. Returns `false` when the row was deleted
    /// locally while the push was in flight; the hub copy stays.
    @discardableResult
    public func markSynced(clientId: String, cloudId: String, cloudUpdatedAt: Date) throws -> Bool {
        guard let row = try row(clientId) else { return false }
        row.cloudId = cloudId
        row.cloudUpdatedAt = cloudUpdatedAt
        if row.deletedAt == nil { row.syncStatus = .synced }
        try modelContext.save()
        return true
    }

    // MARK: Lookup

    /// Deletes `row` for good. A replayable row keeps its `clientId`, so `add`
    /// never brings it back; a dictation's is never added again, so it keeps
    /// none and the markers do not grow with every delete. The caller saves.
    private func remove(_ row: LocalTranscription) {
        let clientId = row.clientId
        let replayable = row.replayable
        modelContext.delete(row)
        guard replayable else { return }
        // Unique, so removing the same clientId twice keeps one marker.
        modelContext.insert(RemovedTranscriptionId(clientId: clientId))
    }

    private func wasRemoved(_ clientId: String) throws -> Bool {
        try modelContext.fetchCount(FetchDescriptor<RemovedTranscriptionId>(
            predicate: #Predicate { $0.clientId == clientId })) > 0
    }

    private func row(_ clientId: String) throws -> LocalTranscription? {
        try modelContext.fetch(FetchDescriptor<LocalTranscription>(
            predicate: #Predicate { $0.clientId == clientId })).first
    }
}
