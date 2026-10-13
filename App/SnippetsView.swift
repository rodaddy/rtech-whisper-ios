import RtechWhisperKit
import SwiftUI

/// Snippets: say a trigger while dictating and it is replaced with the saved
/// text. List, add, edit, and delete, as on the desktop's Snippets view. The
/// field at the top narrows the list to snippets matching what is typed.
struct SnippetsView: View {
    let store: SnippetStore
    @State private var search = ""
    /// The snippet being edited, or a blank one being added.
    @State private var draft: Draft?

    private var visible: [SnippetEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return store.snippets }
        return store.snippets.filter {
            $0.trigger.lowercased().contains(needle) || $0.replacement.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Search snippets", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Say a trigger while dictating and it becomes the saved text. Snippets sync with your Mac through the hub.")
            }

            if store.snippets.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Snippets Yet", systemImage: "text.badge.plus",
                        description: Text("Add a trigger like “my signoff” and the text it stands for.")
                    )
                }
            } else if visible.isEmpty {
                Section {
                    Text("No snippets match “\(search.trimmingCharacters(in: .whitespaces))”.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(store.snippets.count == 1 ? "1 snippet" : "\(store.snippets.count) snippets") {
                    ForEach(visible) { snippet in
                        Button { draft = Draft(snippet) } label: { row(snippet) }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.remove(snippet.clientId) }
                                Button("Edit", systemImage: "pencil") { draft = Draft(snippet) }
                                    .tint(.accentColor)
                            }
                    }
                }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Snippet", systemImage: "plus") { draft = Draft() }
            }
        }
        .sheet(item: $draft) { draft in
            SnippetEditor(store: store, draft: draft)
        }
    }

    private func row(_ snippet: SnippetEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(snippet.trigger).font(.headline)
                if snippet.syncStatus == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Not synced: another snippet on the hub uses this trigger")
                }
            }
            Text(snippet.replacement)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// What the editor sheet opens with: an existing snippet, or none for a new one.
private struct Draft: Identifiable {
    let id = UUID()
    var clientId: String?
    var trigger = ""
    var replacement = ""

    init() {}

    init(_ snippet: SnippetEntry) {
        clientId = snippet.clientId
        trigger = snippet.trigger
        replacement = snippet.replacement
    }
}

private struct SnippetEditor: View {
    let store: SnippetStore
    @State var draft: Draft
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Trigger", text: $draft.trigger)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Trigger")
                } footer: {
                    Text("The words you say, matched as whole words in any case.")
                }
                Section("Text") {
                    TextField("What the trigger becomes", text: $draft.replacement, axis: .vertical)
                        .lineLimit(3...10)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(draft.clientId == nil ? "New Snippet" : "Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        do {
            if let clientId = draft.clientId {
                try store.edit(clientId, trigger: draft.trigger, replacement: draft.replacement)
            } else {
                try store.add(trigger: draft.trigger, replacement: draft.replacement)
            }
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}

private extension SnippetError {
    var userMessage: String {
        switch self {
        case .emptyTrigger: "A trigger cannot be blank."
        case .emptyReplacement: "The text cannot be blank."
        case .triggerTooLong: "A trigger can be at most \(SnippetStore.triggerLimit) characters."
        case .duplicate(let trigger): "“\(trigger)” is already a snippet trigger."
        }
    }
}
