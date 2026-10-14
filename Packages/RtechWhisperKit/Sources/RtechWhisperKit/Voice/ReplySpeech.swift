import Foundation
import Observation

/// `POST /api/voice/upstream/omnivoice/synthesize` (hub protocol section
/// 10.2), the iPhone path: only `text` is sent, so the hub speaks it in
/// its own server-side voice. Returns the reply's WAV bytes.
public enum SpeechRelay {
    public static let path = "api/voice/upstream/omnivoice/synthesize"
    /// The relay takes 1...2000 characters after trimming.
    public static let maxCharacters = 2000

    /// The JSON body: the trimmed text, cut to `maxCharacters`.
    static func requestBody(text: String) -> Data {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
        return (try? JSONEncoder().encode(["text": text])) ?? Data()
    }

    /// The WAV in a 200 answer's `audio_base64`.
    static func audio(from data: Data) throws(HubError) -> Data {
        struct Body: Decodable { let audio_base64: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              let wav = Data(base64Encoded: body.audio_base64), !wav.isEmpty
        else { throw .decoding("The speech relay answered without audio.") }
        return wav
    }

    public static func synthesize(
        _ text: String, key: String, configuration: HubConfiguration = HubConfiguration(),
        session: URLSession = TranscriptionClient.defaultSession
    ) async throws(HubError) -> Data {
        guard DeviceKey.isWellFormed(key) else { throw .malformedKey }
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(text: text)
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
            throw HubError.from(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return try audio(from: data)
    }
}

/// Plays one WAV at a time. `onFinish` runs when the audio ends by itself.
@MainActor
public protocol ReplyAudioPlaying: AnyObject {
    var onFinish: (@MainActor () -> Void)? { get set }
    func play(_ wav: Data) throws
    func stop()
}

/// Reads chat replies aloud (the desktop's `useAssistantSpeech`): one reply
/// at a time, and a new one, or the same one tapped again, stops the last.
@MainActor
@Observable
public final class ReplySpeaker {
    public typealias Synthesize = @Sendable (String) async throws(HubError) -> Data

    public enum Failure: Equatable, Sendable {
        /// A take holds the phone's one audio session.
        case audioBusy
        case synthesis(HubError)
        case playback(String)
    }

    /// The reply being fetched or played; nil when quiet.
    public private(set) var speakingID: UUID?
    /// True while `speakingID`'s audio is still being fetched.
    public private(set) var isLoading = false
    /// Why the last reply was not read; cleared by the next one.
    public private(set) var failure: Failure?

    private let synthesize: Synthesize
    private let player: any ReplyAudioPlaying
    private let otherCaptureActive: @MainActor () -> Bool
    private let isEnabled: @MainActor () -> Bool
    /// Bumped by every `speak` and `stop`, so audio that arrives late for a
    /// reply already called off is never played.
    private var generation = 0

    /// - Parameters:
    ///   - otherCaptureActive: true while a take holds the microphone; the
    ///     audio session is never taken from under it.
    ///   - isEnabled: the "Read replies aloud" setting, read per turn.
    public init(
        synthesize: @escaping Synthesize, player: any ReplyAudioPlaying,
        otherCaptureActive: @escaping @MainActor () -> Bool = { false },
        isEnabled: @escaping @MainActor () -> Bool = { true }
    ) {
        self.synthesize = synthesize
        self.player = player
        self.otherCaptureActive = otherCaptureActive
        self.isEnabled = isEnabled
        player.onFinish = { [weak self] in self?.quiet() }
    }

    /// The speaker button: stops `message` if it is the one being read,
    /// otherwise reads it.
    public func toggle(_ message: ChatMessage) async {
        if speakingID == message.id { stop() } else { await speak(message) }
    }

    /// Called when a turn ends: with the setting on, reads the reply the
    /// turn answered with. Nothing for a failed, cancelled, or cut-off turn.
    public func turnEnded(_ end: ChatSession.TurnEnd?, messages: [ChatMessage]) async {
        guard end == .answered, isEnabled(),
              let reply = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })
        else { return }
        await speak(reply)
    }

    public func speak(_ message: ChatMessage) async {
        stop()
        failure = nil
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !otherCaptureActive() else {
            failure = .audioBusy
            return
        }
        let mine = generation
        speakingID = message.id
        isLoading = true
        let wav: Data
        do {
            wav = try await synthesize(message.content)
        } catch {
            guard mine == generation else { return }
            quiet()
            failure = .synthesis(error)
            return
        }
        guard mine == generation else { return }
        isLoading = false
        guard !otherCaptureActive() else {
            quiet()
            failure = .audioBusy
            return
        }
        do {
            try player.play(wav)
        } catch {
            quiet()
            failure = .playback(error.localizedDescription)
        }
    }

    /// Stops the reply being read, or calls off the one being fetched.
    public func stop() {
        generation += 1
        if speakingID != nil { player.stop() }
        quiet()
    }

    private func quiet() {
        speakingID = nil
        isLoading = false
    }
}

#if canImport(AVFAudio)
import AVFAudio

/// The real player, via `AVAudioPlayer`. It takes the shared audio session
/// for playback only while no recorder runs, and hands it back when done,
/// leaving it alone under a live take (the same rule as `EngineRecorder`).
///
/// Not unit-tested: it needs audio hardware.
@MainActor
public final class AudioReplyPlayer: NSObject, ReplyAudioPlaying, AVAudioPlayerDelegate {
    public var onFinish: (@MainActor () -> Void)?
    private var player: AVAudioPlayer?

    override public init() {}

    public func play(_ wav: Data) throws {
        stop()
        let player = try AVAudioPlayer(data: wav)
        player.delegate = self
        #if os(iOS)
        if Self.noRecorder {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
        self.player = player
    }

    public func stop() {
        guard let player else { return }
        self.player = nil
        player.stop()
        release()
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.player = nil
            self.release()
            self.onFinish?()
        }
    }

    private static var noRecorder: Bool { EngineRecorder.running.withLock { $0 == 0 } }

    private func release() {
        #if os(iOS)
        if Self.noRecorder {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }
}
#endif
