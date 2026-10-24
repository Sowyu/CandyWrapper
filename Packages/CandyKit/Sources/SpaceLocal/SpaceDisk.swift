import Darwin
import Foundation
import SpaceCrypto
import SpaceModel

public enum SpaceLocalError: Error, Equatable, Sendable {
    case storeInUse, incompleteStore, corruptStore, sequenceMismatch, operationMismatch
    case invalidBlobID, blobTooLarge, reopenRequired
}

// Tests throw at every boundary, then reopen with a fresh disk object. Only ciphertext reaches a handle.
struct DiskStep: Equatable, Sendable {
    let path: String
    let phase: String
}

struct LogAppend: Codable {
    var offset: UInt64
    var bytes: Data
}

struct DiskTransaction: Codable {
    var replacements: [String: Data] = [:]
    var append: LogAppend?
}

/// One writer per Space directory, including across processes. No timers or background file watchers.
final class SpaceDisk {
    let root: URL
    let keys: SpaceKeys
    let fault: (DiskStep) throws -> Void
    private var lockFD: Int32
    private let fm = FileManager.default

    init(root: URL, keys: SpaceKeys, fault: @escaping (DiskStep) throws -> Void = { _ in }) throws {
        self.root = root
        self.keys = keys
        self.fault = fault
        try Self.directory(root)
        try Self.directory(root.appendingPathComponent("blobs"))
        lockFD = Darwin.open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw Self.ioError() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            lockFD = -1
            throw SpaceLocalError.storeInUse
        }
    }

    deinit { close() }

    func close() {
        if lockFD >= 0 {
            // Unlock explicitly: a concurrently spawned child can briefly inherit the open file
            // description before exec closes it, even though the descriptor has O_CLOEXEC.
            flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    static func ioError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    static func directory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) { try directory(parent) }
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try syncDirectory(url.deletingLastPathComponent())
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SpaceLocalError.corruptStore }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ioError() }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw ioError() }
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }

    func read(_ path: String) throws -> Data {
        let fd = Darwin.open(url(path).path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.ioError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try file.readToEnd() ?? Data()
    }

    func size(_ path: String) throws -> UInt64 {
        let attributes = try fm.attributesOfItem(atPath: url(path).path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber else { throw SpaceLocalError.corruptStore }
        return bytes.uint64Value
    }

    func seal(_ data: Data, purpose: String) throws -> Data {
        Data(try SpaceEnvelope.seal(data, key: keys.local, aad: aad(purpose)).utf8)
    }

    func open(_ data: Data, purpose: String) throws -> Data {
        try SpaceEnvelope.open(String(decoding: data, as: UTF8.self), key: keys.local, aad: aad(purpose))
    }

    private func aad(_ purpose: String) -> Data { Data("cws1|\(keys.spaceId)|local|\(purpose)".utf8) }

    func atomicWrite(_ bytes: Data, to path: String) throws {
        let target = url(path)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.ioError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Keep an interrupted temp file for recovery tests, just as a killed process would.
        try fault(DiskStep(path: path, phase: "created"))
        let middle = bytes.count / 2
        try file.write(contentsOf: bytes.prefix(middle))
        try fault(DiskStep(path: path, phase: "partial"))
        try file.write(contentsOf: bytes.suffix(bytes.count - middle))
        try fault(DiskStep(path: path, phase: "written"))
        try file.synchronize()
        try fault(DiskStep(path: path, phase: "synced"))
        try file.close()
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw Self.ioError() }
        try fault(DiskStep(path: path, phase: "renamed"))
        try Self.syncDirectory(target.deletingLastPathComponent())
        try fault(DiskStep(path: path, phase: "directorySynced"))
    }

    func remove(_ path: String) throws {
        if exists(path) {
            try fm.removeItem(at: url(path))
            try fault(DiskStep(path: path, phase: "removed"))
            try Self.syncDirectory(url(path).deletingLastPathComponent())
            try fault(DiskStep(path: path, phase: "removalSynced"))
        }
    }

    func commit(_ transaction: DiskTransaction) throws {
        try atomicWrite(seal(SpaceJSON.encode(transaction), purpose: "journal"), to: "transaction.cws")
        try apply(transaction)
        try remove("transaction.cws")
    }

    func recover() throws {
        if exists("transaction.cws") {
            let transaction = try SpaceJSON.decode(DiskTransaction.self, from: open(read("transaction.cws"), purpose: "journal"))
            try apply(transaction)
            try remove("transaction.cws")
        }
        for directory in [root, url("blobs")] {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix(".tmp-") {
                try fm.removeItem(at: file)
            }
            try Self.syncDirectory(directory)
        }
    }

    private func apply(_ transaction: DiskTransaction) throws {
        guard Set(transaction.replacements.keys).isSubset(of: ["snapshot.cws", "log.cws", "pending.cws"]),
              transaction.append == nil || transaction.replacements["log.cws"] == nil else { throw SpaceLocalError.corruptStore }
        if let append = transaction.append {
            guard try size("log.cws") >= append.offset else { throw SpaceLocalError.corruptStore }
            let fd = Darwin.open(url("log.cws").path, O_WRONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw Self.ioError() }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.truncate(atOffset: append.offset)
            try file.seek(toOffset: append.offset)
            try fault(DiskStep(path: "log.cws", phase: "truncated"))
            let middle = append.bytes.count / 2
            try file.write(contentsOf: append.bytes.prefix(middle))
            try fault(DiskStep(path: "log.cws", phase: "partial"))
            try file.write(contentsOf: append.bytes.suffix(append.bytes.count - middle))
            try fault(DiskStep(path: "log.cws", phase: "written"))
            try file.synchronize()
            try fault(DiskStep(path: "log.cws", phase: "synced"))
        }
        for path in transaction.replacements.keys.sorted() {
            try atomicWrite(transaction.replacements[path]!, to: path)
        }
    }
}
