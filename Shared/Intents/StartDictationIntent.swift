import AppIntents

/// Start dictating: opens rTech Whisper on Home and starts recording. The
/// phone's version of the desktop's global hotkey, reachable from Siri,
/// Shortcuts, the Action button, and the Control Center control.
///
/// Compiled into both the app and the widget extension: the extension needs
/// the type for its `ControlWidgetButton`, and the system runs `perform()` in
/// the app because the intent opens it. The app sets `onPerform` at launch.
struct StartDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Opens rTech Whisper and starts recording.")
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
