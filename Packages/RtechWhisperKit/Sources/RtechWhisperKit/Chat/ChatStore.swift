import Foundation
import SwiftData

/// A saved conversation row.
@Model
final class StoredChatConversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \StoredChatMessage.conversation)
    var messages: [StoredChatMessage] = []

    init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A saved message row. `position` keeps the order the model saw.
@Model
final class StoredChatMessage {
    @Attribute(.unique) var id: UUID
    var conversation: StoredChatConversation?
    var position: Int
    var roleRaw: String
    var content: String
    /// `[LLMToolCall]` as JSON; nil when the message asked for none.
    var toolCallsJSON: Data?
    var toolCallId: String?
    var toolName: String?
    var displayText: String?
    var isError: Bool
    var createdAt: Date

    init(_ message: ChatMessage, position: Int) throws {
        id = message.id
        self.position = position
        roleRaw = message.role.rawValue
        content = message.content
        toolCallsJSON = message.toolCalls.isEmpty ? nil : try JSONEncoder().encode(message.toolCalls)
        toolCallId = message.toolCallId
        toolName = message.toolName
        displayText = message.displayText
        isError = message.isError
        createdAt = message.createdAt
    }

    /// The message, or `ChatStoreError.damagedMessage` for a row whose role
    /// or tool calls do not decode: guessing would send the model a tool
    /// result answering no call, or drop the calls a result answers.
    func record() throws -> ChatMessage {
        guard let role = ChatMessage.Role(rawValue: roleRaw) else { throw ChatStoreError.damagedMessage(id) }
        var toolCalls: [LLMToolCall] = []
        if let toolCallsJSON {
            do {
                toolCalls = try JSONDecoder().decode([LLMToolCall].self, from: toolCallsJSON)
            } catch {
                throw ChatStoreError.damagedMessage(id)
            }
        }
        return ChatMessage(
            id: id, role: role, content: content, toolCalls: toolCalls,
            toolCallId: toolCallId, toolName: toolName, displayText: displayText, isError: isError,
            createdAt: createdAt)
    }
}

/// What a chat session needs from its store. `ChatStore` is the real one.
public protocol ChatPersisting: Sendable {
    func createConversation(title: String, now: Date) async throws -> ChatConversation
    func conversation(_ id: UUID) async throws -> ChatConversation?
    func messages(in id: UUID) async throws -> [ChatMessage]
    func append(_ message: ChatMessage, to id: UUID) async throws
}

public enum ChatStoreError: Error, Equatable {
    case conversationNotFound(UUID)
    /// The store could not write (the test seam `failSaves`).
    case saveFailed
    /// `append` was given a message whose id is already stored.
    case duplicateMessage(UUID)
    /// A stored message whose role or tool calls no longer decode.
    case damagedMessage(UUID)
}

/// Chat conversations on this phone. A store of its own (`Chat.store`), apart
/// from the notes store, and never synced: the hub has no chat sync.
@ModelActor
public actor ChatStore: ChatPersisting {
    public static let schema = Schema([StoredChatConversation.self, StoredChatMessage.self])

    /// The on-disk configuration: `Chat.store` in the app's support
    /// directory unless `url` says otherwise, with CloudKit off.
    public static func configuration(url: URL? = nil) -> ModelConfiguration {
        if let url {
            return ModelConfiguration("Chat", schema: schema, url: url, cloudKitDatabase: .none)
        }
        return ModelConfiguration("Chat", schema: schema, cloudKitDatabase: .none)
    }

    public static func persistent(url: URL? = nil) throws -> ChatStore {
        ChatStore(modelContainer: try ModelContainer(for: schema, configurations: configuration(url: url)))
    }

    /// A store that lives only in memory, for tests and previews.
    public static func inMemory() throws -> ChatStore {
        let config = ModelConfiguration("Chat", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ChatStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    @discardableResult
    public func createConversation(title: String, now: Date = Date()) throws -> ChatConversation {
        let row = StoredChatConversation(id: UUID(), title: title, createdAt: now, updatedAt: now)
        context.insert(row)
        try commit()
        return Self.record(row)
    }

    /// Every conversation, most recently active first.
    public func conversations() throws -> [ChatConversation] {
        try context.fetch(FetchDescriptor<StoredChatConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )).map(Self.record)
    }

    public func conversation(_ id: UUID) throws -> ChatConversation? {
        try row(id).map(Self.record)
    }

    /// The conversation's messages in order.
    public func messages(in id: UUID) throws -> [ChatMessage] {
        let conversation = try requireRow(id)
        return try conversation.messages.sorted { $0.position < $1.position }.map { try $0.record() }
    }

    /// Adds a message after the last one and marks the conversation active.
    /// Throws `duplicateMessage` for an id already stored, which would
    /// otherwise overwrite that row.
    public func append(_ message: ChatMessage, to id: UUID) throws {
        let conversation = try requireRow(id)
        let messageId = message.id
        guard try context.fetchCount(FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { $0.id == messageId })) == 0 else {
            throw ChatStoreError.duplicateMessage(messageId)
        }
        // Only the last position, not every message of a long conversation.
        var last = FetchDescriptor<StoredChatMessage>(
            predicate: #Predicate { $0.conversation?.id == id },
            sortBy: [SortDescriptor(\.position, order: .reverse)])
        last.fetchLimit = 1
        let position = (try context.fetch(last).first?.position ?? -1) + 1
        let row = try StoredChatMessage(message, position: position)
        context.insert(row)
        row.conversation = conversation
        conversation.updatedAt = max(conversation.updatedAt, message.createdAt)
        try commit()
    }

    public func rename(_ id: UUID, to title: String) throws {
        try requireRow(id).title = title
        try commit()
    }

    /// Removes the conversation and its messages. When the save fails the
    /// context is replaced, not rolled back: rolling back a delete of a
    /// conversation with messages traps inside SwiftData, even with
    /// the messages deleted one by one. Nothing reached the store, so a
    /// fresh context reads the conversation and its messages as they were.
    public func delete(_ id: UUID) throws {
        guard let conversation = try row(id) else { return }
        for message in conversation.messages { context.delete(message) }
        context.delete(conversation)
        do {
            try save()
        } catch {
            replacement = ModelContext(modelContainer)
            throw error
        }
    }

    /// Test seam: while above zero, each save throws `ChatStoreError.saveFailed`
    /// instead of saving, as a full disk would.
    private var failSaves = 0
    func setFailSaves(_ count: Int) { failSaves = count }

    /// The context in use: `modelContext` until a failed delete discards it.
    private var replacement: ModelContext?
    private var context: ModelContext { replacement ?? modelContext }

    /// Saves the context, or throws with every change since the last save
    /// rolled back. A failed save must not leave rows pending: the next
    /// save that works would write them too (a second copy of a
    /// conversation the caller already retried).
    private func commit() throws {
        do {
            try save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func save() throws {
        if failSaves > 0 {
            failSaves -= 1
            throw ChatStoreError.saveFailed
        }
        try context.save()
    }

    private func row(_ id: UUID) throws -> StoredChatConversation? {
        try context.fetch(FetchDescriptor<StoredChatConversation>(
            predicate: #Predicate { $0.id == id })).first
    }

    private func requireRow(_ id: UUID) throws -> StoredChatConversation {
        guard let row = try row(id) else { throw ChatStoreError.conversationNotFound(id) }
        return row
    }

    private static func record(_ row: StoredChatConversation) -> ChatConversation {
        ChatConversation(id: row.id, title: row.title, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }
}
