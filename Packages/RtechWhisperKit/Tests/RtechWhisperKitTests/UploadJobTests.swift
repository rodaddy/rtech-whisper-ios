import Foundation
import Testing

@testable import RtechWhisperKit

private let fileURL = URL(fileURLWithPath: "/audio/standup.m4a")

/// Records every WAV and prompt the job sends, and answers from `replies`.
private final class RelaySpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(wav: Data, prompt: String?)] = []
    var replies: [Result<Transcript, HubError>]

    init(_ replies: [Result<Transcript, HubError>]) {
        self.replies = replies
    }

    func transcribe(_ wav: Data, prompt: String?) throws(HubError) -> Transcript {
        lock.lock()
        defer { lock.unlock() }
        sent.append((wav, prompt))
        guard !replies.isEmpty else { return Transcript(text: "", noSpeech: true) }
        return try replies.removeFirst().get()
    }
}

@MainActor
private func makeJob(
    audio: Result<DecodedAudio, any Error>, relay: RelaySpy, prompt: String? = nil, maxChunkSeconds: Int = 600
) -> UploadJob {
    UploadJob(
        decode: { _ in try audio.get().source },
        transcribe: { wav, hint throws(HubError) in try relay.transcribe(wav, prompt: hint) },
        prompt: { prompt },
        maxChunkSeconds: maxChunkSeconds)
}

struct Unreadable: LocalizedError { var errorDescription: String? { "bad header" } }

@Suite struct UploadChunkerTests {
    @Test func defaultChunkStaysUnderTheRelayBodyCap() {
        let bytes = UploadChunker.maxChunkSeconds * WavEncoder.relaySampleRate * 2 + WavEncoder.headerLength
        #expect(bytes < 25 * 1024 * 1024)
    }

    @Test func mergeTrimsAndDropsBlankChunks() {
        #expect(UploadChunker.merge([" first part.", "", "  ", "second part\n"]) == "first part. second part")
        #expect(UploadChunker.merge([]) == "")
    }
}

@MainActor
@Suite struct UploadJobTests {
    @Test func oneChunkFileEndsDoneAndReportsOnce() async {
        let relay = RelaySpy([.success(Transcript(text: "hello there", noSpeech: false))])
        // The header says 3.25 s; 3 s of audio is sent, and that is the length.
        let audio = DecodedAudio(samples: Array(repeating: 100, count: 16_000 * 3), durationSeconds: 3.25)
        let job = makeJob(audio: .success(audio), relay: relay, prompt: "Grafana, Kafka")
        var reported: [UploadResult] = []
        job.onTranscribed = { reported.append($0) }

        await job.run(url: fileURL)

        let expected = UploadResult(fileName: "standup.m4a", text: "hello there", durationSeconds: 3, noSpeech: false)
        #expect(job.state == .done(expected))
        #expect(job.result == expected)
        #expect(expected.durationMs == 3000)
        #expect(reported == [expected])
        #expect(relay.sent.count == 1)
        #expect(relay.sent[0].prompt == "Grafana, Kafka")
        #expect(relay.sent[0].wav.count == WavEncoder.headerLength + 16_000 * 3 * 2)
        #expect(!job.isRunning)
        #expect(job.progress == nil)
    }

    @Test func longFileIsSplitAndMerged() async {
        let relay = RelaySpy([
            .success(Transcript(text: "one", noSpeech: false)),
            .success(Transcript(text: "", noSpeech: true)),
            .success(Transcript(text: "three", noSpeech: false)),
        ])
        // 2.5 s at 16 kHz in one-second chunks: a flat signal is cut at the last
        // 50 ms frame of each full second, 15 600 samples in.
        let audio = DecodedAudio(samples: Array(repeating: 1, count: 40_000), durationSeconds: 2.5)
        let job = makeJob(audio: .success(audio), relay: relay, maxChunkSeconds: 1)

        await job.run(url: fileURL)

        #expect(job.result?.text == "one three")
        #expect(job.result?.noSpeech == false)
        #expect(relay.sent.map { $0.wav.count - WavEncoder.headerLength } == [31_200, 31_200, 17_600])
        #expect(relay.sent.allSatisfy { $0.prompt == nil })
    }

    @Test func silentFileIsDoneWithNoSpeechAndNotReported() async {
        let relay = RelaySpy([.success(Transcript(text: "", noSpeech: true))])
        let job = makeJob(audio: .success(DecodedAudio(samples: [0, 0, 0], durationSeconds: 0.1)), relay: relay)
        var reported = 0
        job.onTranscribed = { _ in reported += 1 }

        await job.run(url: fileURL)

        #expect(job.result == UploadResult(fileName: "standup.m4a", text: "", durationSeconds: 3.0 / 16_000, noSpeech: true))
        #expect(reported == 0)
    }

    @Test func unreadableFileFails() async {
        let relay = RelaySpy([])
        let job = makeJob(audio: .failure(Unreadable()), relay: relay)
        await job.run(url: fileURL)
        #expect(job.state == .failed(fileName: "standup.m4a", .unreadable("bad header")))
        #expect(relay.sent.isEmpty)
    }

    @Test func emptyAudioFailsWithoutCallingTheHub() async {
        let relay = RelaySpy([])
        let job = makeJob(audio: .success(DecodedAudio(samples: [], durationSeconds: 0)), relay: relay)
        await job.run(url: fileURL)
        #expect(job.state == .failed(fileName: "standup.m4a", .emptyAudio))
        #expect(relay.sent.isEmpty)
    }

    @Test func hubErrorStopsAtTheFailingChunk() async {
        let relay = RelaySpy([
            .success(Transcript(text: "one", noSpeech: false)),
            .failure(.unauthorized),
        ])
        let audio = DecodedAudio(samples: Array(repeating: 1, count: 48_000), durationSeconds: 3)
        let job = makeJob(audio: .success(audio), relay: relay, maxChunkSeconds: 1)
        var reported = 0
        job.onTranscribed = { _ in reported += 1 }

        await job.run(url: fileURL)

        #expect(job.state == .failed(fileName: "standup.m4a", .hub(.unauthorized)))
        #expect(relay.sent.count == 2)
        #expect(reported == 0)
    }

    @Test func progressWalksTheChunks() async {
        let relay = RelaySpy([])
        let job = makeJob(audio: .success(DecodedAudio(samples: [1], durationSeconds: 1)), relay: relay)
        #expect(job.progress == nil)
        await job.run(url: fileURL)
        #expect(job.progress == nil)
    }

    @Test func resetReturnsToIdleAfterARun() async {
        let relay = RelaySpy([.success(Transcript(text: "hi", noSpeech: false))])
        let job = makeJob(audio: .success(DecodedAudio(samples: [1], durationSeconds: 1)), relay: relay)
        await job.run(url: fileURL)
        #expect(job.result != nil)
        job.reset()
        #expect(job.state == .idle)
    }
}
