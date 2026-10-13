import Foundation

/// How a note reads in a list, matching the desktop's defaults.
extension NoteRecord {
    /// The desktop's `title` column default.
    public static let untitled = "Untitled Note"

    /// The title, or the desktop's "Untitled Note" when it is blank.
    public var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? Self.untitled : trimmed
    }

    /// The content collapsed to one run of text for a one- or two-line row:
    /// blank lines dropped, newlines and runs of spaces folded to one space,
    /// cut at `limit` characters. Empty content gives an empty string, so the
    /// row can show nothing instead of a blank line.
    public func preview(limit: Int = 160) -> String {
        let words = content.split(whereSeparator: \.isWhitespace)
        var out = ""
        for word in words {
            if !out.isEmpty { out.append(" ") }
            out.append(contentsOf: word)
            if out.count >= limit { break }
        }
        return out.count > limit ? String(out.prefix(limit)) : out
    }
}

/// The folders the desktop seeds on first launch (`database.js`): the default
/// "Personal" at sort 0, then "Meetings" and "Videos". The phone seeds the same
/// three by name so both devices' folders converge through the hub.
public struct DefaultFolder: Sendable, Equatable {
    public let name: String
    public let sortOrder: Int
    public let isDefault: Bool

    public static let all: [DefaultFolder] = [
        DefaultFolder(name: "Personal", sortOrder: 0, isDefault: true),
        DefaultFolder(name: "Meetings", sortOrder: 1, isDefault: false),
        DefaultFolder(name: "Videos", sortOrder: 2, isDefault: false),
    ]

    /// The seeds not yet present in `existing`, matched by name without
    /// regard to case, so a folder the Mac already made is never doubled.
    public static func missing(from existing: [FolderRecord]) -> [DefaultFolder] {
        let names = Set(existing.map { $0.name.lowercased() })
        return all.filter { !names.contains($0.name.lowercased()) }
    }
}
