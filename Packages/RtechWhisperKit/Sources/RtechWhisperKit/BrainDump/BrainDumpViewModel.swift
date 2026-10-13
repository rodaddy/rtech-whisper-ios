import Foundation

/// Why a dump was not saved; the text stays in the box.
public enum BrainDumpError: LocalizedError, Equatable {
    /// "Brain dumps" does not exist here yet and the hub's folders could not
    /// be checked, so making it now could clash with the Mac's copy.
    case hubUnchecked

    public var errorDescription: String? {
        switch self {
        case .hubUnchecked:
            "The phone could not check the hub's folders just now, and the Mac may already have a Brain dumps folder. Try again once sync works."
        }
    }
}

/// The Brain dump tab (ios#484): quick capture into a "Brain dumps" folder.
/// Each dump is an ordinary note, so it syncs to the Mac like any other; the
/// Mac sorts them and moves the originals to the processed folder, which
/// this tab leaves out.
@MainActor
public struct BrainDumpViewModel {
    /// The folder new dumps land in, found by exact name.
    public static let folderName = "Brain dumps"
    /// Where the Mac moves processed dumps. Hub folders are flat (no parent
    /// field in the contract), so it is a sibling folder, not a subfolder.
    public static let processedFolderName = "Brain dumps - Processed"
    /// The longest title a dump gets.
    public static let titleLimit = 60

    public let notes: NotesViewModel

    public init(notes: NotesViewModel) {
        self.notes = notes
    }

    /// The unprocessed dumps: notes in "Brain dumps" only, newest first.
    public var dumps: [NoteRecord] {
        guard let folder else { return [] }
        return notes.notes(inFolder: folder.clientId).sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves the text as a dump, titled by its first line. Nothing is saved
    /// for blank text. The title is set here, so the AI titler leaves it alone.
    @discardableResult
    public func save(_ text: String) async throws -> NoteRecord? {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let folder = try await ensureFolder()
        return try await notes.create(title: Self.title(for: content), content: content, folderClientId: folder.clientId)
    }

    /// "Brain dumps", matched ignoring case, made the first time it is needed
    /// and reused after. As `NoteTools.resolveFolder` does, it is made only
    /// after a fresh folder pull: the Mac (or another phone) may already have
    /// "Brain dumps", and a second local copy would be refused by the hub
    /// (`409 folder_name_taken`), so no dump filed in it would ever sync.
    func ensureFolder() async throws -> FolderRecord {
        await notes.reload()
        if let folder = folder { return folder }
        await notes.refreshFolders()
        if let folder = folder { return folder }
        guard notes.foldersCurrent else { throw BrainDumpError.hubUnchecked }
        return try await notes.createFolder(name: Self.folderName)
    }

    /// The local "Brain dumps" folder, ignoring case.
    private var folder: FolderRecord? {
        notes.folders.first { $0.name.lowercased() == Self.folderName.lowercased() }
    }

    /// The first non-blank line, trimmed, at most `titleLimit` characters.
    public static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(titleLimit))
    }

    /// Text heard by the mic, added after what is already in the box: a
    /// space after a line with text, nothing after a line break.
    public static func appending(_ heard: String, to text: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return heard }
        if text.last?.isNewline == true { return text + heard }
        if text.last?.isWhitespace == true { return text + heard }
        return text + " " + heard
    }
}
