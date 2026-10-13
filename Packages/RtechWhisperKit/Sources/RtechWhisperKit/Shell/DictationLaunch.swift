import Foundation
import Observation

/// The tabs of the app shell, in order. Home dictates, Notes is the
/// notebook, Chat talks to the agent, More holds the rest.
public enum AppTab: Hashable, Sendable, CaseIterable {
    case home
    case notes
    case brainDump
    case chat
    case more
}

/// A start-dictation request from outside the app: Siri, Shortcuts, the
/// Action button, or the Control Center control. The intent sets it; the app
/// shell consumes it once it is on screen, switches to Home, and records.
/// This is the phone's version of the desktop's global hotkey.
@MainActor
@Observable
public final class DictationLaunch {
    /// A request is waiting for the app to act on it.
    public private(set) var isPending = false

    public init() {}

    /// Ask the app to start dictating. Asking twice before the app acts is
    /// still one start.
    public func request() {
        isPending = true
    }

    /// Take the waiting request, if any. Returns whether the app should call
    /// `record()`: not when nothing was asked, and not when it is already
    /// recording (a second press must not stop or restart the take).
    public func consume(isRecording: Bool) -> Bool {
        guard isPending else { return false }
        isPending = false
        return !isRecording
    }
}
