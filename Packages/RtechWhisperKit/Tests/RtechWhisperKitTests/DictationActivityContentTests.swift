import Foundation
import Testing

@testable import RtechWhisperKit

@Suite struct DictationActivityContentTests {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func idleShowsNothing() {
        #expect(DictationActivityContent(state: .idle, latestText: nil, startedAt: startedAt) == nil)
    }

    @Test func recordingCountsUpFromWhenTheMicrophoneOpened() {
        let content = DictationActivityContent(state: .recording, latestText: "stale", startedAt: startedAt)
        #expect(content == DictationActivityContent(phase: .recording, startedAt: startedAt, message: nil))
    }

    @Test func queuedIsTranscribing() {
        let content = DictationActivityContent(state: .queued, latestText: "provisional", startedAt: startedAt)
        #expect(content?.phase == .transcribing)
        #expect(content?.message == nil)
    }

    @Test func doneShowsTheFirstLineOfTheResult() {
        let text = "\n  \n  Meeting notes for Monday.  \nSecond paragraph."
        let content = DictationActivityContent(state: .done, latestText: text, startedAt: startedAt)
        #expect(content == DictationActivityContent(phase: .done, startedAt: startedAt, message: "Meeting notes for Monday."))
    }

    @Test(arguments: [nil, "", "  \n\n"] as [String?])
    func doneWithNoTextSaysSo(text: String?) {
        let content = DictationActivityContent(state: .done, latestText: text, startedAt: startedAt)
        #expect(content?.message == DictationActivityContent.noSpeechLine)
    }

    @Test func failedCarriesTheReason() {
        let content = DictationActivityContent(state: .failed("Nothing was recorded."), latestText: nil, startedAt: startedAt)
        #expect(content == DictationActivityContent(phase: .failed, startedAt: startedAt, message: "Nothing was recorded."))
    }
}

@Suite struct DictationActivityStepTests {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    var recording: DictationActivityContent { .init(phase: .recording, startedAt: startedAt) }
    var transcribing: DictationActivityContent { .init(phase: .transcribing, startedAt: startedAt) }
    var done: DictationActivityContent { .init(phase: .done, startedAt: startedAt, message: "Hello.") }
    var failed: DictationActivityContent { .init(phase: .failed, startedAt: startedAt, message: "Nothing was recorded.") }

    @Test func aRecordingStartsTheActivity() {
        #expect(DictationActivityStep.plan(isActive: false, content: recording) == .start(recording))
    }

    @Test func aNewTakeWhileTheLastOneTranscribesUpdatesInPlace() {
        #expect(DictationActivityStep.plan(isActive: true, content: recording) == .update(recording))
    }

    @Test func transcribingUpdatesTheRunningActivity() {
        #expect(DictationActivityStep.plan(isActive: true, content: transcribing) == .update(transcribing))
    }

    @Test func transcribingWithNoActivityShowsNothing() {
        // The queue draining at launch is not a take the person is watching.
        #expect(DictationActivityStep.plan(isActive: false, content: transcribing) == .none)
    }

    @Test func theResultEndsTheActivityAfterAPause() {
        let step = DictationActivityStep.plan(isActive: true, content: done)
        #expect(step == .end(done, dismissAfter: DictationActivityStep.dismissDelay))
        #expect(DictationActivityStep.dismissDelay > 0)
    }

    @Test func anErrorEndsTheActivityWithTheReason() {
        #expect(DictationActivityStep.plan(isActive: true, content: failed) == .end(failed, dismissAfter: DictationActivityStep.dismissDelay))
    }

    @Test func aFailureWithNoActivityShowsNothing() {
        // Microphone access denied before any recording: nothing to end.
        #expect(DictationActivityStep.plan(isActive: false, content: failed) == .none)
    }

    @Test func idleDoesNothing() {
        #expect(DictationActivityStep.plan(isActive: true, content: nil) == .none)
        #expect(DictationActivityStep.plan(isActive: false, content: nil) == .none)
    }
}
