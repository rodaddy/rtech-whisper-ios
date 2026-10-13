import Foundation
import Testing

@testable import RtechWhisperKit

// #96: a kept upload's chunks go through a background transport.

/// A background session stand-in: each send is answered later, from a
/// script by chunk, through `BackgroundAnswers` as the app's delegate would.
private final class FakeBackground: BackgroundTransport, @unchecked Sendable {
    let answers = BackgroundAnswers()
    private let lock = NSLock()
    private var script: [Int: Result<Transcript, HubError>]
    private var tags: [UploadChunkTag] = []

    init(_ script: [Int: Result<Transcript, HubError>]) { self.script = script }

    var sent: [Int] { lock.withLock { tags.map(\.chunk) } }

    func transcribe(
        _ wav: Data, hint: String?, tag: UploadChunkTag, started: @escaping @Sendable () -> Void
    ) async throws(HubError) -> Transcript {
        let answer = lock.withLock { () -> Result<Transcript, HubError>? in
            tags.append(tag)
            return script[tag.chunk]
        }
        started()
        if let answer {
            // Answered while the app is suspended: after the send returns control.
            Task { [answers] in
                await Task.yield()
                await answers.deliver(tag, answer)
            }
        }
        return try await answers.wait(for: tag).get()
    }

    func takeFinished(_ tag: UploadChunkTag) async -> Result<Transcript, HubError>? {
        await answers.take(tag)
    }
}

private func said(_ text: String) -> Result<Transcript, HubError> { .success(Transcript(text: text, noSpeech: false)) }

private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "UploadBackgroundTransportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var uploads: URL { root.appending(path: "Uploads", directoryHint: .isDirectory) }

    init() throws { try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 2.5 s of audio: three 1 s chunks.
    func picked() throws -> URL {
        let url = root.appending(path: "interview.wav")
        let samples: [Int16] = (0..<40_000).map { (index: Int) -> Int16 in
            let sign = index % 2 == 0 ? 1 : -1
            return Int16(sign * (30_000 - index / 2))
        }
        try WavEncoder.pcm16MonoWav(samples: samples).write(to: url)
        return url
    }

    func saving() throws -> UploadSaving {
        UploadSaving(store: try UploadStore.persistent(url: root.appending(path: "uploads.store")), directory: uploads)
    }
}

@MainActor
private func job(_ background: FakeBackground, saving: UploadSaving?) -> UploadJob {
    UploadJob(
        decode: { try AudioFileDecoder.open($0) },
        transcribe: { _, _ throws(HubError) in throw .network("foreground used") },
        maxChunkSeconds: 1,
        sleep: { _ in },
        saving: saving,
        background: background)
}

@MainActor
@Suite struct UploadBackgroundTransportTests {
    @Test func aTagRoundTripsThroughTheTaskDescription() {
        let tag = UploadChunkTag(upload: UUID(), chunk: 2)
        #expect(UploadChunkTag(taskDescription: tag.taskDescription) == tag)
        #expect(UploadChunkTag(taskDescription: "dictation") == nil)
        #expect(UploadChunkTag(taskDescription: nil) == nil)
    }

    @Test func chunksAnsweredWhileSuspendedAreMergedInOrder() async throws {
        let fixture = try Fixture()
        let background = FakeBackground([0: said("one"), 1: said("two"), 2: said("three")])
        let upload = job(background, saving: try fixture.saving())

        await upload.run(url: try fixture.picked())

        #expect(upload.result?.text == "one two three")
        #expect(upload.saveOutcome == .saved)
        #expect(background.sent == [0, 1, 2])
    }

