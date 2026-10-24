import Darwin
import Foundation
import Testing
import SpaceCrypto
import SpaceModel
@testable import SpaceLocal

private let spaceID = try! SpaceID("00000000-0000-4000-8000-000000000001")
private let deviceID = try! DeviceID("00000000-0000-4000-8000-000000000002")
private let recordID = try! RecordID("00000000-0000-4000-8000-000000000003")
private let secret = "Space private plaintext 7f3c9e groceries tomorrow"
private let testKey = try! SpaceKey(rawBytes: Data(repeating: 0x34, count: 32))
private var keys: SpaceKeys { get throws { try SpaceKeys(key: testKey, spaceId: spaceID.rawValue) } }
private enum Interrupted: Error { case crash }

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var steps: [DiskStep] = []
    private var stop: Int?
    func arm(_ stop: Int? = nil) { lock.withLock { enabled = true; steps = []; self.stop = stop } }
    func visit(_ step: DiskStep) throws {
        try lock.withLock {
            guard enabled else { return }
            steps.append(step)
            if steps.count == stop { throw Interrupted.crash }
        }
    }
    var recorded: [DiskStep] { lock.withLock { steps } }
}

private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("space-local-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func allFiles(_ directory: URL) -> [URL] {
    FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects.compactMap { $0 as? URL }
}

private func pending(_ number: Int = 4) -> SpacePendingOperation {
    SpacePendingOperation(op: try! OpID(String(format: "00000000-0000-4000-8000-%012d", number)), dev: deviceID,
                          recs: [RecordRevision(id: recordID, base: nil)],
                          payload: OpPayload(at: 1, changes: [RecordChange(kind: .page, id: recordID, set: ["title": .string(secret)])]),
                          context: ["baseText": .string(secret)])
}

private func frame(_ operation: SpacePendingOperation = pending(), seq: Int64 = 1) throws -> LogFrame {
    let recs = operation.recs.map { SpaceRecordBase(id: $0.id.rawValue, rev: $0.base.map(Int.init)) }
    return try LogFrame(seq: seq, t: 2, dev: operation.dev, op: operation.op, recs: operation.recs,
                        ct: keys.sealFrame(SpaceJSON.encode(operation.payload), op: operation.op.rawValue, dev: operation.dev.rawValue, recs: recs))
}

private func snapshot(_ seq: Int64) throws -> SnapshotPayload {
    try SnapshotPayload(seq: seq, pages: [recordID.rawValue: PageRecord(order: OrderKey("a0"), title: secret, created: 1)],
                        revs: [recordID.rawValue: seq])
}

private func setup(_ directory: URL) async throws {
    let store = try SpaceLocalStore(directory: directory, keys: keys)
    try await store.replacePending([pending()])
    await store.close()
}

private func edit(_ directory: URL, probe: Probe, action: String) async throws {
    let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: probe.visit)
    if action == "snapshot" { try await store.confirm(frame()) }
    if action == "eviction" {
        let old = Data(repeating: 1, count: 200)
        try await store.cacheBlob(old, id: keys.blobId(of: old))
    }
    if action == "touch" {
        let data = Data(secret.utf8)
        try await store.cacheBlob(data, id: keys.blobId(of: data))
    }
    probe.arm()
    switch action {
    case "pending": try await store.replacePending([pending(), pending(5)])
    case "confirm": try await store.confirm(frame())
    case "snapshot": try await store.saveSnapshot(snapshot(1))
    case "touch": _ = try await store.cachedBlob(id: keys.blobId(of: Data(secret.utf8)))
    case "cache", "eviction":
        let data = Data(secret.utf8)
        try await store.cacheBlob(data, id: keys.blobId(of: data))
    default: Issue.record("Unknown action")
    }
    await store.close()
}

