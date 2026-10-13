import Foundation

/// Generates a short note title through the hub's LLM relay, ported from the
/// desktop's `src/utils/generateTitle.ts`. Any failure, or an answer that
/// sanitises to nothing, gives `fallback`.
public struct TitleService: Sendable {
    public static let fallback = "Untitled Note"
    static let systemPrompt =
        "Generate a concise 3-8 word title for these notes. Return ONLY the title text, nothing else — no quotes, no prefix, no explanation."
    /// Only the start of the note is sent (desktop: 2000 characters).
    static let maxInput = 2_000
    static let temperature = 0.3

    public let model: String
    private let llm: any LLMCompleting

    public init(llm: any LLMCompleting, model: String = LLMClient.defaultModel) {
        self.llm = llm
        self.model = model
    }

    public func generate(_ content: String) async -> String {
        let text = String(content.prefix(Self.maxInput))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Self.fallback }
        let request = LLMChatRequest(
            model: model,
            messages: [.system(Self.systemPrompt), .user(text)],
            temperature: Self.temperature
        )
        guard let completion = try? await llm.complete(request) else { return Self.fallback }
        let title = TitleSanitizer.sanitize(ThinkingTags.strip(completion.content))
        return title.isEmpty ? Self.fallback : title
    }
}

/// Cleans a model-generated title, ported from the desktop's
/// `src/utils/sanitizeGeneratedTitle.ts`, plus one iPhone rule: a single
/// trailing period goes (an ellipsis stays). Returns "" for an empty title
/// or one of `maxLength` UTF-16 units or more.
public enum TitleSanitizer {
    /// Titles at or over this many UTF-16 units are rejected (desktop: `< 100`).
    public static let maxLength = 100

    // Quote marks models wrap titles in despite the prompt: ASCII, typographic
    // (curly, German low-9), guillemets, and CJK title brackets.
    private static let wrappingQuotes: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{201E}", "\u{201A}",
        "\u{00AB}", "\u{00BB}", "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}", "\u{300A}", "\u{300B}"
    ]
    // Apostrophe-shaped marks are never stripped one-sided: at a single end
    // they are usually part of the word (Workin', 'Tis the Season).
    private static let apostrophes: Set<Character> = ["'", "\u{2018}", "\u{2019}"]

    public static func sanitize(_ raw: String) -> String {
        var cleaned = trim(raw[...])
        // Peel matched wrappers only (a quote at BOTH ends), so a title that
        // merely contains a quoted phrase at one end stays intact.
        while cleaned.count >= 2,
              let first = cleaned.first, wrappingQuotes.contains(first),
              let last = cleaned.last, wrappingQuotes.contains(last) {
            cleaned = trim(cleaned.dropFirst().dropLast())
        }

        // An unterminated wrapper leaves a quote at exactly one end with no
        // counterpart elsewhere; strip it.
        if cleaned.count > 1, let first = cleaned.first, let last = cleaned.last {
            if wrappingQuotes.contains(first), !apostrophes.contains(first), !hasQuote(in: cleaned.dropFirst()) {
                cleaned = trim(cleaned.dropFirst())
            } else if wrappingQuotes.contains(last), !apostrophes.contains(last), !hasQuote(in: cleaned.dropLast()) {
                cleaned = trim(cleaned.dropLast())
            }
        }

        if cleaned.count == 1, let only = cleaned.first, wrappingQuotes.contains(only) { return "" }

        if cleaned.hasSuffix("."), !cleaned.hasSuffix("..") {
            cleaned = trim(cleaned.dropLast())
        }

        let title = String(cleaned)
        return !title.isEmpty && title.utf16.count < maxLength ? title : ""
    }

    private static func hasQuote(in text: Substring) -> Bool {
        text.contains { wrappingQuotes.contains($0) }
    }

    private static func trim(_ text: Substring) -> Substring {
        var copy = text
        while let first = copy.first, first.isWhitespace { copy = copy.dropFirst() }
        while let last = copy.last, last.isWhitespace { copy = copy.dropLast() }
        return copy
    }
}
