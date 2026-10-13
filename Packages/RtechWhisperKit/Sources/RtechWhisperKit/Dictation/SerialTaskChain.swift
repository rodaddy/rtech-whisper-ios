import Foundation

/// Runs async operations one after another, in the order they were
/// enqueued, off the main actor. The Live Activity sends every ActivityKit
/// call through one, so a take's `update` lands before its `end` and the
/// launch clean-up runs before the first start.
///
/// The trade-off: an operation waits for the one before it for at most
/// `maxWait` once that one has started. An ActivityKit call that stalls then
/// holds the Live Activity back that long, not for good, but it is not
/// cancelled: it may still land after operations enqueued behind it. Order
/// holds only for operations that finish within `maxWait` (#204), so callers
/// must not depend on it for correctness.
@MainActor
public final class SerialTaskChain {
    /// The last operation enqueued: when it started, and when it finished.
    private var tail: (started: Task<Void, Never>, finished: Task<Void, Never>)?
    private let maxWait: Duration

    public init(maxWait: Duration = .seconds(10)) {
        self.maxWait = maxWait
    }

    /// Runs `operation` once everything enqueued before it has finished, or
    /// once the operation just before it has run for `maxWait`.
    public func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = tail
        let maxWait = maxWait
        let started = Task.detached {
            guard let previous else { return }
            await previous.started.value
            await Self.wait(for: previous.finished, atMost: maxWait)
        }
        let finished = Task.detached {
            await started.value
            await operation()
        }
        tail = (started, finished)
    }

    /// Waits for the last operation enqueued so far to finish. An earlier
    /// one that outran `maxWait` may still be running (#206).
    public func drain() async {
        await tail?.finished.value
    }

    /// Returns once `previous` finishes or `limit` passes. When `previous`
    /// never finishes, the task awaiting it never ends either: awaiting a
    /// task's value ignores cancellation, so there is nothing to cancel it
    /// with. One such task per stalled operation, which is itself leaked
    /// already (#241).
    private nonisolated static func wait(for previous: Task<Void, Never>, atMost limit: Duration) async {
        let once = Once()
        await withCheckedContinuation { continuation in
            once.set(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.resume()
            }
            Task {
                await previous.value
                timer.cancel()
                once.resume()
            }
        }
    }

    /// Resumes its continuation the first time it is asked to. `set` runs
    /// before either task that calls `resume` is created.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        func set(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume() {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume()
        }
    }
}
