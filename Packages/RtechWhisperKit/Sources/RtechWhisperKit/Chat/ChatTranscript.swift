import Foundation

/// A note the chat screen offers to open, under the assistant message whose
/// tools touched it (the desktop's `NoteCardRef`).
public struct NoteChip: Sendable, Equatable, Identifiable {
    /// The note's client id, as the tools report it.
    public let noteId: String
    public let title: String

    public var id: String { noteId }

    public init(noteId: String, title: String) {
        self.noteId = noteId
        self.title = title
    }
}

/// The conversation as the screen draws it: one entry per user or assistant
/// message, with the tool results that answered an assistant's calls hung
/// under it, as the desktop hangs `toolCalls` on the assistant message.
public enum ChatTranscript {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let message: ChatMessage
        /// The results of this assistant message's tool calls, in run order.
        public let toolResults: [ChatMessage]
        /// The calls this assistant message asked for that have no result
        /// yet: still running, or never run because the app closed.
        public let pendingCalls: [LLMToolCall]
        /// The notes this message's tools created, updated, read, or found.
        public let noteChips: [NoteChip]

        public var id: UUID { message.id }
    }

    /// Search hits are capped so a broad search does not bury the answer
    /// under a wall of note chips (the desktop's `MAX_SEARCH_CARDS`).
    public static let maxSearchChips = 5
    static let noteTools: Set<String> = ["create_note", "update_note", "get_note"]

    /// Folds `messages` into entries. A tool message before any assistant
    /// message has nothing to hang on and is dropped.
    public static func entries(_ messages: [ChatMessage]) -> [Entry] {
        var out: [Entry] = []
        var current: ChatMessage?
        var results: [ChatMessage] = []
        func flush() {
            guard let message = current else { return }
            let answered = Set(results.compactMap(\.toolCallId))
            out.append(Entry(
                message: message,
                toolResults: results,
                pendingCalls: message.toolCalls.filter { !answered.contains($0.id) },
                noteChips: noteChips(from: results)))
            current = nil
            results = []
        }
        for message in messages {
            switch message.role {
            case .tool:
                if current != nil { results.append(message) }
            case .user, .assistant:
                flush()
                current = message
            }
        }
        flush()
        return out
    }

    /// The notes to offer from a turn's tool results: one per note created,
    /// updated, or read, plus up to `maxSearchChips` a search found, deduped
    /// by id in result order. A later create, update, or read of a note
    /// already shown gives its chip the newer title, in the same place. A
    /// failed tool contributes none.
    public static func noteChips(from results: [ChatMessage]) -> [NoteChip] {
        var chips: [NoteChip] = []
        var seen: Set<String> = []
        var searchChips = 0
        for result in results where !result.isError {
            guard let name = result.toolName, let value = try? JSONValue(parsing: result.content) else { continue }
            if noteTools.contains(name) {
                guard let chip = chip(value, fallbackTitle: titleFromDisplay(result.displayText)) else { continue }
                if seen.insert(chip.noteId).inserted {
                    chips.append(chip)
                } else if let index = chips.firstIndex(where: { $0.noteId == chip.noteId }) {
                    chips[index] = chip
                }
            } else if name == "search_notes", case .array(let hits) = value {
                for hit in hits where searchChips < maxSearchChips {
                    guard let chip = chip(hit, fallbackTitle: nil), seen.insert(chip.noteId).inserted else { continue }
                    chips.append(chip)
                    searchChips += 1
                }
            }
        }
        return chips
    }

    private static func chip(_ value: JSONValue, fallbackTitle: String?) -> NoteChip? {
        guard let id = value["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        let title = value["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.isEmpty else { return NoteChip(noteId: id, title: title) }
        // A blank display title, or the bare "Untitled" older tool results
        // carry, reads as the one untitled label the Notes tab uses.
        let fallback = fallbackTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NoteChip(noteId: id, title: fallback.isEmpty || fallback == "Untitled" ? NoteRecord.untitled : fallback)
    }

    /// The title inside `Created note: "…"`, `Updated note: "…"`, or
    /// `Retrieved note: "…"`. Works on scalars: a title that starts with a
    /// combining mark merges with the opening quote into one Character, and
    /// a Character search would then find the closing quote instead.
    static func titleFromDisplay(_ text: String?) -> String? {
        guard let scalars = text?.unicodeScalars, let open = scalars.firstIndex(of: "\""),
              let close = scalars.lastIndex(of: "\""), close == scalars.index(before: scalars.endIndex),
              open < close
        else { return nil }
        let inner = String(Substring(scalars[scalars.index(after: open)..<close]))
        return inner.isEmpty ? nil : inner
    }
}

/// How a running tool reads on screen (the desktop's `agentMode.tools.*Status`
/// strings and `toolIcons`).
public enum ToolStatus {
    /// "Searching notes...", "Creating note...", …; the tool's name for one
    /// this app does not know.
    public static func running(_ toolName: String) -> String {
        switch toolName {
        case "search_notes": "Searching notes..."
        case "get_note": "Reading note..."
        case "create_note": "Creating note..."
        case "update_note": "Updating note..."
        case "list_folders": "Listing folders..."
        default: toolName
        }
    }

    /// The row for a call that was cut off and never finished: "Search notes
    /// did not finish", never the running line with its trailing "...".
    public static func interrupted(_ toolName: String) -> String {
        let action = switch toolName {
        case "search_notes": "Search notes"
        case "get_note": "Read note"
        case "create_note": "Create note"
        case "update_note": "Update note"
        case "list_folders": "List folders"
        default: toolName
        }
        return "\(action) did not finish"
    }

    /// The SF Symbol for a tool's row.
    public static func symbol(_ toolName: String) -> String {
        switch toolName {
        case "search_notes": "magnifyingglass"
        case "get_note": "doc.text"
        case "create_note": "doc.badge.plus"
        case "update_note": "pencil.line"
        case "list_folders": "folder"
        default: "wrench"
        }
    }
}
