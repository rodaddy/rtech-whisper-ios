import Foundation
import Testing

@testable import RtechWhisperKit

private let when = Date(timeIntervalSince1970: 1_790_000_000)

private func notes(_ ids: [String]) async throws -> [NoteRecord] {
    let store = try NotesStore.inMemory()
    var records: [NoteRecord] = []
    for id in ids {
        var record = try await store.createNote(content: id)
        record.clientId = id
        records.append(record)
    }
    return records
}

private func freshDefaults() -> UserDefaults {
    let name = "NoteOrderTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("NoteOrder")
struct NoteOrderTests {
    @Test("new notes come first, then the saved order; stale ids are ignored")
    func ordered() async throws {
        let result = NoteOrder.ordered(try await notes(["new", "a", "b", "c"]), savedOrder: ["c", "gone", "a", "b"])
        #expect(result.map(\.clientId) == ["new", "c", "a", "b"])
    }

    @Test("no saved order keeps the incoming order")
    func unsaved() async throws {
        #expect(NoteOrder.ordered(try await notes(["a", "b"]), savedOrder: []).map(\.clientId) == ["a", "b"])
    }

    @Test("a drag produces the new order")
    func moved() {
        #expect(NoteOrder.moved(["a", "b", "c", "d"], from: IndexSet(integer: 0), to: 3) == ["b", "c", "a", "d"])
        #expect(NoteOrder.moved(["a", "b", "c", "d"], from: IndexSet(integer: 3), to: 0) == ["d", "a", "b", "c"])
        #expect(NoteOrder.moved(["a", "b", "c"], from: IndexSet([0, 1]), to: 3) == ["c", "a", "b"])
    }

    @Test("the store keeps each folder's order, and folders do not touch each other")
    func storeRoundTrip() {
        let defaults = freshDefaults()
        let store = NoteOrderStore(defaults: defaults)
        store.setOrder(["b", "a"], forFolder: "f1")
        store.setOrder(["z"], forFolder: nil)
        let again = NoteOrderStore(defaults: defaults)
        #expect(again.order(forFolder: "f1") == ["b", "a"])
        #expect(again.order(forFolder: nil) == ["z"])
        #expect(again.order(forFolder: "f2") == [])
    }
}

@Suite("NotesViewModel order")
@MainActor
struct NotesViewModelOrderTests {
    @Test("a move survives a reload, and a new note lands at the top of its folder")
    func moveAndNew() async throws {
        let defaults = freshDefaults()
        let store = try NotesStore.inMemory()
        let engine = SyncEngine(hub: FakeSyncHub(), store: store, cursors: InMemoryCursorStore(), now: { when })
        let model = NotesViewModel(
            store: store, engine: engine, canSync: { false }, syncDelay: nil,
            order: NoteOrderStore(defaults: defaults))
        let folder = try await model.createFolder(name: "Work")
        let a = try await model.create(content: "a", folderClientId: folder.clientId)
        let b = try await model.create(content: "b", folderClientId: folder.clientId)
        let before = model.orderedNotes(inFolder: folder.clientId).map(\.clientId)
        model.move(inFolder: folder.clientId, from: IndexSet(integer: 0), to: 2)
        await model.reload()
        let after = model.orderedNotes(inFolder: folder.clientId).map(\.clientId)
        #expect(after == Array(before.reversed()))
        #expect(Set(after) == [a.clientId, b.clientId])
        let c = try await model.create(content: "c", folderClientId: folder.clientId)
        #expect(model.orderedNotes(inFolder: folder.clientId).map(\.clientId) == [c.clientId] + after)
    }
}
