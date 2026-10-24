import CryptoKit
import Foundation

// Space's keys and envelopes (docs/space.md, "Keys"). CryptoKit only, so Android matches with javax.crypto.
// Nothing here logs, prints or describes key bytes or plaintext.

public enum SpaceCryptoError: Error, Sendable, Equatable {
    /// A key that isn't exactly 32 bytes.
    case badKeyLength
    /// An id that isn't a lowercase UUID, or a blob id that isn't 64 lowercase hex digits.
    case badIdentifier
    /// A ciphertext that isn't base64 or is shorter than a nonce and a tag.
    case malformedCiphertext
    /// Wrong key, wrong AAD or tampered bytes. AES-GCM can't tell them apart.
    case authenticationFailed
    /// A blob chunk out of order, or one after the last chunk.
    case blobChunkOutOfOrder
    /// A blob that ended without its last chunk.
    case blobTruncated
    case recoveryKeyLength
    case recoveryKeyCharacter
    /// The last character's spare bits aren't zero, so the key was mistyped.
    case recoveryKeyTypo
}

/// The Space key K: 32 random bytes. It lives only in each device's Keychain and in the recovery key.
public struct SpaceKey: Sendable, Equatable {
    public static let byteCount = 32
    let key: SymmetricKey

    public static func generate() -> SpaceKey { SpaceKey(key: SymmetricKey(size: .bits256)) }

    public init(rawBytes: some ContiguousBytes) throws {
        guard rawBytes.withUnsafeBytes({ $0.count }) == Self.byteCount else { throw SpaceCryptoError.badKeyLength }
        key = SymmetricKey(data: rawBytes)
    }

    init(key: SymmetricKey) { self.key = key }

    /// The raw bytes, for the Keychain and the recovery key only. Don't copy them out of `body`.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try key.withUnsafeBytes(body)
    }
}

extension SpaceKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SpaceKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// A record a frame touches and the rev the device checked, or nil for no check (docs/space.md, "A log frame").
public struct SpaceRecordBase: Sendable, Equatable {
    public var id: String
    public var rev: Int?
    public init(id: String, rev: Int?) {
        self.id = id
        self.rev = rev
    }
}

/// The keys HKDF-SHA256 derives from K, salted with the Space id's 16 bytes.
public struct SpaceKeys: Sendable {
    public let spaceId: String
    let ops: SymmetricKey
    let blob: SymmetricKey
    let blobId: SymmetricKey
    /// For the device's local files. Their AAD belongs to the local copy's format.
    public let local: SymmetricKey
    let check: SymmetricKey

    public init(key: SpaceKey, spaceId: String) throws {
        let salt = try uuidBytes(spaceId)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key.key, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        self.spaceId = spaceId
        ops = derive("cws1 ops")
        blob = derive("cws1 blob")
        blobId = derive("cws1 blob-id")
        local = derive("cws1 local")
        check = derive("cws1 check")
    }

    // MARK: Log frames

    public func sealFrame(_ payload: some DataProtocol, op: String, dev: String, recs: [SpaceRecordBase]) throws -> String {
        try SpaceEnvelope.seal(payload, key: ops, aad: frameAAD(op: op, dev: dev, recs: recs))
    }

    public func openFrame(_ ct: String, op: String, dev: String, recs: [SpaceRecordBase]) throws -> Data {
        try SpaceEnvelope.open(ct, key: ops, aad: frameAAD(op: op, dev: dev, recs: recs))
    }

    /// `cws1|<spaceId>|<op>|<dev>|` and `recs` as compact JSON in the order given. Ids must be lowercase
    /// UUIDs, which need no JSON escaping, so both platforms produce the same bytes.
    func frameAAD(op: String, dev: String, recs: [SpaceRecordBase]) throws -> Data {
        try checkUUID(op)
        try checkUUID(dev)
        var json = "["
        for (i, rec) in recs.enumerated() {
            try checkUUID(rec.id)
            if let rev = rec.rev, rev < 0 { throw SpaceCryptoError.badIdentifier }
            json += (i == 0 ? "" : ",") + "[\"\(rec.id)\",\(rec.rev.map(String.init) ?? "null")]"
        }
        return Data("cws1|\(spaceId)|\(op)|\(dev)|\(json)]".utf8)
    }

    // MARK: Snapshots

    /// `gzipped` is the gzip of the snapshot JSON. The AAD binds the seq, so the Space machine can't relabel it.
    public func sealSnapshot(_ gzipped: some DataProtocol, seq: Int) throws -> String {
        try SpaceEnvelope.seal(gzipped, key: ops, aad: snapshotAAD(seq: seq))
    }

    public func openSnapshot(_ ct: String, seq: Int) throws -> Data {
        try SpaceEnvelope.open(ct, key: ops, aad: snapshotAAD(seq: seq))
    }

    func snapshotAAD(seq: Int) -> Data { Data("cws1|\(spaceId)|snapshot|\(seq)".utf8) }

    // MARK: Check value

    static let checkPlaintext = Data("candywrapper space".utf8)

    /// The `check` field of a new `space.json`.
    public func makeCheck() throws -> String {
        try SpaceEnvelope.seal(Self.checkPlaintext, key: check, aad: Data())
    }

    /// Whether this key opens the Space whose `space.json` holds `check`. A typo in the recovery key fails here.
    public func verifyCheck(_ check: String) -> Bool {
        (try? SpaceEnvelope.open(check, key: self.check, aad: Data())) == Self.checkPlaintext
    }
}

/// AES-256-GCM with a fresh random 12-byte nonce, stored as base64 of `nonce || ciphertext || tag`.
public enum SpaceEnvelope {
    static let overhead = 12 + 16

    public static func seal(_ plaintext: some DataProtocol, key: SymmetricKey, aad: Data) throws -> String {
        try seal(plaintext, key: key, aad: aad, nonce: AES.GCM.Nonce())
    }

    /// Tests only pass a nonce. Reusing one under the same key breaks GCM.
    static func seal(_ plaintext: some DataProtocol, key: SymmetricKey, aad: Data, nonce: AES.GCM.Nonce) throws -> String {
        // combined is non-nil for the default 12-byte nonce.
        try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad).combined!.base64EncodedString()
    }

    public static func open(_ base64: String, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = Data(base64Encoded: base64), combined.count >= overhead else {
            throw SpaceCryptoError.malformedCiphertext
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
        } catch {
            throw SpaceCryptoError.authenticationFailed
        }
    }
}

func checkUUID(_ id: String) throws { _ = try uuidBytes(id) }

/// The 16 bytes of a lowercase UUID string. Uppercase is refused so the AAD text is the same everywhere.
func uuidBytes(_ id: String) throws -> Data {
    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw SpaceCryptoError.badIdentifier }
    return withUnsafeBytes(of: uuid.uuid) { Data($0) }
}
