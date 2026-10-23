import Foundation
import CryptoKit
import T3Protocol

/// CandyWrapper's own copy of the images agents viewed, for when their files are gone. Agents often look at
/// screenshots in temp files they overwrite or delete right away, and T3 keeps no bytes for Claude's Read of an image:
/// its `{type: "image", file: {...}}` output isn't a block `readToolOutputImage` recognises
/// (packages/shared/src/toolOutput.ts:227-238), so ingest strips it (apps/server/src/orchestration-v2/toolOutputImageBytes.ts:105-119,
/// ProviderEventIngestor.ts:640).
///
/// Layout: `<root>/<environment>/<sha256>.<ext>`, one file per content, and `<root>/index.json` mapping
/// `environment|thread|item` to the content's hash. Everything runs off the main thread.
// ponytail: whole index rewritten on each change (a few hundred bytes per image); a SQLite table if it reaches thousands
public actor AgentImageCache {
    public struct Entry: Codable, Equatable, Sendable { public var hash: String; public var ext: String }
    struct FileInfo: Codable, Equatable { var size: Int64; var lastView: Double }
    struct Index: Codable, Equatable {
        var items: [String: Entry] = [:]
        /// By `<environment>/<hash>.<ext>`.
        var files: [String: FileInfo] = [:]
    }

    /// Set by the app with its caches folder; nil in previews and tests that don't build one.
    nonisolated(unsafe) public static var shared: AgentImageCache?

    let root: URL
    let capBytes: Int64
    private(set) var index = Index()
    private let now: @Sendable () -> Double

    // ponytail: 500 MB cap, least recently viewed first; a setting if people keep long screenshot sessions
    public init(root: URL, capBytes: Int64 = 500 << 20, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.root = root
        self.capBytes = capBytes
        self.now = now
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            self.index = index
        }
    }

    static func itemKey(_ env: String, _ thread: String, _ item: String) -> String { "\(env)|\(thread)|\(item)" }
    static func safe(_ env: String) -> String { env.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
    private func fileKey(_ env: String, _ entry: Entry) -> String { "\(Self.safe(env))/\(entry.hash).\(entry.ext)" }
    private func url(of fileKey: String) -> URL { root.appendingPathComponent(fileKey) }

    public func entry(env: String, thread: String, item: String) -> Entry? { index.items[Self.itemKey(env, thread, item)] }

    /// The kept copy, marked as just viewed. Nil when there is none or its file went missing.
    public func url(env: String, thread: String, item: String) -> URL? {
        guard let entry = entry(env: env, thread: thread, item: item) else { return nil }
        let key = fileKey(env, entry)
        let url = url(of: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index.files[key] = nil
            index.items[Self.itemKey(env, thread, item)] = nil
            save()
            return nil
        }
        index.files[key]?.lastView = now()
        return url
    }

    /// Every kept item of one environment and thread, by item id, with its content hash.
    public func entries(env: String, thread: String) -> [String: Entry] {
        let prefix = Self.itemKey(env, thread, "")
        var out: [String: Entry] = [:]
        for (key, entry) in index.items where key.hasPrefix(prefix) { out[String(key.dropFirst(prefix.count))] = entry }
        return out
    }

    /// Keeps `data` for an item: one file per content, however many items show it. Returns the content's entry.
    @discardableResult
    public func store(env: String, thread: String, item: String, data: Data, ext: String) -> Entry {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = Entry(hash: hash, ext: ext.lowercased().isEmpty ? "img" : ext.lowercased())
        let key = fileKey(env, entry)
        let url = url(of: key)
        if index.files[key] == nil || !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        index.files[key] = FileInfo(size: Int64(data.count), lastView: now())
        index.items[Self.itemKey(env, thread, item)] = entry
        prune()
        save()
        return entry
    }

    /// Copies a file that still exists. Nil when it is gone, unreadable or over 50 MB.
    @discardableResult
    public func capture(env: String, thread: String, item: String, file: URL) -> Entry? {
        if let kept = entry(env: env, thread: thread, item: item) { return kept }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
              size.int64Value > 0, size.int64Value <= 50 << 20, let data = try? Data(contentsOf: file) else { return nil }
        return store(env: env, thread: thread, item: item, data: data, ext: file.pathExtension)
    }

    /// Drops what deleted threads kept: every item of `env` whose thread is not in `threads`.
    public func keepOnly(env: String, threads: Set<String>) {
        let prefix = env + "|"
        let before = index.items.count
        index.items = index.items.filter { key, _ in
            guard key.hasPrefix(prefix) else { return true }
            let thread = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            return threads.contains(thread)
        }
        guard index.items.count != before else { return }
        removeUnreferenced()
        save()
    }

    /// Least recently viewed files go first until the total fits the cap; their items go with them.
    private func prune() {
        var total = index.files.values.reduce(0) { $0 + $1.size }
        guard total > capBytes else { return }
        for (key, info) in index.files.sorted(by: { $0.value.lastView < $1.value.lastView }) where total > capBytes {
            try? FileManager.default.removeItem(at: url(of: key))
            index.files[key] = nil
            total -= info.size
        }
        let live = Set(index.files.keys)
        index.items = index.items.filter { key, entry in
            live.contains(fileKey(String(key.split(separator: "|").first ?? ""), entry))
        }
    }

    private func removeUnreferenced() {
        let used = Set(index.items.map { key, entry in fileKey(String(key.split(separator: "|").first ?? ""), entry) })
        for key in index.files.keys where !used.contains(key) {
            try? FileManager.default.removeItem(at: url(of: key))
            index.files[key] = nil
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic) }
    }

    /// The image's file extension from its bytes, for copies fetched without a name.
    public static func imageExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12, bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return "img"
    }
}

extension AgentImageCache {
    /// A remote environment's file, fetched once through the same signed asset URL the gallery loads it with.
    public func keepRemote(env: String, thread: String, item: String, resource: JSONValue) async -> Entry? {
        if let kept = entry(env: env, thread: thread, item: item) { return kept }
        guard let asset = await MarkdownImages.signedURL(resource: resource),
              let file = await MarkdownImageDownload.fetch(asset.url) else { return nil }
        let data = withExtendedLifetime(file) { try? Data(contentsOf: file.url) }
        guard let data, !data.isEmpty, data.count <= 50 << 20 else { return nil }
        return store(env: env, thread: thread, item: item, data: data, ext: Self.imageExtension(data))
    }
}
