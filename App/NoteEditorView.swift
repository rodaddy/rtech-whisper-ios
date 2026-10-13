import RtechWhisperKit
import SwiftUI

/// Title and body, saved as you type, with a banner when the Mac changed the
/// same note. An untitled note gets a generated title once typing pauses or
/// the editor closes. The sparkles menu runs the desktop's note actions.
struct NoteEditorView: View {
    let notes: NotesViewModel
    let titler: NoteAutoTitler
    let clientId: String
    @Environment(NoteActionRunner.self) private var actions
    @State private var title = ""
    @State private var content = ""

    var body: some View {
        Form {
            if let conflict = notes.conflict(for: clientId) {
                Section {
                    Text("This note changed on the Mac while you edited it here.")
                    Text(conflict.hub.content)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    HStack {
                        Button("Keep mine") {
                            Task { await notes.resolve(clientId, .keepMine) }
                        }
                        Spacer()
                        Button("Use the Mac's") {
                            Task { await notes.resolve(clientId, .takeHub) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .listRowBackground(Color.orange.opacity(0.15))
            }
            actionStatus
            Section {
                TextField(NoteRecord.untitled, text: $title)
                    .font(.headline)
                    .onChange(of: title) { _, new in
                        if new != (notes.note(clientId)?.title ?? "") { notes.edit(clientId, title: new) }
                    }
                TextEditor(text: $content)
                    .frame(minHeight: 300)
                    .disabled(isRunningHere)
                    .onChange(of: content) { _, new in
                        if new != notes.note(clientId)?.content {
                            notes.edit(clientId, content: new)
                            titler.noteChanged(clientId)
                        }
                    }
            } footer: {
                if titler.isGenerating(clientId) {
                    Text("Writing a title…")
                } else if notes.isWaitingToSync(clientId) {
                    Text("Saved on phone, waiting to sync")
                }
            }
            enhancedSection
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            if let note = notes.note(clientId) {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportMenu(title: note.title) { TextExport.noteText(note, format: $0) }
                }
            }
        }
        .onAppear(perform: loadFields)
        // A pull or "Use the Mac's" changed the note underneath: show it,
        // unless an edit here has not been saved yet.
        .onChange(of: notes.note(clientId)) { _, _ in
            if !notes.hasUnsavedEdit(clientId) { loadFields() }
        }
        .onDisappear {
            Task {
                await notes.flushEdits()
                titler.noteClosed(clientId)
            }
        }
    }

    private var isRunningHere: Bool {
        if case .running(let id, _) = actions.state { return id == clientId }
        return false
    }

    private var actionsMenu: some View {
        Menu("Actions", systemImage: "sparkles") {
            ForEach(NoteAction.builtIn) { action in
                // The runner saves any unsaved typing before it reads the note.
                Button(action.name, systemImage: action.systemImage) { actions.run(action, on: clientId) }
            }
        }
        .disabled(actions.isRunning || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Progress with Cancel while an action works on this note; the reason
    /// when one failed; Undo right after one landed.
    @ViewBuilder private var actionStatus: some View {
        switch actions.state {
        case .running(let id, let name) where id == clientId:
            Section {
                HStack {
                    ProgressView()
                    Text("\(name)…")
                    Spacer()
                    Button("Cancel", role: .cancel) { actions.cancel() }
                }
            }
        case .failed(let id, let error) where id == clientId:
            Section {
                Text(Self.message(error))
                Button("OK") { actions.dismissFailure() }
            }
            .listRowBackground(Color.orange.opacity(0.15))
        default:
            if actions.canUndo(clientId), let last = actions.lastApplied {
                Section {
                    Button("Undo \(last.actionName)", systemImage: "arrow.uturn.backward") {
                        Task { try? await actions.undo() }
                    }
                }
            }
        }
    }

    /// An action's result, kept beside the note's text (the desktop's
    /// Enhanced tab), synced as the note's enhanced content.
    @ViewBuilder private var enhancedSection: some View {
        if let note = notes.note(clientId), let enhancement = note.enhancement {
            Section {
                Text(enhancement.content)
                    .textSelection(.enabled)
            } header: {
                Text("Enhanced")
            } footer: {
                if note.enhancementIsOutdated {
                    Text("The note changed after this was made. Run the action again to update it.")
                }
            }
        }
    }

    private static func message(_ error: NoteActionError) -> String {
        switch error {
        case .emptyNote: "This note has no text to work on."
        case .relay(let hubError): hubError.userMessage
        case .noAnswer: "The model gave no usable answer, so the note was left as it was."
        case .noteChanged: "The note changed while the action ran, so the result was not saved."
        }
    }

    private func loadFields() {
        guard let note = notes.note(clientId) else { return }
        if title != (note.title ?? "") { title = note.title ?? "" }
        if content != note.content { content = note.content }
    }
}