// A second entry point arms the failure after setup, not during initialization or the first confirmation.
private func interrupt(_ directory: URL, probe: Probe, action: String, at: Int) async throws {
    let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: probe.visit)
    if action == "snapshot" { try await store.confirm(frame()) }
    if action == "eviction" {
        let old = Data(repeating: 1, count: 200)
        try await store.cacheBlob(old, id: keys.blobId(of: old))
    }
    if action == "touch" {
        let data = Data(secret.utf8)
        try await store.cacheBlob(data, id: keys.blobId(of: data))
    }
    probe.arm(at)
    do {
        switch action {
        case "pending": try await store.replacePending([pending(), pending(5)])
        case "confirm": try await store.confirm(frame())
        case "snapshot": try await store.saveSnapshot(snapshot(1))
        case "touch": _ = try await store.cachedBlob(id: keys.blobId(of: Data(secret.utf8)))
        default:
            let data = Data(secret.utf8)
            try await store.cacheBlob(data, id: keys.blobId(of: data))
        }
        Issue.record("Interrupted mutation returned success")
    } catch Interrupted.crash {
        await #expect(throws: SpaceLocalError.reopenRequired) { try await store.load() }
    }
    await store.close()
}

struct SpaceLocalTests {
    @Test func roundTripConfirmationCheckpointAndRestart() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        try await confirmAndCheckpoint(directory)
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        let state = try await store.load()
        #expect(try state.snapshot == snapshot(1))
        #expect(state.frames.isEmpty && state.pending.isEmpty)
        #expect(state.confirmedSequence == 1)
        await #expect(throws: SpaceLocalError.sequenceMismatch) { try await store.checkRemoteSequence(0) }
        try await store.checkRemoteSequence(1)
    }

    private func confirmAndCheckpoint(_ directory: URL) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        let f = try frame()
        try await store.confirm(f)
        try await store.confirm(f)
        #expect(try await store.payload(of: f) == pending().payload)
        let state = try await store.load()
        #expect(state.pending.isEmpty && state.frames == [f])
        try await store.saveSnapshot(snapshot(1))
        await store.close()
    }

    @Test func checkpointKeepsLaterFramesAndOfflineEdits() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkpointWithTail(directory)
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        let state = try await store.load()
        #expect(state.snapshot.seq == 1)
        #expect(state.frames.map(\.seq) == [2])
        #expect(state.pending == [pending(6)])
        #expect(state.confirmedSequence == 2)
        await #expect(throws: SpaceLocalError.sequenceMismatch) { try await store.saveSnapshot(snapshot(0)) }
        try await store.saveSnapshot(snapshot(100))
        #expect(try await store.load().confirmedSequence == 100)
        #expect(try await store.load().pending == [pending(6)])
    }

    private func checkpointWithTail(_ directory: URL) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        try await store.confirm(frame())
        try await store.confirm(frame(pending(5), seq: 2))
        try await store.replacePending([pending(6)])
        try await store.saveSnapshot(snapshot(1))
        await store.close()
    }

    @Test(arguments: ["pending", "confirm", "snapshot", "cache", "eviction", "touch"])
    func interruptedAtEveryWriteBoundaryRecovers(_ action: String) async throws {
        let sample = try root()
        defer { try? FileManager.default.removeItem(at: sample) }
        try await setup(sample)
        let trace = Probe()
        try await edit(sample, probe: trace, action: action)
        #expect(!trace.recorded.isEmpty)
        if action == "confirm" {
            #expect(trace.recorded.last == DiskStep(path: "transaction.cws", phase: "removalSynced"))
            #expect(trace.recorded.contains(DiskStep(path: "log.cws", phase: "synced")))
            #expect(trace.recorded.contains(DiskStep(path: "pending.cws", phase: "directorySynced")))
        }
        for stop in 1...trace.recorded.count {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await setup(directory)
            let probe = Probe()
            try await interrupt(directory, probe: probe, action: action, at: stop)
            let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: { _ in })
            let state = try await store.load()
            switch action {
            case "confirm":
                #expect((state.confirmedSequence == 0 && state.pending == [pending()]) ||
                        (state.confirmedSequence == 1 && state.pending.isEmpty))
                if state.confirmedSequence == 0 { try await store.confirm(frame()) }
                #expect(try await store.load().frames.count == 1)
            case "pending": #expect(state.pending == [pending()] || state.pending == [pending(), pending(5)])
            case "snapshot":
                #expect(state.confirmedSequence == 1 && state.pending.isEmpty)
                #expect(state.snapshot.seq == 0 || state.snapshot.seq == 1)
            default:
                let data = Data(secret.utf8)
                if let cached = try await store.cachedBlob(id: keys.blobId(of: data)) { #expect(cached == data) }
                #expect(try await store.cachedBlobBytes() <= 400)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("transaction.cws").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".tmp-") })
        }
    }

    @Test func plaintextNeverReachesAnyFileIncludingInterruptedWrites() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        try await confirmAndCheckpoint(directory)
        let probe = Probe()
        try await leaveInterruptedPending(directory, probe: probe)
        // Leave the partial temporary ciphertext and durable journal on disk while grep scans them.
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-a", "-r", "-l", "-F", secret, directory.path]
        grep.standardOutput = Pipe()
        grep.standardError = Pipe()
        try grep.run()
        grep.waitUntilExit()
        #expect(grep.terminationStatus == 1)
        let files = allFiles(directory)
        for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            let data = try Data(contentsOf: file)
            #expect(data.range(of: Data(secret.utf8)) == nil)
            #expect(data.range(of: Data(recordID.rawValue.utf8)) == nil)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    private func leaveInterruptedPending(_ directory: URL, probe: Probe) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: probe.visit)
        let blob = Data(secret.utf8)
        try await store.cacheBlob(blob, id: keys.blobId(of: blob))
        probe.arm(9) // journal durable, pending replacement partially written
        do { try await store.replacePending([pending(6)]) } catch Interrupted.crash {}
        await store.close()
    }

    @Test(arguments: ["snapshot.cws", "pending.cws", "log.cws", "cache.cws"])
    func tamperedFilesFailClosed(_ path: String) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        try await addFrame(directory)
        let url = directory.appendingPathComponent(path)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 65 ? 66 : 65
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try SpaceLocalStore(directory: directory, keys: keys) }
    }

    private func addFrame(_ directory: URL) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        try await store.confirm(frame())
        await store.close()
    }

    @Test func missingAndTruncatedLogAreDetectedAndWrongKeyFails() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        try await addFrame(directory)
        let wrong = try SpaceKeys(key: .generate(), spaceId: spaceID.rawValue)
        #expect(throws: (any Error).self) { try SpaceLocalStore(directory: directory, keys: wrong) }
        let url = directory.appendingPathComponent("log.cws")
        let original = try Data(contentsOf: url)
        try original.dropLast().write(to: url)
        #expect(throws: (any Error).self) { try SpaceLocalStore(directory: directory, keys: keys) }
        try Data().write(to: url)
        #expect(throws: SpaceLocalError.corruptStore) { try SpaceLocalStore(directory: directory, keys: keys) }
        try FileManager.default.removeItem(at: url)
        #expect(throws: SpaceLocalError.incompleteStore) { try SpaceLocalStore(directory: directory, keys: keys) }
    }

    @Test func deletedStateFilesDoNotBecomeANewEmptySpace() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        for name in ["snapshot.cws", "log.cws", "pending.cws"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        #expect(throws: SpaceLocalError.incompleteStore) { try SpaceLocalStore(directory: directory, keys: keys) }
    }

    @Test func closeReleasesLockEvenWithAnInheritedDescriptor() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        // dup shares the open file description, as a child does between fork and exec.
        let duplicate = try duplicateLock(directory)
        defer { Darwin.close(duplicate) }
        await store.close()
        let reopened = try SpaceLocalStore(directory: directory, keys: keys)
        #expect(try await reopened.load().confirmedSequence == 0)
        await #expect(throws: SpaceLocalError.reopenRequired) { try await store.load() }
        await reopened.close()
    }

    private func duplicateLock(_ directory: URL) throws -> Int32 {
        let file = try FileHandle(forReadingFrom: directory.appendingPathComponent("lock"))
        defer { try? file.close() }
        var target = stat()
        guard fstat(file.fileDescriptor, &target) == 0 else { throw SpaceDisk.ioError() }
        for fd in Int32(0)..<Int32(getdtablesize()) where fd != file.fileDescriptor {
            var candidate = stat()
            if fstat(fd, &candidate) == 0, candidate.st_dev == target.st_dev, candidate.st_ino == target.st_ino {
                let duplicate = Darwin.dup(fd)
                guard duplicate >= 0 else { throw SpaceDisk.ioError() }
                return duplicate
            }
        }
        throw SpaceLocalError.corruptStore
    }

    @Test func failedOpenReleasesLockImmediately() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        let wrong = try SpaceKeys(key: .generate(), spaceId: spaceID.rawValue)
        for _ in 0..<50 {
            #expect(throws: SpaceCryptoError.authenticationFailed) { try SpaceLocalStore(directory: directory, keys: wrong) }
            let store = try SpaceLocalStore(directory: directory, keys: keys)
            #expect(try await store.load().pending == [pending()])
            await store.close()
        }
    }

    @Test func sequenceChecksAndWriterExclusion() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        #expect(throws: SpaceLocalError.storeInUse) { try SpaceLocalStore(directory: directory, keys: keys) }
        await #expect(throws: SpaceLocalError.sequenceMismatch) { try await store.confirm(frame(seq: 2)) }
        try await store.replacePending([pending()])
        var wrong = pending()
        wrong.payload.at = 123
        await #expect(throws: SpaceLocalError.operationMismatch) { try await store.confirm(frame(wrong)) }
        #expect(try await store.load().pending == [pending()])
        try await store.confirm(frame())
        await #expect(throws: SpaceLocalError.operationMismatch) { try await store.replacePending([pending()]) }
    }
}

