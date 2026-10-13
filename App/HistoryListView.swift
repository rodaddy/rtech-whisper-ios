import RtechWhisperKit
import SwiftUI

/// The Home tab's history: this phone's dictations, newest first, as the
/// desktop's history panel. Tap a row for the full text; swipe to delete.
struct HistoryRows: View {
    let history: HistoryViewModel
    @Binding var selected: TranscriptionRecord?

    var body: some View {
        if history.items.isEmpty {
            ContentUnavailableView(
                "No transcriptions yet",
                systemImage: "waveform",
                description: Text("Every dictation is saved here and synced through the hub.")
            )
            .listRowSeparator(.hidden)
        } else {
            ForEach(history.items, id: \.clientId) { item in
                Button {
                    selected = item
                } label: {
                    HistoryRow(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await history.delete(item.clientId) }
                    }
                }
            }
        }
        if let message = history.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

struct HistoryRow: View {
    let item: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HistoryFormatting.preview(item.text))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(HistoryFormatting.relativeTime(item.createdAt))
                if let duration = HistoryFormatting.duration(ms: item.audioDurationMs) {
                    Text("·")
                    Text(duration)
                }
                Spacer()
                if let provider = HistoryFormatting.providerLabel(item.provider) {
                    Text(provider)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if item.syncStatus == .pending {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityLabel("Waiting to sync")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// One transcription in full, with the Dictate card's two actions plus the
/// desktop's Copy raw (Whisper's words before cleanup) and Share.
struct HistoryDetailView: View {
    let item: TranscriptionRecord
    let notes: NotesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var saveStatus: SaveNoteStatus = .idle

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(item.createdAt, format: .dateTime.day().month().year().hour().minute())
                        if let duration = HistoryFormatting.duration(ms: item.audioDurationMs) {
                            Text("·")
                            Text(duration)
                        }
                        if let provider = HistoryFormatting.providerLabel(item.provider) {
                            Text("·")
                            Text(provider)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Text(item.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let message = saveStatus.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(saveStatus.isFailure ? .red : .secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ExportMenu(title: TextExport.historyTitle(item)) { _ in TextExport.historyText(item) }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = item.text
                    }
                    if let raw = HistoryFormatting.rawTextToCopy(item) {
                        Button("Copy raw", systemImage: "text.quote") {
                            UIPasteboard.general.string = raw
                        }
                    }
                    Spacer()
                    Button(
                        saveStatus.isSaved(item.text) ? "Saved as note" : "Save as note",
                        systemImage: "note.text.badge.plus"
                    ) {
                        // Set before the await, so a second tap is ignored.
                        guard let token = saveStatus.beginSaving(item.text) else { return }
                        Task {
                            do {
                                try await notes.saveAsNote(item.text)
                                saveStatus.finishSaving(token, error: nil)
                            } catch {
                                saveStatus.finishSaving(token, error: error)
                            }
                        }
                    }
                    .disabled(saveStatus.isSaving || saveStatus.isSaved(item.text))
                }
            }
        }
    }
}
