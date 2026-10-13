import Foundation
import Observation

/// The URL the keyboard's mic key opens: `rtechwhisper://keyboard-dictate`,
/// with `host=<bundle id>` when the keyboard could tell which app it was
/// typing into, so the app can send the person back there.
public enum KeyboardRoute: Equatable, Sendable {
    case dictate(hostBundle: String?)

    private static let dictatePath = "keyboard-dictate"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == KeyboardHandoff.urlScheme,
              url.host(percentEncoded: false)?.lowercased() == Self.dictatePath,
              url.path(percentEncoded: false).isEmpty || url.path(percentEncoded: false) == "/"
        else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let host = items.first { $0.name == "host" }?.value?.trimmingCharacters(in: .whitespaces)
        self = .dictate(hostBundle: host?.isEmpty == false ? host : nil)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = KeyboardHandoff.urlScheme
        components.host = Self.dictatePath
        if let hostBundle { components.queryItems = [URLQueryItem(name: "host", value: hostBundle)] }
        return components.url!
    }

    /// The app the keyboard was typing into, when it could tell.
    public var hostBundle: String? {
        guard case .dictate(let host) = self else { return nil }
        return host
    }

    /// Where to send the person back after the take: a known app's own URL
    /// scheme. Only this fixed list is ever opened, so a crafted link cannot
    /// make the app open an arbitrary URL. `nil` means the app shows a
    /// "swipe back" hint instead.
    public var returnURL: URL? {
        guard let host = hostBundle else { return nil }
        return Self.returnSchemes[host.lowercased()].flatMap(URL.init(string:))
    }

    private static let returnSchemes: [String: String] = [
        "com.apple.mobilesms": "sms://",
        "com.apple.mobilemail": "message://",
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.mobilesafari": "x-web-search://",
        "com.google.gmail": "googlegmail://",
        "com.microsoft.office.outlook": "ms-outlook://",
        "com.microsoft.skype.teams": "msteams://",
        "com.tinyspeck.chatlyio": "slack://",
        "net.whatsapp.whatsapp": "whatsapp://",
        "ph.telegra.telegraph": "tg://",
        "org.whispersystems.signal": "sgnl://",
        "com.hammerandchisel.discord": "discord://",
        "notion.id": "notion://"
    ]
}

/// One keyboard take in the app: from the keyboard's link, through the
/// recording, to the text handed back. The app feeds it every dictation
/// change; it writes the text to the handoff store exactly once, and only
/// for the take the session itself recorded, within `maxAge`.
@MainActor
@Observable
public final class KeyboardDictation {
    /// A keyboard take is in progress.
    public private(set) var isActive = false
    /// Shown when the app cannot send the person back itself, or when it
    /// refused a keyboard take because another recording was running.
    public private(set) var returnHint: String?
    private var route: KeyboardRoute?
    private var sawRecording = false
    /// The latest take when the session began; it is never the session's.
    private var takeAtBegin: UUID?
    /// The session's own take: the first new take id after its recording.
    private var ownTake: UUID?
    private var begunAt: Date?
    /// When the session's recording ended (its first state after recording).
    private var stoppedAt: Date?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    private let store: PendingTranscriptStore?
    private let maxAge: TimeInterval
    private let now: () -> Date

    public init(store: PendingTranscriptStore?, maxAge: TimeInterval = KeyboardHandoff.maxAge, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.maxAge = maxAge
        self.now = now
    }

    /// The session's recording has stopped and its text is not handed over
    /// yet: the app holds a background task for this stretch, so a swipe
    /// back does not stall the handoff.
    public var isHandingOff: Bool { isActive && stoppedAt != nil }

    /// Returns once no session is active: handed over, failed, or expired.
    public func finished() async {
        guard isActive else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The keyboard asked for a take. The app then starts recording.
    /// `currentTake` is the latest take on screen now; it belongs to an
    /// earlier take and is never handed over. One recording at a time: when
    /// the app `isRecording` already, no session starts, the hint asks the
    /// person to finish that dictation, and this returns `false`.
    @discardableResult
    public func begin(_ route: KeyboardRoute, currentTake: UUID?, isRecording: Bool = false) -> Bool {
        guard !isRecording else {
            returnHint = Self.finishFirst
            return false
        }
        self.route = route
        isActive = true
        sawRecording = false
        takeAtBegin = currentTake
        ownTake = nil
        begunAt = now()
        stoppedAt = nil
        returnHint = nil
        store?.setStatus(.recording)
        return true
    }

    public enum Step: Equatable, Sendable {
        case waiting
        /// The text is in the handoff store. Open the URL to go back to the
        /// previous app; with none, `returnHint` is already set.
        case handedOff(returnTo: URL?)
    }

    /// Feed each dictation change: the state, the latest take's text, and
    /// its id. A state left over from before `begin` (an old `.failed` or
    /// `.done`) is ignored until the session's own recording starts.
    public func update(state: DictationController.State, text: String?, take: UUID?) -> Step {
        guard isActive else { return .waiting }
        // Before the recording, the clock runs from `begin`; after it, from
        // the stop. While recording there is no deadline.
        let clockStart = stoppedAt ?? (sawRecording ? nil : begunAt)
        if let clockStart, now().timeIntervalSince(clockStart) > maxAge {
            // Too late: the person has moved on. No text, no jump back.
            finish(hint: nil)
            return .waiting
        }
        switch state {
        case .recording:
            guard stoppedAt == nil else {
                // Another take started after this one stopped: not the keyboard's.
                finish(hint: nil)
                return .waiting
            }
            sawRecording = true
            store?.setStatus(.recording)
            return .waiting
        case .failed:
            guard sawRecording else { return .waiting }
            finish(hint: Self.didNotFinish)
            return .waiting
        case .idle:
            return .waiting
        case .queued, .cleaning, .done:
            guard sawRecording else { return .waiting }
            if stoppedAt == nil { stoppedAt = now() }
            if let take, take != takeAtBegin {
                if ownTake == nil { ownTake = take }
                guard take == ownTake else {
                    // A different take reached the screen: not the keyboard's.
                    finish(hint: nil)
                    return .waiting
                }
            }
            // Cleanup is still rewriting the text; wait for its result.
            guard state != .cleaning, let text, let take, take == ownTake else {
                store?.setStatus(.transcribing)
                return .waiting
            }
            store?.write(text, take: take)
            let url = route?.returnURL
            finish(hint: url == nil ? Self.swipeBack : nil)
            return .handedOff(returnTo: url)
        }
    }

    /// The app asked the microphone to start and it did not (for example
    /// access is off). Ends a session whose recording never began.
    public func recordDidNotStart() {
        guard isActive, !sawRecording else { return }
        finish(hint: Self.didNotFinish)
    }

    private static let swipeBack = "Your text is ready. Swipe back to return."
    private static let didNotFinish = "Dictation did not finish. Swipe back to return."
    private static let finishFirst = "Finish the current dictation first."

    /// Opening the previous app failed; show the hint instead.
    public func returnFailed() {
        returnHint = Self.swipeBack
    }

    /// The person dismissed the hint.
    public func dismissHint() {
        returnHint = nil
    }

    private func finish(hint: String?) {
        store?.setStatus(nil)
        isActive = false
        route = nil
        takeAtBegin = nil
        ownTake = nil
        begunAt = nil
        stoppedAt = nil
        returnHint = hint
        let done = waiters
        waiters = []
        done.forEach { $0.resume() }
    }
}
