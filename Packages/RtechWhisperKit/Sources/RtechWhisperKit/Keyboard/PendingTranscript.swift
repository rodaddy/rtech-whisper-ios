import Foundation

/// What the keyboard extension and the app share. A keyboard cannot record
/// the microphone, so its mic key opens the app, the app records, and the
/// text comes back through the App Group. The keyboard never inserts it on
/// its own: it shows an Insert key, and the person taps it in the field they
/// want.
public enum KeyboardHandoff {
    /// The App Group both the app and the keyboard are entitled to.
    public static let appGroup = "group.com.rtech-consulting.whisper"
    /// The app's URL scheme; the keyboard opens `rtechwhisper://keyboard-dictate`.
    public static let urlScheme = "rtechwhisper"
    /// Text older than this is no longer offered: the person has moved on.
    public static let maxAge: TimeInterval = 5 * 60
    /// How many characters of the text the Insert key shows.
    public static let previewLength = 40

    /// The Insert key's title: `Insert: "<first ~40 chars>…"`.
    public static func insertTitle(for text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let preview = flat.count > previewLength ? flat.prefix(previewLength) + "…" : flat
        return "Insert: \"\(preview)\""
    }
}

/// What the keyboard shows while the app has its take.
public enum KeyboardTakeStatus: String, Sendable {
    case recording
    case transcribing
}

/// Text waiting for the keyboard's Insert key.
public struct PendingTranscript: Equatable, Sendable {
    public let text: String
    public let take: UUID
}

/// The one transcript waiting for the keyboard, in the App Group's defaults.
/// Written once per take. It leaves the store only when the person taps
/// Insert or discards it; stale text is never offered.
public struct PendingTranscriptStore {
    private struct Entry: Codable {
        var text: String
        var take: UUID
        var writtenAt: Date
    }

    private enum Key {
        static let pending = "keyboard.pendingTranscript"
        static let lastTake = "keyboard.lastWrittenTake"
        static let status = "keyboard.takeStatus"
        static let statusAt = "keyboard.takeStatusAt"
    }

    private let defaults: UserDefaults
    private let maxAge: TimeInterval
    private let now: () -> Date

    public init(defaults: UserDefaults, maxAge: TimeInterval = KeyboardHandoff.maxAge, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.maxAge = maxAge
        self.now = now
    }

    /// The store in the shared App Group, or `nil` when the container is not
    /// available (a keyboard without Full Access).
    public static func shared() -> PendingTranscriptStore? {
        UserDefaults(suiteName: KeyboardHandoff.appGroup).map { PendingTranscriptStore(defaults: $0) }
    }

    /// Hand a finished take's text to the keyboard. A take is written once:
    /// writing the same take again is refused, so its text can never be
    /// offered twice. A newer take replaces an older one not yet inserted.
    /// Empty text is refused. Returns whether the text was written.
    @discardableResult
    public func write(_ text: String, take: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(text: trimmed, take: take, writtenAt: now())
        guard !trimmed.isEmpty, defaults.string(forKey: Key.lastTake) != take.uuidString,
              let data = try? JSONEncoder().encode(entry)
        else { return false }
        defaults.set(data, forKey: Key.pending)
        defaults.set(take.uuidString, forKey: Key.lastTake)
        return true
    }

    /// The fresh text waiting for the Insert key, if any. Reading it removes
    /// nothing: only `consume` and `discard` do.
    public var pending: PendingTranscript? {
        guard let entry = stored(), isFresh(entry) else { return nil }
        return PendingTranscript(text: entry.text, take: entry.take)
    }

    /// The person tapped Insert for `take`: its text, once, and removed. Nil
    /// when the store no longer holds that take (a newer one the app wrote
    /// meanwhile stays in place) or when it went stale.
    public func consume(take: UUID) -> String? {
        guard let entry = stored(), entry.take == take, removeIfStill(entry), isFresh(entry)
        else { return nil }
        return entry.text
    }

    /// The person tapped the discard key for `take`: drop it unread.
    public func discard(take: UUID) {
        guard let entry = stored(), entry.take == take else { return }
        removeIfStill(entry)
    }

    /// What the app is doing with the keyboard's take; `nil` clears it.
    public func setStatus(_ status: KeyboardTakeStatus?) {
        defaults.set(status?.rawValue, forKey: Key.status)
        defaults.set(status == nil ? nil : now(), forKey: Key.statusAt)
    }

    /// The app's status for the keyboard's take, or `nil` when none or stale.
    public var status: KeyboardTakeStatus? {
        guard let at = defaults.object(forKey: Key.statusAt) as? Date, now().timeIntervalSince(at) <= maxAge
        else { return nil }
        return defaults.string(forKey: Key.status).flatMap(KeyboardTakeStatus.init(rawValue:))
    }

    private func stored() -> Entry? {
        defaults.data(forKey: Key.pending).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    private func isFresh(_ entry: Entry) -> Bool {
        now().timeIntervalSince(entry.writtenAt) <= maxAge
    }

    /// Remove the entry only if the store still holds this take. Returns
    /// whether it did.
    @discardableResult
    private func removeIfStill(_ entry: Entry) -> Bool {
        guard stored()?.take == entry.take else { return false }
        defaults.removeObject(forKey: Key.pending)
        return true
    }
}
