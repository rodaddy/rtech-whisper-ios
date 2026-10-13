import Foundation

/// What the relay heard. `noSpeech` is true when the hub trimmed the audio to
/// nothing (`x-rtech-no-speech: 1`); `text` is then empty.
public struct Transcript: Sendable, Equatable {
    public let text: String
    public let noSpeech: Bool

    public init(text: String, noSpeech: Bool) {
        self.text = text
        self.noSpeech = noSpeech
    }
}

/// `POST /api/voice/v1/audio/transcriptions` (hub protocol section 10.1).
/// The `URLSession` is injected so tests can answer with a stub `URLProtocol`.
public struct TranscriptionClient: Sendable {
    public static let path = "api/voice/v1/audio/transcriptions"

    public let configuration: HubConfiguration
    private let key: String
    private let session: URLSession

    /// How long one request may take. The hub allows 180 s per transcription
    /// and sends nothing until it is done, so the 60 s URLSession default
    /// would time out a long upload chunk the hub is still working on.
    public static let requestTimeout: TimeInterval = 240

    /// A session whose request timeout covers the hub's 180 s budget.
    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    public init(configuration: HubConfiguration = HubConfiguration(), key: String, session: URLSession = defaultSession) {
        self.configuration = configuration
        self.key = key
        self.session = session
    }

    public func transcribe(wav: Data, language: String? = nil, prompt: String? = nil) async throws(HubError) -> Transcript {
        let (built, body) = try uploadRequest(wav: wav, language: language, prompt: prompt)
        var request = built
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .network(error.localizedDescription)
        }
        return try Self.transcript(data: data, response: response)
    }

    /// The relay request and its multipart body, apart, so a background
    /// session can send the body from a file (#96).
    public func uploadRequest(
        wav: Data, language: String? = nil, prompt: String? = nil
    ) throws(HubError) -> (request: URLRequest, body: Data) {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }

        let boundary = "rtw-\(UUID().uuidString)"
        var request = URLRequest(url: configuration.baseURL.appending(path: Self.path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return (request, Self.multipartBody(boundary: boundary, wav: wav, language: language, prompt: prompt))
    }

    /// The transcript in the relay's answer, or the `HubError` it carries.
    public static func transcript(data: Data, response: URLResponse) throws(HubError) -> Transcript {
        guard let http = response as? HTTPURLResponse else {
            throw .network("The hub answered without an HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            if http.value(forHTTPHeaderField: "x-rtech-no-speech") == "1" {
                return Transcript(text: "", noSpeech: true)
            }
            struct Body: Decodable { let text: String }
            do {
                return Transcript(text: try JSONDecoder().decode(Body.self, from: data).text, noSpeech: false)
            } catch {
                throw .decoding(String(describing: error))
            }
        default:
            throw HubError.from(
                status: http.statusCode,
                body: data,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
    }

    /// The `multipart/form-data` body: the `file` part as `audio/wav`, then
    /// `language` and `prompt` when given.
    static func multipartBody(boundary: String, wav: Data, language: String?, prompt: String?) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }

        line("--\(boundary)")
        line(#"Content-Disposition: form-data; name="file"; filename="audio.wav""#)
        line("Content-Type: audio/wav")
        line("")
        body.append(wav)
        line("")
        for (name, value) in [("language", language), ("prompt", prompt)] {
            guard let value else { continue }
            line("--\(boundary)")
            line(#"Content-Disposition: form-data; name="\#(name)""#)
            line("")
            line(value)
        }
        line("--\(boundary)--")
        return body
    }
}
