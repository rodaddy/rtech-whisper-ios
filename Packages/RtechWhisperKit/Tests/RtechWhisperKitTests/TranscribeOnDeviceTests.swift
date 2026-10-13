import Foundation
import Testing

@testable import RtechWhisperKit

/// The "Transcribe on this iPhone" setting (#476).
@MainActor
@Suite struct TranscribeOnDeviceTests {
    private func controller(
        _ scratch: ScratchDirectory,
        hub: ScriptedTranscriber,
        onDevice: FakeOnDevice,
        settingOn: Bool,
        reported: @escaping @MainActor (QueuedDictation) -> Void = { _ in }
    ) -> DictationController {
        let controller = DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: hub.transcribe,
            onDevice: onDevice,
            requestMicrophone: { true },
            transcribeOnDevice: { settingOn }
        )
        controller.onTranscribed = { reported($0) }
        return controller
    }

    @Test func settingOnAndOnDeviceSucceedsSkipsTheHub() async throws {
        let scratch = ScratchDirectory()
        let hub = ScriptedTranscriber([.success(Transcript(text: "whisper", noSpeech: false))])
        let onDevice = FakeOnDevice(.success("phone words"))
        var reported: [QueuedDictation] = []
        let controller = controller(scratch, hub: hub, onDevice: onDevice, settingOn: true) { reported.append($0) }

        await controller.record()
        await controller.stop()

        #expect(hub.sent.isEmpty)
        #expect(onDevice.calls == [[7, 8, 9]])
        #expect(controller.state == .done)
        #expect(controller.latestText == "phone words")
        #expect(controller.latest?.whisperText == "phone words")
        #expect(reported.map(\.text) == ["phone words"])
        #expect(controller.waiting.isEmpty)
    }

    @Test func settingOnAndOnDeviceFailsFallsBackToTheHub() async throws {
        for failure in [Result<String, OnDeviceSpeechError>.failure(.denied), .success("  ")] {
            let scratch = ScratchDirectory()
            let hub = ScriptedTranscriber([.success(Transcript(text: "whisper", noSpeech: false))])
            var reported: [QueuedDictation] = []
            let controller = controller(scratch, hub: hub, onDevice: FakeOnDevice(failure), settingOn: true) { reported.append($0) }

            await controller.record()
            await controller.stop()

            #expect(hub.sent.count == 1)
            #expect(controller.latestText == "whisper")
            #expect(controller.latest?.source == .hub)
            #expect(reported.map(\.text) == ["whisper"])
        }
    }

    @Test func settingOffNeverCallsOnDeviceWhenTheHubAnswers() async throws {
        let scratch = ScratchDirectory()
        let hub = ScriptedTranscriber([.success(Transcript(text: "whisper", noSpeech: false))])
        let onDevice = FakeOnDevice(.success("unused"))
        let controller = controller(scratch, hub: hub, onDevice: onDevice, settingOn: false)

        await controller.record()
        await controller.stop()

        #expect(onDevice.calls.isEmpty)
        #expect(hub.sent.count == 1)
        #expect(controller.latestText == "whisper")
    }
}
