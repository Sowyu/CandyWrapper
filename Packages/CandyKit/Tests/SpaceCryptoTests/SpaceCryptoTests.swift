import CryptoKit
import Foundation
import Testing
@testable import SpaceCrypto

private func unhex(_ s: String) -> Data {
    var data = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        data.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return data
}

private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }

/// Flips one bit of the decoded envelope at `index` and re-encodes it.
private func flip(_ base64: String, at index: Int) -> String {
    var data = Data(base64Encoded: base64)!
    data[data.startIndex + index] ^= 0x01
    return data.base64EncodedString()
}

private let spaceId = "0f8fad5b-d9cb-469f-a165-70867728950e"
private let op = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
private let dev = "16fd2706-8baf-433b-82eb-8c7fada847da"
private let recA = "a8098c1a-f86e-41b4-b7b4-6b6a0f3b0b36"
private let recB = "e0b1c5a2-3f4d-4b6e-9a7c-1d2e3f4a5b6c"

struct SpaceVectorTests {
    /// RFC 5869 test cases 1 and 3, through the same CryptoKit call the derivation uses.
    @Test func hkdfRFC5869() {
        let ikm = SymmetricKey(data: Data(repeating: 0x0b, count: 22))
        let one = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: unhex("000102030405060708090a0b0c"),
                                         info: unhex("f0f1f2f3f4f5f6f7f8f9"), outputByteCount: 42)
        #expect(hex(one) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        let three = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data(), info: Data(), outputByteCount: 42)
        #expect(hex(three) == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    }

    /// AES-256-GCM test cases 13, 14 and 16 from McGrew and Viega's GCM spec, through SpaceEnvelope.
    @Test(arguments: [
        ("0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000", "", "", "",
         "530f8afbc74536b9a963b4f1c4cb738b"),
        ("0000000000000000000000000000000000000000000000000000000000000000", "000000000000000000000000",
         "00000000000000000000000000000000", "", "cea7403d4d606b6e074ec5d3baf39d18", "d0d1c8a799996bf0265b98b5d48ab919"),
        ("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308", "cafebabefacedbaddecaf888",
         "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39",
         "feedfacedeadbeeffeedfacedeadbeefabaddad2",
         "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662",
         "76fc6ece0f4e1768cddf8853bb2d551b"),
    ])
    func gcmVectors(key: String, iv: String, plaintext: String, aad: String, ciphertext: String, tag: String) throws {
        let k = SymmetricKey(data: unhex(key))
        let sealed = try SpaceEnvelope.seal(unhex(plaintext), key: k, aad: unhex(aad), nonce: AES.GCM.Nonce(data: unhex(iv)))
        #expect(Data(base64Encoded: sealed) == unhex(iv + ciphertext + tag))
        #expect(try SpaceEnvelope.open(sealed, key: k, aad: unhex(aad)) == unhex(plaintext))
    }

