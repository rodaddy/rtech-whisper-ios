import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity for a take in progress: Recording with the elapsed time,
/// then Transcribing, then the first line of the result (or the error) for a
/// moment before it goes away. Compact, minimal, and expanded in the Dynamic
/// Island, plus the Lock Screen banner. The expanded view and the banner have
/// a Stop button while recording.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            DictationLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseSymbol(phase: context.state.phase)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                        if let message = context.state.message {
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseTrailing(state: context.state)
                        .font(.headline)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .recording {
                        StopButton()
                            .padding(.top, 4)
                    }
                }
            } compactLeading: {
                PhaseSymbol(phase: context.state.phase)
                    .padding(.leading, 2)
            } compactTrailing: {
                PhaseTrailing(state: context.state)
                    .font(.caption.monospacedDigit())
                    .padding(.trailing, 2)
            } minimal: {
                PhaseSymbol(phase: context.state.phase)
            }
            .keylineTint(RtechAccent.gold)
        }
    }
}

/// The Lock Screen banner, also shown on the Home Screen when the island is
/// not available.
private struct DictationLockScreenView: View {
    let state: DictationActivityAttributes.ContentState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            PhaseSymbol(phase: state.phase)
                .font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.headline)
                if let message = state.message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if state.phase == .recording {
                StopButton()
            } else {
                PhaseTrailing(state: state)
                    .font(.headline)
            }
        }
        .padding()
        .activityBackgroundTint(nil)
        .activitySystemActionForegroundColor(RtechAccent.color(for: colorScheme))
    }
}

/// The symbol for each phase, in the rTech accent. The waveform pulses while
/// the microphone is open, like the desktop pill.
private struct PhaseSymbol: View {
    let phase: DictationActivityAttributes.ContentState.Phase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch phase {
            case .recording:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
            case .transcribing:
                Image(systemName: "ellipsis.bubble")
                    .symbolEffect(.pulse, isActive: true)
            case .done:
                Image(systemName: "checkmark.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .foregroundStyle(RtechAccent.color(for: colorScheme))
    }
}

/// The right-hand side: the running time while recording, a spinner while
/// transcribing, nothing once the take has ended.
private struct PhaseTrailing: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .frame(minWidth: 44)
                .multilineTextAlignment(.trailing)
        case .transcribing:
            ProgressView()
                .tint(.secondary)
        case .done, .failed:
            EmptyView()
        }
    }
}

/// Stops the recording without opening the app.
private struct StopButton: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(intent: StopDictationIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(RtechAccent.color(for: colorScheme))
    }
}

private extension DictationActivityAttributes.ContentState {
    var title: String {
        switch phase {
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .done: "Transcribed"
        case .failed: "Dictation failed"
        }
    }
}

/// The rTech accent: garnet, gold in dark mode. The Dynamic Island is always
/// dark, so it shows gold; the Lock Screen follows the phone's appearance.
enum RtechAccent {
    static let garnet = Color(red: 0x64 / 255, green: 0x12 / 255, blue: 0x20 / 255)
    static let gold = Color(red: 0xB8 / 255, green: 0x86 / 255, blue: 0x0B / 255)

    static func color(for scheme: ColorScheme) -> Color {
        scheme == .dark ? gold : garnet
    }
}
