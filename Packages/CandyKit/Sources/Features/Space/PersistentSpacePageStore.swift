import Foundation
import SpaceCrypto
import SpaceEngine
import SpaceLocal
import SpaceModel

/// Immediate edits for the synchronous sidebar and editor contracts, followed by a serial durable write.
/// `isSaving` stays true until encrypted pending and confirmation reach disk. Failures stay visible
/// and block further edits and quitting; they never fall back to an empty in-memory store.
/// The screen reads a main-thread `SpaceReplicaStore`, so the page editor gets blocks and undo entries; each of its
/// edits, undo included, goes to the writer in the order it was made.
@MainActor
public final class PersistentSpacePageStore: SpaceDocumentStore {
    public var pages: [PageID: PageRecord] { local.pages }
    public private(set) var isSaving = false
    public private(set) var failure: Error?
    public private(set) var isOpen = false
    public var onFailure: (@MainActor () -> Void)?
    public var onSavingChange: (@MainActor () -> Void)?
    /// What the screen shows. The writer's confirmed frames come back to it, so its pending list holds only edits
    /// still on their way to disk. Undo entries live in the editors and stay valid.
    private(set) var local = SpaceReplicaStore()
    private var writer: LocalPageWriter?
    private var closing = false
    private var writeRevision = 0
    private var queuedWrites = 0
    private var tail: Task<Void, Never>?
    private var observers: [Int: @MainActor () -> Void] = [:]
    private var nextToken = 0

    public init() {}

    /// Called only when Space is on. The key and files are never opened on the disabled launch path.
    public func open(applicationSupport: URL, keyStore: SpaceKeyStore) async throws -> SpaceLocalSetup {
        let setup = try await Task.detached {
            try SpaceLocalSetup(applicationSupport: applicationSupport, keyStore: keyStore)
        }.value
        do {
            let writer = LocalPageWriter(setup: setup)
            let state = try await writer.load()
            self.writer = writer
            failure = nil
            isOpen = true
            attach(SpaceReplicaStore(replica: SpaceReplica(device: setup.device, label: "This Mac", confirmed: state)))
            return setup
        } catch {
            await setup.local.close()
            throw error
        }
    }

    private func attach(_ store: SpaceReplicaStore) {
        local = store
        store.onEdit = { [weak self, weak store] op in
            guard let self, let store else { return }
            let changes = op.payload.changes, at = op.payload.at, id = op.op
            self.enqueue { writer in
                let frames = try await writer.save(changes, at: at, op: id)
                await store.receive(frames)
            }
        }
        _ = store.observe { [weak self] in self?.publish() }
        publish()
    }

    private var canEdit: Bool { isOpen && !closing && failure == nil }

    public func put(_ records: [PageID: PageRecord]) {
        guard canEdit else { return }
        var changes: [RecordChange] = []
        for (id, record) in records.sorted(by: { $0.key < $1.key }) {
            guard case .object(let new)? = try? SpaceModel.JSONValue(encoding: record) else { continue }
            if let change = SpaceReplicaStore.diff(.page, id, old: local.replica.current.pages[id], new: new) { changes.append(change) }
        }
        local.edit(changes)
    }

    /// Delete forever: null every key of the page and the pages under it through apply, leaving unrenderable empty
    /// records and their encrypted history. Their blocks' images and files then leave this Mac's blob cache, unless a
    /// block of another page uses the same blob.
    public func remove(_ id: PageID) {
        let current = local.replica.current
        guard canEdit, let old = current.pages[id], !old.isEmpty else { return }
        let gone = Set([id] + SpaceTree.descendants(of: id, in: local.allPageRecords))
        let changes = gone.sorted().compactMap { p in
            current.pages[p].flatMap { $0.isEmpty ? nil : RecordChange(kind: .page, id: p, set: $0.mapValues { _ in .null }) }
        }
        var dropped = Set<String>(), kept = Set<String>()
        for block in current.blocks.values {
            guard case .object(let blob)? = block["blob"], case .string(let blobID)? = blob["id"] else { continue }
            if case .string(let raw)? = block["page"], let page = try? PageID(raw), gone.contains(page) { dropped.insert(blobID) }
            else { kept.insert(blobID) }
        }
        local.edit(changes)
        let blobs = dropped.subtracting(kept).sorted()
        if !blobs.isEmpty { enqueue { try await $0.removeBlobs(blobs) } }
    }

    public func history(of page: PageID) async throws -> [SpaceVersion] {
        try await flush()
        guard let writer else { return [] }
        return try await writer.history(of: page, stretch: SpaceReplicaStore.historyStretch)
    }

    public func restoreChanges(_ version: SpaceVersion) -> [RecordChange] { local.restoreChanges(version) }
    public func deviceLabel(_ device: DeviceID) -> String { local.deviceLabel(device) }

    public func block(_ id: BlockID) -> BlockRecord? { local.block(id) }
    public func content(of page: PageID) -> [SpaceContent] { local.content(of: page) }
    public var edited: [PageID: Int64] { local.edited }
    public var lastChanged: Set<RecordID> { local.lastChanged }

