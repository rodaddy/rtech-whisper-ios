import Foundation
import Testing

@testable import RtechWhisperKit

/// Regression tests for the integration/v0.1 review findings.

/// Hands out its samples on the first stop only, as the real recorder does.
final class OneTakeRecorder: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    private(set) var stops = 0

    func start() throws {}
    func stop() -> [Int16] {
        lock.withLock {
            stops += 1
            defer { taken = true }
            return taken ? [] : [7, 8, 9]
        }
    }
}

/// Holds the cleanup until opened.
final class HeldCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func clean(_ raw: String) async -> String {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
        return "Cleaned."
    }
}

private func heard(_ text: String) -> Result<Transcript, HubError> {
    .success(Transcript(text: text, noSpeech: false))
}

@MainActor
@Suite struct DictationReviewFixTests {
    @Test func aTakeFinishedButNotReportedBeforeAKillIsReportedAfterRelaunch() async throws {
        let scratch = ScratchDirectory()
        let queue = DictationQueue(directory: scratch.url)
        // Whisper answered, then the process died (for example during
        // cleanup) before the history heard about it.
        try await queue.enqueue(WavEncoder.pcm16MonoWav(samples: [1, 2]))
        _ = await queue.drain(using: ScriptedTranscriber([heard("lost")]).transcribe)

        let relaunched = DictationController(
            recorder: FakeRecorder(), queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([]).transcribe, requestMicrophone: { true })
        var reported: [String?] = []
        relaunched.onTranscribed = { reported.append($0.whisperText) }
        await relaunched.start()
        #expect(reported == ["lost"])

        // Reported once is reported for good, across another relaunch.
        let again = DictationController(
            recorder: FakeRecorder(), queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([]).transcribe, requestMicrophone: { true })
        var second: [String?] = []
        again.onTranscribed = { second.append($0.whisperText) }
        await again.start()
        #expect(second.isEmpty)
    }

    @Test func itemsSavedBeforeTheReportedFlagAreNotReportedAgain() async throws {
        let scratch = ScratchDirectory()
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let legacy = #"[{"id":"\#(UUID().uuidString)","createdAt":"2026-09-01T00:00:00Z","state":{"done":{"_0":"old"}},"attempts":1}]"#
        try Data(legacy.utf8).write(to: scratch.url.appending(path: DictationQueue.indexName))
        let queue = DictationQueue(directory: scratch.url)
        #expect(await queue.items().first?.whisperText == "old")

        let controller = DictationController(
            recorder: FakeRecorder(), queue: queue,
            transcribe: ScriptedTranscriber([]).transcribe, requestMicrophone: { true })
        var reported: [String?] = []
        controller.onTranscribed = { reported.append($0.whisperText) }
        await controller.start()
        #expect(reported.isEmpty)
    }

    @Test func aSecondStopWhileTheFirstSavesIsIgnored() async throws {
        let scratch = ScratchDirectory()
        let recorder = OneTakeRecorder()
        let controller = DictationController(
            recorder: recorder, queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([heard("said")]).transcribe, requestMicrophone: { true })
        var states: [DictationController.State] = []
        await controller.record()
        let first = Task { await controller.stop(); states.append(controller.state) }
        let second = Task { await controller.stop() }
        await first.value
        await second.value
        #expect(recorder.stops == 1)
        #expect(controller.state == .done)
        #expect(states == [.done])
    }

    @Test func aRefreshDuringCleanupDoesNotShowTheRawTextAsDone() async throws {
        let scratch = ScratchDirectory()
        let controller = DictationController(
            recorder: FakeRecorder(), queue: DictationQueue(directory: scratch.url),
            transcribe: ScriptedTranscriber([heard("um raw")]).transcribe, requestMicrophone: { true })
        let gate = HeldCleanup()
        controller.postProcessor = DictationPostProcessor(clean: gate.clean)

        await controller.record()
        let stopping = Task { await controller.stop() }
        for _ in 0..<200 where controller.state != .cleaning {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.state == .cleaning)
        let retrying = Task { await controller.retry() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.state == .cleaning)
        #expect(controller.latestText != "um raw")
        gate.open()
        await stopping.value
        await retrying.value
        #expect(controller.state == .done)
        #expect(controller.latestText == "Cleaned.")
    }
}

