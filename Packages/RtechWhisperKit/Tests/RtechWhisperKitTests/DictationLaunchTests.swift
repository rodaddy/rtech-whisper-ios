import Testing

@testable import RtechWhisperKit

@MainActor
@Test func nothingRequestedMeansNoStart() {
    let launch = DictationLaunch()
    #expect(launch.isPending == false)
    #expect(launch.consume(isRecording: false) == false)
}

@MainActor
@Test func aRequestStartsOnceAndIsCleared() {
    let launch = DictationLaunch()
    launch.request()
    #expect(launch.isPending)
    #expect(launch.consume(isRecording: false))
    #expect(launch.isPending == false)
    #expect(launch.consume(isRecording: false) == false)
}

@MainActor
@Test func twoRequestsBeforeTheAppActsAreOneStart() {
    let launch = DictationLaunch()
    launch.request()
    launch.request()
    #expect(launch.consume(isRecording: false))
    #expect(launch.consume(isRecording: false) == false)
}

@MainActor
@Test func aRequestWhileRecordingIsClearedWithoutAStart() {
    let launch = DictationLaunch()
    launch.request()
    #expect(launch.consume(isRecording: true) == false)
    #expect(launch.isPending == false)
}
