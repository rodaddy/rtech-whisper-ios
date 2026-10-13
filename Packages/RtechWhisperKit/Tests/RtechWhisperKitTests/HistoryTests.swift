import Foundation
import Testing

@testable import RtechWhisperKit

@Suite struct HistoryFormattingTests {
    @Test func providerLabelsReadAsWords() {
        #expect(HistoryFormatting.providerLabel("hub") == "Whisper")
        #expect(HistoryFormatting.providerLabel("on-device") == "On-device")
        #expect(HistoryFormatting.providerLabel("openai") == "Openai")
        #expect(HistoryFormatting.providerLabel(nil) == nil)
        #expect(HistoryFormatting.providerLabel("  ") == nil)
    }

    @Test func previewCollapsesWhitespace() {
        #expect(HistoryFormatting.preview("  hello\n\n world  ") == "hello world")
        #expect(HistoryFormatting.preview("   ") == "(no speech)")
    }

    @Test func relativeTimeIsJustNowUnderAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(HistoryFormatting.relativeTime(now.addingTimeInterval(-30), now: now) == "Just now")
        #expect(HistoryFormatting.relativeTime(now.addingTimeInterval(-3600), now: now) != "Just now")
    }

    @Test func durationReadsAsMinutesAndSeconds() {
        #expect(HistoryFormatting.duration(ms: 7_400) == "0:07")
        #expect(HistoryFormatting.duration(ms: 61_000) == "1:01")
        #expect(HistoryFormatting.duration(ms: 0) == nil)
        #expect(HistoryFormatting.duration(ms: nil) == nil)
    }
}

/// Counts sync passes, standing in for `NotesViewModel.syncNow`.
@MainActor
final class SyncCounter {
    private(set) var passes = 0
    func sync() async { passes += 1 }
}

@MainActor
@Suite struct HistoryViewModelTests {
    @Test func loadsNewestFirst() async throws {
        let store = try TranscriptionStore.inMemory()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try await store.add(text: "first", provider: "hub", createdAt: base)
        try await store.add(text: "second", provider: "hub", createdAt: base.addingTimeInterval(1))
        let counter = SyncCounter()
        let history = HistoryViewModel(store: store, sync: counter.sync)

        await history.load()
        #expect(history.items.map(\.text) == ["second", "first"])
        #expect(counter.passes == 0)
    }

    @Test func recordSavesThenSyncs() async throws {
        let store = try TranscriptionStore.inMemory()
        let counter = SyncCounter()
        let history = HistoryViewModel(store: store, sync: counter.sync)

        let saved = await history.record(text: "hello", rawText: "hello", provider: "hub", durationMs: 1_500)
        #expect(saved?.provider == "hub")
        #expect(saved?.audioDurationMs == 1_500)
        #expect(history.items.map(\.text) == ["hello"])
        #expect(counter.passes == 1)
        #expect(history.errorMessage == nil)
    }

    // ios#468: a delete is local only, so it runs no sync pass.
    @Test func deleteRemovesLocallyWithoutSyncing() async throws {
        let store = try TranscriptionStore.inMemory()
        let row = try await store.add(text: "gone", provider: "hub")
        let counter = SyncCounter()
        let history = HistoryViewModel(store: store, sync: counter.sync)
        await history.load()

        await history.delete(row.clientId)
        #expect(history.items.isEmpty)
        #expect(try await store.list().isEmpty)
        #expect(counter.passes == 0)
    }

    @Test func refreshSyncsAndReloads() async throws {
        let store = try TranscriptionStore.inMemory()
        let counter = SyncCounter()
        let history = HistoryViewModel(store: store, sync: counter.sync)
        await history.load()
        #expect(history.items.isEmpty)

        // A row that arrived by another path (a pull) shows after refresh.
        try await store.add(text: "pulled", provider: "openai")
        await history.refresh()
        #expect(counter.passes == 1)
        #expect(history.items.map(\.text) == ["pulled"])
        #expect(history.isRefreshing == false)
    }