    /// fixtures/space/crypto.json, which Android's tests read too. Its HKDF, HMAC and base32 values were
    /// checked against Python's hmac, hashlib and base64 when they were made.
    @Test func goldenFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/space/crypto.json"))) as! [String: Any]
        let key = try SpaceKey(rawBytes: unhex(v["key"] as! String))
        let keys = try SpaceKeys(key: key, spaceId: v["spaceId"] as! String)
        let derived = v["derived"] as! [String: String]
        #expect(derived == ["cws1 ops": hex(keys.ops), "cws1 blob": hex(keys.blob), "cws1 blob-id": hex(keys.blobId),
                            "cws1 local": hex(keys.local), "cws1 check": hex(keys.check)])
        #expect(RecoveryKey.encode(key) == v["recoveryKey"] as! String)

        let check = v["check"] as! [String: String]
        #expect(try SpaceEnvelope.seal(SpaceKeys.checkPlaintext, key: keys.check, aad: Data(),
                                       nonce: AES.GCM.Nonce(data: unhex(check["nonce"]!))) == check["ct"])
        #expect(keys.verifyCheck(check["ct"]!))

        let frame = v["frame"] as! [String: Any]
        let recs = (frame["recs"] as! [[Any]]).map { SpaceRecordBase(id: $0[0] as! String, rev: $0[1] as? Int) }
        let aad = try keys.frameAAD(op: frame["op"] as! String, dev: frame["dev"] as! String, recs: recs)
        #expect(String(decoding: aad, as: UTF8.self) == frame["aad"] as! String)
        #expect(try SpaceEnvelope.seal(Data((frame["payload"] as! String).utf8), key: keys.ops, aad: aad,
                                       nonce: AES.GCM.Nonce(data: unhex(frame["nonce"] as! String))) == frame["ct"] as! String)
        #expect(try keys.openFrame(frame["ct"] as! String, op: frame["op"] as! String, dev: frame["dev"] as! String, recs: recs)
            == Data((frame["payload"] as! String).utf8))

        let snapshot = v["snapshot"] as! [String: Any]
        #expect(String(decoding: keys.snapshotAAD(seq: 2000), as: UTF8.self) == snapshot["aad"] as! String)
        #expect(try keys.openSnapshot(snapshot["ct"] as! String, seq: 2000) == Data((snapshot["plaintext"] as! String).utf8))

        let blob = v["blob"] as! [String: Any]
        let blobId = blob["blobId"] as! String
        #expect(keys.blobId(of: Data((blob["data"] as! String).utf8)) == blobId)
        #expect(blob["chunkSize"] as! Int == SpaceKeys.blobChunkSize)
        let chunk = (blob["chunks"] as! [[String: Any]])[0]
        #expect(String(decoding: try keys.blobAAD(blobId: blobId, n: 0, last: true), as: UTF8.self) == chunk["aad"] as! String)
        #expect(try SpaceBlobReader.openAll([SpaceBlobChunk(n: 0, last: true, ct: chunk["ct"] as! String)], keys: keys, blobId: blobId)
            == Data((blob["data"] as! String).utf8))
    }
}

struct SpaceEnvelopeTests {
    let keys = try! SpaceKeys(key: .generate(), spaceId: spaceId)
    let recs = [SpaceRecordBase(id: recA, rev: 805), SpaceRecordBase(id: recB, rev: nil)]
    let payload = Data(#"{"v":1,"at":1,"changes":[]}"#.utf8)

    @Test func frameRoundTripAndFreshNonces() throws {
        let a = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        let b = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        #expect(a != b)
        #expect(try keys.openFrame(a, op: op, dev: dev, recs: recs) == payload)
        #expect(Data(base64Encoded: a)!.count == payload.count + 28)
    }

    @Test func frameAADBytes() throws {
        let aad = try keys.frameAAD(op: op, dev: dev, recs: recs)
        #expect(String(decoding: aad, as: UTF8.self) == "cws1|\(spaceId)|\(op)|\(dev)|[[\"\(recA)\",805],[\"\(recB)\",null]]")
        #expect(String(decoding: try keys.frameAAD(op: op, dev: dev, recs: []), as: UTF8.self) == "cws1|\(spaceId)|\(op)|\(dev)|[]")
    }

    @Test func everyFlippedByteFails() throws {
        let ct = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        let count = Data(base64Encoded: ct)!.count
        for i in 0..<count {
            #expect(throws: SpaceCryptoError.authenticationFailed) {
                try keys.openFrame(flip(ct, at: i), op: op, dev: dev, recs: recs)
            }
        }
    }