struct SpaceBlobCacheTests {
    @Test func ciphertextBytesAndLRUSurviveRestart() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = Data(repeating: 1, count: 20), b = Data(repeating: 2, count: 20), c = Data(repeating: 3, count: 20)
        try await seedAndTouch(directory, a, b)
        let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 150, fault: { _ in })
        try await store.cacheBlob(c, id: keys.blobId(of: c))
        #expect(try await store.cachedBlob(id: keys.blobId(of: b)) == nil)
        #expect(try await store.cachedBlob(id: keys.blobId(of: a)) == a)
        #expect(try await store.cachedBlob(id: keys.blobId(of: c)) == c)
        let bytes = try await store.cachedBlobBytes()
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        let actual = try files.reduce(UInt64(0)) { total, file in
            total + UInt64(try Data(contentsOf: file).count)
        }
        #expect(bytes == actual && bytes == 130)
        await #expect(throws: SpaceLocalError.blobTooLarge) {
            let tooBig = Data(repeating: 0, count: 100)
            try await store.cacheBlob(tooBig, id: keys.blobId(of: tooBig))
        }
        #expect(try await store.cachedBlobBytes() == bytes)
    }

    private func seedAndTouch(_ directory: URL, _ a: Data, _ b: Data) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 150, fault: { _ in })
        try await store.cacheBlob(a, id: keys.blobId(of: a))
        try await store.cacheBlob(b, id: keys.blobId(of: b))
        #expect(try await store.cachedBlob(id: keys.blobId(of: a)) == a)
        await store.close()
    }

    @Test func actualOneGBLimitEvictsSparseFilesInLRUOrder() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        // Sparse stand-ins exercise the real byte limit without allocating or writing a gigabyte.
        // Blob authentication is checked separately on reads, not while evicting unopened entries.
        try sparseCache(directory)
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        #expect(SpaceLocalStore.blobCacheLimit == 1_000_000_000)
        #expect(try await store.cachedBlobBytes() == 600_000_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path)
        #expect(!names.contains(String(repeating: "a", count: 64) + ".cws"))
        #expect(names.contains(String(repeating: "b", count: 64) + ".cws"))
        #expect(names.contains(String(repeating: "c", count: 64) + ".cws"))
    }

    private func sparseCache(_ directory: URL) throws {
        let disk = try SpaceDisk(root: directory, keys: keys)
        var index = CacheIndex(clock: 3)
        for (n, letter) in ["a", "b", "c"].enumerated() {
            let id = String(repeating: letter, count: 64)
            let size: UInt64 = n == 0 ? 400_000_001 : 300_000_000
            let path = disk.url("blobs/\(id).cws")
            #expect(FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]))
            let file = try FileHandle(forWritingTo: path)
            try file.truncate(atOffset: size)
            try file.close()
            index.entries[id] = CacheEntry(bytes: size, access: UInt64(n + 1))
        }
        try disk.atomicWrite(disk.seal(SpaceJSON.encode(index), purpose: "cache"), to: "cache.cws")
    }

    @Test(arguments: [0, 1, SpaceKeys.blobChunkSize - 1, SpaceKeys.blobChunkSize, SpaceKeys.blobChunkSize + 1])
    func chunkBoundariesAndSizeAccounting(_ count: Int) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        let data = Data(repeating: 0x61, count: count)
        let id = try keys.blobId(of: data)
        try await store.cacheBlob(data, id: id)
        #expect(try await store.cachedBlob(id: id) == data)
        #expect(try await store.cachedBlobBytes() == SpaceLocalStore.encodedBlobSize(count))
        try await store.cacheBlob(data, id: id)
        #expect(try await store.cachedBlobBytes() == SpaceLocalStore.encodedBlobSize(count))
    }

    @Test(arguments: ["flip", "reorder", "truncate", "rename"])
    func damagedBlobIsNeverReturned(_ mode: String) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        let data = Data(repeating: 7, count: SpaceKeys.blobChunkSize + 100)
        let id = try keys.blobId(of: data)
        try await store.cacheBlob(data, id: id)
        let file = directory.appendingPathComponent("blobs/\(id).cws")
        let original = try Data(contentsOf: file)
        var damaged = original
        switch mode {
        case "flip": damaged[20] = damaged[20] == 65 ? 66 : 65
        case "reorder":
            let lines = original.split(separator: 0x0a)
            damaged = Data(lines[1]); damaged.append(0x0a); damaged.append(contentsOf: lines[0]); damaged.append(0x0a)
        case "truncate": damaged = Data(original.split(separator: 0x0a)[0]); damaged.append(0x0a)
        default:
            let other = Data(repeating: 8, count: data.count)
            let otherID = try keys.blobId(of: other)
            try await store.cacheBlob(other, id: otherID)
            damaged = try Data(contentsOf: directory.appendingPathComponent("blobs/\(otherID).cws"))
        }
        try damaged.write(to: file)
        await #expect(throws: (any Error).self) { try await store.cachedBlob(id: id) }
    }

    @Test func rejectsInvalidIDsAndMismatchedContent() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SpaceLocalStore(directory: directory, keys: keys)
        await #expect(throws: SpaceLocalError.invalidBlobID) { try await store.cachedBlob(id: "../pending") }
        await #expect(throws: SpaceCryptoError.authenticationFailed) { try await store.cacheBlob(Data(), id: String(repeating: "a", count: 64)) }
    }
}

