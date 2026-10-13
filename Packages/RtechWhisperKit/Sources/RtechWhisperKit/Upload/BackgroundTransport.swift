import Foundation

/// Which request of which kept upload a background task carries. It
/// rides in the task's `taskDescription`, which a background `URLSession`
/// hands back after a relaunch, so a response maps back to its chunk.
public struct UploadChunkTag: Hashable, Sendable {
    /// The upload's checkpoint id.
    public let upload: UUID
    /// The chunk's 0-based index: the chunks done before it was sent.
    public let chunk: Int

    public init(upload: UUID, chunk: Int) {
        self.upload = upload
        self.chunk = chunk
    }

    /// `upload/<uuid>/<chunk>`, the task's `taskDescription`.
    public var taskDescription: String { "upload/\(upload.uuidString)/\(chunk)" }

    /// The tag a `taskDescription` carries; `nil` for any other task.
    public init?(taskDescription: String?) {
        let parts = taskDescription?.split(separator: "/", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3, parts[0] == "upload", let upload = UUID(uuidString: String(parts[1])),
            let chunk = Int(parts[2]), chunk >= 0
        else { return nil }
        self.init(upload: upload, chunk: chunk)
    }
}

/// Sends an upload's chunks on a transport that keeps going while the app is
/// suspended or terminated: a background `URLSession` in the app. A kept
/// upload sends through it; the rest send through `TranscribeWithPrompt`.
public protocol BackgroundTransport: Sendable {
    /// Sends `wav` as `tag`'s request and returns its transcript, however
    /// long the system takes. Throws as `TranscribeWithPrompt` does.
    /// `started` is called once the request is handed to the system, so a
    /// suspension from then on no longer stops it.
    func transcribe(
        _ wav: Data, hint: String?, tag: UploadChunkTag, started: @escaping @Sendable () -> Void
    ) async throws(HubError) -> Transcript
    /// The answer to `tag`'s request when it finished while nobody awaited
    /// it, as after a relaunch, and forgets it; `nil` when there is none.
    func takeFinished(_ tag: UploadChunkTag) async -> Result<Transcript, HubError>?
}

/// Where a background session's delegate drops each answer, and where the
/// transport waits for it. An answer nobody awaits is held for `take`.
public actor BackgroundAnswers {
    private var finished: [UploadChunkTag: Result<Transcript, HubError>] = [:]
    private var waiting: [UploadChunkTag: CheckedContinuation<Result<Transcript, HubError>, Never>] = [:]

    public init() {}

    /// The delegate's call when `tag`'s task completes.
    public func deliver(_ tag: UploadChunkTag, _ answer: Result<Transcript, HubError>) {
        if let waiter = waiting.removeValue(forKey: tag) {
            waiter.resume(returning: answer)
        } else {
            finished[tag] = answer
        }
    }

    /// Waits for `tag`'s answer, or returns the one already held.
    public func wait(for tag: UploadChunkTag) async -> Result<Transcript, HubError> {
        if let answer = finished.removeValue(forKey: tag) { return answer }
        return await withCheckedContinuation { waiting[tag] = $0 }
    }

    /// `tag`'s held answer, forgotten; `nil` when none arrived unawaited.
    public func take(_ tag: UploadChunkTag) -> Result<Transcript, HubError>? {
        finished.removeValue(forKey: tag)
    }
}
