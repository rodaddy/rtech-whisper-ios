import Foundation

/// The rows under the More tab: the desktop sidebar views that do not earn
/// a tab of their own on a phone.
public enum MoreFeature: String, CaseIterable, Identifiable, Sendable {
    case dictionary
    case snippets
    case upload

    public var id: String { rawValue }

    /// The row and screen title.
    public var title: String {
        switch self {
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .upload: "Upload"
        }
    }

    /// The SF Symbol for the More row.
    public var systemImage: String {
        switch self {
        case .dictionary: "book"
        case .snippets: "text.badge.plus"
        case .upload: "square.and.arrow.up"
        }
    }
}

/// The lines the Settings sheet shows for the hub connection, derived from
/// `HubConnection.State` so the view only renders.
public struct HubSettingsSummary: Equatable, Sendable {
    /// The hub, as a person reads it (no trailing slash).
    public let hubURL: String
    /// One line: connected as which device, or why not.
    public let statusLine: String
    /// Whether a key is stored, so "Forget this key" has something to forget.
    public let hasStoredKey: Bool

    public init(state: HubConnection.State, configuration: HubConfiguration = HubConfiguration()) {
        hubURL = Self.display(configuration.baseURL)
        switch state {
        case .needsKey:
            statusLine = "Not connected"
            hasStoredKey = false
        case .checking:
            statusLine = "Checking the hub…"
            hasStoredKey = true
        case .connected(let device):
            statusLine = "Connected as \(device.name)"
            hasStoredKey = true
        case .stored:
            statusLine = "Key stored, but the hub check failed"
            hasStoredKey = true
        }
    }

    static func display(_ url: URL) -> String {
        let text = url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
