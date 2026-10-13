import Foundation
import Observation
import OSLog

/// Audio in the relay's shape, 16 kHz Int16 mono, handed out a chunk at a
/// time so a long file is never held whole. `AudioFileReader` in the app.
public protocol AudioSampleSource: Sendable {
    /// The file's length as the decoder read it, before any trimming.
    var durationSeconds: Double { get }
    /// The next samples, at most `maxSamples` of them; empty at the end.
    /// A source that fails part-way first returns the samples it decoded
    /// before the failure, and throws only on a read with none left.
    func read(maxSamples: Int) async throws -> [Int16]
}

/// Audio already decoded in full: 16 kHz Int16 mono. Tests use it as a source.
public struct DecodedAudio: Sendable, Equatable {
    public let samples: [Int16]
    /// The file's length as the decoder read it, before any trimming.
    public let durationSeconds: Double

    public init(samples: [Int16], durationSeconds: Double) {
        self.samples = samples
        self.durationSeconds = durationSeconds
    }

    /// A source that hands these samples out in order.
    public var source: any AudioSampleSource { BufferedAudioSource(self) }
}

/// `DecodedAudio` read from the front, a chunk at a time.
public actor BufferedAudioSource: AudioSampleSource {
    public nonisolated let durationSeconds: Double
    private let samples: [Int16]
    private var offset = 0

    public init(_ audio: DecodedAudio) {
        samples = audio.samples
        durationSeconds = audio.durationSeconds
    }

    public func read(maxSamples: Int) -> [Int16] {
        let end = min(offset + max(0, maxSamples), samples.count)
        defer { offset = end }
        return Array(samples[offset..<end])
    }
}

/// Opens an audio file for reading. `AudioFileDecoder.open` in the app.
public typealias DecodeAudioFile = @Sendable (URL) async throws -> any AudioSampleSource

/// Sends one WAV to the relay with the dictionary hint as `prompt`.
public typealias TranscribeWithPrompt = @Sendable (Data, String?) async throws(HubError) -> Transcript

/// Splits a long file into relay-sized requests. The hub itself cuts audio
/// into 25 s Whisper chunks (protocol section 10.1); this only keeps each
/// request under the 25 MB body cap (section 10.3). A request that would run
/// past the cap is cut at the quietest moment near its end, so a cut rarely
/// lands inside a word; requests share no audio.
public enum UploadChunker {
    /// Ten minutes of 16 kHz PCM16 is 19.2 MB, under the 25 MB cap with room
    /// for the multipart framing.
    public static let maxChunkSeconds = 600

    /// How far back from the end of a full request `cutIndex` looks for quiet.
    static let cutSearchSeconds = 5

    /// Samples in one request at most.
    static func chunkSamples(sampleRate: Int, maxSeconds: Int) -> Int {
        max(1, sampleRate * maxSeconds)
    }

    /// How many 50 ms frames `cutIndex` searches in a request of `count`
    /// samples: those in its last `cutSearchSeconds`, and never more than its
    /// second half, so a short request is not cut near its start.
    static func searchFrames(count: Int, sampleRate: Int) -> Int {
        min(count / 2, cutSearchSeconds * sampleRate) / max(1, sampleRate / 20)
    }

    /// Where to cut a full request `samples` that more audio follows: the
    /// centre of the quietest 50 ms frame (lowest RMS) in its last
    /// `searchFrames`, the latest frame on a tie. Frames do not overlap
    /// and end at the end of `samples`. Always in `1...samples.count`.
    public static func cutIndex(samples: [Int16], sampleRate: Int) -> Int {
        cutIndex(samples: samples[...], sampleRate: sampleRate)
    }

