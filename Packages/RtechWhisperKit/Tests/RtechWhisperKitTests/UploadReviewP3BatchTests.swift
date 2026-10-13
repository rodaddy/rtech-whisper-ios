import Foundation
import Testing

@testable import RtechWhisperKit

// Review P3s #141 #143 #146 #147 #148 #154 #162.

/// Loud deterministic noise, with each range in `gaps` set to silence.
private func noise(count: Int, gaps: [Range<Int>] = []) -> [Int16] {
    var state: UInt32 = 54_321
    var samples = (0..<count).map { _ -> Int16 in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Int16(truncatingIfNeeded: Int(state >> 16) % 20_000 - 10_000)
    }
    for gap in gaps { for i in gap { samples[i] = 0 } }
    return samples
}

/// The job's state at every read and every send, and what each send held.
@MainActor
private final class Recorder {
    weak var job: UploadJob?
    var sent: [[Int16]] = []
    var stateAtSend: [UploadJob.State] = []
    /// The state during each read, with the sends made before it.
    var stateAtRead: [(state: UploadJob.State, sends: Int)] = []

    func read() { stateAtRead.append((job?.state ?? .idle, sent.count)) }

    func send(_ wav: Data) -> Transcript {
        stateAtSend.append(job?.state ?? .idle)
        sent.append(wav.dropFirst(WavEncoder.headerLength).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
        return Transcript(text: "part\(sent.count)", noSpeech: false)
    }
}

private actor RecordedSource: AudioSampleSource {
    nonisolated let durationSeconds: Double
    private let inner: BufferedAudioSource
    private let recorder: Recorder

    init(_ samples: [Int16], recorder: Recorder) {
        durationSeconds = Double(samples.count) / 16_000
        inner = BufferedAudioSource(DecodedAudio(samples: samples, durationSeconds: durationSeconds))
        self.recorder = recorder
    }

    func read(maxSamples: Int) async -> [Int16] {
        await recorder.read()
        return await inner.read(maxSamples: maxSamples)
    }
}

private let url = URL(fileURLWithPath: "/audio/long.m4a")

@MainActor
@Suite struct UploadReviewP3BatchTests {
    // #143 #154 #147 #162: a chunk longer than the cut search, over ~30 s.
    @Test func chunksPartsAndCountFollowWhatIsActuallySent() async throws {
        // Silence 2 s into the first window: a search of the whole window would cut there.
        let input = noise(count: 16_000 * 30 + 1_234, gaps: [32_000..<35_200])
        let recorder = Recorder()
        let job = UploadJob(
            decode: { _ in RecordedSource(input, recorder: recorder) },
            transcribe: { wav, _ throws(HubError) in await recorder.send(wav) },
            maxChunkSeconds: 12, sleep: { _ in })
        recorder.job = job
        let estimate = UploadChunker.chunkCount(sampleCount: input.count, maxSeconds: 12)

        await job.run(url: url)

        #expect(Array(recorder.sent.joined()) == input)
        // #143(c): the estimate is an upper bound on what is sent.
        #expect(recorder.sent.count <= estimate)
        // #143(b): each cut is in the last 5 s of its 12 s window.
        #expect(recorder.sent.dropLast().allSatisfy { $0.count >= 16_000 * 7 })
        let parts = recorder.stateAtSend.map { state -> Int? in
            if case .transcribing(_, let chunk, _) = state { chunk } else { nil }
        }
        #expect(parts == (1...recorder.sent.count).map { Optional($0) })
        // #147: the last part shown is "part N of N".
        let last = try #require(recorder.stateAtSend.last)
        #expect(last == .transcribing(fileName: "long.m4a", chunk: recorder.sent.count, count: recorder.sent.count))
        // #162: no read, the one that finds the end included, shows a part not yet sent.
        for (state, sends) in recorder.stateAtRead {
            if case .transcribing(_, let chunk, _) = state { #expect(chunk <= sends) }
        }
    }

    // #146
    @Test func onlyAResumableHubErrorOffersResume() async {
        let cases: [(HubError, Bool)] = [
            (.tooLarge, false), (.unsupportedAudio, false), (.network("offline"), true),
            // The hub's 30 s body-read timeout: a slow link or a suspended app.
            (.server(status: 408, code: "request_timeout", message: nil), true),
            (.invalidRequest(message: nil), false),  // What HubError.from makes of every 400 (#222).
            (.unauthorized, true), (.upstreamUnavailable(status: 503), true),
            (.server(status: 500, code: nil, message: nil), true),
        ]
        for (error, resumable) in cases {
            let job = UploadJob(
                decode: { _ in DecodedAudio(samples: [1, 2, 3], durationSeconds: 1).source },
                transcribe: { _, _ throws(HubError) in throw error }, sleep: { _ in })
            await job.run(url: url)
            #expect(job.state == .failed(fileName: "long.m4a", .hub(error)))
            #expect(job.canResume == resumable)
        }
    }

    // #148
    @Test func aRequestShorterThanTheSearchIsNotCutNearItsStart() {
        let window = noise(count: 16_000, gaps: [0..<800])  // A silent first frame.
        #expect(UploadChunker.cutIndex(samples: window, sampleRate: 16_000) >= 8_000)
        // Three seconds in one-second requests: every cut keeps at least half.
        #expect(UploadChunker.chunkCount(sampleCount: 48_000, sampleRate: 16_000, maxSeconds: 1) == 5)
    }

    // #141
    @Test func theLengthLimitIsWordedInHoursAndMinutes() {
        #expect(UploadFailure.limitText(seconds: 4 * 3_600) == "4 hours")
        #expect(UploadFailure.limitText(seconds: 3_600) == "1 hour")
        #expect(UploadFailure.limitText(seconds: 5_400) == "1 hour 30 minutes")
        #expect(UploadFailure.limitText(seconds: 1_800) == "30 minutes")
        #expect(UploadFailure.limitText(seconds: 60) == "1 minute")
    }
}
