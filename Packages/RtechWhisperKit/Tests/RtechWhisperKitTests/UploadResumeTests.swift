import Foundation
import Testing

@testable import RtechWhisperKit

// An upload outlives the process.

/// Answers from a script and keeps each WAV.
private final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<Transcript, HubError>]
    private var wavs: [Data] = []

    init(_ replies: [Result<Transcript, HubError>]) { self.replies = replies }

    var sent: [Data] { lock.withLock { wavs } }

    func transcribe(_ wav: Data) throws(HubError) -> Transcript {
        let next = lock.withLock { () -> Result<Transcript, HubError> in
            wavs.append(wav)
            return replies.isEmpty ? .success(Transcript(text: "", noSpeech: true)) : replies.removeFirst()
        }
        return try next.get()
    }
}

private let offline = HubError.network("offline")

private func said(_ text: String) -> Result<Transcript, HubError> { .success(Transcript(text: text, noSpeech: false)) }

/// A picked file, and the app's upload store and copies, in a fresh
/// directory of the test process's temporary area, removed on deinit.
private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "UploadResumeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var uploads: URL { root.appending(path: "Uploads", directoryHint: .isDirectory) }

    init() throws { try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 2.5 s of distinct samples as a 16 kHz WAV: three 1 s chunks.
    func picked() throws -> URL {
        let url = root.appending(path: "interview.wav")
        let samples: [Int16] = (0..<40_000).map { (index: Int) -> Int16 in
            let sign = index % 2 == 0 ? 1 : -1
            return Int16(sign * (30_000 - index / 2))
        }
        try WavEncoder.pcm16MonoWav(samples: samples).write(to: url)
        return url
    }

    /// A new store on the same file each call, as a relaunch opens it.
    func saving() throws -> UploadSaving {
        UploadSaving(store: try UploadStore.persistent(url: root.appending(path: "uploads.store")), directory: uploads)
    }

    func copies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: nil)
    }
}

@MainActor
private func job(_ relay: Relay, saving: UploadSaving?) -> UploadJob {
    UploadJob(
        decode: { try AudioFileDecoder.open($0) },
        transcribe: { wav, _ throws(HubError) in try relay.transcribe(wav) },
        maxChunkSeconds: 1,
        sleep: { _ in },
        saving: saving)
}

/// Runs an upload that the network stops after `done` chunks, then drops
/// the job, as a killed app does.
@MainActor
private func interrupt(_ picked: URL, after done: Int, in fixture: Fixture) async throws {
    let texts = ["one", "two", "three"].prefix(done).map(said)
    let upload = job(Relay(texts + [.failure(offline)]), saving: try fixture.saving())
    await upload.run(url: picked)
    try #require(upload.state == .failed(fileName: "interview.wav", .hub(offline)))
}

@MainActor
@Suite struct UploadResumeTests {
    @Test func aRelaunchResumesAfterTheLastChunkDoneWithTheSameText() async throws {
        let fixture = try Fixture()
        let picked = try fixture.picked()
        let whole = Relay([said("one"), said("two"), said("three")])
        let reference = job(whole, saving: nil)
        await reference.run(url: picked)
        let expected = try #require(reference.result)
        try #require(whole.sent.count == 3)

        try await interrupt(picked, after: 2, in: fixture)
        let relay = Relay([said("three")])
        let relaunched = job(relay, saving: try fixture.saving())
        var reported: [UploadResult] = []
        relaunched.onTranscribed = { reported.append($0) }
        await relaunched.resumeUnfinished()

        // The same result, carrying the kept upload's id as its history clientId.
        let id = try #require(relaunched.result?.clientId)
        let kept = UploadResult(
            fileName: expected.fileName, text: expected.text, durationSeconds: expected.durationSeconds,
            noSpeech: expected.noSpeech, clientId: id)
        #expect(relaunched.result == kept)
        #expect(reported == [kept])
        // Chunks 1 and 2 are not sent again; chunk 3 is cut as in the whole run.
        #expect(relay.sent == [whole.sent[2]])
        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
    }

    @Test func aFinishedUploadLeavesNothingBehind() async throws {
        let fixture = try Fixture()
        let picked = try fixture.picked()
        let saving = try fixture.saving()
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: saving)

        await upload.run(url: picked)