struct SpaceRecoveryTests {
    @Test func initializationSurvivesEveryWriteBoundary() async throws {
        let sample = try root()
        defer { try? FileManager.default.removeItem(at: sample) }
        let probe = Probe()
        probe.arm()
        try bootstrap(sample, probe)
        for stop in 1...probe.recorded.count {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = Probe()
            fault.arm(stop)
            #expect(throws: Interrupted.self) { try bootstrap(directory, fault) }
            let store = try SpaceLocalStore(directory: directory, keys: keys)
            #expect(try await store.load().confirmedSequence == 0)
        }
    }

    private func bootstrap(_ directory: URL, _ probe: Probe) throws {
        _ = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: probe.visit)
    }

    @Test func recoveryItselfSurvivesAnotherCrash() async throws {
        let sample = try root()
        defer { try? FileManager.default.removeItem(at: sample) }
        try await setup(sample)
        try await leaveTornAppend(sample)
        let trace = Probe()
        trace.arm()
        try bootstrap(sample, trace)
        for stop in 1...trace.recorded.count {
            let directory = try root()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await setup(directory)
            try await leaveTornAppend(directory)
            let fault = Probe()
            fault.arm(stop)
            #expect(throws: Interrupted.self) { try bootstrap(directory, fault) }
            let store = try SpaceLocalStore(directory: directory, keys: keys)
            let state = try await store.load()
            #expect(state.confirmedSequence == 1 && state.frames.count == 1 && state.pending.isEmpty)
        }
    }

    private func leaveTornAppend(_ directory: URL) async throws {
        let store = try SpaceLocalStore(directory: directory, keys: keys, cacheLimit: 400, fault: { step in
            if step == DiskStep(path: "log.cws", phase: "partial") { throw Interrupted.crash }
        })
        do { try await store.confirm(frame()); Issue.record("Expected interrupted append") } catch Interrupted.crash {}
        await store.close()
    }

    @Test func tamperedRecoveryJournalFailsBeforeReplay() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await setup(directory)
        try await leaveTornAppend(directory)
        let journal = directory.appendingPathComponent("transaction.cws")
        var bytes = try Data(contentsOf: journal)
        bytes[30] = bytes[30] == 65 ? 66 : 65
        try bytes.write(to: journal)
        #expect(throws: (any Error).self) { try SpaceLocalStore(directory: directory, keys: keys) }
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }
}
