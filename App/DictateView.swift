import RtechWhisperKit
import SwiftUI
import UIKit

/// Record, see and edit the text, copy it, and see what is still waiting for
/// the hub. Each text is marked with where it came from.
struct DictateView: View {
    let dictation: DictationController
    let notes: NotesViewModel
    let history: HistoryViewModel
    @State private var saveStatus: SaveNoteStatus = .idle
    /// The Undo window after Delete (#472).
    @State private var pendingDelete = PendingDelete()
    /// The text box; Done, Record and a swipe on Home put the keyboard away.
    @FocusState private var textFocused: Bool
    /// Brand garnet, pinned so the Record fill stays garnet when the dark-mode accent is gold.
    private static let garnet = Color(red: 0x64 / 255, green: 0x12 / 255, blue: 0x20 / 255)

    var body: some View {
        VStack(spacing: 12) {
            Button {
                textFocused = false
                Task {
                    if dictation.state == .recording {
                        await dictation.stop()
                    } else {
                        await dictation.record()
                    }
                }
            } label: {
                Label(
                    dictation.state == .recording ? "Stop" : "Record",
                    systemImage: dictation.state == .recording ? "stop.circle.fill" : "mic.circle.fill"
                )
                .font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .tint(dictation.state == .recording ? .red : Self.garnet)

            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let notice = dictation.onDeviceNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let notice = dictation.cleanupNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if pendingDelete.take != nil {
                HStack {
                    Text("Dictation deleted.")
                        .foregroundStyle(.secondary)
                    Button("Undo") { pendingDelete.undo() }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            } else if let latest = dictation.latest, let text = latest.text {
                VStack(alignment: .leading, spacing: 4) {
                    Text(latest.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "No speech heard.",
                        text: Binding(get: { dictation.latestText ?? "" }, set: { dictation.edit($0) }),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    if let alternate = latest.alternateText ?? latest.rawBehindCleanup {
                        Text("Whisper heard: \(alternate)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button("Copy") { UIPasteboard.general.string = text }
                        .disabled(text.isEmpty)
                    Button(saveStatus.isSaved(text) ? "Saved as note" : "Save as note") {
                        // Set before the await, so a second tap is ignored.
                        guard let token = saveStatus.beginSaving(text) else { return }
                        Task {
                            do {
                                try await notes.saveAsNote(text)
                                saveStatus.finishSaving(token, error: nil)
                            } catch {
                                saveStatus.finishSaving(token, error: error)
                            }
                        }
                    }
                    .disabled(text.isEmpty || saveStatus.isSaving || saveStatus.isSaved(text))
                    Button("Delete", role: .destructive) {
                        let take = latest.id
                        Task {
                            await pendingDelete.start(take) {
                                await dictation.delete(
                                    take: take, history: history, handoff: PendingTranscriptStore.shared())
                            }
                        }
                    }
                    .disabled(dictation.state == .recording)
                }
                // Borderless, or a List row fires every button in it on one tap.
                .buttonStyle(.borderless)
                if let message = saveStatus.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(saveStatus.isFailure ? .red : .secondary)
                }
            }

            if !dictation.waiting.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting to send: \(dictation.waiting.count)")
                        .font(.headline)
                    ForEach(dictation.waiting) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.createdAt, style: .time)
                                Spacer()
                                Text(item.state.label)
                                    .foregroundStyle(.secondary)
                            }
                            if let text = item.text {
                                Text("\(text) (\(item.sourceLabel))")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A new take, from any trigger, ends the Undo window and deletes now.
        .onChange(of: dictation.state) { _, state in
            if state == .recording { Task { await pendingDelete.commit() } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { textFocused = false }
            }
        }
    }

    private var statusLine: String {
        switch dictation.state {
        case .idle: "Tap Record to dictate."
        case .recording: "Recording…"
        case .queued: "Saved on this phone. It sends when the hub is reachable."
        case .cleaning: "Cleaning up…"
        case .done: "Transcribed."
        case .failed(let reason): reason
        }
    }
}

private extension QueuedDictation {
    /// Whisper's own words when cleanup changed them and no edit hides them,
    /// so the person can check what the model did.
    var rawBehindCleanup: String? {
        guard editedText == nil, wasCleaned else { return nil }
        return whisperText
    }
}

private extension QueuedDictation.State {
    var label: String {
        switch self {
        case .pending: "Waiting"
        case .sending: "Sending…"
        case .failed(let reason): "Failed: \(reason)"
        case .done: "Done"
        }
    }
}
