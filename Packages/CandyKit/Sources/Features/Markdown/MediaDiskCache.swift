import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Host files that replies show, kept on this Mac so a picture seen once never downloads again. Each entry is keyed by
/// environment and absolute path and remembers the server's `fileRevision` (dev:ino:size:mtime:ctime,
/// apps/server/src/assets/AssetAccess.ts:440) or, from servers without it, the route's weak ETag (size and mtime,
/// apps/server/src/http.ts:257). A changed revision drops the entry and the file downloads again.
///
/// Layout: `<root>/<sha256>.bin` (the original bytes), `<root>/<sha256>.thumb` (the decoded picture at the size the
/// timeline last drew it, HEIC) and `<root>/index.json`. Everything runs off the main thread.
// ponytail: whole index rewritten (debounced) on each change, a few hundred bytes per file; SQLite if it holds thousands
public actor MediaDiskCache {
    public struct Entry: Codable, Equatable, Sendable {
        public var scope: String
        public var path: String
        public var revision: String?
        public var etag: String?
        public var width: Double
        public var height: Double
        public var bytes: Int64
        public var thumbSide: Int = 0
        public var thumbBytes: Int64 = 0
        public var lastUse: Double
        var natural: CGSize { CGSize(width: width, height: height) }
    }

    /// Set by the app with its caches folder; nil in previews and in tests that don't build one.
    nonisolated(unsafe) public static var shared: MediaDiskCache?

    public let root: URL
    let capBytes: Int64
    private(set) var entries: [String: Entry] = [:]
    /// Natural sizes by `media-file:<path>`, read at launch, so a reply lays out at its pictures' ratio from the first pass.
    public nonisolated let launchSizes: [String: CGSize]
    private let now: @Sendable () -> Double
    private var saveScheduled = false
    /// Thumbnails stop at this side; larger requests (the viewer) decode the original.
    static let thumbMaxSide = 1600

    // ponytail: 500 MB cap, least recently shown first; a setting if people keep very long image threads
    public init(root: URL, capBytes: Int64 = 500 << 20, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.root = root
        self.capBytes = capBytes
        self.now = now
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            loaded = decoded
        }
        entries = loaded
        var sizes: [String: CGSize] = [:]
        for entry in loaded.values where entry.width > 0 && entry.height > 0 { sizes["media-file:" + entry.path] = entry.natural }
        launchSizes = sizes
    }

    public static func key(scope: String, path: String) -> String {
        SHA256.hash(data: Data("\(scope)\n\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(_ key: String) -> URL { root.appendingPathComponent(key + ".bin") }
    func thumbURL(_ key: String) -> URL { root.appendingPathComponent(key + ".thumb") }

    /// The kept file and its entry, marked as just used. Nil when there is none or its file went missing.
    func lookup(_ key: String) -> (file: URL, entry: Entry)? {
        guard var entry = entries[key] else { return nil }
        let url = fileURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { remove(key); return nil }
        entry.lastUse = now()
        entries[key] = entry
        scheduleSave()
        return (url, entry)
    }

    func entry(_ key: String) -> Entry? { entries[key] }

    /// The kept thumbnail when it is at least `side` pixels on its longer side.
    func thumbnail(_ key: String, side: Int) -> (url: URL, entry: Entry)? {
        guard var entry = entries[key], entry.thumbSide >= min(side, Self.thumbMaxSide), side <= Self.thumbMaxSide else { return nil }
        let url = thumbURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            entry.thumbSide = 0; entry.thumbBytes = 0; entries[key] = entry
            return nil
        }
        entry.lastUse = now()
        entries[key] = entry
        scheduleSave()
        return (url, entry)
    }

    /// Moves a downloaded file into the cache and returns its kept location.
    @discardableResult
    func store(_ key: String, scope: String, path: String, file: URL, revision: String?, etag: String?, natural: CGSize?) -> URL? {
        let target = fileURL(key)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The download first moves next to the kept file, which copies when the temporary folder is on another volume
        // (`replaceItemAt` fails there), then `rename` swaps it in. A download that is gone or will not copy leaves the
        // kept file as it was. `sweep` removes a staged file a crash left: no entry has its name.
        let staged = root.appendingPathComponent("incoming-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: file, to: staged)
        } catch {
            return nil
        }
        guard rename(staged.path, target.path) == 0 else {
            try? FileManager.default.moveItem(at: staged, to: file)
            return nil
        }
        try? FileManager.default.removeItem(at: thumbURL(key))
        let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        entries[key] = Entry(scope: scope, path: path, revision: revision, etag: etag,
                             width: Double(natural?.width ?? 0), height: Double(natural?.height ?? 0), bytes: bytes, lastUse: now())
        prune(keeping: key)
        scheduleSave()
        return target
    }

    func setNatural(_ key: String, _ natural: CGSize) {
        guard var entry = entries[key], entry.natural != natural else { return }
        entry.width = natural.width; entry.height = natural.height
        entries[key] = entry
        scheduleSave()
    }

    /// Keeps the picture the timeline decoded, so the next open draws it without decoding the original.
    func storeThumbnail(_ key: String, image: CGImage, side: Int) {
        guard var entry = entries[key], side <= Self.thumbMaxSide, side > entry.thumbSide else { return }
        let url = thumbURL(key)
        let tmp = root.appendingPathComponent(key + ".thumb-" + UUID().uuidString)
        guard let destination = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: tmp); return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try? FileManager.default.removeItem(at: tmp)
        entry.thumbSide = side
        entry.thumbBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        entries[key] = entry
        prune(keeping: key)
        scheduleSave()
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(key))
        try? FileManager.default.removeItem(at: thumbURL(key))
        entries[key] = nil
        scheduleSave()
    }

    public var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes + $1.thumbBytes } }

    /// "Clear image cache": every kept file and thumbnail.
    public func clear() {
        for key in entries.keys {
            try? FileManager.default.removeItem(at: fileURL(key))
            try? FileManager.default.removeItem(at: thumbURL(key))
        }
        entries = [:]
        save()
    }

    /// Removes files no entry names: left by a quit before the index was saved.
    public func sweep() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name != "index.json" {
            let id = String(name.prefix(while: { $0 != "." }))
            if entries[id] == nil || name.contains(".thumb-") { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        }
    }

    /// Least recently used files go first until the total fits the cap. `keeping` is the file just stored.
    private func prune(keeping: String) {
        var total = totalBytes
        guard total > capBytes else { return }
        for (key, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) where total > capBytes && key != keeping {
            try? FileManager.default.removeItem(at: fileURL(key))
            try? FileManager.default.removeItem(at: thumbURL(key))
            entries[key] = nil
            total -= entry.bytes + entry.thumbBytes
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            self.save()
        }
    }

    func save() {
        saveScheduled = false
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic) }
    }
}
