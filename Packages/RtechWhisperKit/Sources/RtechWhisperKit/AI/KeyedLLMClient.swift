import Foundation

/// An `LLMClient` that reads the device key on every call, like
/// `KeyedHubSync`, so a key pasted or forgotten later takes effect without a
/// restart. With no key stored every call fails with `HubError.unauthorized`:
/// the cleanup and title services treat that as "fall back", and the chat
/// shows it as its error state.
public struct KeyedLLMClient: LLMCompleting, LLMChatStreaming {
    private let keys: any DeviceKeyStore
    private let configuration: HubConfiguration
    private let session: URLSession

    public init(keys: any DeviceKeyStore, configuration: HubConfiguration = HubConfiguration(), session: URLSession = LLMClient.defaultSession) {
        self.keys = keys
        self.configuration = configuration
        self.session = session
    }

    public func complete(_ request: LLMChatRequest) async throws(HubError) -> LLMChatCompletion {
        guard let key = try? keys.load() else { throw .unauthorized }
        return try await LLMClient(configuration: configuration, key: key, session: session).complete(request)
    }

    /// The chat's streamed completion with tool-call pieces, over the same
    /// relay with the same per-call key.
    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        guard let key = try? keys.load() else {
            return AsyncThrowingStream { $0.finish(throwing: HubError.unauthorized) }
        }
        return LLMClient(configuration: configuration, key: key, session: session).streamChat(request)
    }
}
