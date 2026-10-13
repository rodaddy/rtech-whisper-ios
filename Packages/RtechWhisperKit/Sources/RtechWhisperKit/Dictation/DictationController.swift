import Foundation
import Observation

/// Record, queue, send, show. The Dictate screen renders `state`, `latest`,
/// `latestText`, `onDeviceNotice`, `cleanupNotice`, and `waiting`, and calls
/// `record`, `stop`, `retry`, and `edit`.
///
/// When the hub is unreachable at `stop`, the recording is transcribed on the
/// phone right away and shown as provisional text; Whisper replaces it when
/// the queue drains, unless the person has edited it since.
@MainActor
@Observable
public final class DictationController {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        /// The latest recording is saved on the phone and waiting for the hub.
        /// `latestText` may already hold its on-device text.
        case queued
        /// The latest recording came back from the hub and is being cleaned up.
        case cleaning
        /// The latest recording came back from the hub.
        case done
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// The most recent recording, as the queue last reported it.
    public private(set) var latest: QueuedDictation?
    /// Every item not yet transcribed, oldest first.
    public private(set) var waiting: [QueuedDictation] = []
    /// Set when on-device text could not be produced; the recording just
    /// waits for the hub.
    public private(set) var onDeviceNotice: String?
    /// Set when the cleanup model failed on the latest dictation, so its text
    /// is the transcript without AI cleanup (the desktop's "Cleanup failed"
    /// toast). Older takes never set it. Cleared by the next recording.
    public private(set) var cleanupNotice: String?
    public static let cleanupFailedNotice = "AI cleanup failed, so the dictation was kept without it."

    /// The text to show for the most recent recording: the person's edit,
    /// else Whisper, else the on-device text.
    public var latestText: String? { latest?.text }

    /// Called once per recording when Whisper's text arrives and is not
    /// empty, with the item as the queue holds it, after `postProcessor` has
    /// run (so `cleanedText` is set when cleanup changed the text). The app
    /// saves it to the transcription history. A recording already reported
    /// before a relaunch is not reported again; one finished but not yet
    /// reported when the process died is reported after the relaunch. The
    /// item is marked reported only after this returns; when it throws (the
    /// history row was not saved) the item is reported again on the next
    /// refresh or relaunch.
    public var onTranscribed: (@MainActor (QueuedDictation) async throws -> Void)?
    /// AI cleanup for each Whisper text before it is shown and reported.
    /// `nil` shows Whisper's words as they came.
    public var postProcessor: DictationPostProcessor?
    private var reportedIDs: Set<UUID> = []
    /// Takes deleted in this process; a refresh already holding one skips it.
    private var deletedIDs: Set<UUID> = []

    private let recorder: any AudioCapturing
    private let queue: DictationQueue
    private let transcribe: Transcribe
    private let onDevice: (any OnDeviceTranscribing)?
    private let requestMicrophone: RequestMicrophone
    private let reachability: (any ReachabilityMonitoring)?
    /// The "Transcribe on this iPhone" setting, read at each `stop`.
    private let transcribeOnDeviceFirst: @MainActor () -> Bool
    private var latestID: UUID?
    private var editTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var stopping = false

    public init(
        recorder: any AudioCapturing,
        queue: DictationQueue,
        transcribe: @escaping Transcribe,
        onDevice: (any OnDeviceTranscribing)? = nil,
        requestMicrophone: @escaping RequestMicrophone,
        reachability: (any ReachabilityMonitoring)? = nil,
        transcribeOnDevice: @escaping @MainActor () -> Bool = { false }
    ) {
        self.transcribeOnDeviceFirst = transcribeOnDevice
        self.recorder = recorder
        self.queue = queue
        self.transcribe = transcribe
        self.onDevice = onDevice
        self.requestMicrophone = requestMicrophone
        self.reachability = reachability
    }

    /// Show what is already queued, drain it, and drain again whenever the
    /// network comes back.
    public func start() async {
        // Only what already reached the history. An item Whisper finished
        // but the process died before reporting (for example during cleanup)
        // is reported by the next refresh.
        for item in await queue.items() where item.whisperText != nil && item.reported != false {
            reportedIDs.insert(item.id)
        }
        reachability?.start { [weak self] reachable in
            guard reachable else { return }
            Task { @MainActor in await self?.retry() }
        }
        await retry()
    }

    /// Open the microphone. The permission prompt appears on the first call.
    public func record() async {
        guard state != .recording else { return }
        guard await requestMicrophone() else {
            state = .failed("Microphone access is off. Turn it on in Settings.")
            return
        }
        do {
            try recorder.start()
            state = .recording
        } catch {
            state = .failed("Could not start recording. \(error.localizedDescription)")
        }
    }

