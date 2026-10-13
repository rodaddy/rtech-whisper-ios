import Foundation
import Observation

/// The Undo window after Delete on the dictation card. Nothing is deleted
/// while the window is open; `undo` closes it with nothing deleted, and the
/// delete runs when the window ends or `commit` ends it early (a new
/// recording). A kill during the window keeps the take.
@MainActor
@Observable
public final class PendingDelete {
    public static let window: Duration = .seconds(5)

    /// The take waiting to be deleted; the card hides while this is set.
    public private(set) var take: UUID?
    @ObservationIgnored private var action: (@MainActor () async -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Open the window for `take`. A window already open is committed first.
    /// The returned task ends when this window does.
    @discardableResult
    public func start(_ take: UUID, delete: @escaping @MainActor () async -> Void) async -> Task<Void, Never> {
        await commit()
        self.take = take
        action = delete
        let sleep = sleep
        let timer = Task { [weak self] in
            do { try await sleep(Self.window) } catch { return }
            await self?.commit()
        }
        self.timer = timer
        return timer
    }

    /// Close the window; nothing is deleted.
    public func undo() {
        timer?.cancel()
        timer = nil
        action = nil
        take = nil
    }

    /// End the window now and run the delete, if one is waiting.
    public func commit() async {
        guard let action else { return }
        let committed = take
        self.action = nil
        timer?.cancel()
        timer = nil
        await action()
        // The card stays hidden until the delete has cleared it.
        if take == committed { take = nil }
    }
}
