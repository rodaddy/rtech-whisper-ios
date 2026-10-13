import RtechWhisperKit
import SwiftUI

/// The notes in one folder (or every folder), in the order dragged into on
/// this phone (Edit; new notes on top), searched on the phone over title,
/// content, and transcript. Swipe a row to delete it.
struct NoteListView: View {
    @Bindable var notes: NotesViewModel
    /// `nil` lists every folder.
    let folderId: String?
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(visibleNotes, id: \.clientId) { note in
                NavigationLink(value: NotesRoute.note(note.clientId)) {
                    NoteRow(note: note, waiting: notes.isWaitingToSync(note.clientId),
                            conflicted: notes.conflict(for: note.clientId) != nil)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { visibleNotes[$0].clientId }
                Task {
                    for id in ids { try? await notes.delete(id) }
                }
            }
            .onMove(perform: searchText.isEmpty ? { notes.move(inFolder: folderId, from: $0, to: $1) } : nil)
        }
        .overlay {
            if visibleNotes.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No notes" : "No matches",
                    systemImage: "note.text")
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: "Search notes")
        .refreshable { await notes.syncNow() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New note", systemImage: "square.and.pencil") {
                    Task { _ = try? await notes.create(folderClientId: folderId) }
                }
            }
        }
        // New notes made from here file into this folder.
        .onAppear { notes.selectedFolderId = folderId }
    }

    private var visibleNotes: [NoteRecord] {
        searchText.isEmpty ? notes.orderedNotes(inFolder: folderId) : notes.search(searchText, inFolder: folderId)
    }

    private var title: String {
        guard let folderId else { return "All notes" }
        return notes.folders.first { $0.clientId == folderId }?.name ?? "Notes"
    }
}

private struct NoteRow: View {
    let note: NoteRecord
    let waiting: Bool
    let conflicted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                if !note.preview().isEmpty {
                    Text(note.preview())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if conflicted {
                Label("Changed on the Mac too", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if waiting {
                Label("Saved on phone, waiting to sync", systemImage: "icloud.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
