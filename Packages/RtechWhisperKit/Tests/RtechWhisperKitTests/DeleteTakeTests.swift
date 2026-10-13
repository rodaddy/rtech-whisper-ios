import Foundation
import Testing

@testable import RtechWhisperKit

/// A controller wired to a history the way the app wires it: each finished
/// take saved under its queue id, the history pushed through a fake hub.
@MainActor
private struct DeleteRig {
    let scratch = ScratchDirectory()
    let hub = FakeTranscriptionHub()
    let transcriber: ScriptedTranscriber
    let controller: DictationController
    let history: HistoryViewModel
    let sync: TranscriptionSync

    init(_ script: [Result<Transcript, HubError>]) throws {
        transcriber = ScriptedTranscriber(script)
        let store = try TranscriptionStore.inMemory()
        let sync = TranscriptionSync(hub: hub, store: store)
        self.sync = sync
        let history = HistoryViewModel(store: store, sync: { try? await sync.sync() })
        self.history = history
        controller = DictationController(
            recorder: FakeRecorder(), queue: DictationQueue(directory: scratch.url),
            transcribe: transcriber.transcribe, requestMicrophone: { true })
        controller.onTranscribed = { item in
            guard let raw = item.whisperText else { return }
            _ = await history.record(text: raw, provider: "hub", clientId: item.id.uuidString)
        }
    }

    func take() async throws -> UUID {
        await controller.record()
        await controller.stop()
        return try #require(controller.latest?.id)
    }
}

// Delete on the dictation card, with a 5 s Undo.
@MainActor
@Suite("Delete the latest take")
struct DeleteTakeTests {
    @Test func aQueuedTakeIsNeverSentAndNeverReachesTheHistory() async throws {
        let rig = try DeleteRig([.failure(.network("offline")), .success(Transcript(text: "late", noSpeech: false))])
        let id = try await rig.take()
        #expect(rig.controller.state == .queued)

        await rig.controller.delete(take: id, history: rig.history, handoff: nil)
        await rig.controller.retry()

        #expect(rig.transcriber.sent.count == 1, "only the offline attempt before the delete")
        #expect(rig.scratch.wavFiles().isEmpty)
        #expect(rig.history.items.isEmpty)
        #expect(rig.controller.waiting.isEmpty)
    }

    @Test func aDoneTakeLeavesTheHistoryAndSendsNoHubDelete() async throws {
        let rig = try DeleteRig([.success(Transcript(text: "hello", noSpeech: false))])
        let id = try await rig.take()
        #expect(rig.history.items.map(\.clientId) == [id.uuidString])

        await rig.controller.delete(take: id, history: rig.history, handoff: nil)
        try await rig.sync.sync()

        #expect(rig.history.items.isEmpty)
        #expect(await rig.hub.deleteBatches.isEmpty)
    }

    @Test func aMatchingKeyboardHandoffIsDiscarded() async throws {
        let rig = try DeleteRig([.success(Transcript(text: "for the keyboard", noSpeech: false))])
        let id = try await rig.take()
        let handoff = PendingTranscriptStore(defaults: try #require(UserDefaults(suiteName: "DeleteTake-\(UUID())")))
        handoff.write("for the keyboard", take: id)

        await rig.controller.delete(take: id, history: rig.history, handoff: handoff)

        #expect(handoff.pending == nil)
    }

    @Test func deleteClearsTheCard() async throws {
        let rig = try DeleteRig([.success(Transcript(text: "gone", noSpeech: false))])
        let id = try await rig.take()

        await rig.controller.delete(take: id, history: rig.history, handoff: nil)

        #expect(rig.controller.latest == nil)
        #expect(rig.controller.state == .idle)
    }
}

@MainActor
@Suite("The Undo window")
struct PendingDeleteTests {
    /// Sleeps until cancelled: the window never ends on its own.
    private static let never: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    @Test func undoWithinTheWindowDeletesNothing() async {
        let window = PendingDelete(sleep: Self.never)
        var deleted = 0
        let timer = await window.start(UUID()) { deleted += 1 }
        #expect(window.take != nil)

        window.undo()
        await timer.value
        // A recording after Undo must not delete the restored take.
        await window.commit()

        #expect(deleted == 0)
        #expect(window.take == nil)
    }

    @Test func theDeleteRunsWhenTheWindowEnds() async {
        let window = PendingDelete(sleep: { _ in })
        var deleted = 0
        let timer = await window.start(UUID()) { deleted += 1 }

        await timer.value

        #expect(deleted == 1)
        #expect(window.take == nil)
    }

    @Test func aNewRecordingDeletesAtOnceAndOnlyOnce() async {
        let window = PendingDelete(sleep: Self.never)
        var deleted = 0
        let timer = await window.start(UUID()) { deleted += 1 }

        await window.commit()
        await timer.value

        #expect(deleted == 1)
        #expect(window.take == nil)
    }
}
