import Foundation

/// The order the user dragged notes into, per folder. Kept on this phone
/// only: it is never sent to the hub, so the desktop keeps its own order.
public enum NoteOrder {
    /// `notes` in the saved order. Notes the saved order does not name (new
    /// since the last drag) come first, in their incoming order; ids with no
    /// note are ignored.
    public static func ordered(_ notes: [NoteRecord], savedOrder: [String]) -> [NoteRecord] {
        let rank = Dictionary(savedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let unsaved = notes.filter { rank[$0.clientId] == nil }
        let saved = notes.filter { rank[$0.clientId] != nil }.sorted { rank[$0.clientId]! < rank[$1.clientId]! }
        return unsaved + saved
    }

    /// The new order after a drag of the rows at `offsets` to `destination`,
    /// with the same meaning as SwiftUI's `onMove`.
    public static func moved(_ ids: [String], from offsets: IndexSet, to destination: Int) -> [String] {
        let moving = offsets.filter { $0 < ids.count }.map { ids[$0] }
        let before = offsets.count { $0 < destination }
        var rest = ids.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: min(max(destination - before, 0), rest.count))
        return rest
    }
}

/// Each folder's saved note order, as one JSON value in `UserDefaults`.
public final class NoteOrderStore: @unchecked Sendable {
    /// The key for the "All notes" list, which has no folder.
    static let allNotesKey = ""
    private static let defaultsKey = "notes.order.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `nil` is the "All notes" list.
    public func order(forFolder folderClientId: String?) -> [String] {
        all()[folderClientId ?? Self.allNotesKey] ?? []
    }

    public func setOrder(_ ids: [String], forFolder folderClientId: String?) {
        var orders = all()
        orders[folderClientId ?? Self.allNotesKey] = ids
        if let data = try? JSONEncoder().encode(orders) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func all() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
}
