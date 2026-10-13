import Foundation

/// Turns a recording into text on the phone itself, with no network. The
/// offline backup while the hub is unreachable; Whisper replaces it later.
/// Tests drive a fake.
public protocol OnDeviceTranscribing: Sendable {
    /// `samples` is 16 kHz Int16 mono, as `AudioCapturing.stop` returns it.
    func transcribe(_ samples: [Int16]) async throws -> String
}

/// Why on-device text could not be produced. The recording still waits for
/// the hub either way.
public enum OnDeviceSpeechError: Error, Sendable, Equatable {
    /// The person has not allowed speech recognition.
    case denied
    /// This phone or language has no on-device recognizer available.
    case unavailable(String)

    /// One line a person can read.
    public var userMessage: String {
        switch self {
        case .denied:
            "Speech recognition is off, so there is no on-device text. Turn it on in Settings."
        case .unavailable(let detail):
            "On-device speech is unavailable. \(detail)"
        }
    }
}

#if canImport(Speech) && os(iOS)
import AVFAudio
import Speech

/// Apple's speech recognition, on-device only: audio never goes to Apple's
/// servers. Prefers `SpeechAnalyzer`/`SpeechTranscriber` when the model for
/// the language is installed, else `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition`. Asks for speech permission on first use.
///
/// Not unit-tested: it needs the system recognizer, its language assets, and
/// a person to answer the permission prompt.
public final class AppleOnDeviceSpeech: OnDeviceTranscribing {
    private let locale: @MainActor @Sendable () -> Locale

    public convenience init(locale: Locale = .current) {
        self.init(currentLocale: { locale })
    }

    /// `currentLocale` is read on every take, so a changed language setting
    /// applies to the next one.
    public init(currentLocale: @escaping @MainActor @Sendable () -> Locale) {
        self.locale = currentLocale
    }

    public func transcribe(_ samples: [Int16]) async throws -> String {
        try await Self.authorize()
        let locale = await self.locale()
        // The deployment target (iOS 27) always has SpeechAnalyzer; the
        // SFSpeechRecognizer path covers a language whose model is not installed.
        if let text = try await analyzerTranscription(samples, locale: locale) {
            return text
        }
        return try await legacyTranscription(samples, locale: locale)
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else { throw OnDeviceSpeechError.denied }
    }

    /// `nil` when `SpeechTranscriber` cannot run here without a download.
    private func analyzerTranscription(_ samples: [Int16], locale: Locale) async throws -> String? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        // Installed means the model is on the phone; downloading it needs the
        // network this path exists to do without.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return nil }
        let buffer = try Self.buffer(samples, converting: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        async let text = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
        }
        try await analyzer.start(inputSequence: input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func legacyTranscription(_ samples: [Int16], locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw OnDeviceSpeechError.unavailable("This phone has no on-device recognizer for \(locale.identifier).")
        }
        guard recognizer.isAvailable else {
            throw OnDeviceSpeechError.unavailable("The recognizer is busy or not ready.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.append(try Self.buffer(samples, converting: nil))
        request.endAudio()
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    once.run { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    once.run { continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
        }
    }

    /// 16 kHz Float32 mono, converted to `format` when one is given.
    private static func buffer(_ samples: [Int16], converting format: AVAudioFormat?) throws -> AVAudioPCMBuffer {
        guard let relay = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: relay, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0] else {
            throw OnDeviceSpeechError.unavailable("Could not prepare the audio.")
        }
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / Float(Int16.max)
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        guard let format, format != relay else { return source }

        guard let converter = AVAudioConverter(from: relay, to: format) else {
            throw OnDeviceSpeechError.unavailable("Could not convert the audio.")
        }
        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / relay.sampleRate).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw OnDeviceSpeechError.unavailable("Could not convert the audio.")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        return output
    }
}

/// Resumes a continuation at most once; the recognizer may call back again.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
#endif
