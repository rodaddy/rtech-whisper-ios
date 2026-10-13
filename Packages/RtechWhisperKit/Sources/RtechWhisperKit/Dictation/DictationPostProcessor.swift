import Foundation

/// A dictation after cleanup: what to show and keep as `text`, and what
/// Whisper said as `rawText`, the pair the history stores (the desktop keeps
/// `raw_text` beside `text`).
public struct ProcessedDictation: Equatable, Sendable {
    public let text: String
    public let rawText: String
    /// The cleanup model was asked and failed, so `text` is the fallback.
    public let cleanupFailed: Bool

    public init(text: String, rawText: String, cleanupFailed: Bool = false) {
        self.text = text
        self.rawText = rawText
        self.cleanupFailed = cleanupFailed
    }

    /// True when cleanup changed something beyond the edge whitespace that
    /// every path trims, so a Whisper leading space alone is not "cleaned".
    public var wasCleaned: Bool { text != rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs each finished dictation through `CleanupService` with the settings as
/// they are at that moment, so a toggle flipped in Settings applies to the
/// next dictation. Cleanup never loses text: a failure, an empty answer, or
/// cleanup switched off all give the raw text back (the service falls back to
/// the text without fillers, and with filler removal off, to the trimmed raw).
///
/// Snippet triggers are then expanded in that text, as the desktop expands
/// them after cleanup, so the expanded text is what is shown, copied, and
/// saved to the history. `rawText` stays what Whisper said.
public struct DictationPostProcessor: Sendable {
    private let clean: @Sendable (String) async -> (text: String, modelFailed: Bool)
    private let expand: @Sendable (String) async -> String

    /// The real one: `CleanupService` over `llm`, reading `settings` per
    /// call, then `expand` (snippet expansion; none by default).
    public init(
        llm: any LLMCompleting, settings: @escaping @Sendable () async -> CleanupSettings,
        expand: @escaping @Sendable (String) async -> String = { $0 }
    ) {
        clean = { raw in
            await CleanupService(llm: llm, settings: await settings()).cleanReportingFailure(raw)
        }
        self.expand = expand
    }

    /// Any cleanup and expansion, for tests.
    public init(
        clean: @escaping @Sendable (String) async -> String,
        expand: @escaping @Sendable (String) async -> String = { $0 }
    ) {
        self.clean = { (await clean($0), false) }
        self.expand = expand
    }

    public func process(_ rawText: String) async -> ProcessedDictation {
        let (cleaned, failed) = await clean(rawText)
        return ProcessedDictation(
            text: await expand(cleaned.isEmpty ? rawText : cleaned), rawText: rawText, cleanupFailed: failed)
    }
}
