import Foundation
import Testing

@testable import RtechWhisperKit

// #156: a truncated upload is not complete. It writes no history row, stays
// kept, and the next resumeUnfinished retries it.

private struct Damaged: Error {}

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

private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "UploadTruncatedRetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var uploads: URL { root.appending(path: "Uploads", directoryHint: .isDirectory) }

    init() throws { try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 2.5 s of 16 kHz WAV: three 1 s chunks.
    func picked() throws -> URL {
        let url = root.appending(path: "interview.wav")
        try WavEncoder.pcm16MonoWav(samples: (0..<40_000).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) }).write(to: url)
        return url
    }

    func saving() throws -> UploadSaving {
        UploadSaving(store: try UploadStore.persistent(url: root.appending(path: "uploads.store")), directory: uploads)
    }
}

@MainActor
private func job(saving: UploadSaving?, decode: @escaping DecodeAudioFile) -> UploadJob {
    UploadJob(
        decode: decode,
        transcribe: { _, _ throws(HubError) in Transcript(text: "part", noSpeech: false) },
        maxChunkSeconds: 1, sleep: { _ in }, saving: saving)
}

/// The first 1.5 s of the file reads, then the rest fails.
private let damaged: DecodeAudioFile = { _ in
    DamagedSource(good: (0..<24_000).map { Int16(truncatingIfNeeded: $0 &* 7 &+ 1) }, durationSeconds: 2.5)
}

@MainActor
@Suite struct UploadTruncatedRetryTests {
    @Test func aTruncatedUploadWritesNoHistoryRowAndStaysKept() async throws {
        let fixture = try Fixture()
        let upload = job(saving: try fixture.saving(), decode: damaged)
        var reported: [UploadResult] = []
        upload.onTranscribed = { reported.append($0) }

        await upload.run(url: try fixture.picked())

        #expect(upload.result?.truncated == true)
        #expect(reported.isEmpty)
        #expect(upload.saveOutcome == .incomplete(kept: true))
        let kept = try await fixture.saving().store.unfinished()
        #expect(kept.count == 1)
        #expect(kept.first?.status == .truncated)
    }

    @Test func theNextResumeRetriesItAndAFullReadCompletesIt() async throws {
        let fixture = try Fixture()
        let first = job(saving: try fixture.saving(), decode: damaged)
        await first.run(url: try fixture.picked())
        try #require(first.saveOutcome == .incomplete(kept: true))

        let relaunched = job(saving: try fixture.saving(), decode: { try AudioFileDecoder.open($0) })
        var reported: [UploadResult] = []
        relaunched.onTranscribed = { reported.append($0) }
        await relaunched.resumeUnfinished()

        #expect(relaunched.result?.truncated == false)
        #expect(relaunched.saveOutcome == .saved)
        #expect(reported.count == 1)
        #expect(try await fixture.saving().store.unfinished().isEmpty)
    }

    @Test func removingAnIncompleteUploadForgetsIt() async throws {
        let fixture = try Fixture()
        let upload = job(saving: try fixture.saving(), decode: damaged)
        await upload.run(url: try fixture.picked())
        try #require(upload.saveOutcome == .incomplete(kept: true))

        upload.reset()
        var spins = 0
        // reset forgets on a Task of its own; waits up to 5 s on a loaded host.
        while try await !fixture.saving().store.unfinished().isEmpty, spins < 500 {
            try await Task.sleep(for: .milliseconds(10))
            spins += 1
        }
        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(upload.state == .idle)
    }

    @Test func withNoStoreATruncatedUploadIsIncompleteAndNotKept() async throws {
        let fixture = try Fixture()
        let upload = job(saving: nil, decode: damaged)
        var reported: [UploadResult] = []
        upload.onTranscribed = { reported.append($0) }

        await upload.run(url: try fixture.picked())

        #expect(reported.isEmpty)
        #expect(upload.saveOutcome == .incomplete(kept: false))
    }
}
