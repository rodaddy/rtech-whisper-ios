import Foundation

/// What the Live Activity shows for the take in progress: the phone's version
/// of the desktop floating pill (recording, processing). Derived from
/// `DictationController.State` here so the widget only renders.
public struct DictationActivityContent: Equatable, Sendable {
    public enum Phase: String, Sendable, Codable {
        /// The microphone is open. The widget counts up from `startedAt`.
        case recording
        /// The recording is saved and on its way to Whisper.
        case transcribing
        /// Whisper answered; `message` is the first line of the text.
        case done
        /// The take ended badly; `message` says why.
        case failed
    }

    public let phase: Phase
    /// When the microphone opened.
    public let startedAt: Date
    /// The first line of the result, or the error, once the take has ended.
    public let message: String?

    /// What the widget says when Whisper heard nothing.
    public static let noSpeechLine = "No speech heard."

    public init(phase: Phase, startedAt: Date, message: String? = nil) {
        self.phase = phase
        self.startedAt = startedAt
        self.message = message
    }

    /// `nil` when there is nothing to show (`idle`). `latestText` is the
    /// controller's `latestText`; `startedAt` is when the microphone opened.
    public init?(state: DictationController.State, latestText: String?, startedAt: Date) {
        switch state {
        case .idle:
            return nil
        case .recording:
            self.init(phase: .recording, startedAt: startedAt)
        case .queued, .cleaning:
            // AI cleanup is still the "processing" part of the take.
            self.init(phase: .transcribing, startedAt: startedAt)
        case .done:
            self.init(phase: .done, startedAt: startedAt, message: Self.firstLine(of: latestText))
        case .failed(let reason):
            self.init(phase: .failed, startedAt: startedAt, message: reason)
        }
    }

    /// The first non-empty line of a result, trimmed, or `noSpeechLine`.
    public static func firstLine(of text: String?) -> String {
        let line = text?
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line ?? noSpeechLine
    }

    /// How long "Transcribing" stays trustworthy before the system shows it
    /// as stale, for example while the phone is offline and the take waits.
    /// This is a budget, not a guarantee: the hub allows 180 s per
    /// transcription and this leaves room for the upload on top, but
    /// `TranscriptionClient.requestTimeout` is an idle timeout and the
    /// stale date is set once, so a slow upload plus a full hub run can
    /// still show a take that is on track as stale.
    public static let transcribingStaleAfter: TimeInterval = TranscriptionClient.requestTimeout

    /// The ActivityKit `staleDate` for this content shown at `now`. A take
    /// records as long as the person talks, and done or failed ends the
    /// activity, so only `transcribing` goes stale.
    public func staleDate(now: Date) -> Date? {
        phase == .transcribing ? now.addingTimeInterval(Self.transcribingStaleAfter) : nil
    }
}

/// What the app does to its Live Activity when the controller's state
/// changes. A take starts the activity, its progress updates it, and its end
/// shows the result for a moment before the system dismisses it.
public enum DictationActivityStep: Equatable, Sendable {
    case start(DictationActivityContent)
    case update(DictationActivityContent)
    /// End the activity showing `content`; the system removes it after `dismissAfter`.
    case end(DictationActivityContent, dismissAfter: TimeInterval)
    case none

    /// How long the result or error stays on screen after the take ends.
    public static let dismissDelay: TimeInterval = 4

    /// `isActive` is whether an activity is currently showing. A phase that
    /// arrives with no activity to attach to (a failed microphone request, a
    /// queue draining at launch) shows nothing: only a recording starts one.
    public static func plan(isActive: Bool, content: DictationActivityContent?) -> DictationActivityStep {
        guard let content else { return .none }
        switch content.phase {
        case .recording:
            return isActive ? .update(content) : .start(content)
        case .transcribing:
            return isActive ? .update(content) : .none
        case .done, .failed:
            return isActive ? .end(content, dismissAfter: dismissDelay) : .none
        }
    }
}
