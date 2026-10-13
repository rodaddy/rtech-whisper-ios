import RtechWhisperKit
import SwiftUI
import UIKit

/// The app shell: the same places the desktop sidebar leads to, in iPhone
/// form. Home dictates, Notes is the notebook, Chat talks to the agent, More
/// holds the rest.
struct ContentView: View {
    let connection: HubConnection
    let dictation: DictationController
    let notes: NotesViewModel
    let history: HistoryViewModel
    let aiSettings: AISettingsStore
    let appSettings: AppSettingsStore
    let titler: NoteAutoTitler
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let upload: UploadJob
    let launch: DictationLaunch
    let dumpLaunch: BrainDumpLaunch
    let keyboard: KeyboardDictation
    let chat: ChatSession
    let chats: ChatConversationsViewModel
    let voiceDraft: VoiceDraft
    let dumpDraft: VoiceDraft
    @Environment(ReplySpeaker.self) private var speaker
    @State private var showsSettings = false
    @State private var selectedTab: AppTab = .home
    /// The Notes stack, owned here so a note chip in Chat can open a note.
    @State private var notesPath = NavigationPath()
    /// The Brain dump box, owned here so a take ended by the app leaving the
    /// screen still lands in it.
    @State private var dumpText = ""
    /// Bumped to focus the Brain dump box when an intent opens it.
    @State private var dumpFocus = 0
    /// The Brain dump tab's stack, reset when an intent opens the tab.
    @State private var dumpPath = NavigationPath()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(connection: connection, dictation: dictation, notes: notes, history: history)
                        .navigationTitle(AppInfo.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Settings", systemImage: "gearshape") {
                                    showsSettings = true
                                }
                            }
                        }
                }
            }
            Tab("Notes", systemImage: "note.text", value: AppTab.notes) {
                NotesView(notes: notes, titler: titler, path: $notesPath)
            }
            Tab("Brain dump", systemImage: "brain.head.profile", value: AppTab.brainDump) {
                BrainDumpView(notes: notes, titler: titler, draft: dumpDraft, text: $dumpText, path: $dumpPath, focusRequest: dumpFocus)
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.chat) {
                ChatView(session: chat, conversations: chats, voiceDraft: voiceDraft, openNote: openNote)
            }
            Tab("More", systemImage: "ellipsis.circle", value: AppTab.more) {
                MoreView(dictionary: dictionary, snippets: snippets, upload: upload, notes: notes, showsSettings: $showsSettings)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(connection: connection, ai: aiSettings, app: appSettings)
        }
        .task { await connection.restore() }
        // Siri, Shortcuts, the Action button, or Control Center asked to
        // dictate: go to Home and record, like the desktop hotkey.
        .onChange(of: launch.isPending, initial: true) { _, pending in
            guard pending else { return }
            // One microphone owner: close a composer take now, before the
            // dictation starts, not later in the Chat screen's onDisappear.
            voiceDraft.cancel()
            dumpDraft.cancel()
            speaker.stop()
            selectedTab = .home
            showsSettings = false
            if launch.consume(isRecording: dictation.state == .recording) {
                Task {
                    await dictation.record()
                    // The microphone did not open (access off): end a
                    // keyboard take waiting for it. A failure left from an
                    // earlier take does not end it; only this one does.
                    if case .failed = dictation.state { keyboard.recordDidNotStart() }
                }
            }
        }
        // The Action button, Siri, or Control Center asked for a brain dump:
        // open the tab with the box focused. Nothing records.
        .onChange(of: dumpLaunch.isPending, initial: true) { _, pending in
            guard pending, dumpLaunch.consume() else { return }
            showsSettings = false
            selectedTab = .brainDump
            dumpPath = NavigationPath()
            dumpFocus += 1
        }
        // The keyboard's mic key: record here, then hand the text back.
        .onOpenURL { url in
            guard let route = KeyboardRoute(url: url) else { return }
            // One recording at a time: a take already running is not taken
            // over; the hint asks the person to finish it first.
            guard keyboard.begin(route, currentTake: dictation.latest?.id, isRecording: dictation.state == .recording)
            else { return }
            launch.request()
            feedKeyboard()
        }
        // From stop until the text is in the App Group, keep running after a
        // swipe back, so the handoff does not stall in the background.
        .onChange(of: keyboard.isHandingOff) { _, handingOff in
            guard handingOff else { return }
            Task {
                await BackgroundTaskScope.run(
                    begin: { onExpire in
                        let id = UIApplication.shared.beginBackgroundTask(withName: "Keyboard", expirationHandler: onExpire)
                        return id == .invalid ? nil : id
                    },
                    end: { UIApplication.shared.endBackgroundTask($0) },
                    { await keyboard.finished() })
            }
        }
        // A spoken brain dump runs hands-free, often longer than Auto-Lock:
        // keep the screen on while the dump mic records.
        .onChange(of: dumpDraft.status) { _, status in
            UIApplication.shared.isIdleTimerDisabled = status == .recording
        }
        // Leaving the app ends a dump take, but keeps it: the take is
        // transcribed and added to the box, never thrown away.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, dumpDraft.status == .recording else { return }
            Task {
                await UploadView.inBackgroundTask {
                    if let heard = await dumpDraft.stop() {
                        dumpText = BrainDumpViewModel.appending(heard, to: dumpText)
                    }
                }
            }
        }
        .onChange(of: dictation.state) { feedKeyboard() }
        .onChange(of: dictation.latestText) { feedKeyboard() }
        .overlay(alignment: .top) {
            if let hint = keyboard.returnHint {
                Button(hint, systemImage: "arrow.uturn.backward") { keyboard.dismissHint() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .onChange(of: connection.state) { _, state in
            // A key just connected: sync can start.
            if case .connected = state {
                Task { await history.refresh() }
            }
        }
    }

    /// Tell the keyboard take what dictation is doing; once its text is
    /// handed over, go back to the app the person was typing in.
    private func feedKeyboard() {
        let step = keyboard.update(state: dictation.state, text: dictation.latestText, take: dictation.latest?.id)
        guard case .handedOff(let url?) = step else { return }
        openURL(url) { accepted in
            if !accepted { keyboard.returnFailed() }
        }
    }

    /// A note chip in Chat: show the note in the Notes tab, inside its
    /// folder so Back reads naturally. A note no longer on the phone opens
    /// the All notes list instead. The notes may not be loaded yet (Notes
    /// not visited since launch), so a miss reloads them once and looks again.
    private func openNote(_ clientId: String) {
        Task {
            var found = notes.note(clientId)
            if found == nil {
                await notes.reload()
                found = notes.note(clientId)
            }
            var path = NavigationPath()
            if let note = found {
                path.append(NotesRoute.folder(note.folderClientId))
                path.append(NotesRoute.note(clientId))
            } else {
                path.append(NotesRoute.folder(nil))
            }
            notesPath = path
            selectedTab = .notes
        }
    }
}

extension HubError {
    /// One line a person can read.
    var userMessage: String {
        switch self {
        case .malformedKey:
            "That is not a device key. Keys start with rtw_ and are 47 characters."
        case .unauthorized:
            "The hub does not accept this key. It may have been revoked."
        case .network(let detail):
            "Could not reach the hub. \(detail)"
        case .server(let status, _, let message):
            "The hub returned \(status)\(message.map { ": \($0)" } ?? ".")"
        case .decoding:
            "The hub sent a reply this app does not understand."
        case .tooLarge:
            "The recording is larger than the hub accepts."
        case .unsupportedAudio:
            "The hub did not accept the audio format."
        case .rateLimited:
            "The hub is busy. Try again in a moment."
        case .upstreamUnavailable:
            "The hub or its transcription service is unavailable right now."
        case .noteVersionConflict:
            "This note changed on another device. Reload it and try again."
        case .folderNameTaken:
            "A folder with that name already exists."
        case .snippetTriggerTaken:
            "Another snippet already uses that trigger."
        case .notFound:
            "The hub no longer has that item."
        case .invalidRequest(let message):
            "The hub rejected the request\(message.map { ": \($0)" } ?? ".")"
        }
    }
}
