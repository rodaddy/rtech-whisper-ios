import Foundation

/// One recording waiting for, or finished with, the hub relay.
public struct QueuedDictation: Codable, Sendable, Equatable, Identifiable {
    public enum State: Codable, Sendable, Equatable {
        /// Waiting to be sent. The WAV is on disk.
        case pending
        /// A send is in flight. The WAV is on disk.
        case sending
        /// The hub refused this recording for good (for example 413 or 415).
        /// The WAV is kept so nothing is lost.
        case failed(String)
        /// Transcribed. The WAV has been deleted.
        case done(String)
    }

    /// Where the text shown for this item came from.
    public enum Source: String, Codable, Sendable, Equatable {
        /// Apple's on-device recognizer, while the hub was unreachable.
        case onDevice
        /// Whisper, through the hub relay.
        case hub
    }

    public let id: UUID
    public let createdAt: Date
    public internal(set) var state: State
    public internal(set) var attempts: Int
    /// On-device text shown while the recording waits for the hub.
    public internal(set) var provisionalText: String? = nil
    /// Where `text` came from; `nil` while there is no text yet.
    public internal(set) var source: Source? = nil
    /// What the person typed over the shown text. Wins over everything else.
    public internal(set) var editedText: String? = nil
    /// The Whisper text that arrived after the person had edited; kept so
    /// nothing the hub produced is thrown away.
    public internal(set) var alternateText: String? = nil
    /// How long the recording ran, when the recorder knew.
    public internal(set) var durationMs: Int? = nil
    /// The Whisper text after AI cleanup, when cleanup changed it. Shown in
    /// place of Whisper's words; the history keeps both.
    public internal(set) var cleanedText: String? = nil
    /// Whether the finished text has been handed to the transcription
    /// history. `false` from the moment Whisper answers until the report;
    /// `nil` on items saved before this field existed, which were reported.
    public internal(set) var reported: Bool? = nil

    /// What Whisper heard, once the hub has answered; the person's edit never
    /// changes it. This is what the transcription history keeps as `rawText`.
    public var whisperText: String? {
        if case .done(let whisper) = state { return whisper }
        return nil
    }

    /// True when the stored cleaned text changed more than Whisper's edge
    /// whitespace, so a trim alone is stored but not labelled "cleaned up".
    /// Where the shown text came from, in words.
    public var sourceLabel: String {
        var isDone = false
        if case .done = state { isDone = true }
        return Self.sourceLabel(source: source, isDone: isDone, edited: editedText != nil, cleaned: wasCleaned)
    }

    /// The source label as a pure function. An on-device take reads "will
    /// update" only while it waits for the hub; a finished one is final (#492).
    /// An edit is never overwritten, so an edited item no longer "will update".
    public static func sourceLabel(source: Source?, isDone: Bool, edited: Bool, cleaned: Bool) -> String {
        switch source {
        case .onDevice?: edited ? "On-device, edited by you" : isDone ? "On-device" : "On-device, will update"
        case .hub?: edited ? "Whisper, edited by you" : cleaned ? "Whisper, cleaned up" : "Whisper"
        case nil: edited ? "Edited by you" : "No text yet"
        }
    }

    public var wasCleaned: Bool {
        guard let cleanedText, let whisperText else { return false }
        return ProcessedDictation(text: cleanedText, rawText: whisperText).wasCleaned
    }

    /// The text to show: the person's edit, else the cleaned Whisper text,
    /// else Whisper, else on-device.
    public var text: String? {
        if let editedText { return editedText }
        if case .done(let whisper) = state { return cleanedText ?? whisper }
        return provisionalText
    }
}

/// How a `drain` call ended.
public enum DrainResult: Sendable, Equatable {
    /// Nothing pending is left.
    case finished
    /// The hub was unreachable or busy; the item stays pending for the next drain.
    case stopped(HubError)
    /// Another drain was already running; this call did nothing.
    case alreadyDraining
}

/// Sends a recording to the relay. `TranscriptionClient.transcribe` in the app.
public typealias Transcribe = @Sendable (Data) async throws(HubError) -> Transcript

