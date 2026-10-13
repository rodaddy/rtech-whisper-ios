import Foundation

/// How a history row reads: the desktop's `TranscriptionItem`, in iPhone form.
public enum HistoryFormatting {
    /// The `provider` the phone writes when Whisper, through the hub, transcribed.
    public static let hubProvider = "hub"
    /// The `provider` the phone writes when Apple's on-device recognizer did.
    public static let onDeviceProvider = "on-device"

    /// The `provider` a finished take is recorded with: on-device when Apple's
    /// recognizer produced its text, otherwise the hub (#493).
    public static func provider(for source: QueuedDictation.Source?) -> String {
        source == .onDevice ? onDeviceProvider : hubProvider
    }

    /// The small label next to a row. The phone's own providers read as
    /// words; a provider another app wrote (the desktop's `openai`, `local`,
    /// …) is shown as written, capitalized. No provider: no label.
    public static func providerLabel(_ provider: String?) -> String? {
        guard let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty else {
            return nil
        }
        switch provider.lowercased() {
        case hubProvider: return "Whisper"
        case onDeviceProvider: return "On-device"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    /// The row's text: whitespace collapsed so two lines hold as many words
    /// as they can, and an empty transcription reads as such.
    public static func preview(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? "(no speech)" : words.joined(separator: " ")
    }

    /// "2 min. ago", "Yesterday", … relative to `now`; "Just now" under a minute.
    public static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// What "Copy raw" copies: the text as Whisper heard it, before cleanup.
    /// `nil` when there is no raw text or it matches the shown text, so the
    /// action only appears when it copies something different.
    public static func rawTextToCopy(_ item: TranscriptionRecord) -> String? {
        guard let raw = item.rawText, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            raw.trimmingCharacters(in: .whitespacesAndNewlines) != item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return raw
    }

    /// "0:07" for a seven-second recording; `nil` when the length is unknown.
    public static func duration(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let seconds = (ms + 500) / 1000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}
