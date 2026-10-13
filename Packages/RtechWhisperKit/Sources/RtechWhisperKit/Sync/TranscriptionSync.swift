import Foundation

/// The hub call transcription sync makes (protocol section 7).
/// `HubSyncClient` and `KeyedHubSync` are the real ones; tests use a stub.
public protocol TranscriptionHubSyncing: Sendable {
    func batchCreateTranscriptions(_ rows: [TranscriptionCreateInput]) async throws(HubError) -> [HubTranscription]
}

extension HubSyncClient: TranscriptionHubSyncing {}

extension KeyedHubSync: TranscriptionHubSyncing {
    public func batchCreateTranscriptions(_ rows: [TranscriptionCreateInput]) async throws(HubError) -> [HubTranscription] {
        try await client().batchCreateTranscriptions(rows)
    }
}

/// Push-only sync of the dictation history (ios#468): the phone sends its own
/// dictations through `batch-create` and pulls nothing. Its history is short
/// and local; deletes and retention never reach the hub, which keeps every
/// dictation for the Mac.
public actor TranscriptionSync {
    /// The retired pull's cursor. Kept only so the stored cursor migration
    /// (`UserDefaultsCursorStore`) still knows the key.
    public static let cursorKey = "transcriptions"
    /// The contract's page size for batch calls.
    public static let pageSize = 100

    private let hub: any TranscriptionHubSyncing
    private let store: TranscriptionStore

    public init(hub: any TranscriptionHubSyncing, store: TranscriptionStore) {
        self.hub = hub
        self.store = store
    }

    /// One pass: push.
    public func sync() async throws {
        try await push()
    }

    /// Creates in batches of `pageSize`. A create is idempotent on the hub by
    /// `client_transcription_id`, so a failed batch is simply resent next
    /// pass. A row deleted here while its create was in flight stays on the
    /// hub: phone deletes are local only.
    public func push() async throws {
        let creates = try await store.pending()
        var start = 0
        while start < creates.count {
            let batch = Array(creates[start..<min(start + Self.pageSize, creates.count)])
            start += Self.pageSize
            let rows = try await hub.batchCreateTranscriptions(batch.map(\.createInput))
            for row in rows {
                guard let clientId = row.clientTranscriptionId else { continue }
                try await store.markSynced(clientId: clientId, cloudId: row.id, cloudUpdatedAt: row.updatedAt)
            }
        }
    }
}