    @Test func aRelaunchTakesTheAnswerOfTheOutstandingChunkWithoutResending() async throws {
        let fixture = try Fixture()
        let picked = try fixture.picked()
        // The first launch is killed while chunk 1 is in flight: chunk 0 is checkpointed.
        let first = job(FakeBackground([0: said("one"), 1: .failure(.network("killed"))]), saving: try fixture.saving())
        await first.run(url: picked)
        let checkpoint = try #require(try await fixture.saving().store.unfinished().first)
        try #require(checkpoint.chunksDone == 1)

        // The system finished chunk 1 and relaunched the app with its answer.
        let background = FakeBackground([2: said("three")])
        await background.answers.deliver(UploadChunkTag(upload: checkpoint.id, chunk: 1), said("two"))
        let relaunched = job(background, saving: try fixture.saving())
        await relaunched.resumeUnfinished()

        #expect(relaunched.result?.text == "one two three")
        #expect(background.sent == [2])
    }

    @Test func anErrorAnswerFollowsTheFailurePath() async throws {
        let fixture = try Fixture()
        let background = FakeBackground([0: said("one"), 1: .failure(.unsupportedAudio)])
        let upload = job(background, saving: try fixture.saving())

        await upload.run(url: try fixture.picked())

        #expect(upload.state == .failed(fileName: "interview.wav", .hub(.unsupportedAudio)))
        #expect(!upload.canResume)
        #expect(try await fixture.saving().store.unfinished().isEmpty)
    }

    // Review ios-pr-594: the system completion handler of a background
    // relaunch is held until the next chunk is handed over.

    @Test func aSuspendedPassSettlesOnceItsNextChunkIsHandedOver() async throws {
        let fixture = try Fixture()
        let background = FakeBackground([:])
        let upload = job(background, saving: try fixture.saving())
        let running = Task { await upload.run(url: try fixture.picked()) }
        try await until { background.sent == [0] }

        // Chunk 0 answers while the app is suspended in its wait.
        let carried = Task { await upload.carryOnAfterEvents() }
        for _ in 0..<10 { await Task.yield() }
        let id = try #require(try await fixture.saving().store.unfinished().first?.id)
        await background.answers.deliver(UploadChunkTag(upload: id, chunk: 0), said("one"))
        await carried.value

        #expect(background.sent == [0, 1])
        #expect(upload.isRunning)
        await background.answers.deliver(UploadChunkTag(upload: id, chunk: 1), said("two"))
        try await until { background.sent == [0, 1, 2] }
        await background.answers.deliver(UploadChunkTag(upload: id, chunk: 2), said("three"))
        _ = await running.result
        #expect(upload.result?.text == "one two three")
    }

    @Test func aRelaunchSettlesOnceTheNextChunkIsHandedOver() async throws {
        let fixture = try Fixture()
        let first = job(FakeBackground([0: said("one"), 1: .failure(.network("killed"))]), saving: try fixture.saving())
        await first.run(url: try fixture.picked())
        let checkpoint = try #require(try await fixture.saving().store.unfinished().first)

        // Chunk 1 finished while the app was not running; chunk 2 is not answered yet.
        let background = FakeBackground([:])
        await background.answers.deliver(UploadChunkTag(upload: checkpoint.id, chunk: 1), said("two"))
        let relaunched = job(background, saving: try fixture.saving())
        await relaunched.carryOnAfterEvents()

        #expect(background.sent == [2])
        #expect(relaunched.isRunning)
        await background.answers.deliver(UploadChunkTag(upload: checkpoint.id, chunk: 2), said("three"))
        try await until { !relaunched.isRunning }
        #expect(relaunched.result?.text == "one two three")
    }

    @Test func nothingKeptSettlesAtOnce() async throws {
        let fixture = try Fixture()
        let background = FakeBackground([:])
        let upload = job(background, saving: try fixture.saving())

        await upload.carryOnAfterEvents()

        #expect(upload.state == .idle)
        #expect(background.sent.isEmpty)
    }
}

/// Yields until `condition` holds; fails after a bounded number of tries.
@MainActor
private func until(_ condition: () -> Bool) async throws {
    var tries = 0
    while !condition(), tries < 100_000 {
        await Task.yield()
        tries += 1
    }
    try #require(condition())
}
