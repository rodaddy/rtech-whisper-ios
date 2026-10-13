import Foundation
import Testing

@testable import RtechWhisperKit

// Issue #105: chunks are cut at the quietest point near the limit, and share no audio.

/// Loud deterministic noise, with each range in `gaps` set to silence.
private func noise(count: Int, gaps: [Range<Int>] = []) -> [Int16] {
    var state: UInt32 = 12_345
    var samples = (0..<count).map { _ -> Int16 in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Int16(truncatingIfNeeded: Int(state >> 16) % 20_000 - 10_000)
    }
    for gap in gaps { for i in gap { samples[i] = 0 } }
    return samples
}

/// Keeps each WAV sent and answers with its 1-based number.
private final class ChunkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [[Int16]] = []

    func transcribe(_ wav: Data) -> Transcript {
        let samples = wav.dropFirst(WavEncoder.headerLength).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let number = lock.withLock { sent.append(samples); return sent.count }
        return Transcript(text: "part\(number)", noSpeech: false)
    }
}

@MainActor
private func upload(_ samples: [Int16], maxChunkSeconds: Int) async -> ChunkRelay {
    let relay = ChunkRelay()
    let job = UploadJob(
        decode: { _ in DecodedAudio(samples: samples, durationSeconds: Double(samples.count) / 16_000).source },
        transcribe: { wav, _ throws(HubError) in relay.transcribe(wav) },
        maxChunkSeconds: maxChunkSeconds, sleep: { _ in })
    await job.run(url: URL(fileURLWithPath: "/audio/long.m4a"))
    return relay
}

@Suite struct UploadSilenceCutTests {
    @Test func theCutFallsInsideASilentGapNearTheEndOfTheWindow() {
        // A ten-second window; the last five seconds start at 80 000.
        let gap = 112_000..<115_200  // 200 ms of silence at 7.0 s.
        let early = 32_000..<35_200  // Quieter still, but before the search: ignored.
        var window = noise(count: 160_000, gaps: [gap, early])
        // A faint hiss in the late gap, so only the 5 s bound keeps the cut out of the early one (#160).
        for i in gap { window[i] = i % 2 == 0 ? 50 : -50 }
        let cut = UploadChunker.cutIndex(samples: window, sampleRate: 16_000)
        #expect(gap.contains(cut))
    }

    @Test func tiesGoToTheLatestFrame() {
        let window = [Int16](repeating: 7, count: 16_000)
        // Frames of 800; the last is 15 200..<16 000, centred at 15 600.
        #expect(UploadChunker.cutIndex(samples: window, sampleRate: 16_000) == 15_600)
    }

    @Test func mergeJoinsWithSingleSpacesAndDropsBlankTexts() {
        #expect(UploadChunker.merge([" first part. ", "", " \n ", "second  part\n", "third"])
            == "first part. second  part third")
        #expect(UploadChunker.merge(["we met on Tuesday", "on Tuesday again"])
            == "we met on Tuesday on Tuesday again")
        #expect(UploadChunker.merge([]) == "")
    }

    @Test func theChunkCountEstimateIsAnUpperBound() {
        #expect(UploadChunker.chunkCount(sampleCount: 0, sampleRate: 16_000, maxSeconds: 600) == 0)
        #expect(UploadChunker.chunkCount(sampleCount: 16_000 * 600, sampleRate: 16_000, maxSeconds: 600) == 1)
        // Four hours: 24 fixed ten-minute steps, at most one more for the cuts.
        let fourHours = 16_000 * 4 * 60 * 60
        #expect(UploadChunker.chunkCount(sampleCount: fourHours, sampleRate: 16_000, maxSeconds: 600) == 25)
    }
}

@MainActor
@Suite struct UploadSilenceCutJobTests {
    @Test func everySampleIsSentExactlyOnceInOrder() async {
        let input = noise(count: 16_000 * 7 + 1_234, gaps: [9_000..<12_200, 30_000..<30_800])
        let relay = await upload(input, maxChunkSeconds: 2)

        #expect(relay.sent.count > 3)
        #expect(relay.sent.allSatisfy { !$0.isEmpty && $0.count <= 32_000 })
        #expect(Array(relay.sent.joined()) == input)
    }

    @Test func aShortInputIsOneChunk() async {
        let short = noise(count: 8_000)
        let relay = await upload(short, maxChunkSeconds: 1)
        #expect(relay.sent == [short])

        let exact = noise(count: 16_000)
        #expect(await upload(exact, maxChunkSeconds: 1).sent == [exact])
    }
}
