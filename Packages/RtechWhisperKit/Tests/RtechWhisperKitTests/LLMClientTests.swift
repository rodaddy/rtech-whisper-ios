import Foundation
import Testing

@testable import RtechWhisperKit

/// Answers LLM relay requests for one fake host. The body is delivered in the
/// given chunks, so a test can split an SSE stream mid-line.
final class StubLLM: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var bytes: [Data]
        var headers: [String: String]

        init(status: Int = 200, chunks: [String], headers: [String: String] = ["Content-Type": "application/json"]) {
            self.init(status: status, bytes: chunks.map { Data($0.utf8) }, headers: headers)
        }

        init(status: Int = 200, bytes: [Data], headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status
            self.bytes = bytes
            self.headers = headers
        }
    }

    private nonisolated(unsafe) static var replies: [String: Reply] = [:]
    private nonisolated(unsafe) static var seen: [String: [(URLRequest, Data)]] = [:]
    private static let lock = NSLock()

    static func make(_ reply: Reply, key: String = goodKey) -> (client: LLMClient, host: String) {
        let host = "llm-\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubLLM.self]
        let client = LLMClient(
            configuration: HubConfiguration(baseURL: URL(string: "https://\(host)")!),
            key: key,
            session: URLSession(configuration: config)
        )
        return (client, host)
    }

    static func requests(to host: String) -> [(URLRequest, Data)] {
        lock.withLock { seen[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen[host, default: []].append((request, body))
            return Self.replies[host]
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.bytes {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private let sse = ["Content-Type": "text/event-stream"]
private let completionBody = #"{"id":"c-1","object":"chat.completion","model":"qwen3-4b-instruct","choices":[{"index":0,"message":{"role":"assistant","content":"  Hello there.  "},"finish_reason":"stop"}]}"#
private let chat = LLMChatRequest(
    model: "qwen3-4b-instruct",
    messages: [.system("Be brief."), .user("hi")],
    temperature: 0,
    maxTokens: 64
)

private func delta(_ text: String) -> String {
    let json = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text]]]])
    return "data: \(String(decoding: json, as: UTF8.self))\n\n"
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await piece in stream { out.append(piece) }
    return out
}

private func streamError(_ reply: StubLLM.Reply) async -> HubError? {
    let (client, _) = StubLLM.make(reply)
    do {
        _ = try await collect(client.stream(chat))
        return nil
    } catch {
        return error as? HubError
    }
}

@Suite("LLM client requests")
struct LLMClientRequestTests {
    @Test func completionPostsTheChatBodyWithTheDeviceKey() async throws {
        let (client, host) = StubLLM.make(.init(chunks: [completionBody]))
        let completion = try await client.complete(chat)
        #expect(completion == LLMChatCompletion(content: "  Hello there.  ", finishReason: "stop"))

        let (request, data) = try #require(StubLLM.requests(to: host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://\(host)/api/llm/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen3-4b-instruct")
        #expect(body["temperature"] as? Double == 0)
        #expect(body["max_tokens"] as? Int == 64)
        #expect(body["stream"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Be brief."], ["role": "user", "content": "hi"]])
    }

    @Test func unsetOptionsAreLeftOutOfTheBody() async throws {
        let (client, host) = StubLLM.make(.init(chunks: [completionBody]))
        _ = try await client.complete(LLMChatRequest(model: "m", messages: [.user("x")]))
        let (_, data) = try #require(StubLLM.requests(to: host).first)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body.keys.sorted() == ["messages", "model"])
    }

    @Test func streamRequestAsksForServerSentEvents() async throws {
        let (client, host) = StubLLM.make(.init(chunks: [delta("a"), "data: [DONE]\n\n"], headers: sse))
        _ = try await collect(client.stream(chat))
        let (request, data) = try #require(StubLLM.requests(to: host).first)
        #expect(request.url?.path == "/api/llm/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["model"] as? String == "qwen3-4b-instruct")
    }

    @Test func modelsListsTheRelayModels() async throws {
        let body = #"{"object":"list","data":[{"id":"qwen3-4b-instruct","object":"model","owned_by":"llama-swap"}]}"#
        let (client, host) = StubLLM.make(.init(chunks: [body]))
        let models = try await client.models()
        #expect(models == [LLMModel(id: "qwen3-4b-instruct", ownedBy: "llama-swap")])
        let (request, _) = try #require(StubLLM.requests(to: host).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/llm/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
    }

    @Test func malformedKeyIsRejectedBeforeAnyRequest() async {
        let (client, host) = StubLLM.make(.init(chunks: [completionBody]), key: "rtw_short")
        await #expect(throws: HubError.malformedKey) { try await client.complete(chat) }
        #expect(StubLLM.requests(to: host).isEmpty)
    }