    /// Close the microphone, save the recording to the queue, and try to send.
    /// If the hub is unreachable, transcribe on the phone instead for now.
    public func stop() async {
        // A second stop (the Live Activity's button racing the screen's)
        // arrives while the first awaits the queue; it must not stop the
        // recorder again and fail on the empty take.
        guard state == .recording, !stopping else { return }
        stopping = true
        defer { stopping = false }
        let samples = recorder.stop()
        guard !samples.isEmpty else {
            state = .failed("Nothing was recorded.")
            return
        }
        let id: UUID
        do {
            let durationMs = samples.count * 1000 / WavEncoder.relaySampleRate
            id = try await queue.enqueue(WavEncoder.pcm16MonoWav(samples: samples), durationMs: durationMs).id
        } catch {
            state = .failed("Could not save the recording. \(error.localizedDescription)")
            return
        }
        latestID = id
        latest = nil
        onDeviceNotice = nil
        cleanupNotice = nil
        state = .queued
        // Setting on: the phone's text finishes the take as the hub's would
        // (history, push, card). Any failure leaves it for the hub below.
        if transcribeOnDeviceFirst(), let onDevice,
            let text = try? await onDevice.transcribe(samples),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await queue.complete(id, text: text)
        }
        if case .stopped(.network) = await drainAndRefresh() {
            await transcribeOnDevice(samples, for: id)
        }
    }

    /// Send whatever is waiting. The app calls this on foreground; the
    /// reachability monitor calls it when the network returns.
    public func retry() async {
        _ = await drainAndRefresh()
    }

    /// Replace the shown text of the most recent recording with what the
    /// person typed. Whisper text that arrives later is kept alongside as
    /// `alternateText` instead of overwriting the edit. Edits persist in the
    /// order they were made; the returned task finishes when this one has.
    @discardableResult
    public func edit(_ text: String) -> Task<Void, Never> {
        guard let id = latestID, latest != nil else { return Task {} }
        latest?.editedText = text
        let queue = queue
        let previous = editTask
        let task = Task {
            await previous?.value
            await queue.edit(id, text: text)
        }
        editTask = task
        return task
    }

    /// Delete a take from this phone: its queue entry (so an unsent take is
    /// never sent), its history row (local only, as `TranscriptionStore.delete`;
    /// the app saves each take under its queue id), and its keyboard handoff.
    /// A take already pushed stays on the hub. Clears the card when `id` is
    /// still the latest take.
    public func delete(take id: UUID, history: HistoryViewModel?, handoff: PendingTranscriptStore?) async {
        deletedIDs.insert(id)
        await editTask?.value
        await queue.remove(id)
        handoff?.discard(take: id)
        await history?.delete(id.uuidString)
        waiting.removeAll { $0.id == id }
        guard latestID == id else { return }
        latestID = nil
        latest = nil
        onDeviceNotice = nil
        cleanupNotice = nil
        if state != .recording { state = .idle }
    }

    private func drainAndRefresh() async -> DrainResult {
        await editTask?.value
        let result = await queue.drain(using: transcribe)
        await refresh()
        return result
    }

    private func transcribeOnDevice(_ samples: [Int16], for id: UUID) async {
        guard let onDevice else { return }
        do {
            let text = try await onDevice.transcribe(samples)
            await queue.setProvisional(id, text: text)
            await refresh()
        } catch let error as OnDeviceSpeechError {
            onDeviceNotice = error.userMessage
        } catch {
            onDeviceNotice = "On-device speech failed, so the recording waits for the hub. \(error.localizedDescription)"
        }
    }

    /// Refreshes run one at a time, in call order, so a refresh that starts
    /// while another is still cleaning never publishes the raw text as done.
    private func refresh() async {
        let previous = refreshTask
        let task = Task {
            await previous?.value
            await performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        await editTask?.value
        var items = await queue.items()
        // Claim the new Whisper texts first so an overlapping refresh does
        // not clean or report them twice.
        let fresh = items.filter { $0.whisperText?.isEmpty == false && reportedIDs.insert($0.id).inserted }
        if let postProcessor, !fresh.isEmpty {
            if state != .recording, fresh.contains(where: { $0.id == latestID }) { state = .cleaning }
            for item in fresh {
                guard let raw = item.whisperText else { continue }
                let processed = await postProcessor.process(raw)
                // The notice sits above `latest`, so only the latest take's
                // failure sets it: an older take drained alongside, or a
                // backlog take a retry cleans, must not blame this one.
                // `latestID` is read now, so a refresh still cleaning when
                // `stop` starts a new take does not blame the new one.
                if processed.cleanupFailed, item.id == latestID { cleanupNotice = Self.cleanupFailedNotice }
                // Store any change, a trim alone included; `wasCleaned` is only the label.
                if processed.text != raw { await queue.setCleaned(item.id, text: processed.text) }
            }
            items = await queue.items()
        }
        let freshIDs = Set(fresh.map(\.id))
        for item in items where freshIDs.contains(item.id) {
            // Deleted while this refresh was cleaning it: never saved.
            guard !deletedIDs.contains(item.id) else { continue }
            do {
                try await onTranscribed?(item)
            } catch {
                // Not saved: leave it unreported so a later pass tries again.
                reportedIDs.remove(item.id)
                continue
            }
            await queue.markReported(item.id)
        }
        waiting = items.filter {
            if case .done = $0.state { return false }
            return true
        }
        guard let latestID, let item = items.first(where: { $0.id == latestID }) else { return }
        latest = item
        guard state != .recording else { return }
        switch item.state {
        case .done:
            state = .done
        case .failed(let reason):
            state = .failed(reason)
        case .pending, .sending:
            state = .queued
        }
    }
}
