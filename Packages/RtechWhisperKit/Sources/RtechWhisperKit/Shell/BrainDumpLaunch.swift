import Foundation
import Observation

/// A "Brain dump" request from outside the app (ios#484): the Action button,
/// Siri, Spotlight, a Home Screen shortcut, or the Control Center control.
/// The intent sets it; the app shell consumes it once it is on screen and
/// opens the Brain dump tab with the text box focused. It never records.
@MainActor
@Observable
public final class BrainDumpLaunch {
    /// A request is waiting for the app to act on it.
    public private(set) var isPending = false

    public init() {}

    /// Ask the app to open a brain dump. Asking twice before the app acts is
    /// still one open.
    public func request() {
        isPending = true
    }

    /// Take the waiting request, if any. Returns whether the app should open
    /// the Brain dump tab and focus the box.
    public func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }
}
