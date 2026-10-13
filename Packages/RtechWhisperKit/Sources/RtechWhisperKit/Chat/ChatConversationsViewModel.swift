import Foundation
import Observation

/// The saved conversations for the Chat tab's list: load, delete, rename.
/// The `ChatSession` opens and writes them; this only lists them, so the
/// list is reloaded after a turn.
@MainActor
@Observable
public final class ChatConversationsViewModel {
    /// Most recently active first.
    public private(set) var conversations: [ChatConversation] = []
    /// True when the last read or write of the store failed.
    public private(set) var storeFailed = false
    /// True once a reload has read the store. Until then an empty list
    /// means nothing yet, not "no chats".
    public private(set) var hasLoaded = false

    private let store: ChatStore

    public init(store: ChatStore) {
        self.store = store
    }

    /// The list under date headings.
    public func groups(now: Date = Date(), calendar: Calendar = .current) -> [ConversationGroup] {
        ConversationGrouping.group(conversations, now: now, calendar: calendar)
    }

    public func reload() async {
        do {
            conversations = try await store.conversations()
            storeFailed = false
            hasLoaded = true
        } catch {
            storeFailed = true
        }
    }

    /// Deletes; returns false, with `storeFailed` set and the row left in
    /// the list, when the store did not take it.
    @discardableResult
    public func delete(_ id: UUID) async -> Bool {
        do {
            try await store.delete(id)
            conversations.removeAll { $0.id == id }
            storeFailed = false
            return true
        } catch {
            storeFailed = true
            return false
        }
    }

    /// Renames; a blank title leaves the conversation as it was. Returns
    /// the title stored, or nil when nothing changed (`storeFailed` set when
    /// the store did not take it).
    @discardableResult
    public func rename(_ id: UUID, to title: String) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        do {
            try await store.rename(id, to: title)
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index].title = title
            }
            storeFailed = false
            return title
        } catch {
            storeFailed = true
            return nil
        }
    }
}
