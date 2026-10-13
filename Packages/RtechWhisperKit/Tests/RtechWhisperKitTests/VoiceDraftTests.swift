import Foundation
import Testing

@testable import RtechWhisperKit

// `FakeRecorder` (DictationTests), `ScriptedTranscriber` (DictationTests),
// and `FakeOnDevice` (OnDeviceSpeechTests) are shared test fakes.

@MainActor
@Suite("Voice draft")
struct VoiceDraftTests {
    @Test func recordsThenHandsBackTheRelayText() async {
        let recorder = FakeRecorder()
        let transcriber = ScriptedTranscriber([.success(Transcript(text: "  make a note  ", noSpeech: false))])
        let draft = VoiceDraft(recorder: recorder, transcribe: transcriber.transcribe, requestMicrophone: { true })

        await draft.record()
        #expect(draft.status == .recording)
        #expect(draft.recordingSince != nil)
        #expect(recorder.started == 1)

        let text = await draft.stop()
        #expect(text == "make a note")
        #expect(draft.status == .idle)
        #expect(draft.recordingSince == nil)
        #expect(draft.failure == nil)
        #expect(transcriber.sent == [WavEncoder.pcm16MonoWav(samples: recorder.samples)])
    }

    @Test func fallsBackToOnDeviceTextWhenTheHubIsUnreachable() async {
        let transcriber = ScriptedTranscriber([.failure(.network("offline"))])
        let draft = VoiceDraft(
            recorder: FakeRecorder(), transcribe: transcriber.transcribe,
            onDevice: FakeOnDevice(.success("offline words")), requestMicrophone: { true })

        await draft.record()
        #expect(await draft.stop() == "offline words")
        #expect(draft.failure == nil)
    }

    @Test func reportsTheHubErrorWhenNothingCanTranscribe() async {
        let transcriber = ScriptedTranscriber([.failure(.network("offline"))])
        let draft = VoiceDraft(
            recorder: FakeRecorder(), transcribe: transcriber.transcribe,
            onDevice: FakeOnDevice(.failure(.unavailable("no model"))), requestMicrophone: { true })

        await draft.record()
        #expect(await draft.stop() == nil)
        #expect(draft.failure == .transcription(.network("offline")))
        #expect(draft.status == .idle)
    }

    /// Only an unreachable hub falls back on-device: a revoked key must be
    /// reported, never hidden behind on-device text.
    @Test func anUnauthorizedHubIsReportedEvenWhenOnDeviceCouldTranscribe() async {
        let transcriber = ScriptedTranscriber([.failure(.unauthorized)])
        let draft = VoiceDraft(
            recorder: FakeRecorder(), transcribe: transcriber.transcribe,
            onDevice: FakeOnDevice(.success("offline words")), requestMicrophone: { true })

        await draft.record()
        #expect(await draft.stop() == nil)
        #expect(draft.failure == .transcription(.unauthorized))
        #expect(draft.status == .idle)
    }

    @Test func silenceIsNoSpeechNotAnEmptyMessage() async {
        let transcriber = ScriptedTranscriber([.success(Transcript(text: "", noSpeech: true))])
        let draft = VoiceDraft(recorder: FakeRecorder(), transcribe: transcriber.transcribe, requestMicrophone: { true })

        await draft.record()
        #expect(await draft.stop() == nil)
        #expect(draft.failure == .noSpeech)
    }

    @Test func aDeniedMicrophoneNeverStartsTheRecorder() async {
        let recorder = FakeRecorder()
        let transcriber = ScriptedTranscriber([])
        let draft = VoiceDraft(recorder: recorder, transcribe: transcriber.transcribe, requestMicrophone: { false })

        await draft.record()
        #expect(draft.status == .idle)
        #expect(draft.failure == .microphoneDenied)
        #expect(recorder.started == 0)
    }

    @Test func cancelThrowsTheTakeAway() async {
        let transcriber = ScriptedTranscriber([.success(Transcript(text: "never sent", noSpeech: false))])
        let draft = VoiceDraft(recorder: FakeRecorder(), transcribe: transcriber.transcribe, requestMicrophone: { true })

        await draft.record()
        draft.cancel()
        #expect(draft.status == .idle)
        #expect(transcriber.sent.isEmpty)
        #expect(await draft.stop() == nil)
    }

