import Foundation

/// Facts about the app that are useful to both the app target and its tests.
public enum AppInfo {
    /// The name shown to a person, which is not the Xcode target name.
    public static let displayName = "rTech Whisper"

    /// `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, or `"dev"` when the
    /// bundle carries neither key (a `swift test` run, for example).
    public static func version(bundle: Bundle) -> String {
        version(info: bundle.infoDictionary ?? [:])
    }

    /// The same formatting from a raw Info dictionary. Tests use this, because
    /// a `Bundle` subclass override of `object(forInfoDictionaryKey:)` is not
    /// honored by current Foundation.
    public static func version(info: [String: Any]) -> String {
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        case let (nil, build?):
            return "dev (\(build))"
        case (nil, nil):
            return "dev"
        }
    }
}
