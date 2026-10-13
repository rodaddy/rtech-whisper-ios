import RtechWhisperKit
import SwiftUI

/// One transcript entry: a user bubble, or an assistant turn with the tool
/// rows above its reply and the note chips below it.
struct ChatEntryView: View {
    let entry: ChatTranscript.Entry
    /// True for the entry the session is working on now.
    let isLast: Bool
    let status: ChatSession.Status
    let openNote: (String) -> Void

    var body: some View {
        switch entry.message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.toolResults) { result in
                    ToolResultRow(result: result)
                }
                ForEach(entry.pendingCalls, id: \.id) { call in
                    PendingToolRow(call: call, running: isLast && (status == .runningTools || status == .streaming))
                }
                if !entry.message.content.isEmpty {
                    Text(entry.message.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                    if !(isLast && status == .streaming) {
                        SpeakButton(message: entry.message)
                    }
                } else if isLast && status == .streaming && entry.pendingCalls.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                if !entry.noteChips.isEmpty {
                    NoteChipsRow(chips: entry.noteChips, openNote: openNote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            // Tool messages hang under their assistant entry; none stands alone.
            EmptyView()
        }
    }
}

/// Reads a reply aloud; tapped again, stops it.
private struct SpeakButton: View {
    let message: ChatMessage
    @Environment(ReplySpeaker.self) private var speaker

    var body: some View {
        let active = speaker.speakingID == message.id
        Button {
            Task { await speaker.toggle(message) }
        } label: {
            if active && speaker.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: active ? "stop.circle" : "speaker.wave.2")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityLabel(active ? "Stop reading" : "Read aloud")
    }
}

/// A finished tool, in one line: what it did, or why it failed.
private struct ToolResultRow: View {
    let result: ChatMessage

    var body: some View {
        Label {
            Text(result.displayText ?? result.toolName ?? "Tool")
                .lineLimit(2)
        } icon: {
            Image(systemName: result.isError ? "exclamationmark.circle" : ToolStatus.symbol(result.toolName ?? ""))
        }
        .font(.caption)
        .foregroundStyle(result.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 4)
    }
}

/// A tool call still without a result: at work now, or cut off earlier.
private struct PendingToolRow: View {
    let call: LLMToolCall
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            if running {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: ToolStatus.symbol(call.name))
            }
            Text(running ? ToolStatus.running(call.name) : ToolStatus.interrupted(call.name))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// The notes a turn touched, each a tap away in the Notes tab.
private struct NoteChipsRow: View {
    let chips: [NoteChip]
    let openNote: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    Button {
                        openNote(chip.noteId)
                    } label: {
                        Label(chip.title, systemImage: "note.text")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }
}
