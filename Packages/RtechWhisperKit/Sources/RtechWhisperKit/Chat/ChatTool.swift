import Foundation

/// What a tool hands back: `data` goes to the model as JSON, `displayText`
/// is the one-line summary a chat screen shows (the desktop's `ToolResult`).
public struct ChatToolOutput: Sendable, Equatable {
    public var data: JSONValue
    public var displayText: String

    public init(data: JSONValue, displayText: String) {
        self.data = data
        self.displayText = displayText
    }
}

/// A tool failure the model should read and recover from. Its `message`
/// goes to the model as `{"error": message}`.
public struct ChatToolError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One function the chat agent can call. `run` gets the parsed argument
/// object; a thrown error is reported to the model, never swallowed.
public struct ChatTool: Sendable {
    public let name: String
    public let description: String
    /// A JSON Schema object for the arguments.
    public let parameters: JSONValue
    /// True when the tool only reads.
    public let readOnly: Bool
    public let run: @MainActor @Sendable ([String: JSONValue]) async throws -> ChatToolOutput

    public init(
        name: String, description: String, parameters: JSONValue, readOnly: Bool,
        run: @escaping @MainActor @Sendable ([String: JSONValue]) async throws -> ChatToolOutput
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.readOnly = readOnly
        self.run = run
    }

    public var definition: LLMToolDefinition {
        LLMToolDefinition(name: name, description: description, parameters: parameters)
    }
}
