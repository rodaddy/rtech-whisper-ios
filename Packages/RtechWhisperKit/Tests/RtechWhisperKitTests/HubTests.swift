import Foundation
import Testing

@testable import RtechWhisperKit

/// Answers requests for one fake hub host with a canned response and records
/// what was asked. Each test gets its own host, so tests can run in parallel.
final class StubHub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private nonisolated(unsafe) static var replies: [String: Reply] = [:]
    private nonisolated(unsafe) static var seen: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    /// A hub at a fresh host that always answers `reply`.
    static func make(_ reply: Reply) -> (client: HubClient, host: String) {
        let (session, baseURL, host) = register(reply)
        return (HubClient(configuration: HubConfiguration(baseURL: baseURL), session: session), host)
    }

    /// Registers `reply` for a fresh host and returns a session that reaches it.
    static func register(_ reply: Reply) -> (session: URLSession, baseURL: URL, host: String) {
        let host = "hub-\(UUID().uuidString.lowercased()).test"
        lock.withLock { replies[host] = reply }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHub.self]
        return (URLSession(configuration: config), URL(string: "https://\(host)")!, host)
    }

    static func requests(to host: String) -> [URLRequest] {
        lock.withLock { seen[host] ?? [] }
    }

    /// The request bodies sent to `host`, in order. `URLSession` hands a
    /// protocol the body as a stream, so it is read out when the load starts.
    static func bodies(to host: String) -> [Data] {
        lock.withLock { sentBodies[host] ?? [] }
    }

    private nonisolated(unsafe) static var sentBodies: [String: [Data]] = [:]

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = Self.readBody(request)
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen[host, default: []].append(request)
            Self.sentBodies[host, default: []].append(body)
            return Self.replies[host]
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A well-formed key: `rtw_` plus 43 characters.
let goodKey = "rtw_" + String(repeating: "a", count: 43)
let whoamiBody = #"{"device":{"id":"dev-1","name":"Rico's iPhone"}}"#
let unauthorizedBody = #"{"error":{"message":"unknown device key"},"code":"unauthorized"}"#

@Suite struct DeviceKeyFormatTests {
    @Test func acceptsPrefixAndLength() {
        #expect(goodKey.count == 47)
        #expect(DeviceKey.isWellFormed(goodKey))
    }

    @Test(arguments: [
        "",
        "rtw_short",
        "xyz_" + String(repeating: "a", count: 43),
        goodKey + "a",
        String(goodKey.dropLast())
    ])
    func rejectsWrongShape(_ key: String) {
        #expect(!DeviceKey.isWellFormed(key))
    }

    @Test func normalizationTrimsClipboardWhitespace() {
        #expect(DeviceKey.normalized("  \(goodKey)\n") == goodKey)
    }
}

@Suite struct HubClientTests {
    @Test func configuredHubURLWinsAndAnythingElseIsUnconfigured() {
        #expect(HubConfiguration.resolve(" https://hub.example.org ").absoluteString == "https://hub.example.org")
        for bad in [nil, "", "$(RTW_HUB_BASE_URL)", "ftp://hub.example.org", "hub.example.org"] {
            #expect(HubConfiguration.resolve(bad) == HubConfiguration.unconfiguredBaseURL)
        }
    }

    @Test func whoamiDecodesTheDeviceAndSendsTheBearerKey() async throws {
        let (client, host) = StubHub.make(.init(status: 200, body: whoamiBody))
        let device = try await client.whoami(key: goodKey)
        #expect(device == HubDevice(id: "dev-1", name: "Rico's iPhone"))
        let request = try #require(StubHub.requests(to: host).first)
        #expect(request.url?.path == "/api/whoami")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(goodKey)")
    }