@Suite struct TranscriptionTimeoutTests {
    @Test func aRequestMayRunPastTheHubs180SecondBudget() async throws {
        #expect(TranscriptionClient.requestTimeout >= 180)
        #expect(TranscriptionClient.defaultSession.configuration.timeoutIntervalForRequest >= 180)
        let (client, host) = StubRelay.make(.init(status: 200, body: #"{"text":"ok"}"#))
        _ = try await client.transcribe(wav: WavEncoder.pcm16MonoWav(samples: [1]))
        let (request, _) = try #require(StubRelay.requests(to: host).first)
        #expect(request.timeoutInterval >= 180)
    }
}

@Suite struct LLMTimeoutTests {
    @Test func aCallMayRunPastTheRelays120SecondBudget() async throws {
        #expect(LLMClient.requestTimeout > 120)
        #expect(LLMClient.defaultSession.configuration.timeoutIntervalForRequest > 120)
        let (client, host) = StubLLM.make(.init(chunks: [#"{"choices":[{"message":{"content":"ok"}}]}"#]))
        _ = try await client.complete(LLMChatRequest(model: LLMClient.defaultModel, messages: [.user("hi")]))
        _ = try? await client.models()
        let requests = StubLLM.requests(to: host)
        #expect(requests.count == 2)
        for (request, _) in requests { #expect(request.timeoutInterval > 120) }
    }
}

@Suite struct CleanupReviewFixTests {
    @Test func aReplyCutOffAtTheTokenLimitFallsBackToTheTextWithoutFillers() async {
        let llm = FakeLLM(reply: "It works and then", finishReason: "length")
        #expect(await CleanupService(llm: llm).clean("uh, it works and then some more") == "It works and then some more")
    }

    @MainActor
    @Test func cleanupSettingsCarryTheDictionary() {
        let defaults = UserDefaults(suiteName: "ReviewFix-\(UUID().uuidString)")!
        let store = AISettingsStore(defaults: defaults)
        #expect(store.cleanupSettings(dictionary: ["Webpack", "Grafana"]).customDictionary == ["Webpack", "Grafana"])
    }
}

@MainActor
@Suite struct PromptHintUTF16Tests {
    @Test func theBudgetCountsUTF16UnitsAsTheHubDoes() {
        // One grapheme, four UTF-16 units.
        let word = "👍🏽"
        #expect(word.count == 1)
        #expect(DictionaryStore.promptHint([word + word], maxLength: 4) == nil)
        #expect(DictionaryStore.promptHint([word], maxLength: 4) == word)
    }
}

@Suite struct ActivityStaleDateTests {
    @Test func onlyTranscribingGoesStale() {
        let now = Date(timeIntervalSince1970: 1_000)
        let at = Date(timeIntervalSince1970: 0)
        #expect(DictationActivityContent(phase: .transcribing, startedAt: at).staleDate(now: now)
            == now.addingTimeInterval(DictationActivityContent.transcribingStaleAfter))
        #expect(DictationActivityContent(phase: .recording, startedAt: at).staleDate(now: now) == nil)
    }
}

/// Answers from a script and records each send.
private final class BusyRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<Transcript, HubError>]
    private(set) var sends = 0
    private(set) var waits: [Duration] = []

    init(_ replies: [Result<Transcript, HubError>]) { self.replies = replies }

    func transcribe(_ wav: Data, _ hint: String?) throws(HubError) -> Transcript {
        let next = lock.withLock { () -> Result<Transcript, HubError> in
            sends += 1
            return replies.isEmpty ? .success(Transcript(text: "", noSpeech: true)) : replies.removeFirst()
        }
        return try next.get()
    }

    func wait(_ duration: Duration) { lock.withLock { waits.append(duration) } }
}

@MainActor
@Suite struct UploadRetryTests {
    private func job(_ relay: BusyRelay, samples: Int = 16_000) -> UploadJob {
        UploadJob(
            decode: { _ in DecodedAudio(samples: Array(repeating: 1, count: samples), durationSeconds: 1).source },
            transcribe: { wav, hint throws(HubError) in try relay.transcribe(wav, hint) },
            sleep: { relay.wait($0) })
    }

    @Test func aBusyHubIsRetriedWithRetryAfterThenBackoff() async {
        let relay = BusyRelay([
            .failure(.rateLimited(retryAfter: 5)), .failure(.upstreamUnavailable(status: 503)), heard("done")
        ])
        let upload = job(relay)
        await upload.run(url: URL(fileURLWithPath: "/a.m4a"))
        #expect(upload.result?.text == "done")
        #expect(relay.sends == 3)
        #expect(relay.waits == [.seconds(5), .seconds(4)])
    }

    @Test func aBusyHubFailsTheUploadAfterTheLastAttempt() async {
        let relay = BusyRelay(Array(repeating: .failure(.upstreamUnavailable(status: 503)), count: 5))
        let upload = job(relay)
        await upload.run(url: URL(fileURLWithPath: "/a.m4a"))
        #expect(upload.state == .failed(fileName: "a.m4a", .hub(.upstreamUnavailable(status: 503))))
        #expect(relay.sends == UploadJob.maxAttempts)
    }

    @Test func aRefusalIsNotRetried() async {
        let relay = BusyRelay([.failure(.unauthorized)])
        let upload = job(relay)
        await upload.run(url: URL(fileURLWithPath: "/a.m4a"))
        #expect(upload.state == .failed(fileName: "a.m4a", .hub(.unauthorized)))
        #expect(relay.sends == 1)
    }
}