        #expect(upload.result?.text == "one two three")
        #expect(try await saving.store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
        // The picked file is the user's, not the app's copy.
        #expect(FileManager.default.fileExists(atPath: picked.path()))
    }

    enum Damage: CaseIterable { case missing, corrupt }

    @Test(arguments: Damage.allCases)
    func aMissingOrCorruptCopyEndsTheUploadWithAnError(_ damage: Damage) async throws {
        let fixture = try Fixture()
        try await interrupt(try fixture.picked(), after: 1, in: fixture)
        let copy = try #require(try fixture.copies().first)
        switch damage {
        case .missing: try FileManager.default.removeItem(at: copy)
        case .corrupt: try Data("not audio".utf8).write(to: copy)
        }
        let relay = Relay([said("two"), said("three")])
        let relaunched = job(relay, saving: try fixture.saving())

        await relaunched.resumeUnfinished()

        guard case .failed(let fileName, .unreadable) = relaunched.state else {
            Issue.record("expected an unreadable failure, got \(relaunched.state)")
            return
        }
        #expect(fileName == "interview.wav")
        #expect(relay.sent.isEmpty)
        #expect(!relaunched.canResume)
        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
    }

    // ios-pr-361 review: the kept upload is deleted only once its text is saved.

    @Test func theUploadIsKeptUntilTheHistorySaveReturns() async throws {
        let fixture = try Fixture()
        let saving = try fixture.saving()
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: saving)
        var keptDuringSave: [UploadCheckpoint] = []
        var copiesDuringSave: [URL] = []
        upload.onTranscribed = { _ in
            // An async save, as the app's history save is: the upload must still be kept.
            await Task.yield()
            keptDuringSave = try await saving.store.unfinished()
            copiesDuringSave = try fixture.copies()
        }

        await upload.run(url: try fixture.picked())

        #expect(keptDuringSave.count == 1)
        #expect(copiesDuringSave.count == 1)
        #expect(try await saving.store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
    }

    @Test func aFailedHistorySaveKeepsTheUploadAndARelaunchSavesItOnceUnderTheSameId() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        let picked = try fixture.picked()
        let first = job(Relay([said("one"), said("two"), said("three")]), saving: try fixture.saving())
        first.onTranscribed = { _ in throw SaveFailed() }
        await first.run(url: picked)
        let shown = try #require(first.result)
        #expect(shown.text == "one two three")
        #expect(try await fixture.saving().store.unfinished().count == 1)
        #expect(try fixture.copies().count == 1)

        // The relaunch finishes it from the saved texts, sending nothing, and
        // a history that saves the same clientId twice keeps one row.
        let history = try TranscriptionStore.inMemory()
        let relay = Relay([])
        let relaunched = job(relay, saving: try fixture.saving())
        relaunched.onTranscribed = { result in
            try await history.add(text: result.text, clientId: result.clientId)
        }
        await relaunched.resumeUnfinished()
        let again = try #require(relaunched.result)
        try await history.add(text: again.text, clientId: again.clientId)

        #expect(again.text == "one two three")
        #expect(again.clientId == shown.clientId)
        #expect(relay.sent.isEmpty)
        #expect(try await history.list().map(\.clientId) == [shown.clientId])
        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
    }

    // ios-pr-361-r2 review: a history save that keeps failing must not replay
    // the upload on every launch with no way out.

    @Test func discardingAResultWhoseSaveFailedForgetsTheKeptUpload() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: try fixture.saving())
        upload.onTranscribed = { _ in throw SaveFailed() }
        await upload.run(url: try fixture.picked())
        #expect(upload.saveOutcome == .notSaved(kept: true))
        #expect(try fixture.copies().count == 1)

        upload.reset()
        #expect(upload.saveOutcome == nil)
        // reset forgets on a Task of its own.
        var spins = 0
        while try !fixture.copies().isEmpty, spins < 200 {
            await Task.yield()
            spins += 1
        }

        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
        // Nothing is left for the next launch to replay.
        let relay = Relay([])
        let relaunched = job(relay, saving: try fixture.saving())
        var replayed = 0
        relaunched.onTranscribed = { _ in replayed += 1 }
        await relaunched.resumeUnfinished()
        #expect(replayed == 0)
        #expect(relaunched.state == .idle)
    }

    // ios-pr-361-r3 review: the save outcome is explicit state, and nothing
    // but Discard or a retry that saves ends a kept result not saved.

    @Test func aThrowingSaveWithNoCheckpointIsNotSavedAndNotKept() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        // No store, as when `UploadSaving.persistent()` fails in the app.
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: nil)
        upload.onTranscribed = { _ in throw SaveFailed() }

        await upload.run(url: try fixture.picked())

        #expect(upload.result?.text == "one two three")
        #expect(upload.saveOutcome == .notSaved(kept: false))
        #expect(!upload.holdsUnsavedResult)
    }

    @Test func aSaveThatReturnsIsSaved() async throws {
        let fixture = try Fixture()
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: try fixture.saving())
        upload.onTranscribed = { _ in }

        await upload.run(url: try fixture.picked())

        #expect(upload.saveOutcome == .saved)
    }

    @Test func pickingAnotherFileNeverDropsAKeptResultNotSaved() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        let picked = try fixture.picked()
        let relay = Relay([said("one"), said("two"), said("three"), said("four")])
        let upload = job(relay, saving: try fixture.saving())
        var fail = true
        upload.onTranscribed = { _ in if fail { throw SaveFailed() } }
        await upload.run(url: picked)
        let first = try #require(upload.result?.clientId)
        #expect(upload.holdsUnsavedResult)
        fail = false

        await upload.run(url: picked)

        // Ignored: the unsaved result stays on screen, still kept.
        #expect(upload.result?.clientId == first)
        #expect(upload.saveOutcome == .notSaved(kept: true))
        #expect(relay.sent.count == 3)
        #expect(try await fixture.saving().store.unfinished().map(\.id.uuidString) == [first])
        #expect(try fixture.copies().count == 1)
    }

    @Test func retryNowThatSavesForgetsTheKeptUpload() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        let upload = job(Relay([said("one"), said("two"), said("three")]), saving: try fixture.saving())
        var fail = true
        var savedIds: [String?] = []
        upload.onTranscribed = { result in
            if fail { throw SaveFailed() }
            savedIds.append(result.clientId)
        }
        await upload.run(url: try fixture.picked())
        let id = try #require(upload.result?.clientId)
        #expect(upload.saveOutcome == .notSaved(kept: true))

        // A retry that fails again changes nothing.
        await upload.retrySave()
        #expect(upload.saveOutcome == .notSaved(kept: true))
        #expect(try await fixture.saving().store.unfinished().count == 1)

        fail = false
        await upload.retrySave()

        #expect(savedIds == [id])
        #expect(upload.saveOutcome == .saved)
        #expect(!upload.holdsUnsavedResult)
        #expect(upload.result?.text == "one two three")
        #expect(try await fixture.saving().store.unfinished().isEmpty)
        #expect(try fixture.copies().isEmpty)
    }

    @Test func aRelaunchStopsAtTheFirstResultWhoseSaveFailsAgainAndLeavesTheRest() async throws {
        struct SaveFailed: Error {}
        let fixture = try Fixture()
        let picked = try fixture.picked()
        // A: finished, its save failed. B, kept after it: stopped by the hub after one chunk.
        let a = job(Relay([said("a1"), said("a2"), said("a3")]), saving: try fixture.saving())
        a.onTranscribed = { _ in throw SaveFailed() }
        await a.run(url: picked)
        let aId = try #require(a.result?.clientId)
        let b = job(Relay([said("b1"), .failure(offline)]), saving: try fixture.saving())
        await b.run(url: picked)
        try #require(b.canResume)
        let before = try await fixture.saving().store.unfinished()
        try #require(before.map(\.id.uuidString).first == aId)
        try #require(before.count == 2)

        let relay = Relay([said("b2"), said("b3")])
        let relaunched = job(relay, saving: try fixture.saving())
        var tried: [String?] = []
        relaunched.onTranscribed = { result in
            tried.append(result.clientId)
            throw SaveFailed()
        }
        await relaunched.resumeUnfinished()

        // A is shown as not saved; B is untouched: nothing sent, still kept as it was.
        #expect(relaunched.result?.text == "a1 a2 a3")
        #expect(relaunched.saveOutcome == .notSaved(kept: true))
        #expect(tried == [aId])
        #expect(relay.sent.isEmpty)
        #expect(try await fixture.saving().store.unfinished() == before)
        #expect(try fixture.copies().count == 2)
    }

    @Test func aRelaunchRemovesCopiesNoCheckpointNamesAndKeepsTheRest() async throws {
        let fixture = try Fixture()
        try await interrupt(try fixture.picked(), after: 1, in: fixture)
        let kept = try #require(try fixture.copies().first)
        // A copy left by a kill before its first checkpoint, and one a failed copy left.
        let orphan = fixture.uploads.appending(path: "\(UUID().uuidString).wav")
        let partial = fixture.uploads.appending(path: "\(UUID().uuidString).m4a")
        try Data("orphan".utf8).write(to: orphan)
        try Data("part".utf8).write(to: partial)
        // The hub is still down, so the resumed upload stops again and stays kept.
        let relaunched = job(Relay([.failure(offline)]), saving: try fixture.saving())

        await relaunched.resumeUnfinished()

        #expect(relaunched.canResume)
        #expect(try fixture.copies().map(\.lastPathComponent) == [kept.lastPathComponent])
        #expect(try await fixture.saving().store.unfinished().count == 1)
    }
}
