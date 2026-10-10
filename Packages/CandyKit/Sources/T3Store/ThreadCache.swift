import Foundation
import T3Protocol

/// Settled thread snapshots on disk, so a cold open paints before the network answers and then
/// resumes the stream after the cached sequence instead of downloading the thread again.
///
/// T3 keeps the same cache in IndexedDB (`t3code:connection-runtime`, store `thread`, key
/// `environmentId:threadId`; apps/web/src/connection/storage.ts:368, 782-830): the snapshot
/// sequence, the projection and the history cursor, written only while no run is active and only
/// for the bounded window, never after older pages were loaded (threads.ts:90-120). Writes go
/// through a sliding queue: the first 500 ms after a change, then at most one per 10 s, the newest
/// snapshot winning (cachePersistence.ts). A thread's deletion removes its entry and removing an
/// environment clears all of its entries. T3 has no size limit; this cache has one.
///
/// One file per thread, `<dir>/<environment>/<thread>.lzfse`: the typed projection as JSON,
/// without the turn items the visible rows already carry (like the server's compact snapshot),
/// LZFSE compressed. Nothing stays in memory: a file is read, decoded and dropped when its thread
/// opens. The projection holds no credentials; tokens live in the Keychain.
public actor ThreadCache {
    public static let currentVersion = 1

    public struct Key: Hashable, Sendable {
        public var environmentId: String
        public var threadId: ThreadId
        public init(environmentId: String, threadId: ThreadId) {
            self.environmentId = environmentId
            self.threadId = threadId
        }
    }

    /// What one file holds.
    struct Stored: Codable {
        var version: Int
        var environmentId: String
        var threadId: ThreadId
        var snapshotSequence: Int
        /// The window's paging state. The app always asks for bounded snapshots, so like T3
        /// (`snapshotToPersist`) it always keeps it.
        var historyCursor: String?
        var hasMoreHistory: Bool
        var latestLocalTurnOrdinal: Int?
        var projection: ThreadProjection
    }

    public nonisolated let directory: URL
    /// Total bytes on disk; the least recently used files go first.
    public nonisolated let maxBytes: Int
    /// A thread whose compressed snapshot is bigger is not cached.
    public nonisolated let maxEntryBytes: Int
    public nonisolated let firstWriteDelay: Duration
    public nonisolated let writeInterval: Duration

    private var pending: [Key: Stored] = [:]
    private var writer: Task<Void, Never>?

    /// `~/Library/Application Support/CandyWrapper/ThreadCache`.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CandyWrapper/ThreadCache", directoryHint: .isDirectory)
    }

    /// The app's cache: `CANDY_THREAD_CACHE` names another directory (perf runs), `off` turns it off.
    public static func forApp() -> ThreadCache? {
        switch ProcessInfo.processInfo.environment["CANDY_THREAD_CACHE"] {
        case "off": nil
        case let path? where !path.isEmpty: ThreadCache(directory: URL(filePath: path, directoryHint: .isDirectory))
        default: ThreadCache()
        }
    }

    // ponytail: fixed 32 MB total and 8 MB per thread on disk; a 900-run thread's window compresses to about 1 MB. Make it a setting if users keep many huge threads
    public init(directory: URL = ThreadCache.defaultDirectory, maxBytes: Int = 32 << 20, maxEntryBytes: Int = 8 << 20,
                firstWriteDelay: Duration = .milliseconds(500), writeInterval: Duration = .seconds(10)) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxEntryBytes = maxEntryBytes
        self.firstWriteDelay = firstWriteDelay
        self.writeInterval = writeInterval
    }

    public nonisolated func fileURL(_ key: Key) -> URL {
        directory.appending(path: Self.safe(key.environmentId), directoryHint: .isDirectory)
            .appending(path: Self.safe(key.threadId.rawValue) + ".lzfse")
    }

    /// Ids are UUID-like; anything else becomes `_`. Two ids that collide here fail the header
    /// check on load, so they only cost a miss.
    private static func safe(_ id: String) -> String {
        String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "_" })
    }

    // MARK: Reading

    /// The cached snapshot, decoded on the caller's thread; nil when absent, unreadable or from
    /// another format. A bad file is removed. Marks the file as recently used.
    public nonisolated func load(_ key: Key) -> ThreadDetailSnapshot? {
        let url = fileURL(key)
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let data = try? (mapped as NSData).decompressed(using: .lzfse) as Data,
              let stored = try? JSONValue(parsing: data).decode(as: Stored.self),
              stored.version == Self.currentVersion, stored.environmentId == key.environmentId, stored.threadId == key.threadId
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        // The reducer puts the rows' items back into `turnItems` (`restoringLocalVisibleTurnItems`).
        return ThreadDetailSnapshot(
            snapshotSequence: stored.snapshotSequence, projection: stored.projection,
            historyCursor: Tristate(stored.historyCursor), hasMoreHistory: stored.hasMoreHistory,
            latestLocalTurnOrdinal: Tristate(stored.latestLocalTurnOrdinal), turnItemsOmitLocalVisible: true)
    }

    // MARK: Writing

    /// Whether T3 would persist this state (`shouldPersistThread`, threads.ts:110-121): no run
    /// preparing, starting or running, and no older pages merged into the window.
    public static func shouldPersist(_ projection: ThreadProjection, history: ThreadHistoryMeta) -> Bool {
        !history.expanded && !projection.runs.contains { $0.status == .preparing || $0.status == .starting || $0.status == .running }
    }

    /// Queues the newest snapshot of a thread. The first write comes `firstWriteDelay` after a
    /// quiet cache, later ones at most every `writeInterval`; the newest snapshot per thread wins.
    public func offer(_ key: Key, sequence: Int, projection: ThreadProjection, history: ThreadHistoryMeta) {
        // Offers come from separate tasks; an older one never replaces a newer one.
        if let queued = pending[key], queued.snapshotSequence > sequence { return }
        pending[key] = Stored(
            version: Self.currentVersion, environmentId: key.environmentId, threadId: key.threadId, snapshotSequence: sequence,
            historyCursor: history.historyCursor, hasMoreHistory: history.hasMoreHistory,
            latestLocalTurnOrdinal: history.latestLocalTurnOrdinal, projection: projection)
        guard writer == nil else { return }
        writer = Task { await self.drain() }
    }

    /// Writes a thread's queued snapshot now (its view closed).
    public func flush(_ key: Key) {
        guard let stored = pending.removeValue(forKey: key) else { return }
        write(stored, to: key)
    }

    /// Forgets a thread (it was deleted).
    public func remove(_ key: Key) {
        pending[key] = nil
        try? FileManager.default.removeItem(at: fileURL(key))
    }

    /// Forgets every thread of an environment (it was removed from this device).
    public func removeEnvironment(_ environmentId: String) {
        pending = pending.filter { $0.key.environmentId != environmentId }
        try? FileManager.default.removeItem(at: directory.appending(path: Self.safe(environmentId), directoryHint: .isDirectory))
    }

    private func drain() async {
        try? await Task.sleep(for: firstWriteDelay)
        while !pending.isEmpty {
            let batch = pending
            pending = [:]
            for (key, stored) in batch { write(stored, to: key) }
            try? await Task.sleep(for: writeInterval)
        }
        writer = nil
    }

    private func write(_ stored: Stored, to key: Key) {
        let url = fileURL(key)
        var compact = stored
        // The rows carry their own items; a load puts them back (`restoringLocalVisibleTurnItems`).
        let threadId = stored.projection.thread.id
        let local = Set(stored.projection.visibleTurnItems.lazy.filter { $0.isLocal || $0.sourceThreadId == threadId }.map(\.item.id))
        compact.projection.turnItems.removeAll { local.contains($0.id) }
        guard let json = try? Self.encoder.encode(compact),
              let data = try? (json as NSData).compressed(using: .lzfse) as Data
        else { return }
        guard data.count <= maxEntryBytes else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        evict()
    }

    /// Removes the least recently used files until the cache fits in `maxBytes`.
    private func evict() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private static let encoder = JSONEncoder()
}
