import Foundation

/// The chat agent's note tools, matching the desktop's
/// (`src/services/tools/*Tool.ts`): `search_notes`, `get_note`,
/// `create_note`, `update_note`, `list_folders`, same names and arguments.
/// They work over the `NotesViewModel`, so every write lands in the local
/// store as a pending edit and syncs to the hub like one typed by hand.
///
/// Where the phone differs from the desktop:
/// - A note id is the note's client id, a string (the desktop's is a number).
/// - Search is a local keyword match, not semantic: a note matches when its
///   title, content, or transcript contains the query or any word of it,
///   ranked by how many words it contains, then newest first.
/// - There are no spaces, so the `space` arguments are gone.
/// - There is no destination dialog yet: `create_note` with no folder files
///   into the default folder, and a folder name that matches none is created.
/// - `update_note` writes only with proof of what the model read: a new
///   title names the current one (`old_title`), a rewrite names the whole
///   current content (`old_content`), and a partial edit names text found
///   exactly once in it (`edits`). The store checks that proof against the
///   stored text as it writes, so a write built from a preview, a cut-short
///   result, or text that changed since (a pull, a phone draft) is refused
///   and changes nothing. The tools keep no record of reads.
public enum NoteTools {
    /// The desktop's preview length for search results.
    public static let previewLength = 500
    public static let defaultSearchLimit = 5
    public static let maxSearchLimit = 20

    /// Every note tool, in the desktop's order.
    @MainActor
    public static func all(notes: NotesViewModel) -> [ChatTool] {
        [searchNotes(notes), getNote(notes), createNote(notes), updateNote(notes), listFolders(notes)]
    }

    // MARK: Tools

