import Foundation

/// The device a key belongs to, as the hub reports it.
public struct HubDevice: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Every way a hub call can fail, mapped from the protocol's error rules.
/// Every client maps a non-2xx answer through `HubError.from(status:body:retryAfter:)`.
public enum HubError: Error, Sendable, Equatable {
    /// The key is not `rtw_` plus 47 characters; no request was sent.
    case malformedKey
    /// `401`: the key is missing, unknown, or revoked.
    case unauthorized
    /// The request never got an HTTP answer. Carries the transport's description.
    case network(String)
    /// Any other non-2xx. `code` and `message` come from the
    /// `{ error: { message }, code }` body when the hub sent one.
    case server(status: Int, code: String?, message: String?)
    /// A 2xx whose body was not the expected JSON.
    case decoding(String)
    /// `413`: the recording is larger than the hub accepts.
    case tooLarge
    /// `415`: the audio was not WAV, PCM16, mono, 16000 Hz.
    case unsupportedAudio
    /// `429`. `retryAfter` is the `Retry-After` header in seconds, when
    /// the hub sent one as a number.
    case rateLimited(retryAfter: Int?)
    /// `502`, `503`, or `504`: the hub or its upstream is down or slow.
    case upstreamUnavailable(status: Int)
    /// `409 note_version_conflict`: the hub's row is newer than the
    /// `base_updated_at` the update carried. `current` is the hub's row.
    case noteVersionConflict(current: HubNote)
    /// `409 folder_name_taken`: another live folder already has this name.
    case folderNameTaken
    /// `409` on a snippet write: another live snippet already uses this trigger.
    case snippetTriggerTaken
    /// `404`: the id is unknown or already deleted. For a delete, the client
    /// treats this as done.
    case notFound
    /// `400`: the hub rejected the request. Carries its message.
    case invalidRequest(message: String?)
}

extension HubError {
    /// The one mapping from a non-2xx answer to a `HubError`, from its status,
    /// the `{ error: { message }, code, data }` body when there is one, and
    /// the `Retry-After` header value when the hub sent one.
    static func from(status: Int, body data: Data, retryAfter: String? = nil) -> HubError {
        struct Body: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
            let code: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        switch (status, body?.code) {
        case (400, _):
            return .invalidRequest(message: body?.error?.message)
        case (401, _):
            return .unauthorized
        case (404, _):
            return .notFound
        case (409, HubAPIError.noteVersionConflict?):
            if let note = (try? HubDate.decoder().decode(HubAPIError.self, from: data))?.data?.note {
                return .noteVersionConflict(current: note)
            }
        case (409, HubAPIError.folderNameTaken?):
            return .folderNameTaken
        case (409, HubAPIError.snippetTriggerTaken?):
            return .snippetTriggerTaken
        case (413, _):
            return .tooLarge
        case (415, _):
            return .unsupportedAudio
        case (429, _):
            return .rateLimited(retryAfter: retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        case (502, _), (503, _), (504, _):
            return .upstreamUnavailable(status: status)
        default:
            break
        }
        return .server(status: status, code: body?.code, message: body?.error?.message)
    }
}

/// Talks to the hub over HTTPS. The `URLSession` is injected so tests can
/// answer requests with a stub `URLProtocol`.
public struct HubClient: Sendable {
    public let configuration: HubConfiguration
    private let session: URLSession

    public init(configuration: HubConfiguration = HubConfiguration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// `GET /api/whoami`: the device this key belongs to.
    public func whoami(key: String) async throws(HubError) -> HubDevice {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }
        struct Body: Decodable { let device: HubDevice }
        let data = try await get("api/whoami", key: key)
        do {
            return try JSONDecoder().decode(Body.self, from: data).device
        } catch {
            throw .decoding(String(describing: error))
        }
    }

    private func get(_ path: String, key: String) async throws(HubError) -> Data {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .network("The hub answered without an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HubError.from(
                status: http.statusCode,
                body: data,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return data
    }
}
