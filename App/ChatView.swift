import RtechWhisperKit
import SwiftUI

/// The Chat tab, as the desktop's chat in native form: the saved
/// conversations under date headings, then the conversation pushed on top.
struct ChatView: View {
    let session: ChatSession
    let conversations: ChatConversationsViewModel
    let voiceDraft: VoiceDraft
    /// Opens a note in the Notes tab.
    let openNote: (String) -> Void
    @State private var path: [ChatRoute] = []
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var chatError: String?
    /// Where the user asked to go while this chat's last messages are not
    /// saved and a retry of the save failed: confirmed before they are lost.
    @State private var pendingLeave: LeaveTarget?
    /// True while a leave waits on its retried save; another tap meanwhile
    /// is ignored, so two leaves never race.
    @State private var leaving = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(conversations.groups()) { group in
                    Section(group.label) {
                        ForEach(group.conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isActive: session.conversation?.id == conversation.id,
                                isBusy: session.isBusy,
                                open: { open(conversation) },
                                rename: { beginRename(conversation) },
                                delete: { delete(conversation) })
                        }
                    }
                }
            }
            .overlay {
                if conversations.conversations.isEmpty && conversations.storeFailed {
                    // Not "no chats": the saved ones could not be read.
                    ContentUnavailableView {
                        Label("Chats could not be loaded", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved chats are still on this phone. Try again in a moment.")
                    } actions: {
                        Button("Try again") { Task { await conversations.reload() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if conversations.conversations.isEmpty && conversations.hasLoaded {
                    ContentUnavailableView {
                        Label("Start your first conversation", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Ask about your notes, have one written, or just talk.")
                    } actions: {
                        Button("New chat", action: startNew)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Chat")
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .conversation:
                    ChatConversationView(session: session, voiceDraft: voiceDraft, openNote: openNote)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil", action: startNew)
                        // Starting over would cut off the reply arriving now.
                        .disabled(session.isBusy)
                }
            }
            .refreshable { await conversations.reload() }
            .task { await conversations.reload() }
            // Back from a conversation, or a turn ended: the titles and
            // order may have changed.
            .onChange(of: path) { _, path in
                if path.isEmpty { Task { await conversations.reload() } }
            }
            .onChange(of: session.isBusy) { _, busy in
                if !busy { Task { await conversations.reload() } }
            }
            .alert("Rename chat", isPresented: showingRename) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    guard let conversation = renaming else { return }
                    renaming = nil
                    rename(conversation, to: renameText)
                }
            }
            .confirmationDialog(
                "This chat is not fully saved", isPresented: showingLeave, titleVisibility: .visible,
                presenting: pendingLeave
            ) { target in
                Button("Leave anyway", role: .destructive) {
                    pendingLeave = nil
                    leave(to: target)
                }
                Button("Stay", role: .cancel) { pendingLeave = nil }
            } message: { _ in
                Text("Its last messages could not be saved. Leaving it loses them.")
            }
            .alert("Chat", isPresented: showingChatError) {
                Button("OK", role: .cancel) { chatError = nil }
            } message: {
                Text(chatError ?? "")
            }
        }
    }

    private var showingRename: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var showingLeave: Binding<Bool> {
        Binding(get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } })
    }

    private var showingChatError: Binding<Bool> {
        Binding(get: { chatError != nil }, set: { if !$0 { chatError = nil } })
    }

    private func startNew() {
        confirmLeaving(to: .newChat)
    }

    /// Replacing the session drops messages it could not save. Tries the
    /// save again first; only if that fails too does it ask.
    private func confirmLeaving(to target: LeaveTarget) {
        guard !leaving else { return }
        guard session.saveFailed else { return leave(to: target) }
        leaving = true
        Task {
            defer { leaving = false }
            if await session.retrySave() {
                leave(to: target)
            } else {
                pendingLeave = target
            }
        }
    }

    private func leave(to target: LeaveTarget) {
        switch target {
        case .newChat:
            session.startNewConversation()
            path = [.conversation]
        case .conversation(let conversation):
            openSaved(conversation)
        }
    }

    /// Opens a saved conversation. While a reply is arriving only the
    /// conversation it belongs to can be shown; the others wait.
    private func open(_ conversation: ChatConversation) {
        if session.conversation?.id == conversation.id {
            path = [.conversation]
            return
        }
        guard !session.isBusy else { return }
        confirmLeaving(to: .conversation(conversation))
    }

    private func openSaved(_ conversation: ChatConversation) {
        Task {
            do {
                try await session.open(conversation.id)
                path = [.conversation]
            } catch {
                chatError = "That chat could not be opened. It may have been deleted."
                await conversations.reload()
            }
        }
    }

    private func beginRename(_ conversation: ChatConversation) {
        renameText = conversation.title
        renaming = conversation
    }

    /// Renames in the store, and on the conversation screen when it holds
    /// this chat, so its title does not stay old.
    private func rename(_ conversation: ChatConversation, to text: String) {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        Task {
            if let title = await conversations.rename(conversation.id, to: text) {
                session.renamed(conversation.id, to: title)
            } else if !blank {
                chatError = "That chat could not be renamed. Try again."
            }
        }
    }

    private func delete(_ conversation: ChatConversation) {
        Task {
            guard await conversations.delete(conversation.id) else {
                chatError = "That chat could not be deleted. Try again."
                return
            }
            // The screen still held it: the next send must not write to a
            // row that is gone.
            if session.conversation?.id == conversation.id, !session.isBusy {
                session.startNewConversation()
            }
        }
    }
}

/// Where the user asked to go from the conversation the session holds.
private enum LeaveTarget {
    case newChat
    case conversation(ChatConversation)
}

/// Where the Chat stack can go: the one conversation the session holds.
enum ChatRoute: Hashable {
    case conversation
}

/// One saved conversation, with rename and delete on swipe or long press.
private struct ConversationRow: View {
    let conversation: ChatConversation
    let isActive: Bool
    let isBusy: Bool
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive && isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isBusy && !isActive ? .secondary : .primary)
        .contextMenu { actions }
        .swipeActions(edge: .trailing) { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            .disabled(isActive && isBusy)
        Button("Rename", systemImage: "pencil", action: rename)
    }
}
