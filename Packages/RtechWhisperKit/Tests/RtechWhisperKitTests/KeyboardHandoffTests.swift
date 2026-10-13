import Foundation
import Testing

@testable import RtechWhisperKit

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "keyboard-tests-\(UUID().uuidString)")!
}

private let start = Date(timeIntervalSince1970: 1_000_000)

// MARK: - PendingTranscriptStore

@Test func pendingTextIsTakenOnlyByAnInsertTapAndOnlyOnce() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let take = UUID()
    #expect(store.write("hello there", take: take))
    // Showing the Insert key reads the text and leaves it in place.
    #expect(store.pending == PendingTranscript(text: "hello there", take: take))
    #expect(store.pending == PendingTranscript(text: "hello there", take: take))
    // A tap for some other take takes nothing.
    #expect(store.consume(take: UUID()) == nil)
    #expect(store.pending != nil)
    // The tap for this take inserts it once.
    #expect(store.consume(take: take) == "hello there")
    #expect(store.pending == nil)
    #expect(store.consume(take: take) == nil)
}

@Test func discardRemovesThePendingText() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let take = UUID()
    store.write("never mind", take: take)
    // A discard for another take leaves this one.
    store.discard(take: UUID())
    #expect(store.pending?.take == take)
    store.discard(take: take)
    #expect(store.pending == nil)
    #expect(store.consume(take: take) == nil)
}

@Test func staleTextGetsNoInsertKey() {
    let defaults = freshDefaults()
    let take = UUID()
    PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start }).write("late", take: take)
    let later = PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start.addingTimeInterval(301) })
    #expect(later.pending == nil)
    #expect(later.consume(take: take) == nil)
    // Dropped for good, not kept for a clock that moves back.
    #expect(PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start }).pending == nil)
}

@Test func textJustInsideTheWindowStillGetsTheInsertKey() {
    let defaults = freshDefaults()
    let take = UUID()
    PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start }).write("on time", take: take)
    let later = PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start.addingTimeInterval(300) })
    #expect(later.pending?.take == take)
    #expect(later.consume(take: take) == "on time")
}

@Test func theSameTakeIsWrittenOnlyOnce() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let take = UUID()
    #expect(store.write("first", take: take))
    #expect(store.consume(take: take) == "first")
    // A retried stop for the same take must not queue its text again.
    #expect(store.write("first", take: take) == false)
    #expect(store.pending == nil)
}

@Test func aNewerTakeReplacesOneNotYetInserted() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    store.write("old", take: UUID())
    let new = UUID()
    #expect(store.write("new", take: new))
    #expect(store.pending == PendingTranscript(text: "new", take: new))
}

@Test func emptyTextIsNotWritten() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    #expect(store.write("  \n", take: UUID()) == false)
    #expect(store.pending == nil)
}

@Test func theInsertKeyShowsTheFirstFortyCharacters() {
    #expect(KeyboardHandoff.insertTitle(for: "Short one.") == "Insert: \"Short one.\"")
    let long = String(repeating: "a", count: 40) + "bcd"
    #expect(KeyboardHandoff.insertTitle(for: long) == "Insert: \"\(String(repeating: "a", count: 40))…\"")
    #expect(KeyboardHandoff.insertTitle(for: "two\nlines") == "Insert: \"two lines\"")
}

@Test func theStatusGoesStaleAndClears() {
    let defaults = freshDefaults()
    let store = PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start })
    store.setStatus(.recording)
    #expect(store.status == .recording)
    #expect(PendingTranscriptStore(defaults: defaults, maxAge: 300, now: { start.addingTimeInterval(301) }).status == nil)
    store.setStatus(nil)
    #expect(store.status == nil)
}

// MARK: - KeyboardRoute

@Test func theDictateRouteParses() {
    #expect(KeyboardRoute(url: URL(string: "rtechwhisper://keyboard-dictate")!) == .dictate(hostBundle: nil))
    #expect(
        KeyboardRoute(url: URL(string: "rtechwhisper://keyboard-dictate?host=com.apple.MobileSMS")!)
            == .dictate(hostBundle: "com.apple.MobileSMS"))
    #expect(KeyboardRoute(url: URL(string: "RtechWhisper://Keyboard-Dictate/?host=")!) == .dictate(hostBundle: nil))
}

@Test func otherURLsAreNotTheDictateRoute() {
    #expect(KeyboardRoute(url: URL(string: "rtechwhisper://settings")!) == nil)
    #expect(KeyboardRoute(url: URL(string: "rtechwhisper://keyboard-dictate/extra")!) == nil)
    #expect(KeyboardRoute(url: URL(string: "https://keyboard-dictate")!) == nil)
}

@Test func theRouteRoundTripsThroughItsURL() {
    let route = KeyboardRoute.dictate(hostBundle: "com.apple.mobilenotes")
    #expect(KeyboardRoute(url: route.url) == route)
    #expect(KeyboardRoute(url: KeyboardRoute.dictate(hostBundle: nil).url) == .dictate(hostBundle: nil))
}

