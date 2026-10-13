import ActivityKit
import Foundation

/// The Live Activity for a take in progress: the phone's version of the
/// desktop floating pill, shown in the Dynamic Island and on the Lock Screen.
///
/// Compiled into both the app (which starts, updates, and ends it) and the
/// widget extension (which draws it). The extension does not link
/// RtechWhisperKit, so this holds plain values only; the app fills it from
/// the kit's `DictationActivityContent`.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case recording
            case transcribing
            case done
            case failed
        }

        var phase: Phase
        /// When the microphone opened; the widget counts up from it.
        var startedAt: Date
        /// The first line of the result, or the error, once the take has ended.
        var message: String?
    }
}
