import Foundation
import Testing

@testable import RtechWhisperKit

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

/// A hub that serves transcription deltas the way the protocol orders and
/// filters them (`updated_at > since`, ascending), and records every call.
/// The phone only creates, so `listCalls` and `deleteBatches`
/// must stay empty.
actor FakeTranscriptionHub: TranscriptionHubSyncing {
    static let writeStamp = t0.addingTimeInterval(500)

    var rows: [HubTranscription] = []
    var listCalls: [(limit: Int, since: Date)] = []
    var createBatches: [[TranscriptionCreateInput]] = []
    var deleteBatches: [[String]] = []

    func setRows(_ value: [HubTranscription]) { rows = value }
    func upsert(_ row: HubTranscription) {
        rows.removeAll { $0.id == row.id }
        rows.append(row)
    }

    func listTranscriptionChanges(limit: Int, since: Date) async throws(HubError) -> [HubTranscription] {
        listCalls.append((limit, since))
        return Array(rows
            .filter { $0.updatedAt > since }
            .sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
            .prefix(limit))
    }

    func batchCreateTranscriptions(_ inputs: [TranscriptionCreateInput]) async throws(HubError) -> [HubTranscription] {
        createBatches.append(inputs)
        return inputs.map { input in
            if let existing = rows.first(where: { $0.clientTranscriptionId == input.clientTranscriptionId }) {
                return existing
            }
            let row = HubTranscription(
                id: "h-\(input.clientTranscriptionId)", clientTranscriptionId: input.clientTranscriptionId,
                text: input.text, rawText: input.rawText, provider: input.provider, model: input.model,
                audioDurationMs: input.audioDurationMs, status: input.status, deletedAt: nil,
                createdAt: input.createdAt, updatedAt: Self.writeStamp)
            rows.append(row)
            return row
        }
    }

    func batchDeleteTranscriptions(ids: [String]) async throws(HubError) -> [String] {
        deleteBatches.append(ids)
        var deleted: [String] = []
        for index in rows.indices where ids.contains(rows[index].id) && rows[index].deletedAt == nil {
            rows[index].deletedAt = Self.writeStamp
            rows[index].updatedAt = Self.writeStamp
            deleted.append(rows[index].id)
        }
        return deleted
    }
}

private struct Harness {
    let hub = FakeTranscriptionHub()
    let store: TranscriptionStore
    let sync: TranscriptionSync

    init() throws {
        store = try TranscriptionStore.inMemory()
        sync = TranscriptionSync(hub: hub, store: store)
    }
}

@Suite("Transcription wire format")
struct TranscriptionWireTests {
    @Test func createInputEncodesTheContractKeys() throws {
        let input = TranscriptionCreateInput(
            clientTranscriptionId: "local-1", text: "Hello.", rawText: "hello", provider: "local",
            model: "whisper", audioDurationMs: 2350, status: "completed",
            createdAt: HubDate.date(from: "2026-09-29T10:15:30.123Z")!)
        let data = try HubDate.encoder().encode(["transcriptions": [input]])
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        let row = try #require(body["transcriptions"]?.first)
        #expect(row.keys.sorted() == [
            "audio_duration_ms", "client_transcription_id", "created_at", "model", "provider",
            "raw_text", "status", "text"
        ])
        #expect(row["client_transcription_id"] as? String == "local-1")
        #expect(row["raw_text"] as? String == "hello")
        #expect(row["audio_duration_ms"] as? Int == 2350)
        #expect(row["created_at"] as? String == "2026-09-29T10:15:30.123Z")
    }

    @Test func deltaListSendsLimitAndSince() async throws {
        let (session, baseURL, host) = StubHub.register(.init(status: 200, body: #"{"transcriptions":[]}"#))
        let client = HubSyncClient(baseURL: baseURL, key: goodKey, session: session)
        _ = try await client.listTranscriptionChanges(limit: 100, since: HubDate.date(from: "2026-09-29T10:15:30.123Z")!)
        let request = try #require(StubHub.requests(to: host).first)
        let url = try #require(request.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.httpMethod == "GET")
        #expect(url.path == "/api/transcriptions/list")
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            == ["limit": "100", "since": "2026-09-29T10:15:30.123Z"])
    }
}

@Suite("Transcription store and sync")
struct TranscriptionSyncTests {
    @Test func addedRowsArePendingUntilPushed() async throws {
        let h = try Harness()
        let a = try await h.store.add(text: "one", rawText: "one", provider: "local", model: "m", durationMs: 900)
        try await h.store.add(text: "two")
        #expect(try await h.store.pending().count == 2)

        try await h.sync.push()

        #expect(try await h.store.pending().isEmpty)
        let batches = await h.hub.createBatches
        #expect(batches.count == 1)
        #expect(batches.first?.first == a.createInput)
        let listed = try await h.store.list()
        #expect(listed.count == 2)
        #expect(listed.allSatisfy { $0.syncStatus == .synced && $0.cloudId == "h-\($0.clientId)" })
    }

    @Test func createsGoOutInBatchesOfOneHundred() async throws {
        let h = try Harness()
        for i in 0..<250 { try await h.store.add(text: "t\(i)") }
        try await h.sync.push()
        #expect(await h.hub.createBatches.map(\.count) == [100, 100, 50])
        #expect(try await h.store.pending().isEmpty)
    }

    @Test func neverSyncedDeleteStaysLocal() async throws {
        let h = try Harness()
        let row = try await h.store.add(text: "draft")
        try await h.store.delete(clientId: row.clientId)
        try await h.sync.push()
        #expect(try await h.store.list().isEmpty)
        #expect(await h.hub.createBatches.isEmpty)
        #expect(await h.hub.deleteBatches.isEmpty)
    }

    @Test func syncEngineRunsTheTranscriptionStep() async throws {
        let h = try Harness()
        let notes = try NotesStore.inMemory()
        let engine = SyncEngine(
            hub: FakeSyncHub(), store: notes, cursors: InMemoryCursorStore(), transcriptions: h.sync)
        try await h.store.add(text: "via engine")
        try await engine.sync()
        #expect(try await h.store.pending().isEmpty)
        #expect(await h.hub.createBatches.count == 1)
    }
}
