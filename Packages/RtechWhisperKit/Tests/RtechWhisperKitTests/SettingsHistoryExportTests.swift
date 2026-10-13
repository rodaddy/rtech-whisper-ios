import Foundation
import Testing

@testable import RtechWhisperKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

@Suite struct HistoryRetentionTests {
    @Test func cutoffIsTheChosenDaysBeforeNow() {
        #expect(HistoryRetention.all.cutoff(now: now) == nil)
        #expect(HistoryRetention.last15.cutoff(now: now) == nil)
        #expect(HistoryRetention.day1.cutoff(now: now) == now.addingTimeInterval(-day))
        #expect(HistoryRetention.days7.cutoff(now: now) == now.addingTimeInterval(-7 * day))
    }

    @Test func expiredSyncedRowsGoAndPendingOnesStay() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "old local", createdAt: now.addingTimeInterval(-8 * day), clientId: "old-local")
        try await store.add(text: "old synced", createdAt: now.addingTimeInterval(-8 * day), clientId: "old-synced")
        try await store.markSynced(clientId: "old-synced", cloudId: "cloud-1", cloudUpdatedAt: now)
        try await store.add(text: "recent", createdAt: now.addingTimeInterval(-6 * day), clientId: "recent")
        try await store.markSynced(clientId: "recent", cloudId: "cloud-2", cloudUpdatedAt: now)

        let history = await HistoryViewModel(store: store, sync: {})
        await history.applyRetention(.days7, now: now)

        #expect(await history.items.map(\.clientId) == ["recent", "old-local"])
    }

    @MainActor @Test func recordTrimsToTheRetentionSetting() async throws {
        let store = try TranscriptionStore.inMemory()
        for i in 0..<15 {
            try await store.add(text: "s\(i)", createdAt: now.addingTimeInterval(Double(i)), clientId: "s\(i)")
            try await store.markSynced(clientId: "s\(i)", cloudId: "c\(i)", cloudUpdatedAt: now)
        }
        let history = HistoryViewModel(store: store, sync: {})
        history.retention = { .last15 }
        // Pending, so it is kept; the fifteen pushed rows are all still within the limit.
        await history.record(text: "new", provider: "hub")
        #expect(history.items.count == 16)
        try await store.markSynced(clientId: history.items[0].clientId, cloudId: "c-new", cloudUpdatedAt: now)
        await history.record(text: "newer", provider: "hub")
        // Now sixteen pushed rows: the oldest one goes.
        #expect(history.items.count == 16)
        #expect(!history.items.contains { $0.clientId == "s0" })
    }

    @Test func keepAllDeletesNothing() async throws {
        let store = try TranscriptionStore.inMemory()
        try await store.add(text: "ancient", createdAt: now.addingTimeInterval(-900 * day))
        let history = await HistoryViewModel(store: store, sync: {})
        await history.applyRetention(.all, now: now)
        #expect(try await store.list().count == 1)
    }

    @MainActor @Test func settingsDefaultAndPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsHistoryExportTests"))
        defaults.removePersistentDomain(forName: "SettingsHistoryExportTests")
        let settings = AppSettingsStore(defaults: defaults)
        #expect(settings.audioCuesEnabled)
        #expect(settings.historyRetention == .last15)
        settings.audioCuesEnabled = false
        settings.historyRetention = .days7
        let reread = AppSettingsStore(defaults: defaults)
        #expect(!reread.audioCuesEnabled)
        #expect(reread.historyRetention == .days7)
    }

    @Test func cuesPlayOnEnteringAndLeavingRecording() {
        #expect(DictationCue.forChange(from: .idle, to: .recording) == .start)
        #expect(DictationCue.forChange(from: .recording, to: .queued) == .stop)
        #expect(DictationCue.forChange(from: .queued, to: .done) == nil)
    }
}

@Suite struct CopyRawTests {
    private func record(text: String, raw: String?) async throws -> TranscriptionRecord {
        try await TranscriptionStore.inMemory().add(text: text, rawText: raw)
    }

    @Test func rawIsOfferedOnlyWhenItDiffersFromTheCleanedText() async throws {
        #expect(HistoryFormatting.rawTextToCopy(try await record(text: "Hello.", raw: "um hello")) == "um hello")
        #expect(HistoryFormatting.rawTextToCopy(try await record(text: "hello", raw: " hello\n")) == nil)
        #expect(HistoryFormatting.rawTextToCopy(try await record(text: "hello", raw: nil)) == nil)
        #expect(HistoryFormatting.rawTextToCopy(try await record(text: "hello", raw: "  ")) == nil)
    }
}

@Suite struct TextExportTests {
    @Test func fileNameIsTheSafeTitle() {
        #expect(TextExport.fileName(title: "Plan: a/b?", format: .md) == "Plan- a-b-.md")
        #expect(TextExport.fileName(title: "  ", format: .txt) == "Untitled.txt")
        #expect(TextExport.fileName(title: nil, format: .md) == "Untitled.md")
    }

    @Test func markdownPrefersEnhancedAndTextStripsMarks() async throws {
        var note = try await NotesStore.inMemory().createNote(
            content: "# Title\n> quoted **bold** [link](https://x.y) ![pic](a.png) `code`")
        #expect(TextExport.noteText(note, format: .md) == note.content)
        #expect(TextExport.noteText(note, format: .txt) == "Title\nquoted bold link pic code")
        note.enhancedContent = "## Better"
        #expect(TextExport.noteText(note, format: .md) == "## Better")
        #expect(TextExport.noteText(note, format: .txt) == "Title\nquoted bold link pic code")
    }

    @Test func historyItemsShareUnderTheirTime() async throws {
        let item = try await TranscriptionStore.inMemory().add(
            text: "hello there", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(TextExport.historyTitle(item, timeZone: TimeZone(identifier: "UTC")!) == "Transcription 2026-09-21 1413")
        #expect(TextExport.historyText(item) == "hello there")
    }
}
