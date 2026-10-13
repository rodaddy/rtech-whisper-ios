import Foundation

/// Captures one dictation. `start` opens the microphone; `stop` closes it and
/// returns what was heard as 16 kHz Int16 mono, ready for `WavEncoder`.
public protocol AudioCapturing: AnyObject, Sendable {
    func start() throws
    func stop() -> [Int16]
}

#if canImport(AVFAudio)
import AVFAudio
import Synchronization

/// The real microphone, via `AVAudioEngine`.
///
/// The audio session is activated only inside `start()` and deactivated in
/// `stop()`, so the microphone stays cold while idle. The tap only copies
/// samples; every conversion is `AudioConverter`, which is unit-tested.
///
/// The session is the process's one `AVAudioSession`, shared by every
/// recorder: `stop()` deactivates it only when no other recorder is still
/// running, since deactivating it stops that recorder's input too.
///
/// Not unit-tested: it needs microphone hardware and a signed host.
public final class EngineRecorder: AudioCapturing, @unchecked Sendable {
    /// How many recorders are running on the shared session.
    static let running = Mutex(0)
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var captured: [Float] = []
    private var inputRate: Double = 0

    public init() {}

    public func start() throws {
        _ = stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        lock.withLock {
            captured = []
            inputRate = format.sampleRate
        }
        // Deprecated in the 27 SDKs in favour of an error-returning variant
        // that is NS_REFINED_FOR_SWIFT with no public Swift overlay yet.
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).map {
                Array(UnsafeBufferPointer(start: channelData[$0], count: frames))
            }
            let mono = AudioConverter.downmix(channels)
            self.lock.withLock { self.captured.append(contentsOf: mono) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if Self.running.withLock({ $0 == 0 }) { deactivateSession() }
            throw error
        }
        Self.running.withLock { $0 += 1 }
        lock.withLock { self.engine = engine }
    }

    public func stop() -> [Int16] {
        let (engine, samples, rate) = lock.withLock { () -> (AVAudioEngine?, [Float], Double) in
            defer { self.engine = nil; captured = [] }
            return (self.engine, captured, inputRate)
        }
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let last = Self.running.withLock { count in
            count = max(0, count - 1)
            return count == 0
        }
        if last { deactivateSession() }
        return AudioConverter.toRelayPCM(samples, sampleRate: rate)
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
#endif
