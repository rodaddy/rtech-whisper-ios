import Foundation
import Observation

/// Whether a note should get a generated title: it has content and no title
/// of its own (blank, or the default "Untitled Note").
public enum NoteTitling {
    public static func needsTitle(title: String?, content: String) -> Bool {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.isEmpty || title == NoteRecord.untitled else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func needsTitle(_ note: NoteRecord) -> Bool {
        needsTitle(title: note.title, content: note.content)
    }
}

/// Titles untitled notes through `TitleService`, as the desktop's
/// "Auto-generate note titles" does: once the editor has been idle for
/// `idleDelay`, when the note closes, or when a note is created with content
/// (Dictate's "Save as note"). A title the person typed is never replaced:
/// the note is checked again after the model answers, and a fallback answer
/// ("Untitled Note") is not written.
@MainActor
@Observable
public final class NoteAutoTitler {
    /// Notes with a title request in flight, for the editor's footer.
    public private(set) var generating: Set<String> = []

    @ObservationIgnored private let notes: NotesViewModel
    @ObservationIgnored private let generate: @Sendable (String) async -> String
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let idleDelay: Duration
    @ObservationIgnored private var idleTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var runs: [String: Task<String, Never>] = [:]

    /// - Parameters:
    ///   - generate: `TitleService.generate` in the app.
    ///   - isEnabled: the "Auto-generate titles" setting, read per run.
    ///   - idleDelay: the pause after the last keystroke before a title is tried.
    public init(
        notes: NotesViewModel,
        generate: @escaping @Sendable (String) async -> String,
        isEnabled: @escaping @MainActor () -> Bool,
        idleDelay: Duration = .seconds(3)
    ) {
        self.notes = notes
        self.generate = generate
        self.isEnabled = isEnabled
        self.idleDelay = idleDelay
    }

    public func isGenerating(_ clientId: String) -> Bool {
        generating.contains(clientId)
    }

    /// The editor changed the note's content: try a title once typing pauses.
    public func noteChanged(_ clientId: String) {
        idleTasks[clientId]?.cancel()
        let delay = idleDelay
        idleTasks[clientId] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.idleTasks[clientId] = nil
            await self?.titleIfNeeded(clientId)
        }
    }

    /// The editor closed, or a note with content was just created: try now.
    /// The returned task finishes when the title (if any) has been recorded.
    @discardableResult
    public func noteClosed(_ clientId: String) -> Task<Void, Never> {
        idleTasks[clientId]?.cancel()
        idleTasks[clientId] = nil
        return Task { [weak self] in await self?.titleIfNeeded(clientId) }
    }

    /// One title attempt: skipped when the setting is off, the note already
    /// has a title or no content, or a run is already in flight.
    public func titleIfNeeded(_ clientId: String) async {
        if let running = runs[clientId] {
            await running.value
            return
        }
        guard isEnabled(), let note = notes.note(clientId), NoteTitling.needsTitle(note) else { return }
        let content = note.content
        let generate = generate
        generating.insert(clientId)
        let run = Task { await generate(content) }
        runs[clientId] = run
        let title = await run.value
        runs[clientId] = nil
        generating.remove(clientId)
        guard title != TitleService.fallback, !title.isEmpty else { return }
        // The person may have typed a title, or deleted the note, meanwhile.
        guard let current = notes.note(clientId), NoteTitling.needsTitle(current) else { return }
        notes.edit(clientId, title: title)
    }
}
