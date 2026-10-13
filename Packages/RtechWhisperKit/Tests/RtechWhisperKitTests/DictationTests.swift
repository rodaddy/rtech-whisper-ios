import Foundation
import Testing

@testable import RtechWhisperKit

/// A fresh directory in the test process's own temporary area, removed on deinit.
final class ScratchDirectory {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "DictationTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }

    func wavFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }
    }
}

/// A clock that ticks one second per reading, so createdAt order is exact.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date {
        lock.withLock {
            current += 1
            return current
        }
    }
}

/// A transcriber that answers from a script and records what it was sent.
final class ScriptedTranscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<Transcript, HubError>]
    private(set) var sent: [Data] = []

    init(_ script: [Result<Transcript, HubError>]) {
        self.script = script
    }

    var transcribe: Transcribe {
        { wav throws(HubError) in
            let next = self.lock.withLock { () -> Result<Transcript, HubError> in
                self.sent.append(wav)
                return self.script.isEmpty ? .failure(.network("script ran out")) : self.script.removeFirst()
            }
            return try next.get()
        }
    }
}

private func said(_ text: String) -> Result<Transcript, HubError> {
    .success(Transcript(text: text, noSpeech: false))
}

@Suite struct DictationQueueTests {
    let wavA = WavEncoder.pcm16MonoWav(samples: [1, 2, 3])
    let wavB = WavEncoder.pcm16MonoWav(samples: [4, 5, 6])

    @Test func drainSuccessStoresTextAndDeletesTheWav() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let item = try await queue.enqueue(wavA)
        #expect(scratch.wavFiles() == ["\(item.id.uuidString).wav"])

        let transcriber = ScriptedTranscriber([said("hello")])
        #expect(await queue.drain(using: transcriber.transcribe) == .finished)

        let items = await queue.items()
        #expect(items.map(\.state) == [.done("hello")])
        #expect(items.first?.attempts == 1)
        #expect(transcriber.sent == [wavA])
        #expect(scratch.wavFiles().isEmpty)
    }

    @Test func networkErrorKeepsItemsPendingAndInOrder() async throws {
        let scratch = ScratchDirectory()
        let clock = TickingClock()
        let queue = DictationQueue(directory: scratch.url, now: clock.now)
        let first = try await queue.enqueue(wavA)
        let second = try await queue.enqueue(wavB)

        let offline = ScriptedTranscriber([.failure(.network("offline"))])
        #expect(await queue.drain(using: offline.transcribe) == .stopped(.network("offline")))
        #expect(offline.sent == [wavA], "stops after the first network error")
        let afterOffline = await queue.items()
        #expect(afterOffline.map(\.id) == [first.id, second.id])
        #expect(afterOffline.map(\.state) == [.pending, .pending])
        #expect(scratch.wavFiles().count == 2)

        let online = ScriptedTranscriber([said("one"), said("two")])
        #expect(await queue.drain(using: online.transcribe) == .finished)
        #expect(online.sent == [wavA, wavB])
        #expect(await queue.items().map(\.state) == [.done("one"), .done("two")])
    }

    @Test func unsupportedAudioMarksFailedAndKeepsTheWav() async throws {
        let scratch = ScratchDirectory()
        let clock = TickingClock()
        let queue = DictationQueue(directory: scratch.url, now: clock.now)
        let bad = try await queue.enqueue(wavA)
        _ = try await queue.enqueue(wavB)

        let transcriber = ScriptedTranscriber([.failure(.unsupportedAudio), said("fine")])
        #expect(await queue.drain(using: transcriber.transcribe) == .finished)

        let items = await queue.items()
        guard case .failed = items[0].state else {
            Issue.record("expected failed, got \(items[0].state)")
            return
        }
        #expect(items[1].state == .done("fine"))
        #expect(scratch.wavFiles() == ["\(bad.id.uuidString).wav"])
    }

    @Test func reinitFromTheDirectoryRestoresPendingItems() async throws {
        let scratch = ScratchDirectory()
        let clock = TickingClock()
        let before = DictationQueue(directory: scratch.url, now: clock.now)
        let first = try await before.enqueue(wavA)
        let second = try await before.enqueue(wavB)

        let after = DictationQueue(directory: scratch.url)
        let restored = await after.items()
        #expect(restored.map(\.id) == [first.id, second.id])
        #expect(restored.map(\.state) == [.pending, .pending])

        let transcriber = ScriptedTranscriber([said("a"), said("b")])
        #expect(await after.drain(using: transcriber.transcribe) == .finished)
        #expect(transcriber.sent == [wavA, wavB])
    }
}

final class FakeRecorder: AudioCapturing, @unchecked Sendable {
    var samples: [Int16] = [7, 8, 9]
    private(set) var started = 0

    func start() throws { started += 1 }
    func stop() -> [Int16] { samples }
}

final class FakeReachability: ReachabilityMonitoring, @unchecked Sendable {
    private(set) var onChange: (@Sendable (Bool) -> Void)?

    func start(onChange: @escaping @Sendable (Bool) -> Void) { self.onChange = onChange }
    func cancel() { onChange = nil }
}

