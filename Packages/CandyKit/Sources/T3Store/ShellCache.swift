import Foundation
import T3Protocol

/// The last shell snapshot per environment, as JSON in Application Support, so the sidebar
/// shows real data before the server answers. The resume cursor is the snapshot's
/// `snapshotSequence`.
///
/// Saves are debounced: `noteChanged` records the latest snapshot, and one sleeping task writes
/// it once changes have been quiet for `quietPeriod`. Nothing runs while nothing changes. Files are
/// written without a sync (`CacheFile`); one a power loss tore fails to decode, loads as nil, and the
/// next save replaces it.
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
    private var encoders: [String: ShellCacheEncoder] = [:]
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

    /// Starts `load` on a background thread, so the read and the decode overlap the app building its
    /// window. A 1,580-thread snapshot took 16 ms on the main thread warm and 50 ms cold on a 5400 rpm disk.
    public nonisolated func prefetch(environmentId: String) -> Prefetch {
        Prefetch(cache: self, environmentId: environmentId)
    }

    public final class Prefetch: @unchecked Sendable {
        public let environmentId: String
        private let done = DispatchSemaphore(value: 0)
        // Written once before `done` signals, read only after it.
        private var entry: Entry?

        init(cache: ShellCache, environmentId: String) {
            self.environmentId = environmentId
            // The main thread waits on this, so it runs at the main thread's priority.
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                entry = cache.load(environmentId: environmentId)
                done.signal()
            }
        }

        /// The loaded entry, waiting for the read if it still runs.
        public func take() -> Entry? {
            done.wait()
            done.signal()
            return entry
        }
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
        encoders[environmentId] = nil
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
            var encoder = encoders[environmentId] ?? ShellCacheEncoder()
            guard let data = try? encoder.encode(entry) else { continue }
            encoders[environmentId] = encoder
            try? CacheFile.write(data, to: fileURL(environmentId: environmentId))
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Stores only the latest snapshot's row encodings. Unchanged rows skip Codable on later saves.
/// The envelope remains the same JSON document that `ShellCache.Entry` reads.
struct ShellCacheEncoder {
    private var rows: [ThreadId: (ThreadShell, Data)] = [:]

    mutating func encode(_ entry: ShellCache.Entry,
                         encodeRow: ((ThreadShell) throws -> Data)? = nil) throws -> Data {
        struct Header: Encodable {
            var version: Int
            var environmentId: String
            var savedAt: Date
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(Header(version: entry.version, environmentId: entry.environmentId, savedAt: entry.savedAt))
        data.removeLast() // Open the header object to append the snapshot.
        let snapshot = entry.snapshot
        data.append(contentsOf: ",\"snapshot\":{\"schemaVersion\":\(snapshot.schemaVersion),\"snapshotSequence\":\(snapshot.snapshotSequence),\"projects\":".utf8)
        data.append(try encoder.encode(snapshot.projects))
        var retained: [ThreadId: (ThreadShell, Data)] = [:]
        func appendRows(_ values: [ThreadShell], key: String) throws {
            data.append(contentsOf: ",\"\(key)\":[".utf8)
            for (index, row) in values.enumerated() {
                if index > 0 { data.append(0x2c) }
                let encoded: Data
                if let cached = rows[row.id], cached.0 == row { encoded = cached.1 }
                else if let encodeRow { encoded = try encodeRow(row) }
                else { encoded = try encoder.encode(row) }
                data.append(encoded)
                retained[row.id] = (row, encoded)
            }
            data.append(0x5d)
        }
        try appendRows(snapshot.threads, key: "threads")
        try appendRows(snapshot.archivedThreads, key: "archivedThreads")
        data.append(contentsOf: "}}".utf8)
        rows = retained
        return data
    }
}
