import Foundation
import Testing

@testable import RtechWhisperKit

// Review of PR #551 (P1): a truncated upload whose retry reads no further is
// not retried again. It is kept as partial: shown from its saved text with no
// decode, until the user removes it.

private struct Damaged: Error {}

/// Hands out `good` samples, then fails every read after them.
private actor DamagedSource: AudioSampleSource {
    nonisolated let durationSeconds: Double
    private var remaining: [Int16]

    init(good: Int, durationSeconds: Double) {
        remaining = (0..<good).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) }
        self.durationSeconds = durationSeconds
    }

    func read(maxSamples: Int) throws -> [Int16] {
        guard !remaining.isEmpty else { throw Damaged() }
        let chunk = Array(remaining.prefix(maxSamples))
        remaining.removeFirst(chunk.count)
        return chunk
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "UploadTruncatedRetryBoundTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var uploads: URL { root.appending(path: "Uploads", directoryHint: .isDirectory) }

    init() throws { try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    func picked() throws -> URL {
        let url = root.appending(path: "interview.wav")
        try WavEncoder.pcm16MonoWav(samples: (0..<40_000).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) }).write(to: url)
        return url
    }

    func saving() throws -> UploadSaving {
        UploadSaving(store: try UploadStore.persistent(url: root.appending(path: "uploads.store")), directory: uploads)
    }
}

/// Counts decodes; each reads `good` samples, then fails.
private final class Decodes: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }

    func damaged(good: Int) -> DecodeAudioFile {
        { _ in
            self.lock.withLock { self.calls += 1 }
            return DamagedSource(good: good, durationSeconds: 2.5)
        }
    }
}

@MainActor
private func job(saving: UploadSaving, decode: @escaping DecodeAudioFile) -> UploadJob {
    UploadJob(
        decode: decode,
        transcribe: { _, _ throws(HubError) in Transcript(text: "part", noSpeech: false) },
        maxChunkSeconds: 1, sleep: { _ in }, saving: saving)
}

@MainActor
@Suite struct UploadTruncatedRetryBoundTests {
    @Test func aRetryThatReadsNoFurtherIsPartialAndNotRetriedAgain() async throws {
        let fixture = try Fixture()
        let decodes = Decodes()
        await job(saving: try fixture.saving(), decode: decodes.damaged(good: 24_000)).run(url: try fixture.picked())

        let retried = job(saving: try fixture.saving(), decode: decodes.damaged(good: 24_000))
        var reported: [UploadResult] = []
        retried.onTranscribed = { reported.append($0) }
        await retried.resumeUnfinished()

        #expect(retried.saveOutcome == .partial)
        #expect(reported.isEmpty)
        let kept = try await fixture.saving().store.unfinished()
        #expect(kept.map(\.status) == [.partial])
        #expect(decodes.count == 2)

        // The next launch shows its text without decoding it again.
        let relaunched = job(saving: try fixture.saving(), decode: decodes.damaged(good: 24_000))
        await relaunched.resumeUnfinished()
        #expect(decodes.count == 2)
        #expect(relaunched.saveOutcome == .partial)
        #expect(relaunched.result?.truncated == true)
        #expect(relaunched.result?.text == "part part")
        #expect(relaunched.result?.durationSeconds == 1.5)

        // Remove forgets it.
        relaunched.reset()
        var spins = 0
        while try await !fixture.saving().store.unfinished().isEmpty, spins < 500 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        #expect(try await fixture.saving().store.unfinished().isEmpty)
    }

    @Test func aRetryThatReadsFurtherStaysIncompleteAndIsRetriedAgain() async throws {
        let fixture = try Fixture()
        let decodes = Decodes()
        await job(saving: try fixture.saving(), decode: decodes.damaged(good: 20_000)).run(url: try fixture.picked())

        let retried = job(saving: try fixture.saving(), decode: decodes.damaged(good: 30_000))
        await retried.resumeUnfinished()

        #expect(retried.saveOutcome == .incomplete(kept: true))
        let kept = try await fixture.saving().store.unfinished()
        #expect(kept.map(\.status) == [.truncated])
        #expect(kept.first?.sentSamples == 30_000)
    }

    @Test func aPartialUploadIsNotShownOverAResultOnScreen() async throws {
        let fixture = try Fixture()
        let decodes = Decodes()
        await job(saving: try fixture.saving(), decode: decodes.damaged(good: 24_000)).run(url: try fixture.picked())
        await job(saving: try fixture.saving(), decode: decodes.damaged(good: 24_000)).resumeUnfinished()

        let later = job(saving: try fixture.saving(), decode: { try AudioFileDecoder.open($0) })
        later.onTranscribed = { _ in }
        await later.run(url: try fixture.picked())
        try #require(later.saveOutcome == .saved)
        await later.resumeUnfinished()

        #expect(later.saveOutcome == .saved)
        #expect(later.result?.truncated == false)
    }
}
