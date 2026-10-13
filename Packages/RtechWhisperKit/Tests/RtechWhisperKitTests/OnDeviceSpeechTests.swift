import Foundation
import Testing

@testable import RtechWhisperKit

/// An on-device recognizer that answers from a fixed result and records the
/// samples it was given.
final class FakeOnDevice: OnDeviceTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, OnDeviceSpeechError>
    private var received: [[Int16]] = []

    init(_ result: Result<String, OnDeviceSpeechError>) {
        self.result = result
    }

    var calls: [[Int16]] { lock.withLock { received } }

    func transcribe(_ samples: [Int16]) async throws -> String {
        lock.withLock { received.append(samples) }
        return try result.get()
    }
}

@MainActor
@Suite struct OnDeviceSpeechTests {
    private func controller(
        _ scratch: ScratchDirectory,
        hub: ScriptedTranscriber,
        onDevice: FakeOnDevice
    ) -> DictationController {
        DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: hub.transcribe,
            onDevice: onDevice,
            requestMicrophone: { true }
        )
    }

    @Test func offlineStopShowsOnDeviceTextRightAway() async throws {
        let scratch = ScratchDirectory()
        let onDevice = FakeOnDevice(.success("on device words"))
        let controller = controller(scratch, hub: ScriptedTranscriber([.failure(.network("offline"))]), onDevice: onDevice)

        await controller.record()
        await controller.stop()

        #expect(onDevice.calls == [[7, 8, 9]])
        #expect(controller.state == .queued)
        #expect(controller.latestText == "on device words")
        #expect(controller.latest?.source == .onDevice)
        #expect(controller.latest?.provisionalText == "on device words")
        #expect(controller.waiting.map(\.source) == [.onDevice])
        #expect(controller.onDeviceNotice == nil)
    }

    @Test func hubReachableSkipsOnDevice() async throws {
        let scratch = ScratchDirectory()
        let onDevice = FakeOnDevice(.success("unused"))
        let controller = controller(scratch, hub: ScriptedTranscriber([.success(Transcript(text: "whisper", noSpeech: false))]), onDevice: onDevice)

        await controller.record()
        await controller.stop()

        #expect(onDevice.calls.isEmpty)
        #expect(controller.latestText == "whisper")
        #expect(controller.latest?.source == .hub)
    }

    @Test func hubComesBackAndWhisperReplacesTheProvisionalText() async throws {
        let scratch = ScratchDirectory()
        let hub = ScriptedTranscriber([.failure(.network("offline")), .success(Transcript(text: "whisper words", noSpeech: false))])
        let controller = controller(scratch, hub: hub, onDevice: FakeOnDevice(.success("on device words")))

        await controller.record()
        await controller.stop()
        #expect(controller.latestText == "on device words")

        await controller.retry()
        #expect(controller.state == .done)
        #expect(controller.latestText == "whisper words")
        #expect(controller.latest?.source == .hub)
        #expect(controller.latest?.provisionalText == nil)
        #expect(controller.latest?.alternateText == nil)
        #expect(controller.waiting.isEmpty)
    }

    @Test func userEditIsKeptAndWhisperIsStoredAsAlternate() async throws {
        let scratch = ScratchDirectory()
        let hub = ScriptedTranscriber([.failure(.network("offline")), .success(Transcript(text: "whisper words", noSpeech: false))])
        let controller = controller(scratch, hub: hub, onDevice: FakeOnDevice(.success("on device words")))

        await controller.record()
        await controller.stop()
        await controller.edit("my fixed words").value
        #expect(controller.latestText == "my fixed words")

        await controller.retry()
        #expect(controller.state == .done)
        #expect(controller.latestText == "my fixed words")
        #expect(controller.latest?.editedText == "my fixed words")
        #expect(controller.latest?.alternateText == "whisper words")
        #expect(controller.latest?.source == .onDevice)
    }

    @Test func onDeviceUnavailableLeavesTheItemWaiting() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, hub: ScriptedTranscriber([.failure(.network("offline"))]), onDevice: FakeOnDevice(.failure(.denied)))

        await controller.record()
        await controller.stop()

        #expect(controller.state == .queued)
        #expect(controller.latestText == nil)
        #expect(controller.latest?.source == nil)
        #expect(controller.waiting.map(\.state) == [.pending])
        #expect(controller.onDeviceNotice == OnDeviceSpeechError.denied.userMessage)
    }

    @Test func reinitRestoresProvisionalAndEditedText() async throws {
        let scratch = ScratchDirectory()
        let before = DictationQueue(directory: scratch.url)
        let item = try await before.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2, 3]))
        await before.setProvisional(item.id, text: "on device words")
        await before.edit(item.id, text: "edited")

        let restored = try #require(await DictationQueue(directory: scratch.url).items().first)
        #expect(restored.id == item.id)
        #expect(restored.state == .pending)
        #expect(restored.provisionalText == "on device words")
        #expect(restored.source == .onDevice)
        #expect(restored.editedText == "edited")
    }

    @Test func lateOnDeviceTextNeverOverwritesWhisper() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        let item = try await queue.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2, 3]))
        _ = await queue.drain(using: ScriptedTranscriber([.success(Transcript(text: "whisper", noSpeech: false))]).transcribe)
        await queue.setProvisional(item.id, text: "late")

        let after = try #require(await queue.items().first)
        #expect(after.text == "whisper")
        #expect(after.source == .hub)
        #expect(after.provisionalText == nil)
    }

    @Test func indexWrittenBeforeThisFeatureStillLoads() async throws {
        let scratch = ScratchDirectory()
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","createdAt":"2026-09-29T10:00:00Z","state":{"pending":{}},"attempts":1}]"#
        try Data(old.utf8).write(to: scratch.url.appending(path: DictationQueue.indexName))

        let items = await DictationQueue(directory: scratch.url).items()
        #expect(items.map(\.id) == [id])
        #expect(items.first?.provisionalText == nil)
        #expect(items.first?.source == nil)
    }
}
