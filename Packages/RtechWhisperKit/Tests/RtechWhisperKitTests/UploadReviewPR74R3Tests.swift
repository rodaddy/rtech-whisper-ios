import Foundation
import Testing

@testable import RtechWhisperKit

// Review findings for ios-pr-74-r3.

private struct Damaged: Error, LocalizedError {
    var errorDescription: String? { "damaged" }
}

/// Converts `good` in blocks of `block` samples through a `BlockDrain`, as
/// `AudioFileReader` does; the block holding the end of `good` appends it
/// and throws in the same call, so the error arrives inside a read that has
/// already converted samples.
private actor BlockDamagedSource: AudioSampleSource {
    nonisolated let durationSeconds: Double
    private let good: [Int16]
    private let block: Int
    private var offset = 0
    private var drain = BlockDrain()
    private(set) var blocksConverted = 0

    init(good: [Int16], block: Int, durationSeconds: Double) {
        self.good = good
        self.block = block
        self.durationSeconds = durationSeconds
    }

    func read(maxSamples: Int) throws -> [Int16] {
        try drain.read(maxSamples: maxSamples) { pending in
            blocksConverted += 1
            let end = min(offset + block, good.count)
            pending += good[offset..<end]
            offset = end
            if offset == good.count { throw Damaged() }
            return false
        }
    }
}

/// Keeps the samples of every WAV sent.
private final class SampleRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    private(set) var sent: [[Int16]] = []
    init(_ texts: [String]) { self.texts = texts }
    func transcribe(_ wav: Data) -> Transcript {
        let samples = wav.dropFirst(WavEncoder.headerLength).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return lock.withLock {
            sent.append(samples)
            return Transcript(text: texts.isEmpty ? "" : texts.removeFirst(), noSpeech: false)
        }
    }
}

/// Distinct samples, so a lost or repeated stretch changes the joined output.
private func ramp(_ count: Int) -> [Int16] { (0..<count).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) } }

@MainActor
private func upload(_ source: any AudioSampleSource, relay: SampleRelay) -> UploadJob {
    UploadJob(
        decode: { _ in source },
        transcribe: { wav, _ throws(HubError) in relay.transcribe(wav) },
        maxChunkSeconds: 1, sleep: { _ in })
}

@Suite struct BlockDrainTests {
    @Test func samplesConvertedBeforeAFailureAreReturnedAndTheErrorComesNext() throws {
        var drain = BlockDrain()
        var blocks = 0
        let convert: (inout [Int16]) throws -> Bool = { pending in
            blocks += 1
            pending += [1, 2, 3]
            if blocks == 2 { throw Damaged() }
            return false
        }
        // Asks for more than there is: two blocks, the second appends and throws.
        #expect(try drain.read(maxSamples: 4, nextBlock: convert) == [1, 2, 3, 1])
        #expect(try drain.read(maxSamples: 4, nextBlock: convert) == [2, 3])
        #expect(throws: Damaged.self) { try drain.read(maxSamples: 4, nextBlock: convert) }
        // Sticky: a retry never converts past the damage.
        #expect(throws: Damaged.self) { try drain.read(maxSamples: 4, nextBlock: convert) }
        #expect(blocks == 2)
    }

    @Test func theEndOfTheAudioIsEmptyNotAnError() throws {
        var drain = BlockDrain()
        let convert: (inout [Int16]) throws -> Bool = { pending in
            pending += [5, 6]
            return true
        }
        #expect(try drain.read(maxSamples: 10, nextBlock: convert) == [5, 6])
        #expect(try drain.read(maxSamples: 10, nextBlock: convert) == [])
    }
}

@MainActor
@Suite struct UploadDamagedMidReadTests {
    @Test func everyGoodSampleReachesTheRelayWhenTheDamageIsInsideARead() async {
        // 40,000 good samples in 20,000-sample blocks. The second read converts
        // the second block, which holds the rest and throws; it converts past
        // what that read asks for, so later reads hand out the stranded
        // samples before the error.
        let good = ramp(40_000)
        let relay = SampleRelay(["one", "two", "three", "four", "five"])
        let source = BlockDamagedSource(good: good, block: 20_000, durationSeconds: 10)
        let job = upload(source, relay: relay)

        await job.run(url: URL(fileURLWithPath: "/audio/damaged.m4a"))

        #expect(Array(relay.sent.joined()) == good)
        #expect(job.result?.truncated == true)
        // The duration is the audio sent, not the whole damaged file.
        #expect(job.result?.durationSeconds == 2.5)
        #expect(await source.blocksConverted == 2)
        #expect(relay.sent.count > 2)
    }

    @Test func damageInsideTheFirstChunkStillSendsWhatWasRead() async {
        let good = ramp(9_000)
        let relay = SampleRelay(["start"])
        let job = upload(BlockDamagedSource(good: good, block: 3_000, durationSeconds: 10), relay: relay)

        await job.run(url: URL(fileURLWithPath: "/audio/damaged.m4a"))

        #expect(relay.sent == [good])
        #expect(job.result?.text == "start")
        #expect(job.result?.truncated == true)
        #expect(job.result?.durationSeconds == 0.5625)  // 9,000 samples sent, not the 10 s header.
    }
}
