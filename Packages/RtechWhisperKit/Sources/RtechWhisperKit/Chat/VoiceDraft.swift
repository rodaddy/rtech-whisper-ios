import Foundation
import Observation

/// A mic take for the chat composer (the desktop's `useVoiceDraft`): record,
/// transcribe through the relay, hand the text back for the composer. It
/// never enters the dictation queue or the history. When the hub cannot be
/// reached, the on-device recognizer answers instead, when there is one.
@MainActor
@Observable
public final class VoiceDraft {
    public enum Status: Equatable, Sendable {
        case idle
        case recording
        case transcribing
    }

    /// Why the last take produced no text.
    public enum Failure: Equatable, Sendable {
        case microphoneDenied
        /// Another capture (the dictation) took the microphone while the
        /// permission prompt was up.
        case microphoneBusy
        case recorderFailed(String)
        case nothingRecorded
        case noSpeech
        /// The relay failed and there was no on-device text either.
        case transcription(HubError)
    }

    public private(set) var status: Status = .idle
    /// When the take in progress started; nil when not recording.
    public private(set) var recordingSince: Date?
    /// Set when the last take produced no text; cleared by the next `record`
    /// and by `cancel`, so it does not follow the user to another chat.
    public private(set) var failure: Failure?

    private let recorder: any AudioCapturing
    private let transcribe: Transcribe
    private let onDevice: (any OnDeviceTranscribing)?
    private let requestMicrophone: RequestMicrophone
    private let now: @Sendable () -> Date
    private let otherCaptureActive: @MainActor () -> Bool
    private let transcribeOnDeviceFirst: @MainActor () -> Bool
    /// True while `record` waits for microphone permission.
    private var requesting = false
    /// Bumped by `cancel`, so a `record` still waiting for permission knows
    /// it was called off and never opens the microphone.
    private var generation = 0

    /// - Parameter otherCaptureActive: true while another capture (the
    ///   dictation) holds the microphone. The phone has one audio session,
    ///   so a take never starts on top of it.
    /// - Parameter transcribeOnDevice: Settings > Transcribe on this iPhone.
    ///   When on, the phone transcribes first and the hub is only asked if
    ///   that fails, as dictation does.
    public init(
        recorder: any AudioCapturing,
        transcribe: @escaping Transcribe,
        onDevice: (any OnDeviceTranscribing)? = nil,
        requestMicrophone: @escaping RequestMicrophone,
        otherCaptureActive: @escaping @MainActor () -> Bool = { false },
        now: @escaping @Sendable () -> Date = { Date() },
        transcribeOnDevice: @escaping @MainActor () -> Bool = { false }
    ) {
        self.transcribeOnDeviceFirst = transcribeOnDevice
        self.otherCaptureActive = otherCaptureActive
        self.recorder = recorder
        self.transcribe = transcribe
        self.onDevice = onDevice
        self.requestMicrophone = requestMicrophone
        self.now = now
    }

    /// True when `record` would open the microphone: no take in progress or
    /// waiting for permission, and no other capture holding the microphone.
    public var canRecord: Bool {
        status == .idle && !requesting && !otherCaptureActive()
    }

    /// Opens the microphone. Does nothing while a take is in progress or
    /// while another capture holds the microphone. A `cancel` while the
    /// permission prompt is up calls the take off.
    public func record() async {
        guard canRecord else { return }
        failure = nil
        requesting = true
        let take = generation
        let granted = await requestMicrophone()
        guard take == generation else { return }
        requesting = false
        guard granted else {
            failure = .microphoneDenied
            return
        }
        guard !otherCaptureActive() else {
            failure = .microphoneBusy
            return
        }
        do {
            try recorder.start()
            status = .recording
            recordingSince = now()
        } catch {
            failure = .recorderFailed(error.localizedDescription)
        }
    }

    /// Closes the microphone and transcribes. Returns the text, or nil with
    /// `failure` set when there is none.
    public func stop() async -> String? {
        guard status == .recording else { return nil }
        let samples = recorder.stop()
        recordingSince = nil
        guard !samples.isEmpty else {
            status = .idle
            failure = .nothingRecorded
            return nil
        }
        status = .transcribing
        defer { status = .idle }
        if transcribeOnDeviceFirst(), let onDevice, let text = try? await onDevice.transcribe(samples),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return heard(text)
        }
        do {
            let transcript = try await transcribe(WavEncoder.pcm16MonoWav(samples: samples))
            return heard(transcript.noSpeech ? "" : transcript.text)
        } catch {
            // Only an unreachable hub falls back: any other hub error (a
            // revoked key, say) is reported, not hidden behind on-device text.
            guard case .network = error, let onDevice, let text = try? await onDevice.transcribe(samples) else {
                failure = .transcription(error)
                return nil
            }
            return heard(text)
        }
    }

    /// Closes the microphone and throws the take away; a take still waiting
    /// for permission never starts. Clears `failure`.
    public func cancel() {
        failure = nil
        if requesting {
            requesting = false
            generation += 1
        }
        guard status == .recording else { return }
        _ = recorder.stop()
        recordingSince = nil
        status = .idle
    }

    private func heard(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failure = .noSpeech
            return nil
        }
        return text
    }
}