@MainActor
@Suite struct DictationControllerTests {
    @Test func goesIdleRecordingQueuedDone() async throws {
        let scratch = ScratchDirectory()
        let recorder = FakeRecorder()
        let seenWhileSending = StateBox()
        let controllerBox = ControllerBox()
        let controller = DictationController(
            recorder: recorder,
            queue: DictationQueue(directory: scratch.url),
            transcribe: { _ throws(HubError) in
                await MainActor.run { seenWhileSending.set(controllerBox.controller?.state) }
                return Transcript(text: "dictated", noSpeech: false)
            },
            requestMicrophone: { true }
        )
        controllerBox.controller = controller

        #expect(controller.state == .idle)
        await controller.record()
        #expect(controller.state == .recording)
        #expect(recorder.started == 1)
        await controller.stop()
        #expect(seenWhileSending.value == .queued)
        #expect(controller.state == .done)
        #expect(controller.latestText == "dictated")
        #expect(controller.waiting.isEmpty)
    }

    @Test func offlineStopQueuesAndReachabilitySendsIt() async throws {
        let scratch = ScratchDirectory()
        let reachability = FakeReachability()
        let transcriber = ScriptedTranscriber([.failure(.network("offline")), said("later")])
        let controller = DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: transcriber.transcribe,
            requestMicrophone: { true },
            reachability: reachability
        )
        await controller.start()
        await controller.record()
        await controller.stop()
        #expect(controller.state == .queued)
        #expect(controller.waiting.map(\.state) == [.pending])

        let onChange = try #require(reachability.onChange)
        onChange(true)
        for _ in 0..<200 where controller.state != .done {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state == .done)
        #expect(controller.latestText == "later")
        #expect(controller.waiting.isEmpty)
    }

    @Test func deniedMicrophoneDoesNotRecord() async {
        let scratch = ScratchDirectory()
        let recorder = FakeRecorder()
        let controller = DictationController(
            recorder: recorder,
            queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { false }
        )
        await controller.record()
        #expect(recorder.started == 0)
        guard case .failed = controller.state else {
            Issue.record("expected failed, got \(controller.state)")
            return
        }
    }
}

@MainActor
final class ControllerBox: Sendable {
    var controller: DictationController?
}

@MainActor
final class StateBox: Sendable {
    private(set) var value: DictationController.State?
    func set(_ value: DictationController.State?) { self.value = value }
}

@MainActor
@Suite struct DictationTranscribedHookTests {
    @Test func reportsEachWhisperTextOnceWithDuration() async throws {
        let scratch = ScratchDirectory()
        let recorder = FakeRecorder()
        let controller = DictationController(
            recorder: recorder,
            queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([said("one"), said("two")]).transcribe,
            requestMicrophone: { true }
        )
        var reported: [QueuedDictation] = []
        controller.onTranscribed = { reported.append($0) }

        await controller.record()
        await controller.stop()
        await controller.retry()
        #expect(reported.map(\.whisperText) == ["one"])
        #expect(reported.first?.durationMs == recorder.samples.count * 1000 / WavEncoder.relaySampleRate)

        await controller.record()
        await controller.stop()
        #expect(reported.map(\.whisperText) == ["one", "two"])
    }

    @Test func doesNotReportEmptyTextOrOldItems() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let first = DictationController(
            recorder: FakeRecorder(), queue: queue,
            transcribe: ScriptedTranscriber([.success(Transcript(text: "", noSpeech: true)), said("kept")]).transcribe,
            requestMicrophone: { true }
        )
        var reported: [String?] = []
        first.onTranscribed = { reported.append($0.whisperText) }
        await first.record()
        await first.stop()
        #expect(reported.isEmpty)
        await first.record()
        await first.stop()
        #expect(reported == ["kept"])

        // A second controller over the same queue (a relaunch) does not
        // report what is already done.
        let second = DictationController(
            recorder: FakeRecorder(), queue: queue, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { true }
        )
        var again: [String?] = []
        second.onTranscribed = { again.append($0.whisperText) }
        await second.start()
        #expect(again.isEmpty)
    }

    struct SaveFailed: Error {}

    @Test func aFailedSaveIsNotMarkedReportedAndIsRetried() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let controller = DictationController(
            recorder: FakeRecorder(), queue: queue,
            transcribe: ScriptedTranscriber([said("kept")]).transcribe,
            requestMicrophone: { true }
        )
        var attempts: [String?] = []
        var failNext = true
        controller.onTranscribed = { item in
            attempts.append(item.whisperText)
            if failNext {
                failNext = false
                throw SaveFailed()
            }
        }
        await controller.record()
        await controller.stop()
        #expect(attempts == ["kept"])
        #expect(await queue.items().first?.reported == false)

        // The next pass retries it, and a saved row marks it reported.
        await controller.retry()
        #expect(attempts == ["kept", "kept"])
        #expect(await queue.items().first?.reported == true)
        await controller.retry()
        #expect(attempts == ["kept", "kept"])
    }

    @Test func aFailedSaveIsReportedAgainAfterARelaunch() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let first = DictationController(
            recorder: FakeRecorder(), queue: queue,
            transcribe: ScriptedTranscriber([said("kept")]).transcribe,
            requestMicrophone: { true }
        )
        first.onTranscribed = { _ in throw SaveFailed() }
        await first.record()
        await first.stop()

        let relaunched = DictationController(
            recorder: FakeRecorder(), queue: queue, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { true }
        )
        var again: [String?] = []
        relaunched.onTranscribed = { again.append($0.whisperText) }
        await relaunched.start()
        #expect(again == ["kept"])
    }
}
