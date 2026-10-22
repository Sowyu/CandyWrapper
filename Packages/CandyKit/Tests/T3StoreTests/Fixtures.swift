import Foundation
import T3Protocol
@testable import T3Store

/// Every `orchestration.subscribeShell` Chunk from a recorded transcript, decoded, one array per
/// Chunk so replays keep the server's batching.
func recordedShellChunks(_ name: String) throws -> [[ShellStreamItem]] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/transcripts/\(name)")
    var shellIds = Set<String>()
    var chunks: [[ShellStreamItem]] = []
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            record["kind"] as? String == "ws", let body = record["body"] as? [String: Any]
        else { continue }
        if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeShell",
            let id = body["id"] as? String
        {
            shellIds.insert(id)
        } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String,
            shellIds.contains(id), let values = body["values"] as? [Any]
        {
            chunks.append(try values.map {
                try JSONDecoder().decode(ShellStreamItem.self, from: JSONSerialization.data(withJSONObject: $0))
            })
        }
    }
    return chunks
}

/// T3's `v2ThreadShell` fixture (packages/client-runtime/src/state/orchestrationV2TestFixtures.ts).
let baseThreadJSON = """
    {"id":"thread-v2","projectId":"project-v2","title":"Thread","providerInstanceId":"codex",
     "modelSelection":{"instanceId":"codex","model":"gpt-5.4"},"runtimeMode":"full-access",
     "interactionMode":"default","branch":null,"worktreePath":null,"activeProviderThreadId":null,
     "lineage":{"rootThreadId":"thread-v2","parentThreadId":null,"relationshipToParent":null},
     "forkedFrom":null,"createdBy":"user","creationSource":"web","latestRunId":null,"activeRunId":null,
     "status":"idle","pendingRuntimeRequest":null,"latestVisibleMessage":null,"latestUserMessageAt":null,
     "hasActionableProposedPlan":false,"itemCount":0,"visibleItemCount":0,
     "createdAt":"2026-06-20T00:00:00.000Z","updatedAt":"2026-06-20T00:00:00.000Z","archivedAt":null,
     "settledOverride":null,"settledAt":null,"lastVisitedAt":null,"deletedAt":null}
    """

/// T3's `v2Project` fixture.
let baseProjectJSON = """
    {"id":"project-v2","title":"Project","workspaceRoot":"/workspace/project","repositoryIdentity":null,
     "defaultModelSelection":null,"scripts":[],"createdAt":"2026-06-20T00:00:00.000Z",
     "updatedAt":"2026-06-20T00:00:00.000Z"}
    """

let baseThread = try! JSONDecoder().decode(ThreadShell.self, from: Data(baseThreadJSON.utf8))
let baseProject = try! JSONDecoder().decode(ProjectShell.self, from: Data(baseProjectJSON.utf8))
let baseSnapshot = ShellSnapshot(schemaVersion: 1, snapshotSequence: 0, threads: [baseThread], projects: [baseProject])

func thread(_ id: String = "thread-v2", _ edit: (inout ThreadShell) -> Void = { _ in }) -> ThreadShell {
    var t = baseThread
    t.id = ThreadId(id)
    t.lineage.rootThreadId = t.id
    edit(&t)
    return t
}

func sidebarThread(_ id: String = "thread-v2", _ edit: (inout ThreadShell) -> Void = { _ in }) -> SidebarThread {
    SidebarThread(thread(id, edit))
}

func project(_ id: String = "project-v2", _ edit: (inout ProjectShell) -> Void = { _ in }) -> ProjectShell {
    var p = baseProject
    p.id = ProjectId(id)
    edit(&p)
    return p
}

func identity(_ key: String) -> RepositoryIdentity {
    try! JSONDecoder().decode(RepositoryIdentity.self, from: Data("""
        {"canonicalKey":"\(key)","locator":{"source":"git-remote","remoteName":"origin","remoteUrl":"https://\(key).git"}}
        """.utf8))
}

func ms(_ iso: String) -> Int64 { T3Timestamp.parseEpochMs(iso)! }

/// A `SleepClock` the test steps by hand. Sleepers wake only in `advance(by:)`.
final class ManualClock: @unchecked Sendable {
    // NSLock guards everything below.
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [Int: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<Int> = []
    private var nextID = 0
    private var started = 0

    var clock: SleepClock { SleepClock(now: { self.now }, sleep: { duration, _ in try await self.sleep(duration) }) }
    var now: ContinuousClock.Instant { lock.withLock { start + offset } }
    /// Sleeps begun so far, woken or not.
    var sleepCount: Int { lock.withLock { started } }
    /// Sleeps waiting for `advance`.
    var waiting: Int { lock.withLock { sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id: Int = lock.withLock { nextID += 1; started += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let result: Result<Void, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if duration <= .zero { return .success(()) }
                    sleepers[id] = (offset + duration, c)
                    return nil
                }
                if let result { c.resume(with: result) }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let s = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return nil }
                return s.continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper that is due.
    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            offset += duration
            let ready = sleepers.filter { $0.value.deadline <= offset }
            for id in ready.keys { sleepers[id] = nil }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

/// Polls until `condition` holds or `seconds` pass. Use it only for things that will happen; the
/// long cap keeps a busy machine from failing it.
@MainActor func eventually(seconds: Int = 30, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<(seconds * 200) {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
