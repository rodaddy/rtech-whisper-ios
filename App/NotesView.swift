import RtechWhisperKit
import SwiftUI

/// The Notes tab, as the desktop's notes in native form: a folder list, the
/// notes in a folder, then the editor pushed on top.
struct NotesView: View {
    @Bindable var notes: NotesViewModel
    let titler: NoteAutoTitler
    /// The stack, owned by the shell so other tabs can push a note.
    @Binding var path: NavigationPath
    @State private var newFolderName: String?
    @State private var renaming: FolderRecord?
    @State private var renameText = ""
    @State private var folderError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: NotesRoute.folder(nil)) {
                        FolderRow(name: "All notes", systemImage: "tray.full", count: notes.allNotes.count)
                    }
                }
                Section {
                    ForEach(notes.folders, id: \.clientId) { folder in
                        FolderLink(notes: notes, folder: folder, rename: beginRename, delete: delete)
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    SyncFooter(notes: notes)
                }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: NotesRoute.self) { route in
                switch route {
                case .folder(let folderId):
                    NoteListView(notes: notes, folderId: folderId)
                case .note(let clientId):
                    NoteEditorView(notes: notes, titler: titler, clientId: clientId)
                }
            }
            .refreshable { await notes.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New folder", systemImage: "folder.badge.plus") { newFolderName = "" }
                }
            }
            .alert("New folder", isPresented: showingNewFolder) {
                TextField("Name", text: newFolderText)
                Button("Cancel", role: .cancel) { newFolderName = nil }
                Button("Create") {
                    let name = newFolderName ?? ""
                    newFolderName = nil
                    run { try await notes.createFolder(name: name) }
                }
            }
            .alert("Rename folder", isPresented: showingRename) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    guard let folder = renaming else { return }
                    renaming = nil
                    run { try await notes.renameFolder(folder.clientId, to: renameText) }
                }
            }
            .alert("Folder", isPresented: showingError) {
                Button("OK", role: .cancel) { folderError = nil }
            } message: {
                Text(folderError ?? "")
            }
            .task { await notes.ensureDefaultFolders() }
        }
    }

    private var showingNewFolder: Binding<Bool> {
        Binding(get: { newFolderName != nil }, set: { if !$0 { newFolderName = nil } })
    }

    private var newFolderText: Binding<String> {
        Binding(get: { newFolderName ?? "" }, set: { newFolderName = $0 })
    }

    private var showingRename: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var showingError: Binding<Bool> {
        Binding(get: { folderError != nil }, set: { if !$0 { folderError = nil } })
    }

    private func beginRename(_ folder: FolderRecord) {
        renameText = folder.name
        renaming = folder
    }

    private func delete(_ folder: FolderRecord) {
        run { try await notes.deleteFolder(folder.clientId) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch let error as NotesViewModel.FolderError {
                folderError = error.userMessage
            } catch {
                folderError = "The notes store could not be written."
            }
        }
    }
}

/// Where the Notes stack can go.
enum NotesRoute: Hashable {
    /// The notes in a folder; `nil` is every folder.
    case folder(String?)
    case note(String)
}

/// One folder in the list, with rename and delete on swipe or long press.
private struct FolderLink: View {
    let notes: NotesViewModel
    let folder: FolderRecord
    let rename: (FolderRecord) -> Void
    let delete: (FolderRecord) -> Void

    var body: some View {
        NavigationLink(value: NotesRoute.folder(folder.clientId)) {
            FolderRow(
                name: folder.name, systemImage: folder.isDefault ? "folder.fill" : "folder",
                count: notes.noteCount(inFolder: folder.clientId))
        }
        .contextMenu { actions }
        .swipeActions(edge: .trailing) { actions }
    }

    @ViewBuilder
    private var actions: some View {
        if notes.canDelete(folder) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(folder) }
        }
        Button("Rename", systemImage: "pencil") { rename(folder) }
    }
}

private struct FolderRow: View {
    let name: String
    let systemImage: String
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(name)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

struct SyncFooter: View {
    let notes: NotesViewModel

    var body: some View {
        switch notes.syncState {
        case .off:
            Text("Sync is off until a device key is connected. Notes stay on this phone.")
        case .syncing:
            Text("Syncing…")
        case .failed(let error):
            Text("Sync failed: \(error?.userMessage ?? "the notes store could not be read.")")
        case .idle:
            if let last = notes.lastSyncedAt {
                Text("Synced \(last, style: .relative) ago")
            } else {
                Text("Not synced yet. Pull down to sync.")
            }
        }
    }
}

extension NotesViewModel.FolderError {
    var userMessage: String {
        switch self {
        case .cannotDeleteDefault: "The Personal folder is the default and cannot be deleted."
        case .nameTaken(let name): "A folder named \(name) already exists."
        case .emptyName: "Give the folder a name."
        }
    }
}