    @Test func completionWithoutChoicesIsADecodingError() async {
        let (client, _) = StubLLM.make(.init(chunks: [#"{"choices":[]}"#]))
        do {
            _ = try await client.complete(chat)
            Issue.record("expected a decoding error")
        } catch {
            guard case .decoding = error else { Issue.record("expected .decoding, got \(error)"); return }
        }
    }
}

@Suite("LLM client SSE parsing")
struct LLMClientStreamTests {
    @Test func deltasArriveInOrderAcrossChunkBoundaries() async throws {
        // One network chunk splits a line mid-JSON, another carries two
        // events, and a multi-byte character straddles a boundary.
        let whole = delta("Hel") + delta("lo, ") + delta("wörld") + "data: [DONE]\n\n"
        let bytes = Data(whole.utf8)
        let umlaut = try #require(bytes.firstRange(of: Data("ö".utf8)))
        let cuts = [7, 40, umlaut.lowerBound + 1, bytes.count - 3]
        var chunks: [Data] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            chunks.append(bytes.subdata(in: start..<cut))
            start = cut
        }
        let (client, _) = StubLLM.make(.init(bytes: chunks, headers: sse))
        #expect(try await collect(client.stream(chat)) == ["Hel", "lo, ", "wörld"])
    }

    @Test func splitLinesAreJoinedBeforeParsing() async throws {
        let first = delta("one")
        let mid = first.index(first.startIndex, offsetBy: 12)
        let chunks = [String(first[..<mid]), String(first[mid...]) + delta("two"), "data: [DO", "NE]\n\n"]
        let (client, _) = StubLLM.make(.init(chunks: chunks, headers: sse))
        #expect(try await collect(client.stream(chat)) == ["one", "two"])
    }

    @Test func doneEndsTheStreamAndLaterDataIsIgnored() async throws {
        let body = delta("kept") + "data: [DONE]\n\n" + delta("dropped")
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        #expect(try await collect(client.stream(chat)) == ["kept"])
    }

    @Test func malformedAndNonDataLinesAreSkipped() async throws {
        let body = ": keep-alive\n\n"
            + "event: message\nid: 7\n"
            + delta("a")
            + "data: {not json\n\n"
            + "garbage line\n\n"
            + #"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"# + "\n\n"
            + #"data: {"choices":[{"index":0,"delta":{"content":""}}]}"# + "\r\n\r\n"
            + delta("b")
            + "data: [DONE]\n\n"
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        #expect(try await collect(client.stream(chat)) == ["a", "b"])
    }

    @Test func crlfLineEndingsParse() async throws {
        let body = delta("x").replacingOccurrences(of: "\n", with: "\r\n") + "data: [DONE]\r\n\r\n"
        let (client, _) = StubLLM.make(.init(chunks: [body], headers: sse))
        #expect(try await collect(client.stream(chat)) == ["x"])
    }

    @Test func streamClosedBeforeDoneIsCutShort() async {
        let error = await streamError(.init(chunks: [delta("partial")], headers: sse))
        guard case .network = error else { Issue.record("expected .network, got \(String(describing: error))"); return }
    }

    @Test func idleErrorEventMapsToUpstreamTimeout() async {
        let event = #"data: {"error":{"message":"LLM upstream stream went idle"},"code":"upstream_timeout"}"# + "\n\n"
        let error = await streamError(.init(chunks: [delta("a"), event], headers: sse))
        #expect(error == .upstreamUnavailable(status: 504))
    }

    @Test func nonSuccessStreamMapsTheErrorBody() async {
        let body = #"{"error":{"message":"slow down"},"code":"rate_limited"}"#
        let error = await streamError(.init(status: 429, chunks: [body], headers: ["Retry-After": "3"]))
        #expect(error == .rateLimited(retryAfter: 3))
    }
}

@Suite("LLM client errors")
struct LLMClientErrorTests {
    static let cases: [(Int, String, [String: String], HubError)] = [
        (401, #"{"error":{"message":"unknown device key"},"code":"unauthorized"}"#, [:], .unauthorized),
        (413, #"{"error":{"message":"too big"},"code":"payload_too_large"}"#, [:], .tooLarge),
        (429, #"{"error":{"message":"slow down"},"code":"rate_limited"}"#, ["Retry-After": "12"], .rateLimited(retryAfter: 12)),
        (429, #"{"error":{"message":"busy"},"code":"rate_limited"}"#, [:], .rateLimited(retryAfter: nil)),
        (400, #"{"error":{"message":"context overflow"},"code":"upstream_rejected","data":{"upstream_status":400}}"#, [:],
         .invalidRequest(message: "context overflow")),
        (502, #"{"error":{"message":"bad gateway"},"code":"upstream_error"}"#, [:], .upstreamUnavailable(status: 502)),
        (503, #"{"error":{"message":"down"},"code":"upstream_unavailable"}"#, [:], .upstreamUnavailable(status: 503)),
        (504, #"{"error":{"message":"slow"},"code":"upstream_timeout"}"#, [:], .upstreamUnavailable(status: 504))
    ]

    @Test(arguments: 0..<cases.count)
    func completionMapsStatus(_ index: Int) async {
        let (status, body, headers, expected) = Self.cases[index]
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let (client, _) = StubLLM.make(.init(status: status, chunks: [body], headers: allHeaders))
        await #expect(throws: expected) { try await client.complete(chat) }
    }

    @Test func modelsMapsUnauthorized() async {
        let (client, _) = StubLLM.make(.init(status: 401, chunks: [#"{"error":{"message":"no"},"code":"unauthorized"}"#]))
        await #expect(throws: HubError.unauthorized) { try await client.models() }
    }
}
