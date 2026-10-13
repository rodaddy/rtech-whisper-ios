import Foundation

/// One message of a chat conversation, as the chat screen shows it and as
/// the store keeps it.
public struct ChatMessage: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case user, assistant, tool
    }

    public var id: UUID
    public var role: Role
    /// The text. For a tool message, the JSON the model was sent.
    public var content: String
    /// The calls an assistant message asked for.
    public var toolCalls: [LLMToolCall]
    /// For a tool message: the call it answers and the tool's name.
    public var toolCallId: String?
    public var toolName: String?
    /// For a tool message: the one-line summary to show.
    public var displayText: String?
    /// For a tool message: true when the tool failed.
    public var isError: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(), role: Role, content: String, toolCalls: [LLMToolCall] = [],
        toolCallId: String? = nil, toolName: String? = nil, displayText: String? = nil,
        isError: Bool = false, createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.displayText = displayText
        self.isError = isError
        self.createdAt = createdAt
    }

    /// The message as the model reads it.
    var llmMessage: LLMMessage {
        switch role {
        case .user:
            LLMMessage(role: .user, content: content)
        case .assistant:
            LLMMessage(role: .assistant, content: content, toolCalls: toolCalls.isEmpty ? nil : toolCalls)
        case .tool:
            LLMMessage(role: .tool, content: content, toolCallId: toolCallId)
        }
    }
}

/// A saved conversation, newest activity in `updatedAt`.
public struct ChatConversation: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
