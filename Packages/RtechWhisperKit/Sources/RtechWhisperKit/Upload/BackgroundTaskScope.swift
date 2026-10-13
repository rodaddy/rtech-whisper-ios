/// Holds a system background task open while some work runs, and ends it
/// exactly once: when the system says the time is up, or when the work
/// finishes, whichever comes first. A background task left running past
/// its time gets the app terminated instead of suspended, which loses
/// everything held in memory.
///
/// One task per `run`: once the system expires it, the rest of the work runs
/// with none, even after the app comes back to the foreground. Leaving the
/// app again then suspends it mid-chunk; that chunk fails as a hub error the
/// Upload screen offers to resume.
///
/// The app passes `UIApplication.beginBackgroundTask` and `endBackgroundTask`;
/// tests pass fakes.
@MainActor
public enum BackgroundTaskScope {
    /// - Parameters:
    ///   - begin: starts the task, calling its argument when the system
    ///     expires it; returns the task, or `nil` when none was granted.
    ///   - end: ends a task `begin` returned.
    public static func run<ID>(
        begin: (_ onExpire: @escaping @MainActor () -> Void) -> ID?,
        end: @escaping @MainActor (ID) -> Void,
        _ work: () async -> Void
    ) async {
        let held = Held<ID>(end: end)
        held.id = begin { held.finish() }
        await work()
        held.finish()
    }

    @MainActor
    private final class Held<ID> {
        var id: ID?
        let end: @MainActor (ID) -> Void

        init(end: @escaping @MainActor (ID) -> Void) { self.end = end }

        func finish() {
            guard let id else { return }
            self.id = nil
            end(id)
        }
    }
}