    /// `cutIndex` on a slice, counted from the slice's start, so a caller
    /// need not copy the request to search its end.
    static func cutIndex(samples: ArraySlice<Int16>, sampleRate: Int) -> Int {
        let frame = max(1, sampleRate / 20)
        let frames = searchFrames(count: samples.count, sampleRate: sampleRate)
        guard frames > 0 else { return samples.count }
        let base = samples.startIndex
        var best = samples.count - frame
        var bestEnergy = Int64.max
        // From the earliest frame on, so a later frame wins a tie.
        for start in stride(from: samples.count - frames * frame, through: samples.count - frame, by: frame) {
            var energy: Int64 = 0
            for sample in samples[(base + start)..<(base + start + frame)] { energy += Int64(sample) * Int64(sample) }
            if energy <= bestEnergy {
                bestEnergy = energy
                best = start
            }
        }
        return max(1, best + frame / 2)
    }

    /// At least as many requests as `sampleCount` samples are cut into:
    /// every request but the last is at least as long as the earliest cut
    /// `cutIndex` can make. 0 for no samples.
    public static func chunkCount(
        sampleCount: Int, sampleRate: Int = WavEncoder.relaySampleRate, maxSeconds: Int = maxChunkSeconds
    ) -> Int {
        guard sampleCount > 0 else { return 0 }
        let step = chunkSamples(sampleRate: sampleRate, maxSeconds: maxSeconds)
        guard sampleCount > step else { return 1 }
        let frame = max(1, sampleRate / 20)
        let frames = searchFrames(count: step, sampleRate: sampleRate)
        let shortest = frames > 0 ? max(1, step - frames * frame + frame / 2) : step
        return 1 + (sampleCount - step + shortest - 1) / shortest
    }

