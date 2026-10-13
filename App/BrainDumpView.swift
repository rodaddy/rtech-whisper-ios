import RtechWhisperKit
import SwiftUI

/// The Brain dump tab: type or speak a thought, Save, move on.
/// Dumps are notes in the "Brain dumps" folder; the Mac sorts them later.
struct BrainDumpView: View {
    let notes: NotesViewModel
    let titler: NoteAutoTitler
    let draft: VoiceDraft
    /// Owned by ContentView, so a take ended in the background still lands here.
    @Binding var text: String
    /// Owned by ContentView, so the intent can pop back to the box.
    @Binding var path: NavigationPath
    /// Changes when the Brain dump intent opens the tab: focus the box.
    var focusRequest = 0
    @State private var saveError: String?
    @FocusState private var focused: Bool

    private var dumps: BrainDumpViewModel { BrainDumpViewModel(notes: notes) }
    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($focused)
                    HStack {
                        micButton
                        Spacer()
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(isBlank)
                    }
                    if let failure = draft.failure {
                        Label(failure.userMessage, systemImage: "mic.slash").foregroundStyle(.orange)
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                Section("Not processed yet") {
                    ForEach(dumps.dumps, id: \.clientId) { note in
                        NavigationLink(value: note.clientId) {
                            VStack(alignment: .leading) {
                                Text(BrainDumpViewModel.title(for: note.content)).lineLimit(1)
                                Text(note.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { try? await notes.delete(note.clientId) }
                            }
                        }
                    }
                }
            }
            // The box is focused on open, so the keyboard covers the tab bar:
            // Done and a downward drag put it away.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .navigationTitle("Brain dump")
            .navigationDestination(for: String.self) { clientId in
                NoteEditorView(notes: notes, titler: titler, clientId: clientId)
            }
            .task { await notes.reload() }
            .onAppear { focused = true }
            .onChange(of: focusRequest) { focused = true }
        }
    }

    @ViewBuilder private var micButton: some View {
        switch draft.status {
        case .recording:
            Button("Stop", systemImage: "stop.circle.fill") {
                Task {
                    if let heard = await draft.stop() { text = BrainDumpViewModel.appending(heard, to: text) }
                }
            }
            .tint(.red)
        case .transcribing:
            ProgressView()
        case .idle:
            Button("Record", systemImage: "mic") { Task { await draft.record() } }
                .disabled(!draft.canRecord)
        }
    }

    private func save() {
        let content = text
        Task {
            do {
                try await dumps.save(content)
                if text == content { text = "" }
                saveError = nil
                focused = true
            } catch {
                saveError = "Could not save the dump. \(error.localizedDescription)"
            }
        }
    }
}
