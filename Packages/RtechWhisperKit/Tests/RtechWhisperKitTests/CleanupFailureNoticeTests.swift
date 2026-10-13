import Foundation
import Testing

@testable import RtechWhisperKit

@Suite("Cleanup failure is reported")
struct CleanupFailureReportTests {
    @Test func aRelayErrorOrACutOffAnswerIsAFailure() async {
        let failed = await CleanupService(llm: FakeLLM(error: .upstreamUnavailable(status: 502)))
            .cleanReportingFailure("um, send it friday")
        #expect(failed.text == "Send it friday")
        #expect(failed.modelFailed)

        let cutOff = await CleanupService(llm: FakeLLM(reply: "Send it", finishReason: "length"))
            .cleanReportingFailure("send it friday")
        #expect(cutOff.text == "send it friday")
        #expect(cutOff.modelFailed)
    }

    @Test func aCleanAnswerOrCleanupOffIsNotAFailure() async {
        let cleaned = await CleanupService(llm: FakeLLM(reply: "Send it Friday."))
            .cleanReportingFailure("send it friday")
        #expect(cleaned.text == "Send it Friday.")
        #expect(!cleaned.modelFailed)

        let llm = FakeLLM(error: .unauthorized)
        let off = await CleanupService(llm: llm, settings: CleanupSettings(useCleanupModel: false))
            .cleanReportingFailure("send it friday")
        #expect(off.text == "send it friday")
        #expect(!off.modelFailed)
        #expect(llm.requests.isEmpty)
    }
}

@MainActor
@Suite("Cleanup failure notice in the controller")
struct CleanupFailureNoticeTests {
    private func controller(_ scratch: ScratchDirectory, _ llm: FakeLLM) -> DictationController {
        let transcript = Transcript(text: "um so hello there", noSpeech: false)
        let controller = DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([.success(transcript)]).transcribe,
            requestMicrophone: { true })
        controller.postProcessor = DictationPostProcessor(llm: llm, settings: { CleanupSettings() })
        return controller
    }

    @Test func aFailedCleanupKeepsTheTranscriptAndSaysSo() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, FakeLLM(error: .upstreamUnavailable(status: 503)))
        var reported: [QueuedDictation] = []
        controller.onTranscribed = { reported.append($0) }

        await controller.record()
        await controller.stop()

        #expect(controller.state == .done)
        #expect(controller.cleanupNotice == DictationController.cleanupFailedNotice)
        let item = try #require(reported.first)
        #expect(item.whisperText == "um so hello there")
        #expect(item.text == "So hello there")
    }

    @Test func aCleanedDictationShowsNoNotice() async throws {
        let scratch = ScratchDirectory()
        let controller = controller(scratch, FakeLLM(reply: "Hello there."))
        await controller.record()
        await controller.stop()
        #expect(controller.latestText == "Hello there.")
        #expect(controller.cleanupNotice == nil)
    }
}

/// Never answers until the calling task is cancelled; never throws.
private struct SilentLLM: LLMCompleting {
    func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        while !Task.isCancelled { await Task.yield() }
        return LLMChatCompletion(content: "too late", finishReason: "stop")
    }
}

/// Fails the cleanup of any transcript containing `failing`; cleans the rest.
private struct PickyLLM: LLMCompleting {
    let failing: String

    func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        if request.messages.last?.content.contains(failing) == true { throw .upstreamUnavailable(status: 503) }
        return LLMChatCompletion(content: "Cleaned.", finishReason: "stop")
    }
}

@Suite("Cleanup deadline")
struct CleanupDeadlineTests {
    @Test func aModelThatNeverAnswersFallsBackAtTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await CleanupService(llm: SilentLLM(), deadline: .milliseconds(200))
            .cleanReportingFailure("um, send it friday")
        #expect(result.text == "Send it friday")
        #expect(result.modelFailed)
        #expect(clock.now - start < .seconds(5))
    }

    @Test func theDefaultDeadlineIsTheDesktops() {
        #expect(CleanupService.deadline == .seconds(30))
    }

    @Test func anAnswerBeforeTheDeadlineIsUsed() async {
        let result = await CleanupService(llm: FakeLLM(reply: "Send it Friday."), deadline: .seconds(5))
            .cleanReportingFailure("send it friday")
        #expect(result.text == "Send it Friday.")
        #expect(!result.modelFailed)
    }
}

@MainActor
@Suite("Cleanup failure notice is about the latest take")
struct CleanupNoticeLatestTests {
    @Test func anOlderTakesFailureDoesNotBlameTheLatest() async throws {
        let scratch = ScratchDirectory()
        let controller = DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([
                .failure(.network("offline")),
                .success(Transcript(text: "older take", noSpeech: false)),
                .success(Transcript(text: "newer take", noSpeech: false))
            ]).transcribe,
            requestMicrophone: { true })
        controller.postProcessor = DictationPostProcessor(
            llm: PickyLLM(failing: "older"), settings: { CleanupSettings() })

        await controller.record()
        await controller.stop()
        #expect(controller.state == .queued)
        // The second take drains the offline one with it; only the old one fails.
        await controller.record()
        await controller.stop()

        #expect(controller.state == .done)
        #expect(controller.latestText == "Cleaned.")
        #expect(controller.cleanupNotice == nil)
    }

    @Test func aRetryOfABacklogTakeDoesNotSetTheNotice() async throws {
        let scratch = ScratchDirectory()
        // A take Whisper finished but the history never got (the process
        // died, or the save failed) before this launch.
        let earlier = DictationQueue(directory: scratch.url)
        try await earlier.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2, 3]))
        _ = await earlier.drain(using: ScriptedTranscriber([
            .success(Transcript(text: "older take", noSpeech: false))
        ]).transcribe)

        let controller = DictationController(
            recorder: FakeRecorder(),
            queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([.success(Transcript(text: "newer take", noSpeech: false))]).transcribe,
            requestMicrophone: { true })
        controller.postProcessor = DictationPostProcessor(
            llm: PickyLLM(failing: "older"), settings: { CleanupSettings() })
        var reported: [String] = []
        controller.onTranscribed = { reported.append($0.whisperText ?? "") }

        await controller.start()
        #expect(reported == ["older take"])
        #expect(controller.cleanupNotice == nil)

        await controller.record()
        await controller.stop()
        #expect(controller.cleanupNotice == nil)
    }
}
