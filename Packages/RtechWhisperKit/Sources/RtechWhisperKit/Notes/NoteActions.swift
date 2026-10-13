import Foundation
import Observation

/// One AI action the note editor offers, as the desktop's `actions` table
/// holds it (`src/helpers/database.js`). The phone has the built-in actions
/// only; the desktop's custom actions live in its local SQLite and do not sync.
public struct NoteAction: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    /// The action's own instructions, appended to `basePrompt`.
    public let prompt: String
    public let systemImage: String

    public init(id: String, name: String, description: String, prompt: String, systemImage: String = "sparkles") {
        self.id = id
        self.name = name
        self.description = description
        self.prompt = prompt
        self.systemImage = systemImage
    }

    /// The desktop's one built-in action, text identical to its seed row.
    public static let generateNotes = NoteAction(
        id: "generateNotes",
        name: "Generate Notes",
        description: "Clean up, structure, and enhance your notes",
        prompt: "Transform the provided content into clean, well-structured notes in markdown. Preserve the user's intent and all substantive information. Remove filler, small talk, false starts, and redundant content. For personal notes, improve grammar and structure for readability. For meeting transcripts, extract key discussion points, decisions, action items, and follow-ups."
    )

    public static let builtIn: [NoteAction] = [.generateNotes]

    /// The desktop's `BASE_SYSTEM_PROMPT` (`src/stores/actionProcessingStore.ts`);
    /// the action's prompt follows "Instructions: ".
    static let basePrompt = """
        You are a note enhancement assistant. The user will provide raw notes — possibly voice-transcribed, rough, or unstructured. Your job is to clean them up according to the instructions below while preserving all original meaning and information. Output clean markdown.

        FORMAT RULES (strict):
        - Do NOT include any preamble: no title, no date/time/location, no attendee list, no topic header. Start directly with the content.
        - Do NOT use tables, horizontal rules, or block quotes.
        - Do NOT list or guess participant names/roles.
        - Keep the tone professional and concise. Bias toward brevity.

        """ + "\nInstructions: "

    /// The system prompt the relay gets: the base prompt, then this action's.
    public var systemPrompt: String { Self.basePrompt + prompt }
}

/// Why an action left the note as it was.
public enum NoteActionError: Error, Sendable, Equatable {
    /// The note has no text to work on.
    case emptyNote
    /// The relay failed; carries the hub's error.
    case relay(HubError)
    /// The model answered nothing usable, or was cut off at its token limit.
    case noAnswer
    /// The note (its text or its enhancement) changed while the action ran,
    /// or its enhancement changed since the action (for Undo), so writing
    /// would have overwritten that change.
    case noteChanged
}

/// What one applied action changed, kept so Undo can put the enhancement
/// it replaced back. The note's own text is never touched by an action.
public struct NoteActionUndo: Sendable, Equatable {
    public let clientId: String
    public let actionName: String
    /// The enhancement before the action; `nil` when the note had none.
    public let previous: NoteEnhancement?
    public let applied: NoteEnhancement
}

/// Runs a `NoteAction` on a note through the hub's LLM relay, one at a time.
/// As on the desktop, the result goes to the note's synced enhancement
/// (`enhanced_content`, with the action prompt and the note's content hash)
/// and the note's `content` is left as it was, so the raw text is never lost.
/// The write goes through `NotesViewModel.enhance`, which refuses it if the
/// note changed since it was read, marks the note pending, and syncs it.
/// Cancel drops the answer, so the note is left as it was.
@MainActor
@Observable
public final class NoteActionRunner {
    public enum State: Sendable, Equatable {
        case idle
        case running(clientId: String, actionName: String)
        case failed(clientId: String, NoteActionError)
    }

    /// Desktop: temperature 0.3 for note actions.
    static let temperature = 0.3

    public private(set) var state: State = .idle
    /// The last action applied, until it is undone or another one lands.
    public private(set) var lastApplied: NoteActionUndo?

    @ObservationIgnored private let notes: NotesViewModel
    @ObservationIgnored private let llm: any LLMCompleting
    @ObservationIgnored private let model: String
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by each run and each cancel, so a cancelled run's late answer
    /// never touches the state of the one after it.
    @ObservationIgnored private var generation = 0

    public init(notes: NotesViewModel, llm: any LLMCompleting, model: String = LLMClient.defaultModel) {
        self.notes = notes
        self.llm = llm
        self.model = model
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True when Undo would put `clientId` back: its last action is the
    /// latest one and the note still holds the enhancement that action wrote.
    /// Editing the note's text does not void it; a newer enhancement does.
    public func canUndo(_ clientId: String) -> Bool {
        guard let last = lastApplied, last.clientId == clientId else { return false }
        return notes.note(clientId)?.enhancement == last.applied
    }

    /// The request an action sends for `content`: the system prompt, then the
    /// note text as the user message, as the desktop sends it.
    public func request(_ action: NoteAction, content: String) -> LLMChatRequest {
        LLMChatRequest(
            model: model, messages: [.system(action.systemPrompt), .user(content)], temperature: Self.temperature)
    }

    /// Starts `action` on the note. Ignored while another action runs.
    /// Returns the run's task so a caller (or a test) can wait for it.
    @discardableResult
    public func run(_ action: NoteAction, on clientId: String) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        generation += 1
        let current = generation
        state = .running(clientId: clientId, actionName: action.name)
        let run = Task { await self.perform(action, on: clientId, generation: current) }
        task = run
        return run
    }

    /// Stops the running action. The request is cancelled and any answer
    /// that still arrives is dropped.
    public func cancel() {
        guard isRunning else { return }
        generation += 1
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Puts back the enhancement the last action replaced, or clears it when
    /// there was none. Throws `.noteChanged`, and changes nothing, when the
    /// enhancement changed after the action (a pull of the Mac's, say).
    public func undo() async throws(NoteActionError) {
        guard let last = lastApplied else { return }
        do {
            _ = try await notes.enhance(last.clientId, to: last.previous, expecting: last.applied)
        } catch {
            throw .noteChanged
        }
        lastApplied = nil
    }

    public func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func perform(_ action: NoteAction, on clientId: String, generation current: Int) async {
        // Unsaved typing lands first, so the text sent is the text stored.
        await notes.flushEdits()
        guard let note = notes.note(clientId),
              !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return finish(current, clientId, .emptyNote) }
        let original = note.content
        let previous = note.enhancement

        let result: String
        do {
            let completion = try await llm.complete(request(action, content: original))
            guard completion.finishReason != "length" else { return finish(current, clientId, .noAnswer) }
            result = ThinkingTags.strip(completion.content).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return finish(current, clientId, .relay(error))
        }
        guard !result.isEmpty else { return finish(current, clientId, .noAnswer) }
        guard current == generation, !Task.isCancelled else { return }

        let applied = NoteEnhancement(
            content: result, prompt: action.prompt,
            contentHash: NoteEnhancement.contentHash(content: original, transcript: note.transcript))
        do {
            // The result goes beside the text, never over it, as on the desktop.
            _ = try await notes.enhance(clientId, to: applied, expecting: previous, expectedContent: original)
        } catch {
            return finish(current, clientId, .noteChanged)
        }
        lastApplied = NoteActionUndo(clientId: clientId, actionName: action.name, previous: previous, applied: applied)
        finish(current, clientId, nil)
    }

    private func finish(_ current: Int, _ clientId: String, _ error: NoteActionError?) {
        guard current == generation else { return }
        task = nil
        state = error.map { .failed(clientId: clientId, $0) } ?? .idle
    }
}
