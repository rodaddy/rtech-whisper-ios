import RtechWhisperKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pick an audio file, watch it transcribe, read the text, keep it. The
/// desktop's Upload view in iPhone form: the text is saved to the history as
/// soon as it arrives; "Save as note" makes the desktop's `upload` note.
struct UploadView: View {
    let upload: UploadJob
    let notes: NotesViewModel
    @State private var showsPicker = false
    @State private var saveStatus: SaveNoteStatus = .idle

    private static let fileTypes = AudioFileDecoder.fileExtensions.compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        Group {
            switch upload.state {
            case .idle:
                ContentUnavailableView {
                    Label("Upload Audio", systemImage: "square.and.arrow.up")
                } description: {
                    Text("Transcribe a recording from your files. " + Self.fileTypeList + ".")
                } actions: {
                    chooseButton("Choose File")
                }
            case .decoding(let fileName):
                progress(fileName: fileName, line: "Reading the file…", fraction: nil)
            case .transcribing(let fileName, let chunk, let count):
                progress(
                    fileName: fileName,
                    line: count > 1 ? "Transcribing part \(chunk) of \(count)…" : "Transcribing…",
                    fraction: upload.progress)
            case .done(let result):
                resultView(result)
            case .failed(let fileName, let failure):
                ContentUnavailableView {
                    Label("Upload Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(fileName).font(.footnote).foregroundStyle(.secondary)
                    Text(failure.userMessage)
                } actions: {
                    if upload.canResume {
                        Button("Resume", systemImage: "arrow.clockwise") {
                            Task { await Self.inBackgroundTask { await upload.resume() } }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    chooseButton("Try Another File")
                }
            }
        }
        .navigationTitle("Upload")
        .fileImporter(isPresented: $showsPicker, allowedContentTypes: Self.fileTypes) { picked in
            guard case .success(let url) = picked else { return }
            // No reset first: `run` drops a stopped upload itself, and refuses
            // while a result not saved is kept, so picking never discards one.
            guard !upload.isSavingResult, !upload.holdsUnsavedResult else { return }
            saveStatus = .idle
            Task { await Self.inBackgroundTask { await upload.run(url: url) } }
        }
    }

    /// Runs `work` as a background task, so leaving the app for a moment
    /// does not fail the upload in flight. When the background time runs out
    /// the task is ended, so iOS suspends the app rather than terminating it;
    /// a chunk cut off that way fails as a hub error the user can resume.
    static func inBackgroundTask(_ work: () async -> Void) async {
        await BackgroundTaskScope.run(
            begin: { onExpire in
                let id = UIApplication.shared.beginBackgroundTask(withName: "Upload", expirationHandler: onExpire)
                return id == .invalid ? nil : id
            },
            end: { UIApplication.shared.endBackgroundTask($0) },
            work)
    }

    private func chooseButton(_ title: String) -> some View {
        Button(title, systemImage: "folder") { showsPicker = true }
            .buttonStyle(.borderedProminent)
            .disabled(upload.isRunning)
    }

    private func progress(fileName: String, line: String, fraction: Double?) -> some View {
        VStack(spacing: 16) {
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)
            } else {
                ProgressView()
            }
            Text(line).font(.headline)
            Text(fileName).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ result: UploadResult) -> some View {
        List {
            Section {
                LabeledContent("File", value: result.fileName)
                if let duration = HistoryFormatting.duration(ms: result.durationMs) {
                    LabeledContent("Length", value: duration)
                }
            }
            Section {
                if result.noSpeech {
                    Text("No speech was heard in this file.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(result.text)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Transcript")
            } footer: {
                if result.truncated {
                    Text(
                        "The file could not be read to the end. This is the text of all the audio before that point, and the length is that part's."
                            + (result.truncationReason.map { " \($0)" } ?? "")
                    )
                }
            }
            if !result.text.isEmpty {
                Section {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = result.text
                    }
                    Button(
                        saveStatus.isSaved(result.text) ? "Saved as Note" : "Save as Note",
                        systemImage: "note.text.badge.plus"
                    ) {
                        // Set before the await, so a second tap is ignored.
                        guard let token = saveStatus.beginSaving(result.text) else { return }
                        Task {
                            do {
                                try await notes.saveUploadNote(result)
                                saveStatus.finishSaving(token, error: nil)
                            } catch {
                                saveStatus.finishSaving(token, error: error)
                            }
                        }
                    }
                    .disabled(saveStatus.isSaving || saveStatus.isSaved(result.text))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let message = saveStatus.message {
                            Text(message).foregroundStyle(saveStatus.isFailure ? .red : .secondary)
                        }
                        historyLine
                    }
                }
            }
            Section {
                chooseButton("Upload Another File")
                    .buttonStyle(.borderless)
                    .disabled(upload.isSavingResult || upload.holdsUnsavedResult)
                if case .notSaved(let kept) = upload.saveOutcome {
                    if kept {
                        Button("Retry Now", systemImage: "arrow.clockwise") {
                            Task { await upload.retrySave() }
                        }
                        .disabled(upload.isRetryingSave)
                    }
                    // Kept: deletes the kept upload, so no launch replays it.
                    // Not kept: only clears the screen.
                    Button("Discard", systemImage: "trash", role: .destructive) {
                        saveStatus = .idle
                        upload.reset()
                    }
                    .disabled(upload.isRetryingSave)
                }
                if upload.saveOutcome == .incomplete(kept: true) || upload.saveOutcome == .partial {
                    // Deletes the kept upload, so no later retry runs it.
                    Button("Remove from Queue", systemImage: "trash", role: .destructive) {
                        saveStatus = .idle
                        upload.reset()
                    }
                }
            } footer: {
                if upload.holdsUnsavedResult {
                    Text("Discard or retry the unsaved result first.")
                }
            }
        }
    }

    /// Whether the text reached the history, read only from `saveOutcome`;
    /// nothing while it is still being saved.
    @ViewBuilder private var historyLine: some View {
        switch upload.saveOutcome {
        case .saved:
            Text("Saved to your transcription history.")
        case .notSaved(kept: true):
            Text("Not saved to your transcription history. It will be saved again next time the app opens.")
                .foregroundStyle(.red)
        case .notSaved(kept: false):
            Text("Not saved: copy the text now; it cannot be retried.")
                .foregroundStyle(.red)
        case .incomplete(kept: true):
            Text("Incomplete: not saved to your transcription history. It will be retried when you next open the app.")
                .foregroundStyle(.red)
        case .incomplete(kept: false):
            Text("Incomplete: not saved to your transcription history; copy the text now.")
                .foregroundStyle(.red)
        case .partial:
            Text("Incomplete: a retry read no further, so it will not be retried. Not saved to your transcription history; copy the text, then remove it.")
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    /// "M4A, MP3, WAV, CAF, AAC"
    private static var fileTypeList: String {
        AudioFileDecoder.fileExtensions.map { $0.uppercased() }.joined(separator: ", ")
    }
}

private extension UploadFailure {
    var userMessage: String {
        switch self {
        case .unreadable(let detail): "Could not read this audio file. \(detail)"
        case .emptyAudio: "This file holds no audio."
        case .tooLong(let maxSeconds): "This file is too long. Upload up to \(UploadFailure.limitText(seconds: maxSeconds)) at a time."
        case .hub(let error): error.userMessage
        }
    }
}
