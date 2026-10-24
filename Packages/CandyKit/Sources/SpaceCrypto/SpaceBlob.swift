import CryptoKit
import Foundation

// Blobs (docs/space.md, section 7): named by an HMAC of their bytes, encrypted in 1 MiB chunks whose AAD
// `cws1|<spaceId>|<blobId>|<n>|<last>` pins each chunk's place, so chunks can't be reordered or cut short.

public struct SpaceBlobChunk: Sendable, Equatable {
    /// Counts from 0.
    public var n: Int
    public var last: Bool
    public var ct: String
    public init(n: Int, last: Bool, ct: String) {
        self.n = n
        self.last = last
        self.ct = ct
    }
}

extension SpaceKeys {
    public static let blobChunkSize = 1 << 20

    /// HMAC-SHA256 of the bytes under the blob-id key, as lowercase hex.
    public func blobId(of data: some DataProtocol) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: blobId).map { String(format: "%02x", $0) }.joined()
    }

    /// Every chunk of `data`. An empty blob is one empty last chunk. Large uploads can call `sealBlobChunk`
    /// per chunk instead to hold one at a time.
    public func sealBlob(_ data: Data, blobId: String) throws -> [SpaceBlobChunk] {
        let size = Self.blobChunkSize
        let count = max(1, (data.count + size - 1) / size)
        return try (0..<count).map { n in
            let start = data.startIndex + n * size
            let piece = data[start..<min(start + size, data.endIndex)]
            let last = n == count - 1
            return SpaceBlobChunk(n: n, last: last, ct: try sealBlobChunk(piece, blobId: blobId, n: n, last: last))
        }
    }

    public func sealBlobChunk(_ plaintext: some DataProtocol, blobId: String, n: Int, last: Bool) throws -> String {
        try SpaceEnvelope.seal(plaintext, key: blob, aad: blobAAD(blobId: blobId, n: n, last: last))
    }

    func openBlobChunk(_ ct: String, blobId: String, n: Int, last: Bool) throws -> Data {
        try SpaceEnvelope.open(ct, key: blob, aad: blobAAD(blobId: blobId, n: n, last: last))
    }

    func blobAAD(blobId: String, n: Int, last: Bool) throws -> Data {
        guard blobId.utf8.count == 64, blobId.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              n >= 0 else { throw SpaceCryptoError.badIdentifier }
        return Data("cws1|\(spaceId)|\(blobId)|\(n)|\(last)".utf8)
    }
}

/// Opens a blob's chunks as they arrive. It decrypts each one at the place it expects next, so a reordered,
/// repeated or missing chunk fails, and `finish` fails until the last chunk has arrived.
public struct SpaceBlobReader: Sendable {
    public let keys: SpaceKeys
    public let blobId: String
    public private(set) var next = 0
    public private(set) var isComplete = false

    public init(keys: SpaceKeys, blobId: String) {
        self.keys = keys
        self.blobId = blobId
    }

    public mutating func open(_ chunk: SpaceBlobChunk) throws -> Data {
        guard !isComplete, chunk.n == next else { throw SpaceCryptoError.blobChunkOutOfOrder }
        let plaintext = try keys.openBlobChunk(chunk.ct, blobId: blobId, n: next, last: chunk.last)
        next += 1
        isComplete = chunk.last
        return plaintext
    }

    public func finish() throws {
        guard isComplete else { throw SpaceCryptoError.blobTruncated }
    }

    /// The whole blob, checked against its id so a valid but different blob can't stand in for it.
    public static func openAll(_ chunks: [SpaceBlobChunk], keys: SpaceKeys, blobId: String) throws -> Data {
        var reader = SpaceBlobReader(keys: keys, blobId: blobId)
        var data = Data()
        for chunk in chunks { data += try reader.open(chunk) }
        try reader.finish()
        guard keys.blobId(of: data) == blobId else { throw SpaceCryptoError.authenticationFailed }
        return data
    }
}
