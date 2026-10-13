import Testing

@testable import RtechWhisperKit

@MainActor
@Test func noBrainDumpRequestedMeansNothingOpens() {
    let launch = BrainDumpLaunch()
    #expect(launch.isPending == false)
    #expect(launch.consume() == false)
}

@MainActor
@Test func aBrainDumpRequestOpensOnceAndIsCleared() {
    let launch = BrainDumpLaunch()
    launch.request()
    #expect(launch.isPending)
    #expect(launch.consume())
    #expect(launch.isPending == false)
    #expect(launch.consume() == false)
}

@MainActor
@Test func twoBrainDumpRequestsBeforeTheAppActsAreOneOpen() {
    let launch = BrainDumpLaunch()
    launch.request()
    launch.request()
    #expect(launch.consume())
    #expect(launch.consume() == false)
}