    @MainActor
    static func searchNotes(_ notes: NotesViewModel) -> ChatTool {
        ChatTool(
            name: "search_notes",
            description: "Search the user's notes by keyword. Matches the query, or any word of it, in the title, content, and transcript, best matches first. Returns matching notes with id, title, date, folder, and a preview of content.",
            parameters: schema([
                "query": .object(["type": "string", "description": "The search query to find relevant notes"]),
                "limit": .object(["type": "number", "description": "Maximum number of results to return (default 5)"]),
            ], required: ["query"]),
            readOnly: true
        ) { args in
            guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw ChatToolError("query is required")
            }
            let limit = min(max(args["limit"]?.intValue ?? defaultSearchLimit, 1), maxSearchLimit)
            await notes.reload()
            let hits = rank(notes.allNotes, query: query).prefix(limit)
            let results: [JSONValue] = hits.map { note in
                .object([
                    "id": .string(note.clientId),
                    "title": title(note),
                    "date": .string(note.createdAt.formatted(.iso8601)),
                    "type": .string(note.noteType.rawValue),
                    "folder": folderName(note.folderClientId, in: notes),
                    "content": .string(String(note.content.prefix(previewLength))),
                ])
            }
            let text = results.isEmpty
                ? "No notes found for \"\(query)\""
                : "Found \(results.count) note\(results.count == 1 ? "" : "s") for \"\(query)\""
            return ChatToolOutput(data: .array(results), displayText: text)
        }
    }

    @MainActor
    static func getNote(_ notes: NotesViewModel) -> ChatTool {
        ChatTool(
            name: "get_note",
            description: "Get the full title and content of a specific note by ID. Call it before rewriting a note's content. Use search_notes first to find the note ID.",
            parameters: schema([
                "id": .object(["type": "string", "description": "The note ID to retrieve"]),
            ], required: ["id"]),
            readOnly: true
        ) { args in
            let id = try noteId(args)
            await notes.reload()
            guard let note = notes.note(id) else { throw ChatToolError("Note with ID \(id) not found") }
            let data: JSONValue = .object([
                "id": .string(note.clientId),
                "title": title(note),
                "content": .string(note.content),
                "type": .string(note.noteType.rawValue),
                "folder_id": note.folderClientId.map(JSONValue.string) ?? .null,
                "folder": folderName(note.folderClientId, in: notes),
                "created_at": .string(note.createdAt.formatted(.iso8601)),
                "updated_at": .string(note.updatedAt.formatted(.iso8601)),
            ])
            return ChatToolOutput(data: data, displayText: "Retrieved note: \"\(note.title ?? NoteRecord.untitled)\"")
        }
    }

    @MainActor
    static func createNote(_ notes: NotesViewModel) -> ChatTool {
        ChatTool(
            name: "create_note",
            description: "Creates a note with title, content, and an optional folder. When folder is omitted the note goes into the default folder. Use an existing folder whenever one fits (call list_folders first); a folder name that matches none is created, so confirm a new folder with the user before passing it.",
            parameters: schema([
                "title": .object(["type": "string", "description": "The title of the note"]),
                "content": .object(["type": "string", "description": "The content of the note"]),
                "folder": .object(["type": "string", "description": "Folder name. Omit for the default folder. A folder that does not exist is created."]),
                "noteType": .object([
                    "type": "string", "enum": .array(["meeting", "personal"]),
                    "description": "Known note kind (default personal).",
                ]),
            ], required: ["title", "content"]),
            readOnly: false
        ) { args in
            guard let title = args["title"]?.stringValue else { throw ChatToolError("title is required") }
            guard let content = args["content"]?.stringValue else { throw ChatToolError("content is required") }
            let noteType: HubNoteType = args["noteType"]?.stringValue == "meeting" ? .meeting : .personal
            let folder: FolderRecord
            if let name = folderArgument(args) {
                folder = try await resolveFolder(name, in: notes)
            } else {
                folder = try await notes.ensureDefaultFolder()
            }
            let note = try await notes.create(title: title, content: content, noteType: noteType, folderClientId: folder.clientId)
            return ChatToolOutput(
                data: .object([
                    "id": .string(note.clientId), "title": .string(title), "folder_id": .string(folder.clientId),
                    "folder": .string(folder.name), "result": "Note created.",
                ]),
                displayText: "Created note: \"\(title)\"")
        }
    }

    @MainActor
    static func updateNote(_ notes: NotesViewModel) -> ChatTool {
        ChatTool(
            name: "update_note",
            description: "Updates a note's title, content, or folder. Text changes quote the note's current text exactly. For a small change use edits: each old copied exactly from the note, occurring once. To rename, pass title with old_title. To rewrite everything, call get_note first and pass content with old_content (the full content exactly as shown). append adds to the end. Send only one of content, edits, append. A refused update changed nothing: call get_note and resend. Before moving to a folder, call list_folders and reuse one that fits. Use the note ID from context if provided; otherwise search_notes first.",
            parameters: schema([
                "id": .object(["type": "string", "description": "The note ID to update"]),
                "title": .object(["type": "string", "description": "New title. Needs old_title."]),
                "old_title": .object(["type": "string", "description": "The note's current title, exactly as get_note shows it (\"\" if none)."]),
                "content": .object(["type": "string", "description": "New full content, replacing all of it. Needs old_content."]),
                "old_content": .object(["type": "string", "description": "The note's full current content, exactly as get_note shows it."]),
                "edits": .object([
                    "type": "array",
                    "description": "Small changes, applied in order: each old is replaced by new. Each old must occur exactly once in the note, and still once after the earlier edits; merge edits that overlap.",
                    "items": schema([
                        "old": .object(["type": "string", "description": "Text copied exactly from the note"]),
                        "new": .object(["type": "string", "description": "Replacement text (\"\" deletes)"]),
                    ], required: ["old", "new"]),
                ]),
                "append": .object(["type": "string", "description": "Text to add at the end of the note."]),
                "folder": .object(["type": "string", "description": "Folder name to move the note to. Created automatically if it does not exist."]),
            ], required: ["id"]),
            readOnly: false
        ) { args in
            let id = try noteId(args)
            let title = args["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let content = args["content"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let edits = try editsArgument(args)
            let append = args["append"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let folderName = folderArgument(args)
            let contentForms = [content != nil, edits != nil, append != nil].count(where: \.self)
            guard contentForms <= 1 else {
                throw ChatToolError("Send only one of content (with old_content), edits, or append in one update_note call.")
            }
            guard title != nil || contentForms == 1 || folderName != nil else {
                throw ChatToolError("At least one of title, content, edits, append, or folder must be provided")
            }
            var retitle: (from: String, to: String)?
            if let title {
                guard let old = quotedText(args["old_title"]) else {
                    throw ChatToolError("old_title is required with title: send the note's current title exactly as get_note shows it (\"\" if it has none).")
                }
                retitle = (old, title)
            }
            let change: NoteContentChange?
            if let content {
                guard let old = quotedText(args["old_content"]) else {
                    throw ChatToolError("old_content is required with content: call get_note and send the note's full current content exactly as shown, or use edits for a small change.")
                }
                change = .replace(expected: old, content: content)
            } else if let edits {
                change = .edits(edits)
            } else {
                change = append.map(NoteContentChange.append)
            }
            // The proof is checked against the stored text: a phone draft
            // is saved first, so it is part of what the old text must match.
            await notes.flushEdits()
            await notes.reload()
            guard notes.note(id) != nil else { throw ChatToolError("Note with ID \(id) not found") }
            // An existing folder moves with the write in one update. A new
            // folder is made only after the proof passed and the write
            // landed: a refused update must leave no folder behind, and no
            // folder pull may land between the proof and the write.
            let existing = folderName.flatMap { name in notes.folders.first { $0.name.lowercased() == name.lowercased() } }
            var note: NoteRecord
            do {
                note = try await notes.update(id, retitle: retitle, content: change, folderClientId: existing?.clientId)
            } catch NotesStoreError.noteChangedSinceRead {
                throw ChatToolError("Note \(id) was not updated: old_title or old_content is not exactly the note's current text (it changed, or you did not see all of it). Call get_note and resend, or use edits for a small change.")
            } catch NotesStoreError.editTextNotFound(_, let index) {
                throw ChatToolError(index == 0
                    ? "Note \(id) was not updated: edits[0].old is not in the note's current text. Call get_note and copy the text exactly."
                    : "Note \(id) was not updated: edits[\(index)].old is not in the note's current text, or not after applying edits[0..<\(index)] in order. Copy each old exactly from get_note; if edits overlap, merge them into one edit.")
            } catch NotesStoreError.editTextNotUnique(_, let index) {
                throw ChatToolError(index == 0
                    ? "Note \(id) was not updated: edits[0].old occurs more than once. Include more of the surrounding text so it occurs exactly once."
                    : "Note \(id) was not updated: edits[\(index)].old occurs more than once in the note's current text, or after applying edits[0..<\(index)] in order. Include more of the surrounding text so it occurs exactly once; if edits overlap, merge them into one edit.")
            }
            if let folderName, existing == nil {
                let wrote = retitle != nil || change != nil
                do {
                    let folder = try await resolveFolder(folderName, in: notes)
                    note = try await notes.update(id, folderClientId: folder.clientId)
                } catch where wrote {
                    // The write already landed, so resolveFolder's refusal
                    // ("omit the folder, then try again") must not reach the
                    // model: a resend would apply the change twice.
                    throw ChatToolError("Note \(id) was updated but not moved: folder \"\(folderName)\" could not be made right now. Do not resend the change; to move it later, call update_note with only id and folder.")
                }
            }
            let shownTitle = note.title ?? NoteRecord.untitled
            return ChatToolOutput(
                data: .object([
                    "id": .string(id), "title": Self.title(note),
                    "folder_id": note.folderClientId.map(JSONValue.string) ?? .null,
                    "folder": Self.folderName(note.folderClientId, in: notes), "result": "Note updated.",
                ]),
                displayText: "Updated note: \"\(shownTitle)\"")
        }
    }

    @MainActor
    static func listFolders(_ notes: NotesViewModel) -> ChatTool {
        ChatTool(
            name: "list_folders",
            description: "List all available note folders. Use before create_note or update_note to reuse an existing folder instead of creating a near-duplicate.",
            parameters: schema([:], required: []),
            readOnly: true
        ) { _ in
            await notes.reload()
            let folders = notes.folders
            let data: JSONValue = .array(folders.map { .object(["id": .string($0.clientId), "name": .string($0.name)]) })
            let text = folders.isEmpty ? "No folders" : "Folders: " + folders.map(\.name).joined(separator: ", ")
            return ChatToolOutput(data: data, displayText: text)
        }
    }

    // MARK: Helpers

    /// Notes that contain the whole query first, then by how many distinct
    /// words of it they contain; ties keep the input order (newest first).
    static func rank(_ notes: [NoteRecord], query: String) -> [NoteRecord] {
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let scored: [(offset: Int, score: Int, note: NoteRecord)] = notes.enumerated().compactMap { offset, note in
            let fields = [note.title, note.content, note.transcript].compactMap { $0 }
            let contains = { (needle: String) in fields.contains { $0.range(of: needle, options: options) != nil } }
            let score = (contains(query) ? 1_000 : 0) + words.count(where: contains)
            return score > 0 ? (offset, score, note) : nil
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }.map(\.note)
    }

    /// Finds a folder by name, ignoring case; creates it when none matches.
    /// "Personal" is the default folder. Any other new folder, with sync on,
    /// is made only after a fresh folder pull: the Mac may have made one by
    /// that name since the last pull, and a local copy would be refused by
    /// the hub (`409 folder_name_taken`) with its notes never synced. The
    /// pull is folders only: a note pull here would move the note
    /// `update_note` is about to write to the hub's newer revision.
    @MainActor
    static func resolveFolder(_ name: String, in notes: NotesViewModel) async throws -> FolderRecord {
        func match() -> FolderRecord? {
            notes.folders.first { $0.name.lowercased() == name.lowercased() }
        }
        await notes.reload()
        if let found = match() { return found }
        if name.lowercased() == NotesViewModel.defaultFolderName.lowercased() {
            return try await notes.ensureDefaultFolder()
        }
        await notes.refreshFolders()
        if let found = match() { return found }
        guard notes.foldersCurrent else {
            throw ChatToolError("Folder \"\(name)\" was not created: the phone could not check the hub's folders just now, and the Mac may already have a folder by that name. Use an existing folder or omit the folder, then try again once sync works.")
        }
        return try await notes.createFolder(name: name)
    }

    private static func noteId(_ args: [String: JSONValue]) throws -> String {
        // A small model may send the id as a number; the phone's ids are strings.
        switch args["id"] {
        case .string(let id) where !id.trimmingCharacters(in: .whitespaces).isEmpty:
            return id.trimmingCharacters(in: .whitespaces)
        case .number(let number):
            return JSONValue.number(number).intValue.map(String.init) ?? String(number)
        default:
            throw ChatToolError("id is required")
        }
    }

    private static func folderArgument(_ args: [String: JSONValue]) -> String? {
        guard let name = args["folder"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// `edits` as `{old, new}` pairs; `nil` when absent. Anything else
    /// (not a list, an empty list, an entry without both strings, an empty
    /// `old`) is an error for the model.
    private static func editsArgument(_ args: [String: JSONValue]) throws -> [NoteTextEdit]? {
        guard let value = args["edits"], value != .null else { return nil }
        guard case .array(let items) = value, !items.isEmpty else {
            throw ChatToolError("edits must be a non-empty list of {\"old\": ..., \"new\": ...}.")
        }
        return try items.enumerated().map { index, item in
            guard let old = item["old"]?.stringValue, !old.isEmpty, let new = item["new"]?.stringValue else {
                throw ChatToolError("edits[\(index)] needs a non-empty old and a new string.")
            }
            return NoteTextEdit(old: old, new: new)
        }
    }

    /// The model's quote of a field's current text. `null` is read as "":
    /// get_note shows an untitled note's title as null.
    private static func quotedText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text): text
        case .null: ""
        default: nil
        }
    }

    private static func title(_ note: NoteRecord) -> JSONValue {
        note.title.map(JSONValue.string) ?? .null
    }

    @MainActor
    private static func folderName(_ clientId: String?, in notes: NotesViewModel) -> JSONValue {
        guard let clientId, let folder = notes.folders.first(where: { $0.clientId == clientId }) else { return .null }
        return .string(folder.name)
    }

    private static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ])
    }
}
