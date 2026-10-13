import Foundation

/// Replaces spoken snippet triggers with their saved text, by the desktop's
/// `expandSnippets` rules (English only):
/// - a trigger matches whatever its case in the text;
/// - it matches only as a whole word: at the start or end of the text, or
///   next to whitespace, punctuation, or a symbol, never inside a word;
/// - the longest trigger wins, so "investor ask" beats "ask";
/// - one pass, so replaced text is never expanded again.
public struct SnippetExpander: Sendable {
    private let regex: NSRegularExpression?
    private let replacements: [String: String]

    /// `snippets` as (trigger, replacement). Triggers are trimmed; blank ones
    /// are skipped.
    public init(_ snippets: [(trigger: String, replacement: String)]) {
        var replacements: [String: String] = [:]
        for (trigger, replacement) in snippets {
            let key = Self.key(trigger.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !key.isEmpty else { continue }
            replacements[key] = replacement
        }
        self.replacements = replacements
        guard !replacements.isEmpty else {
            regex = nil
            return
        }
        let alternatives = replacements.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let edge = "[\\s\\p{P}\\p{S}]"
        regex = try? NSRegularExpression(
            pattern: "(?<=^|\(edge))(?:\(alternatives))(?=$|\(edge))",
            options: [.caseInsensitive])
    }

    public func expand(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let source = text.precomposedStringWithCanonicalMapping as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
            let found = source.substring(with: match.range)
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replacements[Self.key(found)] ?? found
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return text }
        return result + source.substring(from: last)
    }

    private static func key(_ trigger: String) -> String {
        trigger.precomposedStringWithCanonicalMapping.lowercased()
    }
}
