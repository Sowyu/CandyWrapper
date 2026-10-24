import Foundation
import SpaceCrypto
import SpaceModel

/// The unsent frame and its rebase context. Content and context are encrypted together on disk.
public struct SpacePendingOperation: Codable, Equatable, Sendable {
    public var op: OpID
    public var dev: DeviceID
    public var recs: [RecordRevision]
    public var payload: OpPayload
    public var context: [String: JSONValue]

    public init(op: OpID, dev: DeviceID, recs: [RecordRevision], payload: OpPayload, context: [String: JSONValue] = [:]) {
        self.op = op
        self.dev = dev
        self.recs = recs
        self.payload = payload
        self.context = context
    }
}

public struct SpaceLocalState: Equatable, Sendable {
    public var snapshot: SnapshotPayload
    /// Wire frames, opened from local envelopes. Their ct retains the ops-key envelope for retransmission.
    public var frames: [LogFrame]
    public var pending: [SpacePendingOperation]
    public var confirmedSequence: Int64 { frames.last?.seq ?? snapshot.seq }
}

struct PendingFile: Codable {
    var confirmedSequence: Int64
    var operations: [SpacePendingOperation]
}

/// Encrypted local storage only. It neither applies records nor schedules sync, reminders or UI work.
/// A successful mutation means its journal, data and directory entries have reached fsync.
public actor SpaceLocalStore {
    public static let blobCacheLimit: UInt64 = 1_000_000_000
    let disk: SpaceDisk
    let cacheLimit: UInt64
    var cache: CacheIndex
    var failed = false
    private var state: SpaceLocalState

    /// The caller supplies its bundle-specific Application Support directory, never the live T3 home.
    public static func directory(applicationSupport: URL, spaceID: SpaceID) -> URL {
        applicationSupport.appendingPathComponent("Space", isDirectory: true).appendingPathComponent(spaceID.rawValue, isDirectory: true)
    }

    public init(directory: URL, keys: SpaceKeys) throws {
        try self.init(directory: directory, keys: keys, cacheLimit: Self.blobCacheLimit, fault: { _ in })
    }

    init(directory: URL, keys: SpaceKeys, cacheLimit: UInt64, fault: @escaping (DiskStep) throws -> Void) throws {
        let disk = try SpaceDisk(root: directory, keys: keys, fault: fault)
        self.disk = disk
        self.cacheLimit = min(cacheLimit, Self.blobCacheLimit)
        do {
            try disk.recover()
            let files = ["snapshot.cws", "log.cws", "pending.cws"]
            if !files.contains(where: disk.exists) {
                guard !disk.exists("cache.cws") else { throw SpaceLocalError.incompleteStore }
                let snapshot = SnapshotPayload(seq: 0)
                let pending = PendingFile(confirmedSequence: 0, operations: [])
                try disk.commit(DiskTransaction(replacements: [
                    "snapshot.cws": disk.seal(SpaceJSON.encode(snapshot), purpose: "snapshot"),
                    "log.cws": Data(),
                    "pending.cws": disk.seal(SpaceJSON.encode(pending), purpose: "pending")
                ]))
            }
            guard files.allSatisfy(disk.exists) else { throw SpaceLocalError.incompleteStore }
            state = try Self.load(disk)
            cache = try Self.loadCache(disk, limit: self.cacheLimit)
        } catch {
            disk.close()
            throw error
        }
    }

    public func load() throws -> SpaceLocalState {
        try requireHealthy()
        return state
    }

    /// Release the process lock before opening another instance. An interrupted transaction stays
    /// on disk for the next opener; a closed instance refuses further reads and writes.
    public func close() {
        failed = true
        state = SpaceLocalState(snapshot: SnapshotPayload(seq: 0), frames: [], pending: [])
        cache = CacheIndex()
        disk.close()
    }

    /// Persist before showing an edit as saved. Rebase may replace the queue and its base context together.
    public func replacePending(_ operations: [SpacePendingOperation]) throws {
        try requireHealthy()
        guard Set(operations.map(\.op)).count == operations.count,
              Set(operations.map(\.op)).isDisjoint(with: state.frames.map(\.op)) else { throw SpaceLocalError.operationMismatch }
        // Exercise the model's validators before touching disk.
        _ = try SpaceJSON.encode(operations)
        var next = state
        next.pending = operations
        try commit(next, replacements: [:])
    }

    /// Check the ops-key envelope before recording a frame. A matching pending op leaves the queue in
    /// the same durable transaction, so a crash cannot lose an edit between confirmation and removal.
    public func confirm(_ frame: LogFrame) throws {
        try requireHealthy()
        let payload = try Self.payload(frame, keys: disk.keys)
        if let old = state.frames.first(where: { $0.seq == frame.seq || $0.op == frame.op }) {
            guard old == frame else { throw SpaceLocalError.operationMismatch }
            return
        }
        guard state.confirmedSequence < Int64.max, frame.seq == state.confirmedSequence + 1 else {
            throw SpaceLocalError.sequenceMismatch
        }
        if let pending = state.pending.first(where: { $0.op == frame.op }) {
            guard pending.dev == frame.dev, pending.recs == frame.recs, pending.payload == payload else {
                throw SpaceLocalError.operationMismatch
            }
        }
        var next = state
        next.frames.append(frame)
        next.pending.removeAll { $0.op == frame.op }
        var line = try disk.seal(SpaceJSON.encode(frame), purpose: "log|\(frame.seq)")
        line.append(0x0a)
        try commit(next, replacements: [:], append: LogAppend(offset: disk.size("log.cws"), bytes: line))
    }

    /// Install an already decoded snapshot or checkpoint. The caller supplies the confirmed state;
    /// this module preserves later frames and never invokes the apply/rebase implementation.
    public func saveSnapshot(_ snapshot: SnapshotPayload) throws {
        try requireHealthy()
        guard snapshot.seq >= state.snapshot.seq else { throw SpaceLocalError.sequenceMismatch }
        let later = state.frames.filter { $0.seq > snapshot.seq }
        if let first = later.first {
            guard snapshot.seq < Int64.max, first.seq == snapshot.seq + 1 else { throw SpaceLocalError.sequenceMismatch }
        }
        var next = state
        next.snapshot = snapshot
        next.frames = later
        let log = try Self.encodeLog(later, disk: disk)
        try commit(next, replacements: [
            "snapshot.cws": disk.seal(SpaceJSON.encode(snapshot), purpose: "snapshot"), "log.cws": log
        ])
    }

    /// Use before accepting a server's hello. The highest confirmed seq survives process restarts.
    public func checkRemoteSequence(_ sequence: Int64) throws {
        try requireHealthy()
        guard sequence >= state.confirmedSequence else { throw SpaceLocalError.sequenceMismatch }
    }

    public func payload(of frame: LogFrame) throws -> OpPayload {
        try requireHealthy()
        return try Self.payload(frame, keys: disk.keys)
    }

    func requireHealthy() throws { if failed { throw SpaceLocalError.reopenRequired } }

    private func commit(_ next: SpaceLocalState, replacements: [String: Data], append: LogAppend? = nil) throws {
        var replacements = replacements
        replacements["pending.cws"] = try disk.seal(SpaceJSON.encode(PendingFile(
            confirmedSequence: next.confirmedSequence, operations: next.pending)), purpose: "pending")
        do {
            try disk.commit(DiskTransaction(replacements: replacements, append: append))
            state = next
        } catch {
            failed = true
            throw error
        }
    }

    private static func payload(_ frame: LogFrame, keys: SpaceKeys) throws -> OpPayload {
        let recs = frame.recs.map { SpaceRecordBase(id: $0.id.rawValue, rev: $0.base.map(Int.init)) }
        return try SpaceJSON.decode(OpPayload.self, from: keys.openFrame(frame.ct, op: frame.op.rawValue, dev: frame.dev.rawValue, recs: recs))
    }

    private static func encodeLog(_ frames: [LogFrame], disk: SpaceDisk) throws -> Data {
        var data = Data()
        for frame in frames {
            data.append(try disk.seal(SpaceJSON.encode(frame), purpose: "log|\(frame.seq)"))
            data.append(0x0a)
        }
        return data
    }

    private static func load(_ disk: SpaceDisk) throws -> SpaceLocalState {
        let snapshot = try SpaceJSON.decode(SnapshotPayload.self, from: disk.open(disk.read("snapshot.cws"), purpose: "snapshot"))
        guard snapshot.seq >= 0 else { throw SpaceLocalError.corruptStore }
        let pending = try SpaceJSON.decode(PendingFile.self, from: disk.open(disk.read("pending.cws"), purpose: "pending"))
        let bytes = try disk.read("log.cws")
        guard bytes.isEmpty || bytes.last == 0x0a else { throw SpaceLocalError.corruptStore }
        var frames: [LogFrame] = []
        var sequence = snapshot.seq
        var ops = Set<OpID>()
        for line in bytes.split(separator: 0x0a, omittingEmptySubsequences: false).dropLast() {
            guard sequence < Int64.max else { throw SpaceLocalError.corruptStore }
            sequence += 1
            let frame = try SpaceJSON.decode(LogFrame.self, from: disk.open(Data(line), purpose: "log|\(sequence)"))
            guard frame.seq == sequence, ops.insert(frame.op).inserted else { throw SpaceLocalError.corruptStore }
            _ = try payload(frame, keys: disk.keys)
            frames.append(frame)
        }
        guard pending.confirmedSequence == sequence,
              Set(pending.operations.map(\.op)).count == pending.operations.count,
              ops.isDisjoint(with: pending.operations.map(\.op)) else { throw SpaceLocalError.corruptStore }
        return SpaceLocalState(snapshot: snapshot, frames: frames, pending: pending.operations)
    }
}
