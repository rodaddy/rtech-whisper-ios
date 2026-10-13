import Foundation
import Testing

@testable import RtechWhisperKit

/// A `KeyedLLMClient` on a stub relay host, with the key store the test gives it.
private func keyedClient(_ reply: StubLLM.Reply, keys: any DeviceKeyStore) -> (KeyedLLMClient, String) {
    let (_, host) = StubLLM.make(reply)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubLLM.self]
    let client = KeyedLLMClient(
        keys: keys,
        configuration: HubConfiguration(baseURL: URL(string: "https://\(host)")!),
        session: URLSession(configuration: config))
    return (client, host)
}

@Suite("Keyed LLM client")
struct KeyedLLMClientTests {
    @Test func noKeyFailsTheChatStreamAsUnauthorizedWithoutARequest() async throws {
        let (client, host) = keyedClient(.init(chunks: ["data: [DONE]\n\n"]), keys: InMemoryDeviceKeyStore())
        await #expect(throws: HubError.unauthorized) {
            for try await _ in client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")])) {}
        }
        #expect(StubLLM.requests(to: host).isEmpty)
    }

    @Test func noKeyFailsTheCompletionAsUnauthorized() async throws {
        let (client, host) = keyedClient(.init(chunks: ["{}"]), keys: InMemoryDeviceKeyStore())
        await #expect(throws: HubError.unauthorized) {
            _ = try await client.complete(LLMChatRequest(model: "m", messages: [.user("x")]))
        }
        #expect(StubLLM.requests(to: host).isEmpty)
    }

    @Test func theChatStreamSendsTheStoredKeyAndYieldsTheReply() async throws {
        let body = #"data: {"choices":[{"index":0,"delta":{"content":"hi"}}]}"# + "\n\n" + "data: [DONE]\n\n"
        let keys = InMemoryDeviceKeyStore(key: goodKey)
        let (client, host) = keyedClient(.init(chunks: [body], headers: ["Content-Type": "text/event-stream"]), keys: keys)
        var chunks: [LLMStreamChunk] = []
        for try await chunk in client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")])) { chunks.append(chunk) }
        #expect(chunks == [.content("hi")])
        let (request, _) = try #require(StubLLM.requests(to: host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
    }

    @Test func aKeySavedLaterIsReadOnTheNextStream() async throws {
        let keys = InMemoryDeviceKeyStore()
        let (client, host) = keyedClient(
            .init(chunks: ["data: [DONE]\n\n"], headers: ["Content-Type": "text/event-stream"]), keys: keys)
        await #expect(throws: HubError.unauthorized) {
            for try await _ in client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")])) {}
        }
        try keys.save(goodKey)
        for try await _ in client.streamChat(LLMChatRequest(model: "m", messages: [.user("x")])) {}
        #expect(StubLLM.requests(to: host).count == 1)
    }
}
