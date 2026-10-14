import Foundation
import Testing

@testable import RtechWhisperKit

// The app's background session stages each body in a file and maps a
// finished task back to its chunk's answer.
@Suite struct BackgroundUploaderTests {
    let directory = URL.temporaryDirectory.appending(path: "BackgroundUploaderTests-\(UUID().uuidString)")
    let tag = UploadChunkTag(upload: UUID(), chunk: 2)

    func uploader() -> BackgroundUploader {
        BackgroundUploader(directory: directory, configuration: .ephemeral) { () throws(HubError) in
            (TranscriptionClient(key: "rtw_" + String(repeating: "a", count: 43)), nil)
        }
    }

    func response(_ status: Int, _ headers: [String: String] = [:]) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://hub.example")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func theBodyIsWrittenToTheTagsFile() throws {
        let file = try uploader().writeBody(Data("body".utf8), for: tag)
        #expect(file.lastPathComponent == "\(tag.upload.uuidString)-2.body")
        #expect(try Data(contentsOf: file) == Data("body".utf8))
    }

    @Test func aFinishedTaskDeliversItsTranscriptAndDeletesItsBody() async throws {
        let up = uploader()
        let file = try up.writeBody(Data("body".utf8), for: tag)
        await up.finish(taskDescription: tag.taskDescription, data: Data(#"{"text":"hello"}"#.utf8), response: response(200), error: nil)
        let answer = await up.takeFinished(tag)
        #expect(try answer?.get() == Transcript(text: "hello", noSpeech: false))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aHubErrorIsDeliveredAsTheForegroundClientWouldThrowIt() async {
        let up = uploader()
        await up.finish(taskDescription: tag.taskDescription, data: Data(), response: response(429, ["Retry-After": "5"]), error: nil)
        #expect(await up.takeFinished(tag) == .failure(.rateLimited(retryAfter: 5)))
    }

    @Test func aTransportErrorIsANetworkFailure() async {
        let up = uploader()
        await up.finish(taskDescription: tag.taskDescription, data: Data(), response: nil, error: URLError(.networkConnectionLost))
        guard case .failure(.network)? = await up.takeFinished(tag) else { Issue.record("not a network failure"); return }
    }

    @Test func aTaskWithNoTagIsIgnored() async {
        let up = uploader()
        await up.finish(taskDescription: "other", data: Data(), response: response(200), error: nil)
        #expect(await up.takeFinished(tag) == nil)
    }

    // Review ios-pr-576: an answer outlives the process that received it, so
    // a chunk sent while the app was killed is not sent and billed again.
    @Test func aDeliveredAnswerIsTakenByTheNextProcess() async throws {
        await uploader().finish(
            taskDescription: tag.taskDescription, data: Data(#"{"text":"hello"}"#.utf8), response: response(200), error: nil)
        let relaunched = uploader()
        #expect(try await relaunched.takeFinished(tag)?.get() == Transcript(text: "hello", noSpeech: false))
        #expect(await relaunched.takeFinished(tag) == nil)
    }

    @Test func anAnswerIsOnDiskBeforeItIsHandedOn() async throws {
        uploader().record(taskDescription: tag.taskDescription, data: Data(#"{"text":"hi"}"#.utf8), response: response(200), error: nil)
        #expect(try await uploader().takeFinished(tag)?.get() == Transcript(text: "hi", noSpeech: false))
    }

    @Test func aFailureIsNotKeptAcrossProcesses() async {
        await uploader().finish(taskDescription: tag.taskDescription, data: Data(), response: response(500), error: nil)
        #expect(await uploader().takeFinished(tag) == nil)
    }

    // The session's events can finish before the app delegate hands over the
    // system's handler; it is still called.
    @Test func eventsThatFinishBeforeTheHandlerArrivesStillCallIt() async {
        let up = uploader()
        up.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            up.setEventsFinished { done.resume() }
        }
    }

    @Test func aReplacedHandlerIsCalled() async {
        let up = uploader()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            up.setEventsFinished { done.resume() }
            up.setEventsFinished {}
        }
    }
}
