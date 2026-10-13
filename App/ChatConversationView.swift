import RtechWhisperKit
import SwiftUI

/// One conversation: the messages, the reply streaming in, the tools at
/// work, and the composer pinned at the bottom with Send, Stop, and a mic.
struct ChatConversationView: View {
    @Bindable var session: ChatSession
    let voiceDraft: VoiceDraft
    let openNote: (String) -> Void
    @Environment(ReplySpeaker.self) private var speaker
    @FocusState private var composing: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let entries = ChatTranscript.entries(session.messages)
                ForEach(entries) { entry in
                    ChatEntryView(
                        entry: entry, isLast: entry.id == entries.last?.id, status: session.status,
                        openNote: openNote)
                }
                footer
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if session.messages.isEmpty {
                ContentUnavailableView(
                    "Ask anything", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("The assistant can search your notes, read one, write a new one, or update it."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(session.conversation?.title ?? "New chat")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Leaving the screen throws away a take still open.
            voiceDraft.cancel()
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if case .failed(let error) = session.status {
            VStack(alignment: .leading, spacing: 6) {
                Notice(
                    text: (error.map { $0.userMessage + " " } ?? "The reply failed. ") + "Tap Retry to try again.",
                    systemImage: "exclamationmark.triangle", tint: .red)
                // Runs the turn again from the saved message: nothing is
                // sent twice.
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await speaker.turnEnded(await session.retry(), messages: session.messages) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.isBusy)
            }
        }
        if session.saveFailed {
            Notice(
                text: "This chat could not be saved. It may be missing messages after a relaunch.",
                systemImage: "externaldrive.badge.exclamationmark", tint: .orange)
        }
        if let failure = voiceDraft.failure {
            Notice(text: failure.userMessage, systemImage: "mic.slash", tint: .orange)
        }
        if let failure = speaker.failure {
            Notice(text: failure.userMessage, systemImage: "speaker.slash", tint: .orange)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            micButton
            TextField("Ask anything", text: $session.draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($composing)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit(send)
            sendButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var micButton: some View {
        switch voiceDraft.status {
        case .idle:
            Button("Dictate", systemImage: "mic.circle.fill") {
                speaker.stop()
                Task { await voiceDraft.record() }
            }
            .labelStyle(.iconOnly)
            .font(.title)
            // Also off while a dictation holds the microphone, or while
            // this take waits for permission.
            .disabled(session.isBusy || !voiceDraft.canRecord)
        case .recording:
            Button {
                Task { await stopDictating() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                    if let since = voiceDraft.recordingSince {
                        Text(since, style: .timer)
                            .font(.footnote.monospacedDigit())
                    }
                }
            }
            .tint(.red)
            .accessibilityLabel("Stop dictating")
        case .transcribing:
            ProgressView()
                .frame(width: 34, height: 34)
                .accessibilityLabel("Transcribing")
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isBusy {
            Button("Stop", systemImage: "stop.circle.fill") { session.cancel() }
                .labelStyle(.iconOnly)
                .font(.title)
                .tint(.red)
        } else {
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.title)
                .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceDraft.status != .idle)
        }
    }

    private func send() {
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isBusy else { return }
        session.draft = ""
        // A new message stops the reply being read; the answer to this one
        // is read when the turn ends, if Read replies aloud is on.
        speaker.stop()
        Task { await speaker.turnEnded(await session.send(text), messages: session.messages) }
    }

    /// The take's text lands in the composer after what is already typed,
    /// as the desktop's voice draft does; nothing is sent until Send. It
    /// goes to the session, so a take that finishes after Back is kept --
    /// unless another chat was started or opened meanwhile: then it is
    /// dropped, never written into that chat's draft.
    private func stopDictating() async {
        let generation = session.draftGeneration
        guard let text = await voiceDraft.stop() else { return }
        guard session.appendDictation(text, generation: generation) else { return }
        composing = true
    }
}

/// One line under the messages: an error, or a warning.
private struct Notice: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ReplySpeaker.Failure {
    var userMessage: String {
        switch self {
        case .audioBusy: "A dictation is using the audio. Try again when it ends."
        case .synthesis(let error): "Could not read the reply aloud. \(error.userMessage)"
        case .playback(let detail): "Could not play the reply. \(detail)"
        }
    }
}

extension VoiceDraft.Failure {
    /// One line a person can read.
    var userMessage: String {
        switch self {
        case .microphoneDenied: "Microphone access is off. Turn it on in Settings."
        case .microphoneBusy: "A dictation is using the microphone. Try again when it ends."
        case .recorderFailed(let detail): "Could not start recording. \(detail)"
        case .nothingRecorded: "Nothing was recorded."
        case .noSpeech: "No speech heard."
        case .transcription(let error): "Dictation failed. \(error.userMessage)"
        }
    }
}
