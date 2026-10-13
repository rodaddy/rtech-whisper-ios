import Foundation
import SwiftData

/// An upload's progress, saved after every chunk so a relaunch carries on
/// from the first chunk not done instead of starting over (#86).
@Model
public final class SavedUpload {
    @Attribute(.unique) public var id: UUID
    /// The picked file's name, shown on the Upload screen.
    public var fileName: String
    /// The app's own copy of the file, by name inside `UploadSaving.directory`.
    public var copyName: String
    public var hint: String?
    /// `UploadCheckpoint.Status` raw value.
    public var status: String
    public var chunksDone: Int
    /// Samples in the chunks done: where the next chunk starts.
    public var sentSamples: Int
    public var expectedChunks: Int
    /// The hub's text for each chunk done, in order.
    public var texts: [String]
    public var allSilent: Bool
    public var createdAt: Date

    init(_ checkpoint: UploadCheckpoint, createdAt: Date) {
        id = checkpoint.id
        fileName = checkpoint.fileName
        copyName = checkpoint.copyName
        hint = checkpoint.hint
        status = checkpoint.status.rawValue
        chunksDone = checkpoint.chunksDone
        sentSamples = checkpoint.sentSamples
        expectedChunks = checkpoint.expectedChunks
        texts = checkpoint.texts
        allSilent = checkpoint.allSilent
        self.createdAt = createdAt
    }
}

/// A `Sendable` copy of a `SavedUpload`.
public struct UploadCheckpoint: Sendable, Equatable {
    public enum Status: String, Sendable {
        /// Chunks were being sent when it was saved; a relaunch finds it so when the app was killed.
        case sending
        /// The hub stopped it with an error a resend can get past.
        case stopped
        /// The file stopped being readable part-way (#156); the next
        /// foreground retries it from `sentSamples`.
        case truncated
        /// A retry of a truncated upload read no further than the pass before
        /// it: never retried again, only shown from its texts until removed.
        case partial
    }

    public var id: UUID
    public var fileName: String
    public var copyName: String
    public var hint: String?
    public var status: Status
    public var chunksDone: Int
    public var sentSamples: Int
    public var expectedChunks: Int
    public var texts: [String]
    public var allSilent: Bool

    public init(
        id: UUID, fileName: String, copyName: String, hint: String?, status: Status, chunksDone: Int,
        sentSamples: Int, expectedChunks: Int, texts: [String], allSilent: Bool
    ) {
        self.id = id
        self.fileName = fileName
        self.copyName = copyName
        self.hint = hint
        self.status = status
        self.chunksDone = chunksDone
        self.sentSamples = sentSamples
        self.expectedChunks = expectedChunks
        self.texts = texts
        self.allSilent = allSilent
    }

    init(_ row: SavedUpload) {
        self.init(
            id: row.id, fileName: row.fileName, copyName: row.copyName, hint: row.hint,
            status: Status(rawValue: row.status) ?? .sending, chunksDone: row.chunksDone,
            sentSamples: row.sentSamples, expectedChunks: row.expectedChunks, texts: row.texts,
            allSilent: row.allSilent)
    }
}

/// Unfinished uploads on this phone. Never synced: it only lets an upload
/// outlive the process.
@ModelActor
public actor UploadStore {
    public static let schema = Schema([SavedUpload.self])

    /// `uploads.store` in the app's support directory unless `url` says otherwise.
    public static func persistent(url: URL? = nil) throws -> UploadStore {
        let config =
            url.map { ModelConfiguration("uploads", schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration("uploads", schema: schema, cloudKitDatabase: .none)
        return UploadStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// A store that lives only in memory, for tests and previews.
    public static func inMemory() throws -> UploadStore {
        let config = ModelConfiguration("uploads", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return UploadStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// Saves `checkpoint` over any earlier one with its id.
    public func save(_ checkpoint: UploadCheckpoint) throws {
        if let row = try row(checkpoint.id) {
            row.status = checkpoint.status.rawValue
            row.chunksDone = checkpoint.chunksDone
            row.sentSamples = checkpoint.sentSamples
            row.expectedChunks = checkpoint.expectedChunks
            row.texts = checkpoint.texts
            row.allSilent = checkpoint.allSilent
        } else {
            modelContext.insert(SavedUpload(checkpoint, createdAt: Date()))
        }
        try modelContext.save()
    }

    /// Every unfinished upload, oldest first.
    public func unfinished() throws -> [UploadCheckpoint] {
        try modelContext.fetch(FetchDescriptor<SavedUpload>(sortBy: [SortDescriptor(\.createdAt)]))
            .map(UploadCheckpoint.init)
    }

    public func delete(_ id: UUID) throws {
        guard let row = try row(id) else { return }
        modelContext.delete(row)
        try modelContext.save()
    }

    private func row(_ id: UUID) throws -> SavedUpload? {
        try modelContext.fetch(FetchDescriptor<SavedUpload>(predicate: #Predicate { $0.id == id })).first
    }
}

/// Where an upload is kept across launches: its checkpoints and a copy of
/// its file, since a picked file's URL does not outlive the process.
public struct UploadSaving: Sendable {
    public let store: UploadStore
    /// Holds one copy per unfinished upload, named by its id.
    public let directory: URL

    public init(store: UploadStore, directory: URL) {
        self.store = store
        self.directory = directory
    }

    /// The app's store, and `Uploads` in Application Support, kept out of backups.
    public static func persistent() throws -> UploadSaving {
        var directory = URL.applicationSupportDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return UploadSaving(store: try UploadStore.persistent(), directory: directory)
    }

    /// Where `adopt` copies `url` for the upload `id`.
    func copy(of url: URL, id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(url.pathExtension)")
    }

    /// Copies the picked file into `directory` as `id`, off the main actor.
    /// A copy that fails part-way is removed, so no partial file is left.
    func adopt(_ url: URL, id: UUID) async throws -> URL {
        let copy = self.copy(of: url, id: id)
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.copyItem(at: url, to: copy)
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
        }.value
        return copy
    }

    /// The copy a checkpoint names.
    func copy(_ checkpoint: UploadCheckpoint) -> URL {
        directory.appending(path: checkpoint.copyName)
    }

    /// Deletes an upload's checkpoint, then its copy. A checkpoint that
    /// could not be deleted keeps its copy, so a relaunch still reads it; a
    /// copy left without a checkpoint is removed by `sweep`.
    func forget(id: UUID, copy: URL) async throws {
        try await store.delete(id)
        try? FileManager.default.removeItem(at: copy)
    }

    /// Removes every file in `directory` not named in `keeping`: copies
    /// no checkpoint names, left by a kill before the first checkpoint was
    /// saved or a copy that failed part-way. Returns how many it removed.
    @discardableResult
    func sweep(keeping: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where !keeping.contains(file.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
