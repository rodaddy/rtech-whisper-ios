import AppIntents

/// Stop the recording from the Live Activity's expanded view. A
/// `LiveActivityIntent` runs in the app's process without bringing it to the
/// front, so the take ends where the person is: on the Lock Screen or in the
/// Dynamic Island over another app, as the desktop pill's stop does.
///
/// Compiled into both the app and the widget extension, like
/// `StartDictationIntent`: the extension needs the type for its button, the
/// app runs `perform()`. The app sets `onPerform` at launch.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription("Stops the recording in progress.")

    /// Set by the app at launch to hand the request to its dictation controller.
    @MainActor static var onPerform: (@MainActor () async -> Void)?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await Self.onPerform?()
        return .result()
    }
}
