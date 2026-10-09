import Foundation
import T3Protocol
import T3Store

/// Sidebar data without a server: a recorded transcript replayed through ShellReducer, and synthetic
/// datasets shaped like the reference captures. The gallery and the tests use these.
public enum SidebarPreview {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The clock the synthetic datasets are written against.
    public static let referenceNow = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!

    /// Replays every `orchestration.subscribeShell` Chunk of a transcript (default 03-turn2.jsonl) through the reducer.
    public static func replayedSnapshot(transcript: String = "03-turn2.jsonl") throws -> ShellSnapshot? {
        let url = repo.appendingPathComponent("fixtures/transcripts/\(transcript)")
        var shellIds = Set<String>()
        var reducer = ShellReducer()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["kind"] as? String == "ws", let body = record["body"] as? [String: Any] else { continue }
            if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeShell", let id = body["id"] as? String {
                shellIds.insert(id)
            } else if body["_tag"] as? String == "Chunk", let id = body["requestId"] as? String, shellIds.contains(id),
                      let values = body["values"] as? [Any] {
                let items = try values.map {
                    try JSONDecoder().decode(ShellStreamItem.self, from: JSONSerialization.data(withJSONObject: $0))
                }
                _ = reducer.apply(items)
            }
        }
        return reducer.snapshot
    }

    // MARK: Synthetic

    static func iso(_ minutesAgo: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: referenceNow.addingTimeInterval(-minutesAgo * 60))
    }

    static func project(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "title": title, "workspaceRoot": "/Users/demo/\(title)", "repositoryIdentity": NSNull(),
         "defaultModelSelection": NSNull(), "scripts": [], "createdAt": iso(600), "updatedAt": iso(600)]
    }

    enum Kind { case done, read, input, approval, working, failed, waiting }

    static func thread(_ id: String, _ title: String, project: String, kind: Kind, minutesAgo: Double,
                       extra: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = [
            "id": id, "projectId": project, "title": title, "providerInstanceId": "claudeAgent",
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-haiku-5-5"], "runtimeMode": "full-access",
            "interactionMode": "default", "branch": NSNull(), "worktreePath": NSNull(), "activeProviderThreadId": NSNull(),
            "lineage": ["rootThreadId": id, "parentThreadId": NSNull(), "relationshipToParent": NSNull()],
            "forkedFrom": NSNull(), "createdBy": "user", "creationSource": "web", "latestRunId": "run-\(id)",
            "activeRunId": NSNull(), "status": "completed", "pendingRuntimeRequest": NSNull(), "latestVisibleMessage": NSNull(),
            "latestUserMessageAt": iso(minutesAgo), "hasActionableProposedPlan": false, "itemCount": 4, "visibleItemCount": 4,
            "latestRunRequestedAt": iso(minutesAgo), "latestRunStartedAt": iso(minutesAgo),
            "latestRunCompletedAt": iso(minutesAgo - 0.5), "createdAt": iso(minutesAgo + 1), "updatedAt": iso(minutesAgo - 0.5),
            "archivedAt": NSNull(), "settledOverride": NSNull(), "settledAt": NSNull(), "deletedAt": NSNull(),
            "lastVisitedAt": iso(minutesAgo - 1),
        ]
        switch kind {
        case .done: t["lastVisitedAt"] = iso(minutesAgo + 0.2)
        case .read: break
        case .input:
            t["status"] = "waiting"; t["latestRunCompletedAt"] = NSNull()
            t["pendingRuntimeRequest"] = ["id": "req-\(id)", "kind": "user_input", "createdAt": iso(minutesAgo - 0.2)]
        case .approval:
            t["status"] = "waiting"; t["latestRunCompletedAt"] = NSNull()
            t["pendingRuntimeRequest"] = ["id": "req-\(id)", "kind": "file-change", "createdAt": iso(minutesAgo - 0.2)]
        case .working:
            t["status"] = "running"; t["activeRunId"] = "run-\(id)"; t["latestRunCompletedAt"] = NSNull()
            t["activityRunStatus"] = "running"; t["activityRunStartedAt"] = iso(minutesAgo)
        case .failed: t["status"] = "failed"; t["lastError"] = "Provider error"
        case .waiting: t["status"] = "idle"; t["latestRunId"] = NSNull()
        }
        t.merge(extra) { $1 }
        return t
    }

    static func snapshot(projects: [[String: Any]], threads: [[String: Any]]) -> ShellSnapshot {
        let json: [String: Any] = ["schemaVersion": 1, "snapshotSequence": 1, "threads": threads, "archivedThreads": [], "projects": projects]
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ShellSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The content of design/reference/02-sidebar-populated: eight demo-repo threads, three Done, three
    /// read, one Input and one Approval, the fifth one open.
    public static func referenceSnapshot() -> ShellSnapshot {
        let p = "project-demo"
        return snapshot(projects: [project(p, "demo-repo")], threads: [
            thread("t1", "Write a 700 word story about a lighthouse keeper", project: p, kind: .done, minutesAgo: 2),
            thread("t2", "Write a 700 word story about a robot gardener", project: p, kind: .done, minutesAgo: 3),
            thread("t3", "Run exactly this shell command and report back", project: p, kind: .done, minutesAgo: 4),
            thread("t4", "$cloudflare-one-migrations Plan a migration", project: p, kind: .read, minutesAgo: 16),
            thread("t5", "Reply with markdown only, no tools. Include: an H1", project: p, kind: .read, minutesAgo: 17),
            thread("t6", "Reply with markdown containing a table", project: p, kind: .read, minutesAgo: 18),
            thread("t7", "Use your question tool (AskUserQuestion) to ask me", project: p, kind: .input, minutesAgo: 19),
            thread("t8", "Create a file named approval-demo.txt", project: p, kind: .approval, minutesAgo: 20),
        ])
    }

    public static let referenceActiveThread = ThreadId("t5")

    /// A fuller sidebar: several projects, pinned, running, approval, input, unread, failed, snoozed and settled.
    public static func richSnapshot() -> ShellSnapshot {
        snapshot(projects: [project("p1", "demo-repo"), project("p2", "candywrapper"), project("p3", "t3code")], threads: [
            thread("r1", "Ship the sidebar virtualization", project: "p2", kind: .working, minutesAgo: 2,
                   extra: ["pinnedAt": iso(300), "branch": "m3-skeleton", "worktreePath": "/tmp/wt"]),
            thread("r2", "Pin the release checklist", project: "p3", kind: .read, minutesAgo: 140, extra: ["pinnedAt": iso(200)]),
            thread("r3", "Create a file named approval-demo.txt", project: "p1", kind: .approval, minutesAgo: 5),
            thread("r4", "Use your question tool to ask me", project: "p1", kind: .input, minutesAgo: 7),
            thread("r5", "Write a 700 word story about a lighthouse keeper", project: "p1", kind: .done, minutesAgo: 9),
            thread("r6", "Port the timestamp formatter", project: "p2", kind: .working, minutesAgo: 1),
            thread("r7", "Fix flaky reconnect test", project: "p3", kind: .failed, minutesAgo: 30, extra: ["branch": "fix/reconnect"]),
            thread("r8", "Reply with markdown containing a table", project: "p1", kind: .read, minutesAgo: 75),
            thread("r9", "Look at this tomorrow", project: "p2", kind: .read, minutesAgo: 400,
                   extra: ["snoozedUntil": iso(-90), "snoozedAt": iso(60)]),
            thread("r10", "Rename the store actor", project: "p2", kind: .read, minutesAgo: 1500,
                   extra: ["settledOverride": "settled", "settledAt": iso(1400)]),
            thread("r11", "Draft the protocol notes", project: "p3", kind: .read, minutesAgo: 3000,
                   extra: ["settledOverride": "settled", "settledAt": iso(2900)]),
        ])
    }
}