    @Test func wrongKeyFails() throws {
        let ct = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        let otherKey = try SpaceKeys(key: .generate(), spaceId: spaceId)
        let otherSpace = try SpaceKeys(key: .generate(), spaceId: "11111111-2222-4333-8444-555555555555")
        #expect(throws: SpaceCryptoError.authenticationFailed) { try otherKey.openFrame(ct, op: op, dev: dev, recs: recs) }
        #expect(throws: SpaceCryptoError.authenticationFailed) { try otherSpace.openFrame(ct, op: op, dev: dev, recs: recs) }
        // The other derived keys don't open it either.
        #expect(throws: SpaceCryptoError.authenticationFailed) {
            try SpaceEnvelope.open(ct, key: keys.local, aad: keys.frameAAD(op: op, dev: dev, recs: recs))
        }
    }

    @Test func sameKeyOtherSpaceIdFails() throws {
        let key = SpaceKey.generate()
        let a = try SpaceKeys(key: key, spaceId: spaceId)
        let b = try SpaceKeys(key: key, spaceId: "11111111-2222-4333-8444-555555555555")
        let ct = try a.sealFrame(payload, op: op, dev: dev, recs: recs)
        #expect(throws: SpaceCryptoError.authenticationFailed) { try b.openFrame(ct, op: op, dev: dev, recs: recs) }
    }

    /// Every way the Space machine could rewrite a frame's clear fields.
    @Test func wrongAADFails() throws {
        let ct = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        let rewrites: [(String, String, [SpaceRecordBase])] = [
            (dev, dev, recs),
            (op, op, recs),
            (op, dev, Array(recs.reversed())),
            (op, dev, [recs[0]]),
            (op, dev, recs + [SpaceRecordBase(id: "11111111-2222-4333-8444-555555555555", rev: nil)]),
            (op, dev, [SpaceRecordBase(id: recA, rev: 806), recs[1]]),
            (op, dev, [SpaceRecordBase(id: recA, rev: nil), recs[1]]),
            (op, dev, [recs[0], SpaceRecordBase(id: recB, rev: 0)]),
        ]
        for (o, d, r) in rewrites {
            #expect(throws: SpaceCryptoError.authenticationFailed) { try keys.openFrame(ct, op: o, dev: d, recs: r) }
        }
    }

    @Test func truncationFails() throws {
        let ct = try keys.sealFrame(payload, op: op, dev: dev, recs: recs)
        let data = Data(base64Encoded: ct)!
        for cut in [1, 16, data.count - 28] {
            #expect(throws: SpaceCryptoError.authenticationFailed) {
                try keys.openFrame(data.dropLast(cut).base64EncodedString(), op: op, dev: dev, recs: recs)
            }
        }
        for short in [data.prefix(27), Data()] {
            #expect(throws: SpaceCryptoError.malformedCiphertext) {
                try keys.openFrame(short.base64EncodedString(), op: op, dev: dev, recs: recs)
            }
        }
        #expect(throws: SpaceCryptoError.malformedCiphertext) { try keys.openFrame("not base64!", op: op, dev: dev, recs: recs) }
    }

    @Test func idsMustBeLowercaseUUIDs() throws {
        #expect(throws: SpaceCryptoError.badIdentifier) { try SpaceKeys(key: .generate(), spaceId: spaceId.uppercased()) }
        #expect(throws: SpaceCryptoError.badIdentifier) { try SpaceKeys(key: .generate(), spaceId: "space") }
        #expect(throws: SpaceCryptoError.badIdentifier) { try keys.sealFrame(payload, op: "a|b", dev: dev, recs: []) }
        #expect(throws: SpaceCryptoError.badIdentifier) {
            try keys.sealFrame(payload, op: op, dev: dev, recs: [SpaceRecordBase(id: "x\"]", rev: nil)])
        }
        #expect(throws: SpaceCryptoError.badIdentifier) {
            try keys.sealFrame(payload, op: op, dev: dev, recs: [SpaceRecordBase(id: recA, rev: -1)])
        }
    }

    @Test func snapshotSeqIsBound() throws {
        let ct = try keys.sealSnapshot(payload, seq: 2000)
        #expect(try keys.openSnapshot(ct, seq: 2000) == payload)
        #expect(throws: SpaceCryptoError.authenticationFailed) { try keys.openSnapshot(ct, seq: 4000) }
        // A frame's ciphertext can't pass as a snapshot, or the reverse.
        let frame = try keys.sealFrame(payload, op: op, dev: dev, recs: [])
        #expect(throws: SpaceCryptoError.authenticationFailed) { try keys.openSnapshot(frame, seq: 0) }
        #expect(throws: SpaceCryptoError.authenticationFailed) { try keys.openFrame(ct, op: op, dev: dev, recs: []) }
    }

    @Test func checkValue() throws {
        let check = try keys.makeCheck()
        #expect(keys.verifyCheck(check))
        #expect(!(try SpaceKeys(key: .generate(), spaceId: spaceId)).verifyCheck(check))
        #expect(!keys.verifyCheck(flip(check, at: 20)))
        #expect(!keys.verifyCheck("garbage"))
    }

    @Test func keysNeverDescribeTheirBytes() throws {
        let key = try SpaceKey(rawBytes: Data(repeating: 0xab, count: 32))
        for text in ["\(key)", String(reflecting: key), String(describing: [key])] {
            #expect(!text.lowercased().contains("ab"), "\(text)")
        }
        var dumped = ""
        dump(key, to: &dumped)
        #expect(!dumped.contains("171") && !dumped.lowercased().contains("abab"))
        #expect(throws: SpaceCryptoError.badKeyLength) { try SpaceKey(rawBytes: Data(count: 31)) }
    }
}

