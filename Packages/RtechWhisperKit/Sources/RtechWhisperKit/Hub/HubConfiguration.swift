import Foundation

/// Where the hub lives. Every hub call is built from `baseURL`.
public struct HubConfiguration: Sendable, Equatable {
    /// The Info.plist key that names the hub. project.yml fills it from the
    /// `RTW_HUB_BASE_URL` build setting, so each build picks its own hub.
    public static let infoPlistKey = "RTWHubBaseURL"

    /// Used when the build names no hub. `.invalid` never resolves, so an
    /// unconfigured build fails its hub calls instead of reaching a stranger.
    public static let unconfiguredBaseURL = URL(string: "https://hub.example.invalid")!

    /// The hub this build was configured with.
    public static let defaultBaseURL = resolve(Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)

    /// A configured value wins when it is an absolute http(s) URL; anything
    /// else (missing, empty, an unexpanded `$(...)`) means unconfigured.
    static func resolve(_ configured: String?) -> URL {
        let text = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return unconfiguredBaseURL }
        return url
    }

    public let baseURL: URL

    public init(baseURL: URL = HubConfiguration.defaultBaseURL) {
        self.baseURL = baseURL
    }
}
