import Foundation

/// The `BackgroundTransport` the app uses (#96): a background `URLSession`
/// that sends each kept chunk's relay body from a file, so the system keeps
/// sending while the app is suspended or terminated, and hands each answer
/// to `BackgroundAnswers` by the task's `UploadChunkTag`.
public final class BackgroundUploader: NSObject, BackgroundTransport, URLSessionDataDelegate, @unchecked Sendable {
    /// The session's fixed identifier; a relaunch reconnects to it by name.
    public static let identifier = "com.rtech-consulting.whisper.upload"

    /// The relay client for one send: the key and language are read per send.
    public typealias MakeClient = @Sendable () async throws(HubError) -> (client: TranscriptionClient, language: String?)

    public let answers = BackgroundAnswers()
    private let directory: URL
    private let makeClient: MakeClient
    private let lock = NSLock()
    private var received: [Int: Data] = [:]
    private var eventsFinished: (@Sendable () -> Void)?
    /// The session's events finished before the app delegate's handler arrived.
    private var eventsDelivered = false
    private var session: URLSession!

    /// `directory` holds the body files; `configuration` is the background
    /// session's unless a test passes another.
    public init(
        directory: URL,
        configuration: URLSessionConfiguration = .background(withIdentifier: BackgroundUploader.identifier),
        makeClient: @escaping MakeClient
    ) {
        self.directory = directory
        self.makeClient = makeClient
        super.init()
        configuration.timeoutIntervalForRequest = TranscriptionClient.requestTimeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The file `tag`'s body is sent from.
    func bodyFile(_ tag: UploadChunkTag) -> URL {
        directory.appending(path: "\(tag.upload.uuidString)-\(tag.chunk).body")
    }

    /// Writes `body` to `tag`'s file, replacing an earlier attempt's.
    func writeBody(_ body: Data, for tag: UploadChunkTag) throws(HubError) -> URL {
        let file = bodyFile(tag)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: file, options: .atomic)
        } catch {
            throw .network("The upload could not be staged: \(error.localizedDescription)")
        }
        return file
    }

    /// The file `tag`'s transcript is kept in until the upload takes it, so
    /// an answer that arrives while the app is not running outlives the process.
    func answerFile(_ tag: UploadChunkTag) -> URL {
        directory.appending(path: "\(tag.upload.uuidString)-\(tag.chunk).answer")
    }

    private struct StoredAnswer: Codable {
        let text: String
        let noSpeech: Bool
    }

    /// Writes `transcript` to `tag`'s answer file; a failed write only means
    /// the chunk is sent again.
    private func store(_ transcript: Transcript, for tag: UploadChunkTag) {
        guard let data = try? JSONEncoder().encode(StoredAnswer(text: transcript.text, noSpeech: transcript.noSpeech)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: answerFile(tag), options: .atomic)
    }

    /// `tag`'s kept transcript, deleted; `nil` when none was kept.
    private func takeStored(_ tag: UploadChunkTag) -> Transcript? {
        let file = answerFile(tag)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        guard let stored = try? JSONDecoder().decode(StoredAnswer.self, from: data) else { return nil }
        return Transcript(text: stored.text, noSpeech: stored.noSpeech)
    }

    public func transcribe(
        _ wav: Data, hint: String?, tag: UploadChunkTag, started: @escaping @Sendable () -> Void
    ) async throws(HubError) -> Transcript {
        let (client, language) = try await makeClient()
        let (request, body) = try client.uploadRequest(wav: wav, language: language, prompt: hint)
        let file = try writeBody(body, for: tag)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = tag.taskDescription
        task.resume()
        started()
        let answer = await answers.wait(for: tag)
        // Handed over in memory, so its kept copy is not needed.
        _ = takeStored(tag)
        return try answer.get()
    }

    public func takeFinished(_ tag: UploadChunkTag) async -> Result<Transcript, HubError>? {
        let held = await answers.take(tag)
        let stored = takeStored(tag)
        return held ?? stored.map { .success($0) }
    }

    /// The app delegate's completion handler, called once the session's
    /// events for a background relaunch are delivered. Called at once when
    /// they were delivered before it arrived; a handler it replaces is
    /// called rather than dropped, since the system needs every one.
    public func setEventsFinished(_ handler: @escaping @Sendable () -> Void) {
        let (replaced, now) = lock.withLock { () -> ((@Sendable () -> Void)?, Bool) in
            let replaced = eventsFinished
            if eventsDelivered {
                eventsDelivered = false
                eventsFinished = nil
                return (replaced, true)
            }
            eventsFinished = handler
            return (replaced, false)
        }
        DispatchQueue.main.async {
            replaced?()
            if now { handler() }
        }
    }

    /// Maps a finished task to its tag and answer, deletes its body file,
    /// and keeps a transcript on disk; `nil` for a task with no tag. Runs on
    /// the session's serial delegate queue, so every answer of a background
    /// relaunch is on disk before the session's events are reported finished.
    @discardableResult
    func record(taskDescription: String?, data: Data, response: URLResponse?, error: (any Error)?)
        -> (UploadChunkTag, Result<Transcript, HubError>)?
    {
        guard let tag = UploadChunkTag(taskDescription: taskDescription) else { return nil }
        try? FileManager.default.removeItem(at: bodyFile(tag))
        let answer: Result<Transcript, HubError>
        if let error {
            answer = .failure(.network(error.localizedDescription))
        } else if let response {
            answer = Result { () throws(HubError) in try TranscriptionClient.transcript(data: data, response: response) }
        } else {
            answer = .failure(.network("The hub answered without an HTTP response."))
        }
        // Only a transcript is kept: a failure is sent again by the next process.
        if case .success(let transcript) = answer { store(transcript, for: tag) }
        return (tag, answer)
    }

    /// `record`, then the answer to whoever waits for it.
    func finish(taskDescription: String?, data: Data, response: URLResponse?, error: (any Error)?) async {
        guard let (tag, answer) = record(taskDescription: taskDescription, data: data, response: response, error: error) else { return }
        await answers.deliver(tag, answer)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let data = lock.withLock { received.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let (tag, answer) = record(taskDescription: task.taskDescription, data: data, response: task.response, error: error)
        else { return }
        Task { await answers.deliver(tag, answer) }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { eventsFinished = nil }
            if eventsFinished == nil { eventsDelivered = true }
            return eventsFinished
        }
        DispatchQueue.main.async { handler?() }
    }
}
