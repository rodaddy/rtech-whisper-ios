import AppIntents

/// Brain dump: opens rTech Whisper on the Brain dump tab with the
/// box focused. Reachable from the Action button, Siri, Spotlight, a Home
/// Screen shortcut, and the Control Center control. It does not record.
///
/// Compiled into both the app and the widget extension, like
/// StartDictationIntent. The app sets `onPerform` at launch.
struct BrainDumpIntent: AppIntent {
    static let title: LocalizedStringResource = "Brain Dump"
    static let description = IntentDescription("Opens rTech Whisper on a new brain dump.")
    static let supportedModes: IntentModes = .foreground

    /// Set by the app at launch to hand the request to its shell.
    @MainActor static var onPerform: (@MainActor () -> Void)?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.onPerform?()
        return .result()
    }
}
