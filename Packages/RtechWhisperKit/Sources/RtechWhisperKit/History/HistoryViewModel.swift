import Foundation
import Observation

/// What the Home tab's history list renders and calls: the transcriptions on
/// this phone, newest first, plus record (auto-save), delete, and refresh.
/// Every write lands in the local store first; `sync` then runs the app's
/// sync pass (the same one the notes use), which carries the transcription
/// step, so the list works offline and with no device key.
@MainActor
@Observable
public final class HistoryViewModel {
    public private(set) var items: [TranscriptionRecord] = []
    /// Set when the store could not be read or written; cleared by the next success.
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    /// The retention each new dictation is trimmed to; the app reads its setting.
    @ObservationIgnored public var retention: @MainActor () -> HistoryRetention = { .all }

    private let store: TranscriptionStore
    private let sync: @MainActor () async -> Void
    private let limit: Int?

    /// - Parameters:
    ///   - sync: one full sync pass; `NotesViewModel.syncNow` in the app.
    ///   - limit: how many rows the list holds; `nil` is every row.
    public init(store: TranscriptionStore, sync: @escaping @MainActor () async -> Void, limit: Int? = 200) {
        self.store = store
        self.sync = sync
        self.limit = limit
    }

    public func item(_ clientId: String) -> TranscriptionRecord? {
        items.first { $0.clientId == clientId }
    }

    /// Re-reads the list from the store.
    public func load() async {
        do {
            items = try await store.list(limit: limit)
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the history. \(error.localizedDescription)"
        }
    }

    /// Saves a finished dictation or upload to the history, trims the history
    /// to `retention`, and syncs. This is the
    /// auto-save: it keeps the text as transcribed, never a later edit.
    /// A `clientId` already in the history adds nothing (`TranscriptionStore.add`).
    @discardableResult
    public func record(
        text: String, rawText: String? = nil, provider: String, model: String? = nil, durationMs: Int? = nil,
        clientId: String? = nil
    ) async -> TranscriptionRecord? {
        let saved: TranscriptionRecord
        do {
            saved = try await store.add(
                text: text, rawText: rawText, provider: provider, model: model, durationMs: durationMs,
                clientId: clientId)
        } catch {
            errorMessage = "Could not save the transcription to the history. \(error.localizedDescription)"
            return nil
        }
        await applyRetention(retention())
        await refresh()
        return saved
    }

    /// Removes a transcription from this phone only; the hub keeps it.
    public func delete(_ clientId: String) async {
        do {
            try await store.delete(clientId: clientId)
        } catch {
            errorMessage = "Could not delete the transcription. \(error.localizedDescription)"
        }
        await load()
    }

    /// Trims the history to `retention`, on this phone only. The app calls
    /// this on launch; `record` calls it after each new dictation.
    public func applyRetention(_ retention: HistoryRetention, now: Date = Date()) async {
        do {
            try await store.applyRetention(retention, now: now)
        } catch {
            errorMessage = "Could not clear old transcriptions. \(error.localizedDescription)"
        }
        await load()
    }

    /// One sync pass, then reload. Pull-to-refresh calls this.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await sync()
        isRefreshing = false
        await load()
    }
}
