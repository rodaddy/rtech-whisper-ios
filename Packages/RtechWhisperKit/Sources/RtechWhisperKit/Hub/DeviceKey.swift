import Foundation

/// The shape of a hub device key: the `rtw_` prefix and 47 characters in all.
/// This is a paste check only; the hub decides whether a key is real.
public enum DeviceKey {
    public static let prefix = "rtw_"
    public static let length = 47

    /// The pasted text with surrounding whitespace removed, so a stray newline
    /// from the clipboard does not fail an otherwise good key.
    public static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isWellFormed(_ key: String) -> Bool {
        key.hasPrefix(prefix) && key.count == length
    }
}