@Test func onlyKnownAppsGetAReturnURL() {
    #expect(KeyboardRoute.dictate(hostBundle: "com.apple.MobileSMS").returnURL == URL(string: "sms://"))
    #expect(KeyboardRoute.dictate(hostBundle: "com.example.unknown").returnURL == nil)
    #expect(KeyboardRoute.dictate(hostBundle: nil).returnURL == nil)
}

// MARK: - KeyboardDictation

@MainActor
@Test func aKeyboardTakeHandsItsTextOverOnceAndReturns() {
    let defaults = freshDefaults()
    let store = PendingTranscriptStore(defaults: defaults, now: { start })
    let session = KeyboardDictation(store: store)
    let take = UUID()
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    #expect(store.status == .recording)
    #expect(session.update(state: .recording, text: nil, take: nil) == .waiting)
    #expect(session.update(state: .queued, text: nil, take: take) == .waiting)
    #expect(store.status == .transcribing)
    #expect(session.update(state: .cleaning, text: "raw words", take: take) == .waiting)
    #expect(session.update(state: .done, text: "Clean words.", take: take) == .handedOff(returnTo: URL(string: "sms://")))
    #expect(session.isActive == false)
    #expect(session.returnHint == nil)
    #expect(store.status == nil)
    // A later change for the same take hands nothing over again.
    #expect(session.update(state: .done, text: "Clean words.", take: take) == .waiting)
    #expect(store.consume(take: take) == "Clean words.")
    #expect(store.consume(take: take) == nil)
}

@MainActor
@Test func anOldTakeShownBeforeRecordingIsNotHandedOver() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    session.begin(.dictate(hostBundle: nil), currentTake: nil)
    #expect(session.update(state: .done, text: "yesterday's take", take: UUID()) == .waiting)
    #expect(store.pending == nil)
}

@MainActor
@Test func anUnknownHostGetsTheSwipeBackHint() {
    let session = KeyboardDictation(store: PendingTranscriptStore(defaults: freshDefaults(), now: { start }))
    session.begin(.dictate(hostBundle: nil), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    #expect(session.update(state: .done, text: "hi", take: UUID()) == .handedOff(returnTo: nil))
    #expect(session.returnHint?.contains("Swipe back") == true)
}

@MainActor
@Test func aTakeThatFailsAfterRecordingEndsWithAHintAndNoText() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    _ = session.update(state: .failed("Nothing was recorded."), text: nil, take: nil)
    #expect(session.isActive == false)
    #expect(session.returnHint != nil)
    #expect(store.pending == nil)
    #expect(store.status == nil)
}

@MainActor
@Test func aMicrophoneThatDoesNotStartEndsTheSession() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    session.recordDidNotStart()
    #expect(session.isActive == false)
    #expect(session.returnHint != nil)
    #expect(store.status == nil)
}

// MARK: - Review findings for ios-pr-377

@MainActor
@Test func aFailureLeftFromAnEarlierTakeDoesNotEndTheNextSession() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    let old = UUID()
    let take = UUID()
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: old)
    // The app feeds the state right after begin, before record() runs.
    #expect(session.update(state: .failed("Nothing was recorded."), text: nil, take: old) == .waiting)
    #expect(session.isActive)
    #expect(session.returnHint == nil)
    _ = session.update(state: .recording, text: nil, take: old)
    _ = session.update(state: .queued, text: nil, take: take)
    #expect(session.update(state: .done, text: "Hello.", take: take) == .handedOff(returnTo: URL(string: "sms://")))
    #expect(store.consume(take: take) == "Hello.")
}

@MainActor
@Test func aRecordStartFailureAfterAStaleFailureStillEndsTheSession() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    session.begin(.dictate(hostBundle: nil), currentTake: nil)
    let denied = DictationController.State.failed("Microphone access is off. Turn it on in Settings.")
    _ = session.update(state: denied, text: nil, take: nil)
    #expect(session.isActive)
    // record() failed again with the same message: no state change to feed.
    session.recordDidNotStart()
    #expect(session.isActive == false)
    #expect(session.returnHint?.contains("did not finish") == true)
}

@MainActor
@Test func aTakeThatFinishesAfterTheDeadlineIsNotHandedOver() {
    var clock = start
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { clock })
    let session = KeyboardDictation(store: store, maxAge: 300, now: { clock })
    let take = UUID()
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    // A long recording is not cut off: the clock starts at the stop.
    clock = start.addingTimeInterval(600)
    #expect(session.update(state: .queued, text: nil, take: take) == .waiting)
    #expect(session.isActive)
    // The hub was down; the foreground retry finishes it hours later.
    clock = start.addingTimeInterval(600 + 3 * 3600)
    #expect(session.update(state: .done, text: "Old words.", take: take) == .waiting)
    #expect(session.isActive == false)
    #expect(session.returnHint == nil)
    #expect(store.pending == nil)
    #expect(store.status == nil)
}

