import Foundation
import Observation

/// The AI toggles the Settings sheet shows, persisted in `UserDefaults` with
/// the desktop's defaults (`useCleanupModel`, `removeFillerWords`, and
/// `autoGenerateTitle` in `src/stores/settingsStore.ts`, all on). The model
/// is fixed to the one chat model on llama-swap for now.
@MainActor
@Observable
public final class AISettingsStore {
    public enum Key {
        public static let useCleanupModel = "ai.useCleanupModel"
        public static let removeFillerWords = "ai.removeFillerWords"
        public static let autoGenerateTitle = "ai.autoGenerateTitle"
        public static let assistantSpeechEnabled = "ai.assistantSpeechEnabled"
    }

    /// Read each chat reply aloud in Skippy's voice. Off by default, as on
    /// the desktop (`assistantSpeechEnabled`).
    public var assistantSpeechEnabled: Bool {
        didSet { defaults.set(assistantSpeechEnabled, forKey: Key.assistantSpeechEnabled) }
    }

    /// Send each dictation through the cleanup model.
    public var useCleanupModel: Bool {
        didSet { defaults.set(useCleanupModel, forKey: Key.useCleanupModel) }
    }

    /// Strip filler words from each dictation.
    public var removeFillerWords: Bool {
        didSet { defaults.set(removeFillerWords, forKey: Key.removeFillerWords) }
    }

    /// Title an untitled note from its content.
    public var autoGenerateTitle: Bool {
        didSet { defaults.set(autoGenerateTitle, forKey: Key.autoGenerateTitle) }
    }

    /// The chat model both services use; read-only until the hub offers more.
    public let model = LLMClient.defaultModel

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        useCleanupModel = Self.bool(defaults, Key.useCleanupModel, default: true)
        removeFillerWords = Self.bool(defaults, Key.removeFillerWords, default: true)
        autoGenerateTitle = Self.bool(defaults, Key.autoGenerateTitle, default: true)
        assistantSpeechEnabled = Self.bool(defaults, Key.assistantSpeechEnabled, default: false)
    }

    /// What `CleanupService` should do right now, with the dictionary's words
    /// as the spellings cleanup must keep.
    public func cleanupSettings(dictionary: [String] = []) -> CleanupSettings {
        CleanupSettings(
            useCleanupModel: useCleanupModel, model: model, removeFillerWords: removeFillerWords,
            customDictionary: dictionary)
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
