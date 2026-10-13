import Foundation

/// Filler-word removal, ported from the desktop's `src/helpers/fillerWords.js`.
/// Pure string work: it runs on every transcript before the optional cleanup
/// model, so the model never sees the fillers and the no-cleanup path still
/// loses them.
public enum FillerWords {
    public static let defaults = [
        "um", "uh", "er", "ah", "eh", "umm", "uhh", "err", "ahh", "ehh",
        "hmm", "hm", "mm", "mmm", "erm", "urm", "ugh"
    ]

    // A filler only counts when neither side is a letter, digit, or mark, so
    // "summer" and "humm" stay intact. Commas and dashes on either side go
    // with it; sentence punctuation is handled on its own because it carries
    // meaning the filler does not.
    private static let wordChar = #"\p{L}\p{N}\p{M}"#
    private static let softChars = #",\-\x{2013}\x{2014}"#
    private static let endChars = #".;:!?\x{2026}"#

    /// `text` without the words in `words`, matched case-insensitively as
    /// whole words. An empty list leaves the text unchanged.
    public static func remove(from text: String, words: [String] = defaults) -> String {
        guard !text.isEmpty else { return text }
        let list = normalized(words)
        guard !list.isEmpty else { return text }

        let alternation = list.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let unit = "(?<![\(wordChar)])(?:\(alternation))(?![\(wordChar)])[\(softChars)\\s]*"
        let pattern = "([\(softChars)\\s]*)((?:\(unit))+)([\(endChars)]*)(\\s*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let source = text as NSString
        var removedAtStart = false
        let stripped = replace(regex, in: text) { match in
            let lead = match.range(at: 1)
            let end = source.substring(with: match.range(at: 3))
            let before = source.substring(to: lead.location + lead.length).trimmingTrailingWhitespace()
            if before.isEmpty { removedAtStart = true }
            // The filler opened the text or a sentence: the break already
            // exists, so the filler goes with everything attached to it.
            if before.isEmpty || before.last.map({ ".;:!?\u{2026}".contains($0) }) == true {
                return " "
            }
            // Mid-sentence: a real stop after the filler belongs to the words
            // before it; a hesitation ellipsis does not.
            let kept = end.replacingOccurrences(of: #"\x{2026}|\.{2,}"#, with: "", options: .regularExpression)
            return kept.isEmpty ? " " : kept + " "
        }
        guard stripped != text else { return text }

        let out = stripped
            .replacingOccurrences(of: #"[^\S\r\n]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\S\r\n]+([,.;:!?\x{2026}])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }

        // Re-capitalise a word that follows a sentence stop, and the first
        // word when a filler was removed from the front.
        var result = out
        if let stop = try? NSRegularExpression(pattern: #"([.!?\x{2026}]\s+)(\p{Ll})"#) {
            let current = out as NSString
            result = replace(stop, in: out) { match in
                current.substring(with: match.range(at: 1)) + current.substring(with: match.range(at: 2)).uppercased()
            }
        }
        if removedAtStart, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        return result
    }

    /// Trimmed, lowercased, de-duplicated; empty entries dropped.
    private static func normalized(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty, seen.insert(trimmed).inserted { list.append(trimmed) }
        }
        return list
    }

    /// Every match of `regex` in `text` replaced by `transform(match)`.
    private static func replace(
        _ regex: NSRegularExpression, in text: String, with transform: (NSTextCheckingResult) -> String
    ) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += transform(match)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var copy = self[...]
        while let last = copy.last, last.isWhitespace { copy = copy.dropLast() }
        return String(copy)
    }
}
