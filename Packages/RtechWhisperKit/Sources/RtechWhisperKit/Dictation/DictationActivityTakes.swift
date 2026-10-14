import Foundation

/// Which Live Activity belongs to the take on screen. Each start makes a
/// new `Take`; its `update` and `end` touch only the activity its own
/// request started, so a late call on the `SerialTaskChain` cannot reach a
/// leftover or a later take's activity. A request that fails clears
/// the take, so the next recording starts a new activity.
@MainActor
public final class DictationActivityTakes {
    /// One take's activity id, set by its request on the chain.
    public final class Take: @unchecked Sendable {
        private let lock = NSLock()
        private var id: String?

        /// The id of the activity this take's request started, or `nil`
        /// before it ran or when it failed.
        public var activityID: String? {
            get { lock.withLock { id } }
            set { lock.withLock { id = newValue } }
        }
    }

    /// The take whose activity is showing, from its start until its end.
    public private(set) var current: Take?

    public init() {}

    /// Whether a take's activity has been started and not yet ended.
    public var isActive: Bool { current != nil }

    /// A new take, now the current one.
    public func start() -> Take {
        let take = Take()
        current = take
        return take
    }

    /// Ends the current take and returns it.
    public func end() -> Take? {
        defer { current = nil }
        return current
    }

    /// `take`'s request threw: nothing is showing for it. A later take is left alone.
    public func requestFailed(_ take: Take) {
        if current === take { current = nil }
    }
}
