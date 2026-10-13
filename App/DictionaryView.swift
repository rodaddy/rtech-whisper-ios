import RtechWhisperKit
import SwiftUI

/// The custom dictionary: words Whisper should know. Type to add, swipe to
/// delete, tap to edit. The list narrows to words matching what is typed,
/// as the desktop's does.
struct DictionaryView: View {
    let store: DictionaryStore
    @State private var newWord = ""
    @State private var editing: String?
    @State private var editValue = ""
    @State private var editError: String?
    @FocusState private var addFieldFocused: Bool

    private var visibleWords: [String] {
        let needle = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.words }
        return store.words.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Add a word", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($addFieldFocused)
                        .onSubmit(add)
                    Button("Add", systemImage: "plus.circle.fill", action: add)
                        .labelStyle(.iconOnly)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Words are sent to Whisper as a spelling hint with every transcription. They sync with your Mac through the hub.")
            }

            if store.words.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Words Yet", systemImage: "book",
                        description: Text("Add names and terms Whisper gets wrong.")
                    )
                }
            } else if visibleWords.isEmpty {
                Section {
                    Text("No words match “\(newWord.trimmingCharacters(in: .whitespaces))”.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(store.words.count == 1 ? "1 word" : "\(store.words.count) words") {
                    ForEach(visibleWords, id: \.self) { word in
                        Button(word) { startEdit(word) }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.remove(word) }
                                Button("Edit", systemImage: "pencil") { startEdit(word) }
                                    .tint(.accentColor)
                            }
                    }
                }
            }
        }
        .navigationTitle("Dictionary")
        .alert("Edit Word", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Word", text: $editValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save", action: commitEdit)
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .alert("Could Not Save", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK") { editError = nil }
        } message: {
            Text(editError ?? "")
        }
    }

    private func add() {
        if store.add(newWord) > 0 {
            newWord = ""
        }
        addFieldFocused = true
    }

    private func startEdit(_ word: String) {
        editValue = word
        editing = word
    }

    private func commitEdit() {
        guard let word = editing else { return }
        editing = nil
        do {
            try store.edit(word, to: editValue)
        } catch {
            editError = error.userMessage
        }
    }
}

private extension DictionaryError {
    var userMessage: String {
        switch self {
        case .emptyWord: "A word cannot be blank."
        case .duplicate(let word): "“\(word)” is already in the dictionary."
        }
    }
}