/// Recordings that have not reached the hub yet, persisted as one WAV file per
/// item plus `index.json` in `directory`, so a restart or a phone with no
/// signal loses nothing.
public actor DictationQueue {
    public static let indexName = "index.json"

    public nonisolated let directory: URL
    private let now: @Sendable () -> Date
    private var entries: [QueuedDictation] = []
    private var draining = false

    /// Load whatever `directory` already holds. An item left `sending` by a
    /// killed process goes back to `pending`, and a WAV missing from the index
    /// (a crash between the two writes) is picked up as pending.
    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        entries = Self.load(from: directory)
    }

    /// Persist a recording as pending and return its item.
    @discardableResult
    public func enqueue(_ wav: Data, durationMs: Int? = nil) throws -> QueuedDictation {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let item = QueuedDictation(id: UUID(), createdAt: now(), state: .pending, attempts: 0, durationMs: durationMs)
        try wav.write(to: wavURL(item.id), options: .atomic)
        entries.append(item)
        try persist()
        return item
    }

    /// Store on-device text for an item still waiting for the hub. Ignored
    /// once Whisper has answered, so a slow recognizer never overwrites it.
    public func setProvisional(_ id: UUID, text: String) {
        update(id) { item in
            if case .done = item.state { return }
            item.provisionalText = text
            item.source = .onDevice
        }
    }

    /// Finish a pending item with on-device text, as a hub answer would
    /// ("Transcribe on this iPhone"): it is reported, pushed, and never sent.
    public func complete(_ id: UUID, text: String) {
        guard let item = entries.first(where: { $0.id == id }), item.state == .pending else { return }
        update(id) { item in
            item.state = .done(text)
            item.reported = false
            item.provisionalText = nil
            item.source = .onDevice
        }
        try? FileManager.default.removeItem(at: wavURL(id))
    }

    /// Record what the person typed over the shown text.
    public func edit(_ id: UUID, text: String) {
        update(id) { $0.editedText = text }
    }

    /// Record the cleaned form of a finished dictation's Whisper text.
    public func setCleaned(_ id: UUID, text: String) {
        update(id) { item in
            guard case .done = item.state else { return }
            item.cleanedText = text
        }
    }

    /// Record that the item's finished text reached the transcription history.
    public func markReported(_ id: UUID) {
        update(id) { $0.reported = true }
    }

    /// Drop an item and its WAV, so a take not yet sent is never sent. The
    /// WAV goes first: a kill between the two writes leaves an entry with no
    /// file, which fails, never an orphan WAV, which would be picked up and sent.
    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: wavURL(id))
        entries.removeAll { $0.id == id }
        try? persist()
    }

    /// Every item, oldest first.
    public func items() -> [QueuedDictation] {
        entries
    }

    /// Send pending items oldest first, one at a time. Stops at the first
    /// network, upstream, rate-limit, or auth error and leaves that item
    /// pending; a permanent refusal marks the item failed and moves on.
    public func drain(using transcribe: Transcribe) async -> DrainResult {
        guard !draining else { return .alreadyDraining }
        draining = true
        defer { draining = false }

        while let index = nextPending() {
            let id = entries[index].id
            entries[index].state = .sending
            entries[index].attempts += 1
            try? persist()

            let wav: Data
            do {
                wav = try Data(contentsOf: wavURL(id))
            } catch {
                update(id) { $0.state = .failed("The recording file is missing.") }
                continue
            }

            do {
                let transcript = try await transcribe(wav)
                update(id) { item in
                    item.state = .done(transcript.text)
                    item.reported = false
                    if item.editedText != nil {
                        // The person edited the on-device text: keep their
                        // words and store Whisper's alongside.
                        item.alternateText = transcript.text
                    } else {
                        item.provisionalText = nil
                        item.source = .hub
                    }
                }
                try? FileManager.default.removeItem(at: wavURL(id))
            } catch {
                if let reason = Self.permanentFailureReason(error) {
                    update(id) { $0.state = .failed(reason) }
                } else {
                    update(id) { $0.state = .pending }
                    return .stopped(error)
                }
            }
        }
        return .finished
    }

    /// `nil` when the error is worth retrying later (the item stays pending);
    /// otherwise the reason the hub will never accept this recording.
    static func permanentFailureReason(_ error: HubError) -> String? {
        switch error {
        case .network, .upstreamUnavailable, .rateLimited, .unauthorized, .malformedKey:
            return nil
        case .tooLarge:
            return "The recording is larger than the hub accepts."
        case .unsupportedAudio:
            return "The hub did not accept the audio format."
        case .decoding:
            return "The hub sent a reply this app does not understand."
        case .server(let status, _, let message) where (400..<500).contains(status):
            return "The hub returned \(status)\(message.map { ": \($0)" } ?? ".")"
        case .server:
            return nil
        case .invalidRequest(let message):
            return "The hub returned 400\(message.map { ": \($0)" } ?? ".")"
        case .notFound:
            return "The hub returned 404."
        case .noteVersionConflict, .folderNameTaken, .snippetTriggerTaken:
            return "The hub returned 409."
        }
    }

    private func nextPending() -> Int? {
        entries.indices
            .filter { entries[$0].state == .pending }
            .min { entries[$0].createdAt < entries[$1].createdAt }
    }

    private func update(_ id: UUID, _ change: (inout QueuedDictation) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        try? persist()
    }

    private func wavURL(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).wav")
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: directory.appending(path: Self.indexName), options: .atomic)
    }

    private static func load(from directory: URL) -> [QueuedDictation] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries = (try? Data(contentsOf: directory.appending(path: indexName)))
            .flatMap { try? decoder.decode([QueuedDictation].self, from: $0) } ?? []
        for index in entries.indices where entries[index].state == .sending {
            entries[index].state = .pending
        }
        let known = Set(entries.map(\.id))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "wav" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !known.contains(id) else { continue }
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            entries.append(QueuedDictation(id: id, createdAt: created, state: .pending, attempts: 0))
        }
        return entries.sorted { $0.createdAt < $1.createdAt }
    }
}
