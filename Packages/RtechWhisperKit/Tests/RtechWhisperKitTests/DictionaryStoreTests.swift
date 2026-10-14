import Foundation
import Testing

@testable import RtechWhisperKit

@MainActor
@Suite struct DictionaryStoreTests {
    @Test func addSplitsLinesAndCommasAndSkipsKnownWords() {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Zephyr"]))
        #expect(store.add("Ansible, zephyr\n  Nginx ,\n\nansible") == 2)
        #expect(store.words == ["Zephyr", "Ansible", "Nginx"])
        #expect(store.add("   ") == 0)
        #expect(store.add("nginx") == 0)
    }

    @Test func wordsPersistAndReloadDeduplicated() {
        let persistence = InMemoryDictionaryPersistence()
        let store = DictionaryStore(persistence: persistence)
        store.add("Grafana")
        store.add("Jenkins")
        #expect(persistence.load().map(\.word) == ["Grafana", "Jenkins"])

        let reloaded = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: [" Grafana", "grafana", "", "Kafka"]))
        #expect(reloaded.words == ["Grafana", "Kafka"])
    }

    @Test func editRenamesInPlace() throws {
        let persistence = InMemoryDictionaryPersistence(words: ["Grafana", "Kafka"])
        let store = DictionaryStore(persistence: persistence)
        try store.edit("Grafana", to: " Grafana VE ")
        #expect(store.words == ["Grafana VE", "Kafka"])
        #expect(persistence.load().map(\.word) == ["Grafana VE", "Kafka"])
    }

    @Test func editRefusesBlankAndDuplicate() {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Grafana", "Kafka"]))
        #expect(throws: DictionaryError.emptyWord) { try store.edit("Grafana", to: "  ") }
        #expect(throws: DictionaryError.duplicate("kafka")) { try store.edit("Grafana", to: "kafka") }
        #expect(store.words == ["Grafana", "Kafka"])
    }

    @Test func editToSameCaseIsAllowedAndUnknownWordIsANoOp() throws {
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["grafana"]))
        try store.edit("grafana", to: "Grafana")
        #expect(store.words == ["Grafana"])
        try store.edit("nothing", to: "x")
        #expect(store.words == ["Grafana"])
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
        let store = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Grafana", "Kafka", "Terraform"]))
        #expect(store.promptHint() == "Grafana, Kafka, Terraform")
        // "Grafana, Kafka" is 14 characters; ", Terraform" would not fit in 20.
        #expect(store.promptHint(maxLength: 20) == "Grafana, Kafka")
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
            cloudId: "h1", word: "Nginx", syncStatus: .synced, cloudUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000.123))
        persistence.save([entry])
        #expect(persistence.load() == [entry])
    }
}
