import Foundation

/// The language dictation is transcribed in, the desktop's
/// `preferredLanguage` with the same choices as its `languageRegistry.json`.
/// Auto lets the hub detect it and on-device speech use the phone's locale.
public struct TranscriptionLanguage: Hashable, Identifiable, Sendable {
    public let code: String
    public let label: String

    public var id: String { code }

    init(_ code: String, _ label: String) {
        self.code = code
        self.label = label
    }

    /// The choice stored as `code`; `nil` when the list has no such code.
    public init?(code: String) {
        guard let match = Self.all.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    public static let auto = TranscriptionLanguage("auto", "Auto-detect")

    /// The relay's `language` field (ISO-639-1), the base of a regional code
    /// as the desktop's `getBaseLanguageCode` sends it; `nil` for Auto.
    public var hubLanguage: String? {
        code == Self.auto.code ? nil : String(code.prefix { $0 != "-" })
    }

    /// The on-device recognizer's locale; `nil` for Auto (the phone's own).
    public var locale: Locale? {
        code == Self.auto.code ? nil : Locale(identifier: code)
    }

    /// The desktop's list, in its order.
    public static let all: [TranscriptionLanguage] = [
        auto,
        .init("af", "Afrikaans"),
        .init("ar", "Arabic"),
        .init("hy", "Armenian"),
        .init("az", "Azerbaijani"),
        .init("be", "Belarusian"),
        .init("bs", "Bosnian"),
        .init("bg", "Bulgarian"),
        .init("ca", "Catalan"),
        .init("zh-CN", "Chinese (Simplified)"),
        .init("zh-TW", "Chinese (Traditional)"),
        .init("hr", "Croatian"),
        .init("cs", "Czech"),
        .init("da", "Danish"),
        .init("nl", "Dutch"),
        .init("en-US", "English (US)"),
        .init("en-GB", "English (UK)"),
        .init("et", "Estonian"),
        .init("fi", "Finnish"),
        .init("fr", "French"),
        .init("gl", "Galician"),
        .init("de", "German"),
        .init("el", "Greek"),
        .init("he", "Hebrew"),
        .init("hi", "Hindi"),
        .init("hu", "Hungarian"),
        .init("is", "Icelandic"),
        .init("id", "Indonesian"),
        .init("it", "Italian"),
        .init("ja", "Japanese"),
        .init("kn", "Kannada"),
        .init("kk", "Kazakh"),
        .init("ko", "Korean"),
        .init("lv", "Latvian"),
        .init("lt", "Lithuanian"),
        .init("mk", "Macedonian"),
        .init("ms", "Malay"),
        .init("mt", "Maltese"),
        .init("mr", "Marathi"),
        .init("mi", "Maori"),
        .init("ne", "Nepali"),
        .init("no", "Norwegian"),
        .init("fa", "Persian"),
        .init("pl", "Polish"),
        .init("pt", "Portuguese"),
        .init("ro", "Romanian"),
        .init("ru", "Russian"),
        .init("sr", "Serbian"),
        .init("sk", "Slovak"),
        .init("sl", "Slovenian"),
        .init("es", "Spanish"),
        .init("sw", "Swahili"),
        .init("sv", "Swedish"),
        .init("tl", "Tagalog"),
        .init("ta", "Tamil"),
        .init("th", "Thai"),
        .init("tr", "Turkish"),
        .init("uk", "Ukrainian"),
        .init("ur", "Urdu"),
        .init("vi", "Vietnamese"),
        .init("cy", "Welsh"),
    ]
}
