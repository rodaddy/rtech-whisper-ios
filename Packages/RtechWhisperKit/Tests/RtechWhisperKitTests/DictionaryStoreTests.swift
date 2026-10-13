import Foundation
import Testing

@testable import RtechWhisperKit

@MainActor
@Suite struct DictionaryStoreTests {
    @Test func addSplitsLinesAndCommasAndSkipsKnownWords() {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Skippy"]))
        #expect(store.add("Forgejo, skippy\n  Bilby ,\n\nforgejo") == 2)
        #expect(store.words == ["Skippy", "Forgejo", "Bilby"])
        #expect(store.add("   ") == 0)
        #expect(store.add("bilby") == 0)
    }

    @Test func wordsPersistAndReloadDeduplicated() {
        let persistence = InMemoryDictionaryPersistence()
        let store = DictionaryStore(persistence: persistence)
        store.add("Proxmox")
        store.add("TrueNAS")
        #expect(persistence.load().map(\.word) == ["Proxmox", "TrueNAS"])

        let reloaded = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: [" Proxmox", "proxmox", "", "Caddy"]))
        #expect(reloaded.words == ["Proxmox", "Caddy"])
    }

    @Test func editRenamesInPlace() throws {
        let persistence = InMemoryDictionaryPersistence(words: ["Proxmox", "Caddy"])
        let store = DictionaryStore(persistence: persistence)
        try store.edit("Proxmox", to: " Proxmox VE ")
        #expect(store.words == ["Proxmox VE", "Caddy"])
        #expect(persistence.load().map(\.word) == ["Proxmox VE", "Caddy"])
    }

    @Test func editRefusesBlankAndDuplicate() {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Proxmox", "Caddy"]))
        #expect(throws: DictionaryError.emptyWord) { try store.edit("Proxmox", to: "  ") }
        #expect(throws: DictionaryError.duplicate("caddy")) { try store.edit("Proxmox", to: "caddy") }
        #expect(store.words == ["Proxmox", "Caddy"])
    }

    @Test func editToSameCaseIsAllowedAndUnknownWordIsANoOp() throws {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["proxmox"]))
        try store.edit("proxmox", to: "Proxmox")
        #expect(store.words == ["Proxmox"])
        try store.edit("nothing", to: "x")
        #expect(store.words == ["Proxmox"])
    }

    @Test func removeByWordAndByOffsets() {
        let persistence = InMemoryDictionaryPersistence(words: ["a", "b", "c", "d"])
        let store = DictionaryStore(persistence: persistence)
        store.remove("b")
        store.remove("zzz")
        store.remove(atOffsets: IndexSet([0, 2]))
        #expect(store.words == ["c"])
        #expect(persistence.load().map(\.word) == ["c"])
    }

    @Test func promptHintJoinsWithCommasAndStopsAtAWholeWord() {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Proxmox", "Caddy", "Authentik"]))
        #expect(store.promptHint() == "Proxmox, Caddy, Authentik")
        // "Proxmox, Caddy" is 14 characters; ", Authentik" would not fit in 20.
        #expect(store.promptHint(maxLength: 20) == "Proxmox, Caddy")
        #expect(store.promptHint(maxLength: 3) == nil)
        #expect(DictionaryStore(persistence: InMemoryDictionaryPersistence()).promptHint() == nil)
    }

    @Test func promptHintHonoursTheHubLimit() throws {
        let long = (0..<200).map { "word\($0)" }
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: long))
        let hint = try #require(store.promptHint())
        #expect(hint.count <= DictionaryStore.promptLimit)
        #expect(hint.hasPrefix("word0, word1"))
        #expect(!hint.hasSuffix(","))
    }

    @Test func userDefaultsPersistenceRoundTrips() throws {
        let suite = "RtechWhisperKitTests.dictionary.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsDictionaryPersistence(defaults: defaults)
        #expect(persistence.load() == [])
        let entry = DictionaryEntry(
            cloudId: "h1", word: "Bilby", syncStatus: .synced, cloudUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000.123))
        persistence.save([entry])
        #expect(persistence.load() == [entry])
    }
}
