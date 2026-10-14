import Foundation
import OSLog

/// Outcome of "Save as note" in Dictate, History and Upload, shown under the buttons.
public enum SaveNoteStatus: Equatable, Sendable {
    /// Names one save, so a save that outlives its text never settles
    /// another save of the same text.
    public struct Token: Hashable, Sendable {
        let id = UUID()
    }

    case idle
    /// A save of the given text is in flight; another tap must not start a second one.
    case saving(Token, String)
    /// The given text was saved.
    case saved(String)
    /// The save failed; the message is for the user.
    case failed(String)

    public init(failure error: any Error) {
        self = .failed("Could not save the note: \(Self.detail(error))")
    }

    private static func detail(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static let log = Logger(subsystem: "com.rtech-consulting.whisper", category: "save-note")

    /// Whether `text` is the one already saved.
    public func isSaved(_ text: String) -> Bool { self == .saved(text) }

    /// The line to show, or `nil` for none.
    public var message: String? {
        switch self {
        case .idle, .saving: nil
        case .saved: "Saved to notes."
        case .failed(let message): message
        }
    }

    public var isSaving: Bool { if case .saving = self { true } else { false } }

    /// Marks a save of `text` as started and returns its token. `nil`, and
    /// nothing changes, when a save is already in flight or `text` is
    /// already saved, so a double tap creates one note.
    public mutating func beginSaving(_ text: String) -> Token? {
        guard !isSaving, !isSaved(text) else { return nil }
        let token = Token()
        self = .saving(token, text)
        return token
    }

    /// Records how the save `token` names ended: `error` is `nil` on
    /// success. Ignored unless that save is still the one shown, so a save
    /// that outlives its screen never changes the status of whatever
    /// replaced it; a failure ignored that way is logged, to `logOutdated`
    /// when given, rather than dropped.
    public mutating func finishSaving(
        _ token: Token, error: (any Error)?, logOutdated: ((String) -> Void)? = nil
    ) {
        guard case .saving(token, let text) = self else {
            guard let error else { return }
            let line = "An earlier note save failed after its screen moved on: \(Self.detail(error))"
            if let logOutdated { logOutdated(line) } else { Self.log.error("\(line, privacy: .public)") }
            return
        }
        self = error.map(SaveNoteStatus.init(failure:)) ?? .saved(text)
    }

    public var isFailure: Bool { if case .failed = self { true } else { false } }
}
