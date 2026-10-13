import Foundation
import Testing

@testable import RtechWhisperKit

// `EngineRecorder` (AVAudioEngine) is not unit-tested: it needs microphone
// hardware. Its conversion math is `AudioConverter`, tested below.

@Suite struct WavEncoderTests {
    @Test func headerBytesAndLengthForKnownSampleCount() {
        let wav = WavEncoder.pcm16MonoWav(samples: [0, 1, -1, .max, .min], sampleRate: 16_000)
        #expect(wav.count == 44 + 10)
        let expectedHeader: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 46, 0, 0, 0,        // "RIFF", 36 + 10
            0x57, 0x41, 0x56, 0x45,                     // "WAVE"
            0x66, 0x6D, 0x74, 0x20, 16, 0, 0, 0,        // "fmt ", 16
            1, 0, 1, 0,                                 // PCM, mono
            0x80, 0x3E, 0, 0,                           // 16000 Hz
            0x00, 0x7D, 0, 0,                           // 32000 bytes/s
            2, 0, 16, 0,                                // block align 2, 16 bits
            0x64, 0x61, 0x74, 0x61, 10, 0, 0, 0         // "data", 10 bytes
        ]
        #expect(Array(wav.prefix(44)) == expectedHeader)
        #expect(Array(wav.suffix(10)) == [0, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x80])
    }
}

@Suite struct AudioConverterTests {
    @Test func sine48kResamplesTo16kSampleCount() {
        let count = 48_000 + 123
        let sine = (0..<count).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        let pcm = AudioConverter.toRelayPCM(sine, sampleRate: 48_000)
        #expect(abs(pcm.count - count / 3) <= 1)
        // Linear resampling of a 3:1 ratio keeps every third input sample.
        #expect(pcm[100] == AudioConverter.toInt16(sine[300]))
    }

    @Test func clampsOutOfRangeSamples() {
        #expect(AudioConverter.toInt16(2.0) == .max)
        #expect(AudioConverter.toInt16(-2.0) == .min)
        #expect(AudioConverter.toInt16(1.0) == 32_767)
        #expect(AudioConverter.toInt16(0) == 0)
        #expect(AudioConverter.toInt16(.nan) == 0)
    }

    @Test func downmixAveragesChannels() {
        #expect(AudioConverter.downmix([[1, 0], [0, 0.5]]) == [0.5, 0.25])
    }
}

/// Answers relay requests for one fake host with a canned response, headers
/// included, and records each request with its body.
final class StubRelay: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        var headers: [String: String] = [:]
    }

    private nonisolated(unsafe) static var replies: [String: Reply] = [:]
    private nonisolated(unsafe) static var seen: [String: [(URLRequest, Data)]] = [:]
    private static let lock = NSLock()

    static func make(_ reply: Reply, key: String = goodKey) -> (client: TranscriptionClient, host: String) {
        let host = "relay-\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        let client = TranscriptionClient(
            configuration: HubConfiguration(baseURL: URL(string: "https://\(host)")!),
            key: key,
            session: URLSession(configuration: config)
        )
        return (client, host)
    }

    static func requests(to host: String) -> [(URLRequest, Data)] {
        lock.withLock { seen[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen[host, default: []].append((request, body))
            return Self.replies[host]
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite struct TranscriptionClientTests {
    let wav = WavEncoder.pcm16MonoWav(samples: [1, 2, 3])

    @Test func sendsMultipartFilePartFieldsAndBearerKey() async throws {
        let (client, host) = StubRelay.make(.init(status: 200, body: #"{"text":"hello there"}"#))
        let transcript = try await client.transcribe(wav: wav, language: "en", prompt: "rTech")
        #expect(transcript == Transcript(text: "hello there", noSpeech: false))

        let (request, body) = try #require(StubRelay.requests(to: host).first)
        #expect(request.url?.path == "/api/voice/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))

        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#"Content-Disposition: form-data; name="file"; filename="audio.wav"\#r\#nContent-Type: audio/wav\#r\#n\#r\#n"#))
        #expect(body.range(of: wav) != nil)
        #expect(text.contains("name=\"language\"\r\n\r\nen\r\n"))
        #expect(text.contains("name=\"prompt\"\r\n\r\nrTech\r\n"))
    }

    @Test func omitsAbsentOptionalFields() async throws {
        let (client, host) = StubRelay.make(.init(status: 200, body: #"{"text":"x"}"#))
        _ = try await client.transcribe(wav: wav, language: nil, prompt: nil)
        let (_, body) = try #require(StubRelay.requests(to: host).first)
        let text = String(decoding: body, as: UTF8.self)
        #expect(!text.contains("name=\"language\""))
        #expect(!text.contains("name=\"prompt\""))
    }

    @Test func noSpeechHeaderGivesNoSpeech() async throws {
        let (client, _) = StubRelay.make(.init(status: 200, body: #"{"text":""}"#, headers: ["x-rtech-no-speech": "1"]))
        let transcript = try await client.transcribe(wav: wav)
        #expect(transcript == Transcript(text: "", noSpeech: true))
    }

    @Test func status429CarriesRetryAfter() async {
        let (client, _) = StubRelay.make(.init(status: 429, body: "", headers: ["Retry-After": "7"]))
        await #expect(throws: HubError.rateLimited(retryAfter: 7)) {
            try await client.transcribe(wav: wav)
        }
    }

    @Test(arguments: [502, 503, 504])
    func upstreamStatusesMapToUpstreamUnavailable(_ status: Int) async {
        let (client, _) = StubRelay.make(.init(status: status, body: ""))
        await #expect(throws: HubError.upstreamUnavailable(status: status)) {
            try await client.transcribe(wav: wav)
        }
    }

    @Test func status413And415MapToAudioErrors() async {
        let (tooLarge, _) = StubRelay.make(.init(status: 413, body: ""))
        await #expect(throws: HubError.tooLarge) { try await tooLarge.transcribe(wav: wav) }
        let (unsupported, _) = StubRelay.make(.init(status: 415, body: ""))
        await #expect(throws: HubError.unsupportedAudio) { try await unsupported.transcribe(wav: wav) }
    }

    @Test func status401IsUnauthorized() async {
        let (client, _) = StubRelay.make(.init(status: 401, body: unauthorizedBody))
        await #expect(throws: HubError.unauthorized) { try await client.transcribe(wav: wav) }
    }
}