    /// One text from the chunks' texts: trimmed, blanks dropped, one space between.
    public static func merge(_ texts: [String]) -> String {
        texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What an upload produced.
public struct UploadResult: Sendable, Equatable {
    public let fileName: String
    public let text: String
    public let durationSeconds: Double
    /// True when the hub heard no speech in any chunk; `text` is then empty.
    public let noSpeech: Bool
    /// True when the file stopped being readable part-way; `text` covers
    /// only the audio before that point, and `durationSeconds` is that
    /// audio's length, not the whole file's.
    public let truncated: Bool
    /// Why the file stopped being readable, from the read that failed, when `truncated`.
    public let truncationReason: String?
    /// The history row's `clientId`: the kept upload's checkpoint id, so an
    /// upload finished again after a relaunch rewrites no second row. `nil`
    /// when the upload was not kept.
    public let clientId: String?

    public init(
        fileName: String, text: String, durationSeconds: Double, noSpeech: Bool, truncated: Bool = false,
        truncationReason: String? = nil, clientId: String? = nil
    ) {
        self.fileName = fileName
        self.text = text
        self.durationSeconds = durationSeconds
        self.noSpeech = noSpeech
        self.truncated = truncated
        self.truncationReason = truncationReason
        self.clientId = clientId
    }

    /// The history row's `audio_duration_ms`.
    public var durationMs: Int { Int((durationSeconds * 1000).rounded()) }
}

/// Why an upload stopped.
public enum UploadFailure: Error, Equatable, Sendable {
    /// The file could not be read or decoded. Carries the decoder's description.
    case unreadable(String)
    /// The file decoded to no audio at all.
    case emptyAudio
    /// The file is longer than `UploadJob.maxDurationSeconds`.
    case tooLong(maxSeconds: Int)
    /// The relay refused or could not be reached. The view words it.
    case hub(HubError)

    /// A `tooLong` limit in words: "4 hours", "1 hour 30 minutes", "45 minutes".
    public static func limitText(seconds: Int) -> String {
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        var parts: [String] = []
        if hours > 0 { parts.append(count(hours, "hour")) }
        if minutes > 0 || hours == 0 { parts.append(count(minutes, "minute")) }
        return parts.joined(separator: " ")
    }
}

/// Pick a file, decode it, send it, show the text. The Upload screen renders
/// `state` and calls `run`, `resume` and `reset`. One upload runs at a time.
@MainActor
@Observable
public final class UploadJob {
    public enum State: Equatable, Sendable {
        case idle
        case decoding(fileName: String)
        /// Sending chunk `chunk` of `count` (1-based).
        case transcribing(fileName: String, chunk: Int, count: Int)
        case done(UploadResult)
        case failed(fileName: String, UploadFailure)
    }

    /// Whether a finished upload's text reached the transcription history.
    public enum SaveOutcome: Equatable, Sendable {
        /// `onTranscribed` returned, or there was nothing to save.
        case saved
        /// `onTranscribed` threw. `kept` when the upload's checkpoint is kept,
        /// so `retrySave` or the next launch saves it again; otherwise the
        /// text on screen is the only copy.
        case notSaved(kept: Bool)
        /// The file stopped being readable part-way (#156): nothing was saved
        /// to the history. `kept` when its checkpoint is kept, so the next
        /// `resumeUnfinished` retries it until it reads to the end or the
        /// user removes it (`reset`).
        case incomplete(kept: Bool)
        /// A retry of a truncated upload read no further than the pass before
        /// it, so it is never retried again: kept, with its text shown, until
        /// the user removes it (`reset`). Nothing was saved to the history.
        case partial
    }

    public private(set) var state: State = .idle

    /// Set when a pass finishes (`.done`); `nil` before that and while its
    /// text is being saved. The Upload screen's footer and buttons read only this.
    public private(set) var saveOutcome: SaveOutcome?

    /// True while `retrySave` runs.
    public private(set) var isRetryingSave = false

    /// Called once per upload whose text is not empty, so the app can save it
    /// to the transcription history. Awaited before the kept upload is
    /// deleted; a throw means the text was not saved, and the upload is kept
    /// so a relaunch finishes it again, with the same `clientId`.
    public var onTranscribed: (@MainActor (UploadResult) async throws -> Void)?

    private let decode: DecodeAudioFile
    private let transcribe: TranscribeWithPrompt
    private let prompt: @MainActor () -> String?
    private let maxChunkSeconds: Int
    private let sleep: @Sendable (Duration) async -> Void
    /// Keeps each upload across launches; `nil` keeps it only in memory.
    private let saving: UploadSaving?
    /// Carries a kept upload's chunks while the app is suspended (#96);
    /// `nil` sends every chunk through `transcribe`.
    private let background: (any BackgroundTransport)?

    /// Sends per chunk, counting the first, before a busy hub fails the upload.
    public static let maxAttempts = 3
    /// The longest `Retry-After` honoured before a resend.
    static let maxRetryDelaySeconds = 30
    /// The longest file an upload takes: four hours, at most 25 requests.
    public static let maxDurationSeconds = 4 * 60 * 60

    /// An upload stopped by the hub, kept so `resume` carries on from the
    /// chunk that failed instead of sending the whole file again.
    private struct Pass {
        let fileName: String
        let source: any AudioSampleSource
        let hint: String?
        /// Chunks expected: an upper bound, set to the true count at the last chunk.
        var count: Int
        var texts: [String] = []
        var allSilent = true
        /// Chunks sent and answered.
        var done = 0
        /// Samples in the chunks sent and answered.
        var sentSamples = 0
        /// Audio read but not yet sent: what followed the last cut, sent at
        /// the start of the next chunk.
        var carry: [Int16] = []
        /// Set once a read failed part-way, to why in the user's words; nothing more is read.
        var truncationReason: String?
        var truncated: Bool { truncationReason != nil }
        /// The chunk the hub failed, sent first on resume.
        var failedChunk: [Int16]?
        /// The checkpoint id and file copy when `saving` keeps this upload.
        var saved: (id: UUID, copy: URL)?
        /// Set when this pass retries a truncated upload: the samples the
        /// pass before it reached. Ending truncated no further makes it partial.
        var truncatedAt: Int?
    }

    private var interrupted: Pass?
    /// The checkpoint and copy of the finished upload whose history save
    /// threw, while `saveOutcome` is `.notSaved(kept: true)`. Only `reset`
    /// (Discard) and a `retrySave` that succeeds end it.
    private var unsaved: (id: UUID, copy: URL)?
    /// The checkpoint and copy of the truncated upload on screen, while
    /// `saveOutcome` is `.incomplete(kept: true)` or `.partial`. `reset` (Remove) forgets it.
    private var incomplete: (id: UUID, copy: URL)?

    /// True while a result not saved is kept: `run` does nothing, so picking
    /// another file never drops it. Discard it or retry its save first.
    public var holdsUnsavedResult: Bool { saveOutcome == .notSaved(kept: true) }

    /// True while a finished pass is saving its text, before `saveOutcome` is
    /// set: `run` waits for it too, so the outcome is never lost to a new pass.
    public var isSavingResult: Bool {
        if case .done = state { saveOutcome == nil } else { false }
    }

    /// Names of the copies this process's uploads hold, which `resumeUnfinished`
    /// never sweeps even before their first checkpoint is saved.
    private var held: Set<String> = []

    /// `carryOnAfterEvents` calls waiting for the next chunk to be handed to
    /// the system or for the pass to end.
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - prompt: the dictionary hint to send with every chunk; `nil` for none.
    ///   - sleep: waits between resends of a chunk the hub was too busy for.
    ///   - saving: where each upload is kept, so `resumeUnfinished` carries it on after a relaunch.
    public init(
        decode: @escaping DecodeAudioFile,
        transcribe: @escaping TranscribeWithPrompt,
        prompt: @escaping @MainActor () -> String? = { nil },
        maxChunkSeconds: Int = UploadChunker.maxChunkSeconds,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        saving: UploadSaving? = nil,
        background: (any BackgroundTransport)? = nil
    ) {
        self.decode = decode
        self.transcribe = transcribe
        self.prompt = prompt
        self.maxChunkSeconds = maxChunkSeconds
        self.sleep = sleep
        self.saving = saving
        self.background = background
    }

    /// How long to wait before resending after `error`, or `nil` when the
    /// error is not worth a resend. Protocol section 10 asks clients to retry
    /// 429 and 5xx with backoff; `attempt` is the 1-based send that failed.
    static func retryDelay(after error: HubError, attempt: Int) -> Duration? {
        let backoff = 1 << attempt
        switch error {
        case .rateLimited(let retryAfter):
            return .seconds(min(retryAfter ?? backoff, maxRetryDelaySeconds))
        case .upstreamUnavailable:
            return .seconds(backoff)
        case .server(let status, _, _) where status >= 500:
            return .seconds(backoff)
        default:
            return nil
        }
    }

    /// One chunk, resent while the hub is busy, up to `maxAttempts` sends.
    /// A kept upload's chunk goes as `tag` through `background` when there is one.
    private func send(_ wav: Data, hint: String?, tag: UploadChunkTag?) async throws(HubError) -> Transcript {
        var attempt = 1
        while true {
            do {
                if let background, let tag {
                    return try await background.transcribe(wav, hint: hint, tag: tag) { [weak self] in
                        Task { @MainActor in self?.settle() }
                    }
                }
                return try await transcribe(wav, hint)
            } catch {
                guard attempt < Self.maxAttempts, let delay = Self.retryDelay(after: error, attempt: attempt) else {
                    throw error
                }
                await sleep(delay)
                attempt += 1
            }
        }
    }

    public var isRunning: Bool {
        switch state {
        case .decoding, .transcribing: true
        case .idle, .done, .failed: false
        }
    }

    /// True when the hub stopped an upload part-way; `resume` carries on
    /// from the failed chunk, keeping the text of the chunks before it.
    public var canResume: Bool { !isRunning && interrupted != nil }

    /// Progress through the chunks, 0...1, while transcribing; `nil` otherwise.
    public var progress: Double? {
        guard case .transcribing(_, let chunk, let count) = state, count > 0 else { return nil }
        return Double(chunk - 1) / Double(count)
    }

    public var result: UploadResult? {
        if case .done(let result) = state { return result }
        return nil
    }

    /// Decode and transcribe `url`. A call while another upload runs, or
    /// while a finished result is being saved or a result not saved is kept
    /// (`holdsUnsavedResult`), is ignored.
    public func run(url: URL) async {
        guard !isRunning, !isSavingResult, !holdsUnsavedResult else { return }
        // A file that fails to open ends the run with no pass to settle it.
        defer { settle() }
        let abandoned = interrupted?.saved
        interrupted = nil
        // A truncated upload stays kept for its next retry.
        incomplete = nil
        saveOutcome = nil
        let fileName = url.lastPathComponent
        state = .decoding(fileName: fileName)
        await forget(abandoned)

        // The picked URL does not outlive the process, so a kept upload reads its own copy.
        var file = url
        var saved: (id: UUID, copy: URL)?
        if let saving {
            let id = UUID()
            held.insert(saving.copy(of: url, id: id).lastPathComponent)
            do {
                file = try await saving.adopt(url, id: id)
                saved = (id, file)
            } catch {
                // Upload anyway; this one only does not outlive the process.
                held.remove(saving.copy(of: url, id: id).lastPathComponent)
                Self.log.error("Upload copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let source: any AudioSampleSource
        do {
            source = try await decode(file)
        } catch {
            await forget(saved)
            state = .failed(fileName: fileName, .unreadable(error.localizedDescription))
            return
        }
        guard source.durationSeconds <= Double(Self.maxDurationSeconds) else {
            await forget(saved)
            state = .failed(fileName: fileName, .tooLong(maxSeconds: Self.maxDurationSeconds))
            return
        }
        let estimated = Int(source.durationSeconds * Double(WavEncoder.relaySampleRate))
        let count = max(1, UploadChunker.chunkCount(sampleCount: estimated, maxSeconds: maxChunkSeconds))
        var pass = Pass(fileName: fileName, source: source, hint: prompt(), count: count)
        pass.saved = saved
        await persist(pass, .sending)
        await transcribe(pass)
    }

    /// Carries on every upload a relaunch finds saved, oldest first, each
    /// from its first chunk not done. Stops at one the hub stops again, which
    /// the Upload screen offers to resume; any after it wait for the next launch.
    public func resumeUnfinished() async {
        guard let saving, !isRunning, interrupted == nil, !holdsUnsavedResult else { return }
        let checkpoints: [UploadCheckpoint]
        do {
            checkpoints = try await saving.store.unfinished()
        } catch {
            Self.log.error("Saved uploads unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Checked again with no await before the sweep, so an upload the user
        // started meanwhile keeps its copy. A copy no checkpoint names was
        // left by a kill before its first save or by a failed copy.
        guard !isRunning, interrupted == nil, !holdsUnsavedResult else { return }
        let removed = saving.sweep(keeping: held.union(checkpoints.map(\.copyName)))
        if removed > 0 { Self.log.info("Removed \(removed) upload copies no checkpoint names") }
        for checkpoint in checkpoints where checkpoint.status != .partial {
            // Stops at the first whose history save fails again: it stays on
            // screen as not saved, and the rest stay kept, untouched, for later.
            guard !isRunning, interrupted == nil, !holdsUnsavedResult else { return }
            await restore(checkpoint, from: saving)
        }
        // A partial upload is never decoded again: its text is shown, only
        // on an empty screen, until the user removes it.
        if state == .idle, let partial = checkpoints.first(where: { $0.status == .partial }) {
            show(partial, from: saving)
        }
    }

    /// After a background session's events: carries on the kept upload and
    /// returns once its next chunk is handed to the system, or once no pass
    /// has a chunk left to send. The app holds the system's completion
    /// handler and a background task until then, so the app is not
    /// suspended before the next chunk is on its way. The upload itself
    /// goes on after this returns. A pass already running (the app was
    /// suspended, not killed) is the one carried on; otherwise the kept
    /// uploads are resumed (`resumeUnfinished`).
    public func carryOnAfterEvents() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            settleWaiters.append(waiter)
            guard !isRunning else { return }
            Task {
                await resumeUnfinished()
                settle()
            }
        }
    }

    /// Resumes every `carryOnAfterEvents` waiting: a chunk was handed to the
    /// system, or a pass ended.
    private func settle() {
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Puts a partial upload's saved text on screen, with no decode.
    private func show(_ checkpoint: UploadCheckpoint, from saving: UploadSaving) {
        held.insert(checkpoint.copyName)
        incomplete = (id: checkpoint.id, copy: saving.copy(checkpoint))
        state = .done(
            UploadResult(
                fileName: checkpoint.fileName, text: UploadChunker.merge(checkpoint.texts),
                durationSeconds: Double(checkpoint.sentSamples) / Double(WavEncoder.relaySampleRate),
                noSpeech: checkpoint.allSilent, truncated: true, clientId: checkpoint.id.uuidString))
        saveOutcome = .partial
    }

    /// Reopens a saved upload's copy past the chunks already done and sends the rest.
    private func restore(_ checkpoint: UploadCheckpoint, from saving: UploadSaving) async {
        let saved = (id: checkpoint.id, copy: saving.copy(checkpoint))
        held.insert(checkpoint.copyName)
        incomplete = nil
        saveOutcome = nil
        state = .decoding(fileName: checkpoint.fileName)
        let source: any AudioSampleSource
        do {
            source = try await decode(saved.copy)
            try await Self.skip(checkpoint.sentSamples, of: source, step: chunkStep)
        } catch {
            // A copy gone or damaged ends the upload.
            await forget(saved)
            state = .failed(fileName: checkpoint.fileName, .unreadable(error.localizedDescription))
            return
        }
        var pass = Pass(fileName: checkpoint.fileName, source: source, hint: checkpoint.hint, count: checkpoint.expectedChunks)
        pass.texts = checkpoint.texts
        pass.allSilent = checkpoint.allSilent
        pass.done = checkpoint.chunksDone
        pass.sentSamples = checkpoint.sentSamples
        pass.saved = saved
        if checkpoint.status == .truncated { pass.truncatedAt = checkpoint.sentSamples }
        await persist(pass, .sending)
        await transcribe(pass)
    }

    /// Reads and drops the first `count` samples of `source`: the chunks
    /// already sent. A chunk starts where the one before it ended, so the
    /// chunks after are cut as they would have been without the relaunch.
    private static func skip(_ count: Int, of source: any AudioSampleSource, step: Int) async throws {
        var left = count
        while left > 0 {
            let read = try await source.read(maxSamples: min(left, step)).count
            guard read > 0 else { throw AudioFileDecoderError.endedEarly }
            left -= read
        }
    }

    private var chunkStep: Int {
        UploadChunker.chunkSamples(sampleRate: WavEncoder.relaySampleRate, maxSeconds: maxChunkSeconds)
    }

    /// Saves `pass`'s progress when it is kept. Only while the pass runs, so
    /// a save never brings back one that `run` or `reset` already forgot.
    private func persist(_ pass: Pass, _ status: UploadCheckpoint.Status) async {
        guard let saving, let saved = pass.saved else { return }
        let checkpoint = UploadCheckpoint(
            id: saved.id, fileName: pass.fileName, copyName: saved.copy.lastPathComponent, hint: pass.hint,
            status: status, chunksDone: pass.done, sentSamples: pass.sentSamples, expectedChunks: pass.count,
            texts: pass.texts, allSilent: pass.allSilent)
        do {
            try await saving.store.save(checkpoint)
        } catch {
            Self.log.error("Upload checkpoint not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a finished or abandoned upload's checkpoint and copy.
    private func forget(_ saved: (id: UUID, copy: URL)?) async {
        guard let saving, let saved else { return }
        do {
            try await saving.forget(id: saved.id, copy: saved.copy)
        } catch {
            Self.log.error("Upload checkpoint not deleted: \(error.localizedDescription, privacy: .public)")
        }
        held.remove(saved.copy.lastPathComponent)
    }

    /// Carry on with an upload the hub stopped, from the chunk that failed.
    public func resume() async {
        guard canResume, let pass = interrupted else { return }
        interrupted = nil
        await transcribe(pass)
    }

    /// Reads and sends chunk after chunk, each read only when it is sent.
    private func transcribe(_ start: Pass) async {
        // A pass that ends, however it ends, has nothing more to send.
        defer { settle() }
        var pass = start
        let step = chunkStep
        while true {
            let chunk: [Int16]
            let rest: [Int16]
            if let failed = pass.failedChunk {
                chunk = failed
                rest = pass.carry
            } else {
                // The state moves to the next part only once the read shows
                // there is one, so the end of the file shows no phantom part.
                var window = pass.carry
                if !pass.truncated {
                    do {
                        // One sample past a full chunk shows whether more audio follows.
                        window += try await pass.source.read(maxSamples: step + 1 - pass.carry.count)
                    } catch {
                        // Keep the text the hub already sent back: a file damaged
                        // part-way still yields everything before the damage.
                        guard pass.done > 0 else {
                            await forget(pass.saved)
                            state = .failed(fileName: pass.fileName, .unreadable(error.localizedDescription))
                            return
                        }
                        Self.log.error("Upload read stopped part-way: \(error.localizedDescription, privacy: .public)")
                        pass.truncationReason = Self.truncationReason(for: error)
                    }
                }
                if window.isEmpty {
                    guard pass.done > 0 else {
                        await forget(pass.saved)
                        state = .failed(fileName: pass.fileName, .emptyAudio)
                        return
                    }
                    break
                }
                if window.count > step {
                    let cut = UploadChunker.cutIndex(samples: window[..<step], sampleRate: WavEncoder.relaySampleRate)
                    chunk = Array(window[..<cut])
                    rest = Array(window[cut...])
                } else {
                    // Nothing follows this chunk: the count is now known.
                    chunk = window
                    rest = []
                    pass.count = pass.done + 1
                }
            }
            state = .transcribing(fileName: pass.fileName, chunk: pass.done + 1, count: max(pass.count, pass.done + 1))
            do {
                let tag = pass.saved.map { UploadChunkTag(upload: $0.id, chunk: pass.done) }
                // An answer that arrived while the app was not running is used, not resent.
                var finished: Result<Transcript, HubError>?
                if let background, let tag { finished = await background.takeFinished(tag) }
                let transcript: Transcript
                if let finished {
                    transcript = try finished.get()
                } else {
                    transcript = try await send(WavEncoder.pcm16MonoWav(samples: chunk), hint: pass.hint, tag: tag)
                }
                pass.texts.append(transcript.text)
                if !transcript.noSpeech { pass.allSilent = false }
            } catch {
                pass.failedChunk = chunk
                pass.carry = rest
                // A chunk the hub rejected fails again when resent, so only a
                // resumable error keeps the pass and the open file it holds.
                // Saved or forgotten before the state leaves running.
                let resumable = Self.isResumable(error)
                if resumable { await persist(pass, .stopped) } else { await forget(pass.saved) }
                interrupted = resumable ? pass : nil
                state = .failed(fileName: pass.fileName, .hub(error))
                return
            }
            pass.done += 1
            pass.sentSamples += chunk.count
            pass.failedChunk = nil
            pass.carry = rest
            await persist(pass, .sending)
        }

        // The audio sent, not the header's length: the reader reads past a
        // short VBR estimate, and a truncated file stops short of it (#201).
        let duration = Double(pass.sentSamples) / Double(WavEncoder.relaySampleRate)
        let result = UploadResult(
            fileName: pass.fileName, text: UploadChunker.merge(pass.texts),
            durationSeconds: duration, noSpeech: pass.allSilent, truncated: pass.truncated,
            truncationReason: pass.truncationReason, clientId: pass.saved?.id.uuidString)
        state = .done(result)
        // Not complete: no history row, and kept so the next resumeUnfinished
        // retries it (#156), unless this retry read no further than the last.
        if result.truncated {
            let partial = pass.truncatedAt.map { pass.sentSamples <= $0 } ?? false
            await persist(pass, partial ? .partial : .truncated)
            incomplete = pass.saved
            saveOutcome = pass.saved == nil ? .incomplete(kept: false) : partial ? .partial : .incomplete(kept: true)
            return
        }
        if !result.text.isEmpty, let onTranscribed {
            do {
                try await onTranscribed(result)
            } catch {
                // Not saved. A kept checkpoint stays, so `retrySave` or a
                // relaunch saves it again from its texts, with no chunk
                // resent, until the user discards it (`reset`).
                unsaved = pass.saved
                saveOutcome = .notSaved(kept: pass.saved != nil)
                Self.log.error("Upload text not saved: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        saveOutcome = .saved
        // Only once the text is saved: a kill before this finishes the upload
        // again on relaunch, and the same clientId adds no second row.
        await forget(pass.saved)
    }

    /// Whether resending the chunk after `error` can succeed: the hub was
    /// busy or unreachable, the upload was too slow for the hub's 30 s body
    /// read (408), a 2xx body did not decode (a proxy or a hub fault), or
    /// the key was refused and can be fixed in Settings. Not when the hub
    /// rejected the audio or the request itself.
    static func isResumable(_ error: HubError) -> Bool {
        switch error {
        case .network, .rateLimited, .upstreamUnavailable, .unauthorized, .malformedKey, .decoding: true
        case .server(let status, _, _): status >= 500 || status == 408
        default: false
        }
    }

    private static let log = Logger(subsystem: "com.rtech-consulting.whisper", category: "upload")

    /// Why a read stopped part-way, in the user's words: a known reader error
    /// says what went wrong, anything else (an `OSStatus`, say) is general.
    /// The raw error is logged, not shown (#207).
    static func truncationReason(for error: any Error) -> String {
        switch error as? AudioFileDecoderError {
        case .endedEarly: "The file ends before the length it says it has."
        case .conversionFailed, .unsupportedFormat: "Part of the audio could not be converted."
        case nil: "The rest of the file could not be read."
        }
    }

    /// Saves the kept result's text to the history again, under the same
    /// `clientId`. On success the kept upload is deleted and the outcome is
    /// `.saved`; on a throw nothing changes. Only while `holdsUnsavedResult`.
    public func retrySave() async {
        guard holdsUnsavedResult, !isRetryingSave, let result, let saved = unsaved, let onTranscribed else { return }
        isRetryingSave = true
        defer { isRetryingSave = false }
        do {
            try await onTranscribed(result)
        } catch {
            Self.log.error("Upload text not saved again: \(error.localizedDescription, privacy: .public)")
            return
        }
        unsaved = nil
        saveOutcome = .saved
        await forget(saved)
    }

    /// Back to idle, ready for another file. For a result not saved this is
    /// its Discard: a kept upload is deleted. Does nothing while one runs or
    /// while `retrySave` runs.
    public func reset() {
        guard !isRunning, !isRetryingSave else { return }
        if let saved = interrupted?.saved ?? unsaved ?? incomplete { Task { await forget(saved) } }
        interrupted = nil
        unsaved = nil
        incomplete = nil
        saveOutcome = nil
        state = .idle
    }
}
