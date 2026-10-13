import Foundation
import SwiftData
import Testing

@testable import RtechWhisperKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let day: TimeInterval = 86_400

/// A store over a container the test can also read directly, so a row gone
/// for good (not just hidden as a tombstone) can be told apart.
private struct Rig {
    let container: ModelContainer
    let store: TranscriptionStore
    let hub = FakeTranscriptionHub()
    let sync: TranscriptionSync

    init() throws {
        container = try ModelContainer(
            for: TranscriptionStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = TranscriptionStore(modelContainer: container)
        sync = TranscriptionSync(hub: hub, store: store)
    }

    /// Every stored row, tombstones included.
    func storedRowCount() throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<LocalTranscription>())
    }
}

// ios#468: the phone pushes its own dictations and keeps a short local history.
@Suite("Phone history is push-only and local")
struct PhoneHistoryLocalTests {
    @Test func syncPushesPendingRowsAndPullsNothing() async throws {
        let rig = try Rig()
        let row = try await rig.store.add(text: "mine")

        try await rig.sync.sync()

        #expect(await rig.hub.listCalls.isEmpty)
        #expect(await rig.hub.createBatches.map { $0.map(\.clientTranscriptionId) } == [[row.clientId]])
    }

    @Test func deletingASyncedRowSendsNothingAndRemovesItForGood() async throws {
        let rig = try Rig()
        let row = try await rig.store.add(text: "drop me")
        try await rig.sync.push()

        try await rig.store.delete(clientId: row.clientId)
        try await rig.sync.sync()

        #expect(await rig.hub.deleteBatches.isEmpty)
        #expect(try rig.storedRowCount() == 0)
    }

    @Test func lastFifteenKeepsTheNewestSyncedRowsAndEveryPendingOne() async throws {
        let rig = try Rig()
        // The pending rows are the oldest, so a trim that counted them would drop them.
        for i in 0..<2 {
            try await rig.store.add(text: "p\(i)", createdAt: now.addingTimeInterval(Double(i)), clientId: "p\(i)")
        }
        for i in 0..<20 {
            try await rig.store.add(text: "s\(i)", createdAt: now.addingTimeInterval(Double(100 + i)), clientId: "s\(i)")
            try await rig.store.markSynced(clientId: "s\(i)", cloudId: "c\(i)", cloudUpdatedAt: now)
        }

        try await rig.store.applyRetention(.last15, now: now)

        let kept = Set(try await rig.store.list().map(\.clientId))
        #expect(kept == Set((5..<20).map { "s\($0)" } + ["p0", "p1"]))
        #expect(try rig.storedRowCount() == 17)
    }

    @Test func oneDayRemovesAnOldSyncedRowAndKeepsAnOldPendingOne() async throws {
        let rig = try Rig()
        try await rig.store.add(text: "old synced", createdAt: now.addingTimeInterval(-2 * day), clientId: "old-synced")
        try await rig.store.markSynced(clientId: "old-synced", cloudId: "c1", cloudUpdatedAt: now)
        try await rig.store.add(text: "old pending", createdAt: now.addingTimeInterval(-2 * day), clientId: "old-pending")
        try await rig.store.add(text: "new synced", createdAt: now.addingTimeInterval(-day / 2), clientId: "new-synced")
        try await rig.store.markSynced(clientId: "new-synced", cloudId: "c2", cloudUpdatedAt: now)

        try await rig.store.applyRetention(.day1, now: now)

        #expect(Set(try await rig.store.list().map(\.clientId)) == ["old-pending", "new-synced"])
        #expect(try rig.storedRowCount() == 2)
    }

    @Test func anOldTombstoneIsHardDeletedByRetentionAndNothingIsSent() async throws {
        let rig = try Rig()
        // What the old code left behind: a synced row deleted here, its hub delete never sent.
        let context = ModelContext(rig.container)
        context.insert(LocalTranscription(
            clientId: "tomb", cloudId: "c-tomb", text: "gone", status: "completed", syncStatus: .pending,
            deletedAt: now, cloudUpdatedAt: now, createdAt: now))
        try context.save()

        try await rig.store.applyRetention(.all, now: now)
        try await rig.sync.sync()

        #expect(try rig.storedRowCount() == 0)
        #expect(await rig.hub.deleteBatches.isEmpty)
    }

    @MainActor @Test func storedRetentionValuesMapToTheNewChoices() throws {
        let suite = "PhoneHistoryLocalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let key = AppSettingsStore.Key.historyRetentionDays
        #expect(AppSettingsStore(defaults: defaults).historyRetention == .last15)
        defaults.set(30, forKey: key)
        #expect(AppSettingsStore(defaults: defaults).historyRetention == .days7)
        defaults.set(90, forKey: key)
        #expect(AppSettingsStore(defaults: defaults).historyRetention == .all)
        defaults.set(0, forKey: key)
        #expect(AppSettingsStore(defaults: defaults).historyRetention == .all)

        AppSettingsStore(defaults: defaults).historyRetention = .last50
        #expect(AppSettingsStore(defaults: defaults).historyRetention == .last50)
        defaults.removePersistentDomain(forName: suite)
    }
}
