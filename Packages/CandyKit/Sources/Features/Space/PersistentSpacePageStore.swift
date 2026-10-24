import Foundation
import SpaceCrypto
import SpaceEngine
import SpaceLocal
import SpaceModel

/// Immediate edits for the synchronous sidebar contract, followed by a serial durable write.
/// `isSaving` stays true until encrypted pending and confirmation reach disk. Failures stay visible
/// and block further edits and quitting; they never fall back to an empty in-memory store.
@MainActor
public final class PersistentSpacePageStore: SpacePageStore {
    public private(set) var pages: [PageID: PageRecord] = [:]
    public private(set) var isSaving = false
    public private(set) var failure: Error?
    public private(set) var isOpen = false
    public var onFailure: (@MainActor () -> Void)?
    public var onSavingChange: (@MainActor () -> Void)?
    private var state = SpaceState()
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
            state = try await writer.load()
            self.writer = writer
            failure = nil
            isOpen = true
            publish()
            return setup
        } catch {
            await setup.local.close()
            throw error
        }
    }

    public func put(_ records: [PageID: PageRecord]) {
        guard isOpen, !closing, failure == nil else { return }
        do {
            let changes = try records.keys.sorted().compactMap { id -> RecordChange? in
                let replacement = try RecordChange.page(id, records[id]!).set
                let old = state.pages[id] ?? [:]
                var set: [String: SpaceModel.JSONValue] = [:]
                for key in Set(old.keys).union(replacement.keys) where old[key] != replacement[key] {
                    set[key] = replacement[key] ?? .null
                }
                return set.isEmpty ? nil : RecordChange(kind: .page, id: id, set: set)
            }
            enqueue(changes)
        } catch { fail(error) }
    }

    /// Null every key through apply, leaving an unrenderable empty record and its encrypted history.
    public func remove(_ id: PageID) {
        guard isOpen, !closing, failure == nil, let old = state.pages[id], !old.isEmpty else { return }
        enqueue([RecordChange(kind: .page, id: id, set: old.mapValues { _ in .null })])
    }

    private func enqueue(_ changes: [RecordChange]) {
        guard !changes.isEmpty, let writer else { return }
        let at = SpaceClock.now()
        state.apply(changes)
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
            do { try await writer.save(changes, at: at) }
            catch { fail(error) }
        }
        onSavingChange?()
        publish(changes)
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
        state = SpaceState()
        pages = [:]
        isOpen = false
        isSaving = false
        publish()
    }

    public func observe(_ callback: @escaping @MainActor () -> Void) -> Int {
        nextToken += 1
        observers[nextToken] = callback
        return nextToken
    }
    public func removeObserver(_ token: Int) { observers[token] = nil }
    private func publish(_ changes: [RecordChange]? = nil) {
        if let changes {
            for change in changes where change.kind == .page { pages[change.id] = state.page(change.id) }
        } else {
            pages = state.pages.compactMapValues { try? SpaceModel.JSONValue.object($0).decoded(PageRecord.self) }
        }
        for callback in observers.values { callback() }
    }
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

    func save(_ changes: [RecordChange], at: Int64) async throws {
        try replica.edit(changes, at: at)
        let pending = try replica.pending.map {
            SpacePendingOperation(op: $0.op, dev: setup.device, recs: $0.recs, payload: $0.payload,
                                  context: ["bases": try SpaceModel.JSONValue(encoding: $0.bases)])
        }
        try await setup.local.replacePending(pending)
        for operation in replica.pending { try await confirm(operation) }
    }

    private func confirm(_ operation: PendingOp) async throws {
        let recs = operation.recs.map { SpaceRecordBase(id: $0.id.rawValue, rev: $0.base.map(Int.init)) }
        let ct = try setup.keys.sealFrame(SpaceJSON.encode(operation.payload), op: operation.op.rawValue,
                                          dev: setup.device.rawValue, recs: recs)
        let frame = LogFrame(seq: replica.confirmed.seq + 1, t: operation.payload.at, dev: setup.device,
                             op: operation.op, recs: operation.recs, ct: ct)
        try await setup.local.confirm(frame)
        try replica.receive([(frame, operation.payload)])
    }

    func close() async { await setup.local.close() }
}
