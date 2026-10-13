import Foundation

/// The two formats the desktop's Export menu offers.
public enum ExportFormat: String, CaseIterable, Sendable {
    case md
    case txt
}

/// What a shared `.md` or `.txt` file holds and is called, as the desktop's
/// `export-note` handler writes it.
public enum TextExport {
    /// The title with characters a file name cannot hold replaced by `-`;
    /// "Untitled" when there is none.
    public static func fileName(title: String?, format: ExportFormat) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = (trimmed.isEmpty ? "Untitled" : trimmed)
            .replacingOccurrences(of: #"[/\\?%*:|"<>]"#, with: "-", options: .regularExpression)
        return "\(base).\(format.rawValue)"
    }

    /// Markdown is the enhanced content when there is one, else the note's
    /// text; text is the note's text with the markdown marks stripped.
    public static func noteText(_ note: NoteRecord, format: ExportFormat) -> String {
        switch format {
        case .md:
            if let enhanced = note.enhancedContent, !enhanced.isEmpty { return enhanced }
            return note.content
        case .txt:
            return plainText(note.content)
        }
    }

    /// A history item is plain words either way.
    public static func historyText(_ item: TranscriptionRecord) -> String { item.text }

    /// "Transcription 2026-09-30 1405", the name a history item is shared under.
    public static func historyTitle(_ item: TranscriptionRecord, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Transcription \(formatter.string(from: item.createdAt))"
    }

    /// The desktop's strip: headings, emphasis marks, images and links to
    /// their text, quote marks.
    public static func plainText(_ markdown: String) -> String {
        var text = markdown
        for (pattern, template) in [
            (#"#{1,6}\s+"#, ""),
            (#"[*_~`]+"#, ""),
            (#"!\[([^\]]*)\]\([^)]+\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"(?m)^>\s+"#, ""),
        ] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
