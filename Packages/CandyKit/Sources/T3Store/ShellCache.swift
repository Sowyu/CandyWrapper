import Foundation
import T3Protocol

/// The last shell snapshot per environment, as JSON in Application Support, so the sidebar
/// shows real data before the server answers. The resume cursor is the snapshot's
/// `snapshotSequence`.
///
/// Saves are debounced: `noteChanged` records the latest snapshot, and one sleeping task writes
/// it once changes have been quiet for `quietPeriod`. Nothing runs while nothing changes.
public actor ShellCache {
    public struct Entry: Codable, Sendable, Equatable {
        public static let currentVersion = 1
        public var version: Int
        public var environmentId: String
        public var savedAt: Date
        public var snapshot: ShellSnapshot

        public var afterSequence: Int { snapshot.snapshotSequence }
    }

    public nonisolated let directory: URL
    public nonisolated let quietPeriod: Duration
    private var pending: [String: ShellSnapshot] = [:]
    private var lastChange = ContinuousClock.now
    private var writer: Task<Void, Never>?

    /// `~/Library/Application Support/CandyWrapper/ShellCache`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CandyWrapper/ShellCache", directoryHint: .isDirectory)
    }

    public init(directory: URL = ShellCache.defaultDirectory, quietPeriod: Duration = .seconds(2)) {
        self.directory = directory
        self.quietPeriod = quietPeriod
    }

    public nonisolated func fileURL(environmentId: String) -> URL {
        // Environment ids are UUID-like; strip anything that could leave the directory.
        let safe = environmentId.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appending(path: String(safe) + ".json")
    }

    /// Reads synchronously; meant for app startup before connecting. Nil when absent, unreadable
    /// or from another format version.
    public nonisolated func load(environmentId: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(environmentId: environmentId)),
              let entry = try? Self.decoder.decode(Entry.self, from: data),
              entry.version == Entry.currentVersion, entry.environmentId == environmentId
        else { return nil }
        return entry
    }

    public func noteChanged(_ snapshot: ShellSnapshot, environmentId: String) {
        pending[environmentId] = snapshot
        lastChange = .now
        guard writer == nil else { return }
        writer = Task(priority: .utility) { await self.writeWhenQuiet() }
    }

    /// Writes anything pending now, for app quit.
    public func flush() {
        writer?.cancel()
        writer = nil
        writePending()
    }

    public func remove(environmentId: String) {
        pending[environmentId] = nil
        try? FileManager.default.removeItem(at: fileURL(environmentId: environmentId))
    }

    private func writeWhenQuiet() async {
        while !Task.isCancelled {
            let wait = lastChange + quietPeriod - .now
            if wait <= .zero { break }
            try? await Task.sleep(for: wait, tolerance: quietPeriod / 10)
        }
        guard !Task.isCancelled else { return }
        writer = nil
        writePending()
    }

    private func writePending() {
        let batch = pending
        pending = [:]
        guard !batch.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (environmentId, snapshot) in batch {
            let entry = Entry(version: Entry.currentVersion, environmentId: environmentId, savedAt: Date(), snapshot: snapshot)
            guard let data = try? Self.encoder.encode(entry) else { continue }
            try? data.write(to: fileURL(environmentId: environmentId), options: [.atomic])
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