struct SpaceBlobTests {
    let keys = try! SpaceKeys(key: .generate(), spaceId: spaceId)

    private func blob(_ count: Int) -> (Data, String, [SpaceBlobChunk]) {
        let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let id = keys.blobId(of: data)
        return (data, id, try! keys.sealBlob(data, blobId: id))
    }

    @Test func roundTripsAtChunkEdges() throws {
        let size = SpaceKeys.blobChunkSize
        for (count, chunks) in [(0, 1), (1, 1), (size - 1, 1), (size, 1), (size + 1, 2), (size * 2 + size / 2, 3)] {
            let (data, id, sealed) = blob(count)
            #expect(sealed.count == chunks)
            #expect(sealed.map(\.n) == Array(0..<chunks))
            #expect(sealed.map(\.last) == Array(repeating: false, count: chunks - 1) + [true])
            #expect(try SpaceBlobReader.openAll(sealed, keys: keys, blobId: id) == data)
        }
    }

    @Test func blobIdIsKeyedHex() throws {
        let data = Data("same bytes".utf8)
        let id = keys.blobId(of: data)
        #expect(id.count == 64 && id == id.lowercased())
        #expect(id == keys.blobId(of: data))
        #expect(id != (try SpaceKeys(key: .generate(), spaceId: spaceId)).blobId(of: data))
        #expect(id != SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    @Test func reorderedChunksFail() throws {
        let (_, id, sealed) = blob(SpaceKeys.blobChunkSize * 2 + 10)
        // Swapped places, renumbered by the Space machine to look in order.
        let swapped = [SpaceBlobChunk(n: 0, last: false, ct: sealed[1].ct), SpaceBlobChunk(n: 1, last: false, ct: sealed[0].ct), sealed[2]]
        #expect(throws: SpaceCryptoError.authenticationFailed) { try SpaceBlobReader.openAll(swapped, keys: keys, blobId: id) }
        #expect(throws: SpaceCryptoError.blobChunkOutOfOrder) {
            try SpaceBlobReader.openAll([sealed[1], sealed[0], sealed[2]], keys: keys, blobId: id)
        }
        #expect(throws: SpaceCryptoError.blobChunkOutOfOrder) {
            try SpaceBlobReader.openAll([sealed[0], sealed[0], sealed[1], sealed[2]], keys: keys, blobId: id)
        }
    }

    @Test func truncatedBlobsFail() throws {
        let (_, id, sealed) = blob(SpaceKeys.blobChunkSize * 2 + 10)
        #expect(throws: SpaceCryptoError.blobTruncated) { try SpaceBlobReader.openAll(Array(sealed.prefix(2)), keys: keys, blobId: id) }
        #expect(throws: SpaceCryptoError.blobTruncated) { try SpaceBlobReader.openAll([], keys: keys, blobId: id) }
        // Calling an earlier chunk the last one.
        #expect(throws: SpaceCryptoError.authenticationFailed) {
            try SpaceBlobReader.openAll([sealed[0], SpaceBlobChunk(n: 1, last: true, ct: sealed[1].ct)], keys: keys, blobId: id)
        }
        #expect(throws: SpaceCryptoError.blobChunkOutOfOrder) {
            try SpaceBlobReader.openAll([sealed[0], sealed[2]], keys: keys, blobId: id)
        }
        #expect(throws: SpaceCryptoError.blobChunkOutOfOrder) {
            try SpaceBlobReader.openAll(sealed + [SpaceBlobChunk(n: 3, last: true, ct: sealed[2].ct)], keys: keys, blobId: id)
        }
    }

    @Test func chunksDontMoveBetweenBlobs() throws {
        let (_, idA, a) = blob(10)
        let (_, idB, _) = blob(11)
        #expect(throws: SpaceCryptoError.authenticationFailed) { try SpaceBlobReader.openAll(a, keys: keys, blobId: idB) }
        #expect(throws: SpaceCryptoError.authenticationFailed) {
            try SpaceBlobReader.openAll([SpaceBlobChunk(n: 0, last: true, ct: flip(a[0].ct, at: 13))], keys: keys, blobId: idA)
        }
        #expect(throws: SpaceCryptoError.badIdentifier) { try keys.sealBlob(Data(), blobId: "../etc") }
    }
}

