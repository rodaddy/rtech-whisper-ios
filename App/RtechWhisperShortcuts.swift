import AppIntents

/// The phrases Siri and Shortcuts offer without setup. The Action button
/// picks the same shortcut under Settings > Action Button > Shortcut.
struct RtechWhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Dictate with \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: BrainDumpIntent(),
            phrases: [
                "Brain dump in \(.applicationName)",
                "New brain dump in \(.applicationName)"
            ],
            shortTitle: "Brain Dump",
            systemImageName: "brain.head.profile"
        )
    }
}
