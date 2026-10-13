import Foundation
import Observation

/// How much dictation history this iPhone keeps (ios#468). Trims are local
/// only: the hub and the Mac keep every dictation.
public enum HistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case last15
    case last50
    case day1
    case days7
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .last15: "Last 15"
        case .last50: "Last 50"
        case .day1: "1 day"
        case .days7: "7 days"
        case .all: "All"
        }
    }

    /// How many pushed rows a count choice keeps; `nil` for the others.
    public var keepCount: Int? {
        switch self {
        case .last15: 15
        case .last50: 50
        default: nil
        }
    }

    /// Rows created before this date have expired; `nil` for the count
    /// choices and for `all`.
    public func cutoff(now: Date = Date()) -> Date? {
        switch self {
        case .day1: now.addingTimeInterval(-86_400)
        case .days7: now.addingTimeInterval(-7 * 86_400)
        default: nil
        }
    }

    /// Reads the stored value. Builds before ios#468 stored a day count
    /// (0 = keep all, 30, 90): 30 becomes 7 days, the rest all. Unset is last 15.
    init(stored value: Any?) {
        switch value {
        case let raw as String: self = HistoryRetention(rawValue: raw) ?? .last15
        case let days as Int: self = days == 30 ? .days7 : .all
        default: self = .last15
        }
    }
}

/// The start/stop cue a dictation state change plays, as the desktop's
/// `dictationCues.js` does when recording starts and stops.
public enum DictationCue: Sendable, Equatable {
    case start
    case stop

    public static func forChange(
        from old: DictationController.State, to new: DictationController.State
    ) -> DictationCue? {
        if old != .recording && new == .recording { return .start }
        if old == .recording && new != .recording { return .stop }
        return nil
    }
}

/// The non-AI settings, persisted in `UserDefaults`: audio cues on, as the
/// desktop's `audioCuesEnabled`, and the last 15 dictations kept on this iPhone.
@MainActor
@Observable
public final class AppSettingsStore {
    public enum Key {
        public static let audioCuesEnabled = "app.audioCuesEnabled"
        /// Named for the day counts older builds stored; see `HistoryRetention(stored:)`.
        public static let historyRetentionDays = "app.historyRetentionDays"
        public static let transcribeOnDevice = "app.transcribeOnDevice"
        public static let transcriptionLanguage = "app.transcriptionLanguage"
    }

    public var audioCuesEnabled: Bool {
        didSet { defaults.set(audioCuesEnabled, forKey: Key.audioCuesEnabled) }
    }

    public var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetentionDays) }
    }

    /// "Transcribe on this iPhone": Apple speech first, the hub as the fallback. Off by default.
    public var transcribeOnDevice: Bool {
        didSet { defaults.set(transcribeOnDevice, forKey: Key.transcribeOnDevice) }
    }

    /// The dictation language; Auto by default, and Auto again for a code no longer listed.
    public var transcriptionLanguage: TranscriptionLanguage {
        didSet { defaults.set(transcriptionLanguage.code, forKey: Key.transcriptionLanguage) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        audioCuesEnabled = defaults.object(forKey: Key.audioCuesEnabled) as? Bool ?? true
        historyRetention = HistoryRetention(stored: defaults.object(forKey: Key.historyRetentionDays))
        transcribeOnDevice = defaults.bool(forKey: Key.transcribeOnDevice)
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage).flatMap(TranscriptionLanguage.init(code:)) ?? .auto
    }
}