    @discardableResult
    public func edit(_ changes: [RecordChange], at: Int64) -> UndoEntry? {
        guard canEdit else { return nil }
        return local.edit(changes, at: at)
    }

    @discardableResult
    public func undo(_ entry: UndoEntry, at: Int64) -> UndoEntry? {
        guard canEdit else { return nil }
        return local.undo(entry, at: at)
    }

    /// Runs one write on the writer after every write queued before it.
    private func enqueue(_ work: @escaping @Sendable (LocalPageWriter) async throws -> Void) {
        guard let writer else { return }
        writeRevision += 1
        queuedWrites += 1
        isSaving = true
        let previous = tail
        tail = Task { [self] in
            await previous?.value
            defer {
                queuedWrites -= 1
                isSaving = queuedWrites > 0
                onSavingChange?()
            }
            guard failure == nil else { return }
            do { try await work(writer) }
            catch { fail(error) }
        }
        onSavingChange?()
    }

    public func flush() async throws {
        while true {
            let revision = writeRevision
            await tail?.value
            if revision == writeRevision { break }
        }
        if let failure { throw failure }
    }

    /// Used on disable after queued edits finish. No file or Keychain item is removed.
    public func close() async throws {
        closing = true
        defer { closing = false }
        try await flush()
        await writer?.close()
        writer = nil
        tail = nil
        isOpen = false
        isSaving = false
        attach(SpaceReplicaStore())
    }

    public func observe(_ callback: @escaping @MainActor () -> Void) -> Int {
        nextToken += 1
        observers[nextToken] = callback
        return nextToken
    }
    public func removeObserver(_ token: Int) { observers[token] = nil }
    private func publish() { for callback in observers.values { callback() } }
    private func fail(_ error: Error) { failure = error; onFailure?() }
}

private actor LocalPageWriter {
    let setup: SpaceLocalSetup
    var replica: SpaceReplica

    init(setup: SpaceLocalSetup) {
        self.setup = setup
        replica = SpaceReplica(device: setup.device, label: "This Mac")
    }

    func load() async throws -> SpaceState {
        let stored = try await setup.local.load()
        var confirmed = try SpaceState(snapshot: stored.snapshot)
        for frame in stored.frames { try confirmed.apply(frame, await setup.local.payload(of: frame)) }
        let pending = try stored.pending.map { operation in
            PendingOp(op: operation.op, payload: operation.payload,
                      bases: try operation.context["bases"]?.decoded([String: TextBase].self) ?? [:])
        }
        replica = SpaceReplica(device: setup.device, label: "This Mac", confirmed: confirmed, pending: pending)
        // A crash after pending was fsynced resumes that exact op before new edits can start.
        for operation in replica.pending { try await confirm(operation) }
        return replica.current
    }

    /// Keeps the screen's op id, so the frames it returns confirm the screen's own pending op.
    func save(_ changes: [RecordChange], at: Int64, op: OpID) async throws -> [(frame: LogFrame, payload: OpPayload)] {
        try replica.edit(changes, at: at, op: op)
        let pending = try replica.pending.map {
            SpacePendingOperation(op: $0.op, dev: setup.device, recs: $0.recs, payload: $0.payload,
                                  context: ["bases": try SpaceModel.JSONValue(encoding: $0.bases)])
        }
        try await setup.local.replacePending(pending)
        var frames: [(frame: LogFrame, payload: OpPayload)] = []
        for operation in replica.pending { frames.append(try await confirm(operation)) }
        return frames
    }

    @discardableResult
    private func confirm(_ operation: PendingOp) async throws -> (frame: LogFrame, payload: OpPayload) {
        let recs = operation.recs.map { SpaceRecordBase(id: $0.id.rawValue, rev: $0.base.map(Int.init)) }
        let ct = try setup.keys.sealFrame(SpaceJSON.encode(operation.payload), op: operation.op.rawValue,
                                          dev: setup.device.rawValue, recs: recs)
        let frame = LogFrame(seq: replica.confirmed.seq + 1, t: operation.payload.at, dev: setup.device,
                             op: operation.op, recs: operation.recs, ct: ct)
        try await setup.local.confirm(frame)
        try replica.receive([(frame, operation.payload)])
        return (frame, operation.payload)
    }

    func removeBlobs(_ ids: [String]) async throws { try await setup.local.removeBlobs(ids) }

    /// Replays the local snapshot and log; `save` confirms every op at once, so the log holds all of them.
    func history(of page: PageID, stretch: Int64) async throws -> [SpaceVersion] {
        let stored = try await setup.local.load()
        var ops: [(device: DeviceID, payload: OpPayload)] = []
        ops.reserveCapacity(stored.frames.count + stored.pending.count)
        for frame in stored.frames { ops.append((frame.dev, try await setup.local.payload(of: frame))) }
        for operation in stored.pending { ops.append((operation.dev, operation.payload)) }
        return SpaceHistory.versions(of: page, base: try SpaceState(snapshot: stored.snapshot), ops: ops, stretch: stretch)
    }

    func close() async { await setup.local.close() }
}
