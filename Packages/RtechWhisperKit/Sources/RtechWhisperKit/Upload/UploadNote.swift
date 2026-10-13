import Foundation

/// How an upload becomes a note, matching the desktop's `uploadNotes.ts`:
/// `note_type` `upload`, `source_file` the file's name, and
/// `audio_duration_seconds` when the length is known.
public enum UploadNote {
    /// The desktop's `uploadTitleFallback`: the first six words of the text
    /// ("..." when there are more), else the file name without its extension.
    public static func title(text: String, fileName: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let preview = words.prefix(6).joined(separator: " ") + (words.count > 6 ? "..." : "")
        return preview.isEmpty ? (fileName as NSString).deletingPathExtension : preview
    }

    /// `audio_duration_seconds` as the desktop stores it: a finite length
    /// above zero, else `nil`.
    public static func durationSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

extension NotesViewModel {
    /// Upload's "Save as note": the transcription as an `upload` note in the
    /// selected folder, else the default, titled as the desktop titles it.
    @discardableResult
    public func saveUploadNote(_ result: UploadResult) async throws -> NoteRecord {
        try await create(
            title: UploadNote.title(text: result.text, fileName: result.fileName),
            content: result.text, transcript: result.text, noteType: .upload,
            sourceFile: result.fileName,
            audioDurationSeconds: UploadNote.durationSeconds(result.durationSeconds))
    }
}
