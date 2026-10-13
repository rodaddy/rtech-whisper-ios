import Foundation
import Testing

@testable import RtechWhisperKit

/// Records every prompt a send carried.
private final class PromptSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String?] = []
    var prompts: [String?] { lock.withLock { _prompts } }

    func send(_ wav: Data, prompt: String?) -> Transcript {
        lock.withLock { _prompts.append(prompt) }
        return Transcript(text: "ok", noSpeech: false)
    }
}

@Suite struct PromptedTranscribeTests {
    @MainActor @Test func sendsTheDictionaryHintReadFreshOnEverySend() async throws {
        let dictionary = DictionaryStore(persistence: InMemoryDictionaryPersistence(words: ["Proxmox"]))
        let spy = PromptSpy()
        let transcribe = prompted({ wav, prompt throws(HubError) in spy.send(wav, prompt: prompt) },
                                  hint: { dictionary.promptHint() })

        let first = try await transcribe(Data([1]))
        #expect(first.text == "ok")
        dictionary.add("Caddy")
        _ = try await transcribe(Data([2]))

        #expect(spy.prompts == ["Proxmox", "Proxmox, Caddy"])
    }

    @MainActor @Test func anEmptyDictionarySendsNoPrompt() async throws {
        let dictionary = DictionaryStore(persistence: InMemoryDictionaryPersistence())
        let spy = PromptSpy()
        let transcribe = prompted({ wav, prompt throws(HubError) in spy.send(wav, prompt: prompt) },
                                  hint: { dictionary.promptHint() })

        _ = try await transcribe(Data([1]))

        #expect(spy.prompts == [nil])
    }
}
