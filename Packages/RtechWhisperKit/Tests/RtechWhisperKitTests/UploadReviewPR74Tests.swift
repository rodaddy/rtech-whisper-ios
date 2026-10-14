import Foundation
import Testing

@testable import RtechWhisperKit

// Review findings for ios-pr-74.

private struct Damaged: Error, LocalizedError {
    var errorDescription: String? { "damaged" }
}

/// Hands out `good` samples, then fails every read after them.
private actor DamagedSource: AudioSampleSource {
    nonisolated let durationSeconds: Double
    private var remaining: [Int16]

    init(good: [Int16], durationSeconds: Double) {
        remaining = good
        self.durationSeconds = durationSeconds
    }

    func read(maxSamples: Int) throws -> [Int16] {
        guard !remaining.isEmpty else { throw Damaged() }
        let chunk = Array(remaining.prefix(maxSamples))
        remaining.removeFirst(chunk.count)
        return chunk
    }
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    private(set) var sent: [[Int16]] = []
    var sends: Int { lock.withLock { sent.count } }
    init(_ texts: [String]) { self.texts = texts }
    func next(_ wav: Data) -> Transcript {
        lock.withLock {
            sent.append(wav.dropFirst(WavEncoder.headerLength).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) })
            return Transcript(text: texts.isEmpty ? "" : texts.removeFirst(), noSpeech: false)
        }
    }
}

@MainActor
private func job(_ source: @escaping @Sendable () -> any AudioSampleSource, replies: Replies) -> UploadJob {
    UploadJob(
        decode: { _ in source() },
        transcribe: { wav, _ throws(HubError) in replies.next(wav) },
        maxChunkSeconds: 1, sleep: { _ in })
}

private let url = URL(fileURLWithPath: "/audio/damaged.m4a")

@MainActor
@Suite struct UploadDamagedFileTests {
    @Test func aReadErrorAfterTheFirstChunkKeepsTheTextSoFar() async {
        let replies = Replies(["one", "two"])
        let upload = job({ DamagedSource(good: Array(repeating: 1, count: 32_000), durationSeconds: 5) }, replies: replies)
        var reported: [UploadResult] = []
        upload.onTranscribed = { reported.append($0) }

        await upload.run(url: url)

        let expected = UploadResult(
            fileName: "damaged.m4a", text: "one two", durationSeconds: 2, noSpeech: false, truncated: true,
            truncationReason: "The rest of the file could not be read.")  // Plain words for the footer.
        #expect(upload.state == .done(expected))
        // A truncated upload is not complete, so no history row is written.
        #expect(reported.isEmpty)
        // Two cut chunks, then the 800 samples left before the damage.
        #expect(replies.sends == 3)
    }

    // The read that throws finds carry left over from the last cut, and sends it.
    @Test func aReadErrorWithCarryLeftSendsTheCarry() async {
        let good = (0..<16_001).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) }
        let replies = Replies(["one", "two"])
        let upload = job({ DamagedSource(good: good, durationSeconds: 5) }, replies: replies)

        await upload.run(url: url)

        #expect(replies.sent.count == 2)
        #expect(Array(replies.sent.joined()) == good)
        #expect(upload.result?.text == "one two")
        #expect(upload.result?.truncated == true)
        #expect(upload.result?.durationSeconds == 16_001.0 / 16_000)
    }

    @Test func aReadErrorBeforeAnySendStillFails() async {
        let replies = Replies([])
        let upload = job({ DamagedSource(good: [], durationSeconds: 5) }, replies: replies)

        await upload.run(url: url)

        #expect(upload.state == .failed(fileName: "damaged.m4a", .unreadable("damaged")))
        #expect(replies.sends == 0)
    }

    @Test func aFileReadToTheEndIsNotTruncated() async {
        let upload = job({ DecodedAudio(samples: [1, 2, 3], durationSeconds: 1).source }, replies: Replies(["hi"]))
        await upload.run(url: url)
        #expect(upload.result?.truncated == false)
    }
}

@MainActor
@Suite struct BackgroundTaskScopeTests {
    @Test func endsTheTaskWhenTheSystemExpiresItAndNotAgainAfter() async {
        var ended: [Int] = []
        var expire: (@MainActor () -> Void)?
        var workFinished = false

        await BackgroundTaskScope.run(
            begin: { onExpire in expire = onExpire; return 7 },
            end: { ended.append($0) }
        ) {
            expire?()
            #expect(ended == [7])
            workFinished = true
        }

        #expect(workFinished)
        #expect(ended == [7])
    }

    @Test func endsTheTaskWhenTheWorkFinishes() async {
        var ended: [Int] = []
        await BackgroundTaskScope.run(begin: { _ in 3 }, end: { ended.append($0) }) {
            #expect(ended.isEmpty)
        }
        #expect(ended == [3])
    }

    @Test func aTaskThatWasNotGrantedIsNeverEnded() async {
        var ended: [Int] = []
        await BackgroundTaskScope.run(begin: { _ -> Int? in nil }, end: { ended.append($0) }) {}
        #expect(ended.isEmpty)
    }
}