    @Test func status401MapsToUnauthorized() async {
        let (client, _) = StubHub.make(.init(status: 401, body: unauthorizedBody))
        await #expect(throws: HubError.unauthorized) {
            try await client.whoami(key: goodKey)
        }
    }

    @Test func otherErrorsCarryStatusCodeAndMessage() async {
        let body = #"{"error":{"message":"boom"},"code":"internal","data":null}"#
        let (client, _) = StubHub.make(.init(status: 500, body: body))
        await #expect(throws: HubError.server(status: 500, code: "internal", message: "boom")) {
            try await client.whoami(key: goodKey)
        }
    }

    @Test func nonJSONErrorBodyStillMapsToServer() async {
        let (client, _) = StubHub.make(.init(status: 500, body: "Internal Server Error"))
        await #expect(throws: HubError.server(status: 500, code: nil, message: nil)) {
            try await client.whoami(key: goodKey)
        }
    }

    @Test func gatewayErrorsMapToUpstreamUnavailable() async {
        let (client, _) = StubHub.make(.init(status: 503, body: "Service Unavailable"))
        await #expect(throws: HubError.upstreamUnavailable(status: 503)) {
            try await client.whoami(key: goodKey)
        }
    }

    @Test func unexpectedSuccessBodyIsADecodingError() async {
        let (client, _) = StubHub.make(.init(status: 200, body: #"{"nope":true}"#))
        do {
            _ = try await client.whoami(key: goodKey)
            Issue.record("expected a decoding error")
        } catch {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func malformedKeyIsRejectedBeforeAnyRequest() async {
        let (client, host) = StubHub.make(.init(status: 200, body: whoamiBody))
        await #expect(throws: HubError.malformedKey) {
            try await client.whoami(key: "rtw_tooshort")
        }
        #expect(StubHub.requests(to: host).isEmpty)
    }

    @Test func transportFailureIsANetworkError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHub.self]
        // No reply registered for this host, so the stub fails the load.
        let client = HubClient(
            configuration: HubConfiguration(baseURL: URL(string: "https://unregistered.test")!),
            session: URLSession(configuration: config)
        )
        do {
            _ = try await client.whoami(key: goodKey)
            Issue.record("expected a network error")
        } catch {
            guard case .network = error else {
                Issue.record("expected .network, got \(error)")
                return
            }
        }
    }
}

@Suite struct DeviceKeyStoreTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryDeviceKeyStore()
        #expect(try store.load() == nil)
        try store.save(goodKey)
        #expect(try store.load() == goodKey)
        try store.save("rtw_other")
        #expect(try store.load() == "rtw_other")
        try store.delete()
        #expect(try store.load() == nil)
    }
}

/// A store whose save always fails, standing in for a Keychain error.
private struct FailingStore: DeviceKeyStore {
    func load() throws -> String? { nil }
    func save(_ key: String) throws { throw DeviceKeyStoreError.keychain(-25_300) }
    func delete() throws {}
}

@MainActor
@Suite struct HubConnectionTests {
    @Test func connectStoresTheKeyOnlyWhenTheHubAcceptsIt() async throws {
        let store = InMemoryDeviceKeyStore()
        let connection = HubConnection(client: StubHub.make(.init(status: 200, body: whoamiBody)).client, store: store)
        await connection.connect(pastedKey: " \(goodKey)\n")
        #expect(connection.state == .connected(HubDevice(id: "dev-1", name: "Rico's iPhone")))
        #expect(try store.load() == goodKey)
    }

    @Test func rejectedKeyIsNotStored() async throws {
        let store = InMemoryDeviceKeyStore()
        let connection = HubConnection(client: StubHub.make(.init(status: 401, body: unauthorizedBody)).client, store: store)
        await connection.connect(pastedKey: goodKey)
        #expect(connection.state == .needsKey)
        #expect(connection.lastError == .hub(.unauthorized))
        #expect(try store.load() == nil)
    }

    @Test func keychainFailureIsReportedAndNotConnected() async {
        let connection = HubConnection(client: StubHub.make(.init(status: 200, body: whoamiBody)).client, store: FailingStore())
        await connection.connect(pastedKey: goodKey)
        #expect(connection.state == .needsKey)
        #expect(connection.lastError == .keyNotSaved)
    }

    @Test func restoreWithNoKeyAsksForOne() async {
        let connection = HubConnection(client: StubHub.make(.init(status: 200, body: whoamiBody)).client, store: InMemoryDeviceKeyStore())
        await connection.restore()
        #expect(connection.state == .needsKey)
    }

    @Test func restoreKeepsTheKeyWhenTheHubCheckFails() async throws {
        let store = InMemoryDeviceKeyStore(key: goodKey)
        let connection = HubConnection(client: StubHub.make(.init(status: 503, body: "")).client, store: store)
        await connection.restore()
        #expect(connection.state == .stored(.upstreamUnavailable(status: 503)))
        #expect(try store.load() == goodKey)
    }

    @Test func forgetDeletesTheKey() async throws {
        let store = InMemoryDeviceKeyStore(key: goodKey)
        let connection = HubConnection(client: StubHub.make(.init(status: 200, body: whoamiBody)).client, store: store)
        await connection.restore()
        #expect(connection.state == .connected(HubDevice(id: "dev-1", name: "Rico's iPhone")))
        connection.forget()
        #expect(connection.state == .needsKey)
        #expect(try store.load() == nil)
    }
}
