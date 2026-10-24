import Foundation
import SpaceCrypto
import SpaceModel

struct CacheEntry: Codable, Equatable {
    var bytes: UInt64
    var access: UInt64
}

struct CacheIndex: Codable {
    var clock: UInt64 = 0
    var entries: [String: CacheEntry] = [:]

    var bytes: UInt64 { entries.values.reduce(0) { $0 + $1.bytes } }

    /// Stable ties also make recovery independent of FileManager's directory enumeration order.
    func oldestFirst() -> [String] {
        entries.keys.sorted {
            let a = entries[$0]!.access, b = entries[$1]!.access
            return a == b ? $0 < $1 : a < b
        }
    }

    mutating func touch(_ id: String) {
        if clock == UInt64.max {
            for (n, id) in oldestFirst().enumerated() { entries[id]!.access = UInt64(n) }
            clock = UInt64(entries.count)
        }
        clock += 1
        entries[id]!.access = clock
    }
}

extension SpaceLocalStore {
    public func cachedBlobBytes() throws -> UInt64 {
        try requireHealthy()
        return cache.bytes
    }

    /// Accept original bytes, never a decrypted temporary file. The keyed id is checked before caching.
    /// The cache counts actual ciphertext bytes, including base64 and authentication overhead.
    public func cacheBlob(_ plaintext: Data, id: String) throws {
        try requireHealthy()
        try Self.checkBlobID(id)
        guard disk.keys.blobId(of: plaintext) == id else { throw SpaceCryptoError.authenticationFailed }
        let size = Self.encodedBlobSize(plaintext.count)
        guard size <= cacheLimit else { throw SpaceLocalError.blobTooLarge }
        if cache.entries[id] != nil {
            _ = try cachedBlob(id: id)
            return
        }
        do {
            // Delete first, then stage the new ciphertext. Neither a temp nor an orphan can exceed
            // the cap. Blobs are disposable; a crash may cause a miss, never a partial blob hit.
            for oldest in cache.oldestFirst() {
                if cache.bytes <= cacheLimit - size { break }
                try disk.remove("blobs/\(oldest).cws")
                cache.entries.removeValue(forKey: oldest)
            }
            try persistCache()
            var encrypted = Data()
            let count = max(1, (plaintext.count + SpaceKeys.blobChunkSize - 1) / SpaceKeys.blobChunkSize)
            for n in 0..<count {
                let start = plaintext.startIndex + n * SpaceKeys.blobChunkSize
                let end = min(start + SpaceKeys.blobChunkSize, plaintext.endIndex)
                encrypted.append(try disk.seal(Data(plaintext[start..<end]), purpose: Self.blobPurpose(id, n, n == count - 1)))
                encrypted.append(0x0a)
            }
            try disk.atomicWrite(encrypted, to: "blobs/\(id).cws")
            cache.entries[id] = CacheEntry(bytes: UInt64(encrypted.count), access: 0)
            cache.touch(id)
            try persistCache()
        } catch {
            failed = true
            throw error
        }
    }

    /// A missing cache entry is normal. A present entry that fails authentication is an error.
    public func cachedBlob(id: String) throws -> Data? {
        try requireHealthy()
        try Self.checkBlobID(id)
        guard let entry = cache.entries[id] else { return nil }
        let bytes = try disk.read("blobs/\(id).cws")
        guard UInt64(bytes.count) == entry.bytes, bytes.last == 0x0a else { throw SpaceLocalError.corruptStore }
        let lines = bytes.split(separator: 0x0a, omittingEmptySubsequences: false).dropLast()
        guard !lines.isEmpty else { throw SpaceLocalError.corruptStore }
        var plaintext = Data()
        for (n, line) in lines.enumerated() {
            let last = n == lines.count - 1
            let chunk = try disk.open(Data(line), purpose: Self.blobPurpose(id, n, last))
            guard chunk.count <= SpaceKeys.blobChunkSize, last || chunk.count == SpaceKeys.blobChunkSize else {
                throw SpaceLocalError.corruptStore
            }
            plaintext.append(chunk)
        }
        guard disk.keys.blobId(of: plaintext) == id else { throw SpaceCryptoError.authenticationFailed }
        cache.touch(id)
        do { try persistCache() } catch { failed = true; throw error }
        return plaintext
    }

    private func persistCache() throws {
        try disk.atomicWrite(disk.seal(SpaceJSON.encode(cache), purpose: "cache"), to: "cache.cws")
    }

    static func checkBlobID(_ id: String) throws {
        guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SpaceLocalError.invalidBlobID
        }
    }

    static func blobPurpose(_ id: String, _ n: Int, _ last: Bool) -> String { "blob|\(id)|\(n)|\(last)" }

    static func encodedBlobSize(_ plaintext: Int) -> UInt64 {
        let full = plaintext / SpaceKeys.blobChunkSize
        let remainder = plaintext % SpaceKeys.blobChunkSize
        func encoded(_ n: Int) -> UInt64 { UInt64(4 * ((n + 28 + 2) / 3) + 1) }
        if plaintext == 0 { return encoded(0) }
        return UInt64(full) * encoded(SpaceKeys.blobChunkSize) + (remainder == 0 ? 0 : encoded(remainder))
    }

    static func loadCache(_ disk: SpaceDisk, limit: UInt64) throws -> CacheIndex {
        var index = disk.exists("cache.cws")
            ? try SpaceJSON.decode(CacheIndex.self, from: disk.open(disk.read("cache.cws"), purpose: "cache"))
            : CacheIndex()
        var changed = !disk.exists("cache.cws")
        for id in Array(index.entries.keys) {
            try checkBlobID(id)
            guard let entry = index.entries[id], entry.bytes <= SpaceLocalStore.blobCacheLimit,
                  entry.access <= index.clock else { throw SpaceLocalError.corruptStore }
            let path = "blobs/\(id).cws"
            if !disk.exists(path) {
                index.entries.removeValue(forKey: id)
                changed = true
            } else if try disk.size(path) != entry.bytes {
                throw SpaceLocalError.corruptStore
            }
        }
        for file in try FileManager.default.contentsOfDirectory(at: disk.url("blobs"), includingPropertiesForKeys: nil) {
            let id = file.deletingPathExtension().lastPathComponent
            if index.entries[id] == nil || file.pathExtension != "cws" {
                try disk.remove("blobs/" + file.lastPathComponent)
            }
        }
        for id in index.oldestFirst() {
            if index.bytes <= limit { break }
            try disk.remove("blobs/\(id).cws")
            index.entries.removeValue(forKey: id)
            changed = true
        }
        if changed {
            try disk.atomicWrite(disk.seal(SpaceJSON.encode(index), purpose: "cache"), to: "cache.cws")
        }
        return index
    }
}
