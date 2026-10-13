import AppIntents
import SwiftUI
import WidgetKit

@main
struct RtechWhisperWidgets: WidgetBundle {
    var body: some Widget {
        DictateControl()
        BrainDumpControl()
        DictationLiveActivity()
    }
}

/// The Control Center (and Lock Screen) control: one tap starts dictation.
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rtech-consulting.whisper.widgets.dictate") {
            ControlWidgetButton(action: StartDictationIntent()) {
                Label("Dictate", systemImage: "mic")
            }
        }
        .displayName("Dictate")
        .description("Open rTech Whisper and start recording.")
    }
}

/// The Control Center control for a brain dump (ios#484): opens the Brain
/// dump tab with the box focused.
struct BrainDumpControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rtech-consulting.whisper.widgets.brain-dump") {
            ControlWidgetButton(action: BrainDumpIntent()) {
                Label("Brain dump", systemImage: "brain.head.profile")
            }
        }
        .displayName("Brain dump")
        .description("Open rTech Whisper on a new brain dump.")
    }
}