    @Test func limitCapsTheList() async throws {
        let store = try TranscriptionStore.inMemory()
        for i in 0..<5 {
            try await store.add(text: "\(i)", createdAt: Date(timeIntervalSince1970: Double(i)))
        }
        let history = HistoryViewModel(store: store, sync: {}, limit: 3)
        await history.load()
        #expect(history.items.map(\.text) == ["4", "3", "2"])
    }
}

// ios-pr-361 review: a replayed save with the same clientId adds no second row.
@Suite struct TranscriptionClientIdTests {
    @Test func addingTheSameClientIdTwiceKeepsOneRow() async throws {
        let store = try TranscriptionStore.inMemory()
        let first = try await store.add(text: "one two three", clientId: "upload-1")
        let again = try await store.add(text: "one two three", clientId: "upload-1")

        #expect(first.clientId == "upload-1")
        #expect(again.clientId == "upload-1")
        #expect(try await store.list().count == 1)
        #expect(try await store.pending().count == 1)
    }

    // ios-pr-361-r2 review: the unique attribute alone upserts, so these seed
    // rows the replay must leave exactly as they were.

    @Test func replayingASyncedRowChangesNothing() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "one", createdAt: Date(timeIntervalSince1970: 100), clientId: "upload-1")
        try await store.markSynced(clientId: "upload-1", cloudId: "cloud-1", cloudUpdatedAt: Date(timeIntervalSince1970: 200))
        let before = try #require(try await store.list().first)

        try await store.add(text: "one", createdAt: Date(timeIntervalSince1970: 999), clientId: "upload-1")

        let after = try #require(try await store.list().first)
        #expect(after == before)
        #expect(after.cloudId == "cloud-1")
        #expect(after.syncStatus == .synced)
        #expect(after.createdAt == Date(timeIntervalSince1970: 100))
        #expect(try await store.pending().isEmpty)
    }

    @Test func replayingARowDeletedAfterItsPushAddsNothing() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "one", createdAt: Date(timeIntervalSince1970: 100), clientId: "upload-1")
        try await store.markSynced(clientId: "upload-1", cloudId: "cloud-1", cloudUpdatedAt: Date(timeIntervalSince1970: 200))
        try await store.delete(clientId: "upload-1")

        let replayed = try await store.add(text: "one", createdAt: Date(timeIntervalSince1970: 999), clientId: "upload-1")

        #expect(replayed.deletedAt != nil)
        #expect(try await store.list().isEmpty)
        #expect(try await store.pending().isEmpty)
    }

    @Test func replayingARowRetentionTrimmedAddsNothing() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "one", createdAt: Date(timeIntervalSince1970: 100), clientId: "upload-1")
        try await store.markSynced(clientId: "upload-1", cloudId: "cloud-1", cloudUpdatedAt: Date(timeIntervalSince1970: 200))
        try await store.applyRetention(.day1, now: Date(timeIntervalSince1970: 100 + 2 * 86_400))

        try await store.add(text: "one", clientId: "upload-1")

        #expect(try await store.list().isEmpty)
        #expect(try await store.pending().isEmpty)
    }

    @Test func replayingARowDeletedBeforeItsFirstPushAddsNothing() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "one", clientId: "upload-1")
        try await store.delete(clientId: "upload-1")

        let replayed = try await store.add(text: "one", clientId: "upload-1")

        #expect(replayed.deletedAt != nil)
        #expect(try await store.list().isEmpty)
        #expect(try await store.pending().isEmpty)
    }

    // ios-pr-361-r3 review: only an upload's row leaves a removal marker, so
    // the markers do not grow with every dictation delete.

    @Test func aDictationDeleteLeavesNoRemovalMarker() async throws {
        let store = try TranscriptionStore.inMemory()
        let row = try await store.add(text: "dictated")
        try await store.delete(clientId: row.clientId)

        // With a marker this add would return an unstored tombstone.
        try await store.add(text: "dictated", clientId: row.clientId)

        #expect(try await store.list().map(\.clientId) == [row.clientId])
    }

    @Test func withoutAClientIdEveryAddIsANewRow() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "a")
        try await store.add(text: "a")
        #expect(try await store.list().count == 2)
    }
}