    @Test func anEmptyRecordingIsReported() async {
        let recorder = FakeRecorder()
        recorder.samples = []
        let transcriber = ScriptedTranscriber([])
        let draft = VoiceDraft(recorder: recorder, transcribe: transcriber.transcribe, requestMicrophone: { true })

        await draft.record()
        #expect(await draft.stop() == nil)
        #expect(draft.failure == .nothingRecorded)
        #expect(transcriber.sent.isEmpty)
    }

    @Test func cancelClearsTheLastFailure() async {
        let recorder = FakeRecorder()
        recorder.samples = []
        let draft = VoiceDraft(recorder: recorder, transcribe: ScriptedTranscriber([]).transcribe, requestMicrophone: { true })

        await draft.record()
        _ = await draft.stop()
        #expect(draft.failure == .nothingRecorded)
        // Leaving the chat calls cancel: the notice must not follow the user.
        draft.cancel()
        #expect(draft.failure == nil)
    }
}

/// The permission prompt, held open until `answer`.
final class HeldPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var askedCount = 0

    var asked: Int { lock.withLock { askedCount } }

    func answer(_ granted: Bool) {
        let pending = lock.withLock {
            answer = granted
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: granted) }
    }

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool? in
                askedCount += 1
                if let answer { return answer }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

@MainActor
@Suite("Voice draft: one microphone owner")
struct VoiceDraftOwnershipTests {
    private func waitUntilAsked(_ permission: HeldPermission, times: Int = 1) async {
        while permission.asked < times { await Task.yield() }
    }

    @Test func cancelWhileAskingPermissionNeverOpensTheMicrophone() async {
        let recorder = FakeRecorder()
        let permission = HeldPermission()
        let draft = VoiceDraft(
            recorder: recorder, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { await permission.request() })

        let take = Task { await draft.record() }
        await waitUntilAsked(permission)
        #expect(draft.canRecord == false)
        draft.cancel()
        permission.answer(true)
        await take.value

        #expect(recorder.started == 0)
        #expect(draft.status == .idle)
        #expect(draft.canRecord)
    }

    @Test func aSecondTapWhileAskingPermissionStartsOneTake() async {
        let recorder = FakeRecorder()
        let permission = HeldPermission()
        let draft = VoiceDraft(
            recorder: recorder, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { await permission.request() })

        let first = Task { await draft.record() }
        await waitUntilAsked(permission)
        // Run as its own task: before the fix it waited on the prompt too.
        let second = Task { await draft.record() }
        for _ in 0..<50 { await Task.yield() }
        permission.answer(true)
        await first.value
        await second.value

        #expect(permission.asked == 1)
        #expect(recorder.started == 1)
        #expect(draft.status == .recording)
    }

    @Test func refusesWhileTheDictationHoldsTheMicrophone() async {
        let recorder = FakeRecorder()
        var dictating = true
        let draft = VoiceDraft(
            recorder: recorder, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { true }, otherCaptureActive: { dictating })

        #expect(draft.canRecord == false)
        await draft.record()
        #expect(recorder.started == 0)
        #expect(draft.status == .idle)

        dictating = false
        #expect(draft.canRecord)
        await draft.record()
        #expect(recorder.started == 1)
    }

    @Test func aDictationThatStartsDuringThePromptWinsTheMicrophone() async {
        let recorder = FakeRecorder()
        let permission = HeldPermission()
        var dictating = false
        let draft = VoiceDraft(
            recorder: recorder, transcribe: ScriptedTranscriber([]).transcribe,
            requestMicrophone: { await permission.request() }, otherCaptureActive: { dictating })

        let take = Task { await draft.record() }
        await waitUntilAsked(permission)
        dictating = true
        permission.answer(true)
        await take.value

        #expect(recorder.started == 0)
        #expect(draft.status == .idle)
        // Said so, not a button that silently goes back to idle.
        #expect(draft.failure == .microphoneBusy)
    }
}