@MainActor
@Test func aSessionThatNeverRecordsExpires() {
    var clock = start
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { clock })
    let session = KeyboardDictation(store: store, maxAge: 300, now: { clock })
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    clock = start.addingTimeInterval(301)
    // A later Home-screen take is not adopted by the abandoned session.
    _ = session.update(state: .recording, text: nil, take: nil)
    #expect(session.isActive == false)
    #expect(session.update(state: .done, text: "A note.", take: UUID()) == .waiting)
    #expect(store.pending == nil)
}

@MainActor
@Test func aLaterUnrelatedTakeIsNotHandedOver() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    let own = UUID()
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    _ = session.update(state: .queued, text: nil, take: own)
    // The keyboard's take waits for the hub; the person records from Home.
    #expect(session.update(state: .recording, text: nil, take: own) == .waiting)
    #expect(session.isActive == false)
    #expect(session.update(state: .done, text: "A note.", take: UUID()) == .waiting)
    #expect(store.pending == nil)
}

@MainActor
@Test func aDifferentTakeIdIsNotHandedOver() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    _ = session.update(state: .queued, text: nil, take: UUID())
    #expect(session.update(state: .done, text: "Other.", take: UUID()) == .waiting)
    #expect(session.isActive == false)
    #expect(store.pending == nil)
}

@MainActor
@Test func theTakeOnScreenAtBeginIsNeverTheSessionsTake() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    let old = UUID()
    session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: old)
    _ = session.update(state: .recording, text: "Old.", take: old)
    #expect(session.update(state: .done, text: "Old.", take: old) == .waiting)
    #expect(session.isActive)
    #expect(store.pending == nil)
}


// MARK: - One recording at a time, finish in the background

@MainActor
@Test func aSessionBegunWhileRecordingIsRefusedAndHandsNothingOff() {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    #expect(session.begin(.dictate(hostBundle: "com.apple.MobileSMS"), currentTake: nil, isRecording: true) == false)
    #expect(session.isActive == false)
    #expect(session.returnHint == "Finish the current dictation first.")
    #expect(store.status == nil)
    // The recording already running finishes; it is not the keyboard's.
    #expect(session.update(state: .recording, text: nil, take: nil) == .waiting)
    #expect(session.update(state: .done, text: "A note.", take: UUID()) == .waiting)
    #expect(store.pending == nil)
}

@MainActor
@Test func theSessionIsHandingOffFromStopUntilTheTextIsWritten() async {
    let store = PendingTranscriptStore(defaults: freshDefaults(), now: { start })
    let session = KeyboardDictation(store: store)
    let take = UUID()
    await session.finished()  // no session: returns at once
    session.begin(.dictate(hostBundle: nil), currentTake: nil)
    _ = session.update(state: .recording, text: nil, take: nil)
    #expect(session.isHandingOff == false)
    _ = session.update(state: .queued, text: nil, take: take)
    #expect(session.isHandingOff)
    let waiter = Task { await session.finished() }
    _ = session.update(state: .done, text: "Done.", take: take)
    await waiter.value
    #expect(session.isHandingOff == false)
    #expect(store.pending?.take == take)
}

/// Runs `onRead` once, right after the keyboard reads the pending key: the
/// app's write landing between the keyboard's read and its remove.
private final class RacingDefaults: UserDefaults, @unchecked Sendable {
    var onRead: (() -> Void)?

    override func data(forKey defaultName: String) -> Data? {
        let value = super.data(forKey: defaultName)
        if defaultName == "keyboard.pendingTranscript", let hook = onRead {
            onRead = nil
            hook()
        }
        return value
    }
}

@Test func aTakeWrittenBetweenReadAndRemoveIsNotDeleted() {
    let defaults = RacingDefaults(suiteName: "keyboard-race-\(UUID().uuidString)")!
    let store = PendingTranscriptStore(defaults: defaults, now: { start })
    let first = UUID()
    let second = UUID()
    store.write("first", take: first)
    defaults.onRead = { store.write("second", take: second) }
    // The tap was for the first take; the newer take replaced it and survives.
    #expect(store.consume(take: first) == nil)
    #expect(store.consume(take: second) == "second")
}

@Test func aTakeWrittenBetweenReadAndDiscardIsNotDeleted() {
    let defaults = RacingDefaults(suiteName: "keyboard-race-\(UUID().uuidString)")!
    let store = PendingTranscriptStore(defaults: defaults, now: { start })
    let first = UUID()
    let second = UUID()
    store.write("first", take: first)
    defaults.onRead = { store.write("second", take: second) }
    store.discard(take: first)
    #expect(store.pending?.take == second)
}
