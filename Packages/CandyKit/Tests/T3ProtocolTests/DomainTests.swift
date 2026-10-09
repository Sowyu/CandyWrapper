import Foundation
import Testing
@testable import T3Protocol

/// Every `orchestration.subscribeShell` Chunk value in a recorded transcript, as raw JSON.
func recordedShellValues(_ name: String) throws -> [Data] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/transcripts/\(name)")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let records = try lines.map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:]
    }
    var shellIds = Set<String>()
    var values: [Data] = []
    for record in records where record["kind"] as? String == "ws" {
        guard let body = record["body"] as? [String: Any] else { continue }
        if record["dir"] as? String == "send", body["tag"] as? String == "orchestration.subscribeShell",
            let id = body["id"] as? String
        {
            shellIds.insert(id)
        } else if record["dir"] as? String == "recv", body["_tag"] as? String == "Chunk",
            let id = body["requestId"] as? String, shellIds.contains(id),
            let chunk = body["values"] as? [Any]
        {
            values += try chunk.map { try JSONSerialization.data(withJSONObject: $0) }
        }
    }
    return values
}

@Suite struct DomainTests {
    @Test(arguments: [("01-basic.jsonl", 2), ("02-turn.jsonl", 16), ("03-turn2.jsonl", 23)])
    func decodesEveryRecordedShellValue(name: String, count: Int) throws {
        let values = try recordedShellValues(name)
        #expect(values.count == count)
        for value in values {
            let item = try JSONDecoder().decode(ShellStreamItem.self, from: value)
            if case .unknown(let kind, _) = item { Issue.record("unexpected unknown kind \(kind)") }
        }
    }

    @Test func knownFieldsFromTheTurnRecording() throws {
        let items = try recordedShellValues("02-turn.jsonl").map {
            try JSONDecoder().decode(ShellStreamItem.self, from: $0)
        }
        guard case .snapshot(let empty, nil) = items[0] else { Issue.record("first item"); return }
        #expect(empty.schemaVersion == 2 && empty.snapshotSequence == 0 && empty.projects.isEmpty)
        #expect(items[1] == .synchronized)
        guard case .snapshot(let enrichment, let roots?) = items[2] else { Issue.record("enrichment"); return }
        #expect(roots == ["/Users/user/sandbox/demo-repo"])
        #expect(enrichment.snapshotSequence == 1 && enrichment.threads.isEmpty)
        guard case .projectUpdated(1, let project) = items[3] else { Issue.record("project"); return }
        #expect(project.title == "demo-repo")
        #expect(project.workspaceRoot == "/Users/user/sandbox/demo-repo")
        #expect(project.repositoryIdentity == nil && project.autoPull == false)

        let updates = items.compactMap { item -> (Int, ThreadShell)? in
            if case .threadUpdated(let s, .active?, let t) = item { return (s, t) }
            return nil
        }
        #expect(updates.map(\.0) == [2, 16, 22, 26, 32, 37, 38, 56, 59, 60, 67, 70])
        #expect(updates.map(\.1.status) == [
            .idle, .running, .running, .running, .waiting, .completed, .completed, .queued,
            .cancelled, .cancelled, .cancelled, .cancelled,
        ])
        let last = try #require(updates.last?.1)
        #expect(last.title == "Count files")
        #expect(last.modelSelection == ModelSelection(instanceId: "claudeAgent", model: "claude-haiku-5-5"))
        #expect(last.lineage.rootThreadId == last.id && last.lineage.relationshipToParent == nil)
        #expect(last.lastVisitedAt == .null)
        #expect(last.latestRunCompletedAt.value?.raw == "2026-10-09T09:14:53.191Z")
        #expect(last.latestRunCompletedAt.value?.epochMs == 1_791_537_293_191)
        #expect(last.backgroundTasks.isEmpty && last.pullRequests == [])
        #expect(updates[1].1.activityRunStatus == .running)
    }

    @Test func approvalRecordingCarriesThePendingRequest() throws {
        let threads = try recordedShellValues("03-turn2.jsonl").compactMap { data -> ThreadShell? in
            if case .threadUpdated(_, _, let t) = try JSONDecoder().decode(ShellStreamItem.self, from: data) { return t }
            return nil
        }
        let pending = try #require(threads.compactMap(\.pendingRuntimeRequest).first)
        #expect(pending.kind == .fileChange)
        #expect(threads.last?.title == "Add notes and docstring")
        #expect(threads.last?.status == .completed)
    }

    @Test func forwardCompatibleDecoding() throws {
        let unknown = try JSONDecoder().decode(
            ShellStreamItem.self, from: Data(#"{"kind":"future.thing","sequence":42,"x":1}"#.utf8))
        #expect(unknown == .unknown(kind: "future.thing", sequence: 42))
        #expect(unknown.sequence == 42)

        let task = try JSONDecoder().decode(PendingBackgroundTask.self, from: Data(#"{"taskId":"t"}"#.utf8))
        #expect(task.kind == .backgroundTask)
        let newKind = try JSONDecoder().decode(
            PendingBackgroundTask.self, from: Data(#"{"taskId":"t","kind":"robot"}"#.utf8))
        #expect(newKind.kind.rawValue == "robot")

        let legacy = try JSONDecoder().decode(
            ModelSelection.self, from: Data(#"{"provider":"codex","model":"gpt"}"#.utf8))
        #expect(legacy.instanceId == "codex")
    }

    @Test func timestampsParseLikeDateParse() {
        #expect(T3Timestamp("2026-04-07T12:00:00.000Z").epochMs == 1_775_563_200_000)
        #expect(T3Timestamp("2026-04-07T12:00:00Z").epochMs == 1_775_563_200_000)
        #expect(T3Timestamp("not-a-date").epochMs == nil)
        #expect(T3Timestamp(epochMs: 1_775_563_200_001).raw == "2026-04-07T12:00:00.001Z")
    }

    @Test func tristateRoundTripsAbsentAndNull() throws {
        struct Box: Codable, Equatable { var v: Tristate<T3Timestamp> }
        let absent = try JSONDecoder().decode(Box.self, from: Data("{}".utf8))
        let null = try JSONDecoder().decode(Box.self, from: Data(#"{"v":null}"#.utf8))
        #expect(absent.v == .absent && null.v == .null)
        #expect(String(decoding: try JSONEncoder().encode(absent), as: UTF8.self) == "{}")
        #expect(String(decoding: try JSONEncoder().encode(null), as: UTF8.self) == #"{"v":null}"#)
    }
}
