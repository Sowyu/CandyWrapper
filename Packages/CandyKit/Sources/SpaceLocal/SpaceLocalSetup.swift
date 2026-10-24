import Darwin
import Foundation
import SpaceCrypto
import SpaceModel

/// Local-only identity. Its plaintext metadata contains ids and a key check, never page content or K.
/// Keychain calls run in the caller's background task. Disabling Space never calls delete.
public final class SpaceLocalSetup: Sendable {
    private struct Identity: Codable {
        var header: SpaceHeader
        var device: DeviceID
        var recoverySaved: Bool
    }
    public let header: SpaceHeader
    public let device: DeviceID
    public let keys: SpaceKeys
    public let local: SpaceLocalStore
    public let recoveryKey: String?
    private let metadata: URL

    public init(applicationSupport: URL, keyStore: SpaceKeyStore) throws {
        let root = applicationSupport.appendingPathComponent("Space", isDirectory: true)
        try SpaceDisk.directory(root)
        let fd = Darwin.open(root.appendingPathComponent("setup.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpaceDisk.ioError() }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw SpaceLocalError.storeInUse }
        metadata = root.appendingPathComponent("space.json")
        let identity: Identity
        let key: SpaceKey
        let existing = FileManager.default.fileExists(atPath: metadata.path)
        if existing {
            identity = try SpaceJSON.decode(Identity.self, from: Data(contentsOf: metadata))
            guard identity.header.format == "candywrapper.space", identity.header.version == 1,
                  identity.header.movedTo == nil else { throw SpaceLocalError.corruptStore }
            guard let stored = try keyStore.load(spaceId: identity.header.spaceId.rawValue) else {
                throw SpaceLocalSetupError.missingKey
            }
            key = stored
        } else {
            let id = SpaceID()
            key = SpaceKey.generate()
            let keys = try SpaceKeys(key: key, spaceId: id.rawValue)
            identity = Identity(header: SpaceHeader(spaceId: id, created: Int64(Date().timeIntervalSince1970 * 1000),
                                                    check: try keys.makeCheck()), device: DeviceID(), recoverySaved: false)
            try keyStore.save(key, spaceId: id.rawValue)
        }
        header = identity.header
        device = identity.device
        keys = try SpaceKeys(key: key, spaceId: header.spaceId.rawValue)
        guard keys.verifyCheck(header.check) else { throw SpaceLocalError.corruptStore }
        let directory = SpaceLocalStore.directory(applicationSupport: applicationSupport, spaceID: header.spaceId)
        if existing, !FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.cws").path),
           !FileManager.default.fileExists(atPath: directory.appendingPathComponent("transaction.cws").path) {
            throw SpaceLocalError.incompleteStore
        }
        local = try SpaceLocalStore(directory: directory, keys: keys)
        recoveryKey = identity.recoverySaved ? nil : RecoveryKey.encode(key)
        if !existing { try Self.write(identity, to: metadata) }
    }

    /// Only the explicit "I saved it" action dismisses first-run recovery across launches.
    public func acknowledgeRecovery() throws {
        try Self.write(Identity(header: header, device: device, recoverySaved: true), to: metadata)
    }

    private static func write(_ identity: Identity, to url: URL) throws {
        let bytes = try SpaceJSON.encode(identity)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".setup-\(UUID().uuidString)")
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SpaceDisk.ioError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw SpaceDisk.ioError() }
        try SpaceDisk.syncDirectory(url.deletingLastPathComponent())
    }
}

public enum SpaceLocalSetupError: Error { case missingKey }
