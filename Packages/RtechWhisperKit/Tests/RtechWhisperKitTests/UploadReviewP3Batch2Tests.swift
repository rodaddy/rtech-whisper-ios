import Foundation
import Testing

@testable import RtechWhisperKit

// Upload and dictation review P3s, batch 2.

@MainActor
@Suite struct DictationActivityTakesTests {
    private let recording = DictationActivityContent(phase: .recording, startedAt: .now)

    // A request that throws leaves nothing showing, so the next recording starts one.
    @Test func aFailedRequestLetsTheNextRecordingStartAgain() throws {
        let takes = DictationActivityTakes()
        let take = takes.start()
        #expect(DictationActivityStep.plan(isActive: takes.isActive, content: recording) == .update(recording))
        takes.requestFailed(take)
        #expect(!takes.isActive)
        #expect(DictationActivityStep.plan(isActive: takes.isActive, content: recording) == .start(recording))
    }

    // An old take's late failure or id never reaches a later take.
    @Test func anOldTakeNeverTouchesALaterOne() throws {
        let takes = DictationActivityTakes()
        let first = takes.start()
        #expect(takes.end() === first)
        let second = takes.start()
        takes.requestFailed(first)
        #expect(takes.current === second)
        first.activityID = "old"
        second.activityID = "new"
        #expect(takes.current?.activityID == "new")
    }
}

@MainActor
@Suite struct UploadReviewP3Batch2Tests {
    // A 2xx body that did not decode costs one resend, not the pass.
    @Test func aBodyThatDidNotDecodeIsResumable() {
        #expect(UploadJob.isResumable(.decoding("unexpected body")))
    }

    // The footer gets plain words; the raw reader error is only logged.
    @Test func aTruncationReasonIsInPlainWords() {
        #expect(UploadJob.truncationReason(for: AudioFileDecoderError.endedEarly)
            == "The file ends before the length it says it has.")
        #expect(UploadJob.truncationReason(for: AudioFileDecoderError.conversionFailed("OSStatus -50"))
            == "Part of the audio could not be converted.")
        let osStatus = NSError(domain: NSOSStatusErrorDomain, code: -50)
        #expect(UploadJob.truncationReason(for: osStatus) == "The rest of the file could not be read.")
    }
}