struct RecoveryKeyTests {
    @Test func roundTrips() throws {
        for _ in 0..<200 {
            let key = SpaceKey.generate()
            let text = RecoveryKey.encode(key)
            let groups = text.split(separator: " ")
            #expect(groups.count == 13 && groups.allSatisfy { $0.count == 4 })
            #expect(try RecoveryKey.decode(text) == key)
            #expect(try RecoveryKey.decode(text.lowercased().replacingOccurrences(of: " ", with: "-")) == key)
            #expect(try RecoveryKey.decode(text.replacingOccurrences(of: " ", with: "")) == key)
        }
        let edges = [Data(count: 32), Data(repeating: 0xff, count: 32)]
        for raw in edges {
            let key = try SpaceKey(rawBytes: raw)
            #expect(try RecoveryKey.decode(RecoveryKey.encode(key)) == key)
        }
        #expect(RecoveryKey.encode(try SpaceKey(rawBytes: Data(count: 32))) == Array(repeating: "AAAA", count: 13).joined(separator: " "))
    }

    /// Every single-character typo either fails to decode or gives a key that fails the check value.
    @Test func everyTypoIsCaught() throws {
        let key = SpaceKey.generate()
        let keys = try SpaceKeys(key: key, spaceId: spaceId)
        let check = try keys.makeCheck()
        let chars = Array(RecoveryKey.encode(key).replacingOccurrences(of: " ", with: ""))
        var caughtAtDecode = 0
        for i in chars.indices {
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" where c != chars[i] {
                var typo = chars
                typo[i] = c
                do {
                    let wrong = try RecoveryKey.decode(String(typo))
                    #expect(wrong != key)
                    #expect(!(try SpaceKeys(key: wrong, spaceId: spaceId)).verifyCheck(check))
                } catch {
                    #expect(error as? SpaceCryptoError == .recoveryKeyTypo)
                    caughtAtDecode += 1
                }
            }
        }
        // The last character's four spare bits catch 30 of its 31 typos without the check value.
        #expect(caughtAtDecode == 30)
    }

    @Test func malformedInputFails() {
        let text = RecoveryKey.encode(.generate())
        #expect(throws: SpaceCryptoError.recoveryKeyLength) { try RecoveryKey.decode(String(text.dropLast())) }
        #expect(throws: SpaceCryptoError.recoveryKeyLength) { try RecoveryKey.decode(text + "A") }
        #expect(throws: SpaceCryptoError.recoveryKeyLength) { try RecoveryKey.decode("") }
        for bad in ["0", "1", "8", "9", "=", "é"] {
            #expect(throws: SpaceCryptoError.recoveryKeyCharacter) { try RecoveryKey.decode(bad + String(text.dropFirst())) }
        }
    }
}

struct SpaceKeyStoreTests {
    @Test func inMemoryNeverReplacesAKey() throws {
        let store = SpaceKeyStore.inMemory()
        let key = SpaceKey.generate()
        #expect(try store.load(spaceId: spaceId) == nil)
        try store.save(key, spaceId: spaceId)
        try store.save(key, spaceId: spaceId)
        #expect(try store.load(spaceId: spaceId) == key)
        #expect(throws: SpaceKeyStore.Failure.differentKeyStored) { try store.save(.generate(), spaceId: spaceId) }
        #expect(try store.load(spaceId: spaceId) == key)
        try store.delete(spaceId: spaceId)
        #expect(try store.load(spaceId: spaceId) == nil)
        try store.delete(spaceId: spaceId)
    }

    @Test func serviceNamesTheBundle() {
        #expect(SpaceKeyStore().service.hasSuffix(".space-key"))
    }

    /// The real login Keychain, trusted to this test runner. scripts/space-keychain-test checks the ACL against
    /// other apps in a release-style signed build.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_INTEGRATION"] == "1", "writes the login Keychain: run scripts/test-integration"))
    func loginKeychain() throws {
        let store = SpaceKeyStore(service: "dev.candywrapper.space-key.test-\(UUID().uuidString)")
        let key = SpaceKey.generate()
        defer { try? store.delete(spaceId: spaceId) }
        try store.save(key, spaceId: spaceId)
        #expect(try store.load(spaceId: spaceId) == key)
        #expect(throws: SpaceKeyStore.Failure.differentKeyStored) { try store.save(.generate(), spaceId: spaceId) }
        try store.delete(spaceId: spaceId)
        #expect(try store.load(spaceId: spaceId) == nil)
    }
}
