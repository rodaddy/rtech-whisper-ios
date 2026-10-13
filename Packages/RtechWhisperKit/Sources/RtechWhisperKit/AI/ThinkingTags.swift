import Foundation

/// Removes `<think>...</think>` blocks a reasoning model leaks into its
/// answer, ported from the desktop's `src/helpers/stripThinking.js`.
/// Innermost closed pairs go first so nesting leaves no stray tag, then a
/// trailing unterminated `<think>`, then any orphan `</think>`.
enum ThinkingTags {
    static func strip(_ text: String) -> String {
        var out = text
        while true {
            let next = out.replacingOccurrences(
                of: #"<think>(?:(?!<think>)[\s\S])*?</think>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            if next == out { break }
            out = next
        }
        return out
            .replacingOccurrences(of: #"<think>[\s\S]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</think>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
