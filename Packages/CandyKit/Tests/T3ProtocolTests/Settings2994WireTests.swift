import Foundation
import Testing
@testable import T3Protocol

/// The settings RPCs and keys added in 2994: storage cleanup reports, OTLP endpoint checks and
/// per-project provider instances.
struct Settings2994WireTests {
    @Test func storageCleanupReportDecodes() {
        let report = StorageCleanupReport(json: UsageTests.json(#"""
        {"trigger":"manual","startedAt":"2026-10-13T10:00:00.000Z","finishedAt":"2026-10-13T10:00:02.000Z",
         "entries":[
           {"kind":"worktree","outcome":"removed","reason":"Thread was deleted.","path":"/h/worktrees/repo/t3-abc","threadId":"t1","threadTitle":"Fix it","bytes":2048,"files":null},
           {"kind":"logs","outcome":"failed","reason":"Permission denied.","path":null,"threadId":null,"threadTitle":null}
         ],
         "counts":{"removed":1,"kept":0,"failed":1},"omittedCount":3,"bytesFreed":2048}
        """#))
        #expect(report?.entries.count == 2)
        #expect(report?.entries[0].path == "/h/worktrees/repo/t3-abc")
        #expect(report?.entries[0].bytes == 2048)
        // `bytes` and `files` default to null when absent.
        #expect(report?.entries[1].bytes == nil && report?.entries[1].files == nil)
        #expect(report?.removed == 1 && report?.failed == 1 && report?.omittedCount == 3)
        // The stream sends null before the first run.
        #expect(StorageCleanupReport(json: .null) == nil)
        // `bytesFreed` defaults to 0.
        #expect(StorageCleanupReport(json: UsageTests.json(#"{"finishedAt":"x","entries":[],"counts":{"removed":0,"kept":0,"failed":0},"omittedCount":0}"#))?.bytesFreed == 0)
    }

    @Test func formatBytesMatchesWeb() {
        #expect(StorageCleanupReport.formatBytes(0) == "0 B")
        #expect(StorageCleanupReport.formatBytes(1023) == "1023 B")
        #expect(StorageCleanupReport.formatBytes(1536) == "1.50 KB")
        #expect(StorageCleanupReport.formatBytes(15 * 1024) == "15.0 KB")
        #expect(StorageCleanupReport.formatBytes(150 * 1024 * 1024) == "150 MB")
    }

    @Test func otlpEndpointCheckDecodesAndLabels() {
        #expect(OtlpEndpointCheckResult(json: UsageTests.json(#"{"_tag":"Accepted","latencyMs":12.6}"#)) == .accepted(latencyMs: 12.6))
        #expect(OtlpEndpointCheckResult(json: UsageTests.json(#"{"_tag":"Rejected","status":404}"#)) == .rejected(status: 404))
        #expect(OtlpEndpointCheckResult(json: UsageTests.json(#"{"_tag":"Unreachable","timedOut":true}"#)) == .unreachable(timedOut: true))
        #expect(OtlpEndpointCheckResult(json: UsageTests.json(#"{"_tag":"Other"}"#)) == nil)
        #expect(OtlpEndpointCheckResult.isHttpURL("HTTPS://x") && !OtlpEndpointCheckResult.isHttpURL("http://") && !OtlpEndpointCheckResult.isHttpURL("data:x"))
        let url = "http://127.0.0.1:4318/v1/traces"
        #expect(OtlpEndpointCheckResult.status(url: "", check: nil).label == "Off")
        #expect(OtlpEndpointCheckResult.status(url: url, check: ("http://other", nil)).label == "Not checked")
        #expect(OtlpEndpointCheckResult.status(url: url, check: (url, nil)) == .init(label: "Checking…", tone: .checking))
        #expect(OtlpEndpointCheckResult.status(url: url, check: (url, .accepted(latencyMs: 12.6))).label == "Connected · 13 ms")
        #expect(OtlpEndpointCheckResult.status(url: url, check: (url, .rejected(status: 404))).label == "Rejected · HTTP 404")
        #expect(OtlpEndpointCheckResult.status(url: url, check: (url, .unreachable(timedOut: false))) == .init(label: "Unreachable", tone: .failure))
    }

    @Test func projectProviderOverrides() {
        let s = ServerSettingsValues(UsageTests.json(#"{"projectSettingsOverrides":{"p1":{"defaultAutoPull":true,"providerInstances":{"codex":{"enabled":false}}},"p2":{"providerInstances":{"codex":{"enabled":true}}}}}"#))
        #expect(ProjectSettings.providerOverride(s, projectId: "p1", instanceId: "codex") == false)
        #expect(ProjectSettings.providerOverride(s, projectId: "p1", instanceId: "claudeAgent") == nil)
        #expect(ProjectSettings.providerOverride(s, projectId: "p3", instanceId: "codex") == nil)
        // Setting keeps each entry's other keys; resetting drops the instance, and an emptied entry becomes null.
        #expect(ProjectSettings.providerOverridePatch(s, projectIds: ["p1", "p3"], instanceId: "cursor", enabled: true) == UsageTests.json(
            #"{"p1":{"defaultAutoPull":true,"providerInstances":{"codex":{"enabled":false},"cursor":{"enabled":true}}},"p3":{"providerInstances":{"cursor":{"enabled":true}}}}"#))
        #expect(ProjectSettings.providerOverridePatch(s, projectIds: ["p1", "p2"], instanceId: "codex", enabled: nil) == UsageTests.json(
            #"{"p1":{"defaultAutoPull":true,"providerInstances":{}},"p2":null}"#))
    }

    @Test func worktreeKeepWhenFollowsTheEnvironment() {
        let s = ServerSettingsValues(UsageTests.json(#"{"storageCleanup":{"worktreeKeepWhen":"tracked-changes"},"projectSettingsFolded":true,"projectSettingsOverrides":{"off":{"worktreeCleanup":{"mode":"off"}}}}"#))
        #expect(ProjectSettings.worktreeCleanup(s, projectId: nil)["worktreeKeepWhen"] == .string("tracked-changes"))
        #expect(ProjectSettings.worktreeCleanup(s, projectId: "off")["worktreeKeepWhen"] == .string("tracked-changes"))
        // 2861 servers send no keep rule, so none is written back.
        #expect(ProjectSettings.worktreeCleanup(ServerSettingsValues(UsageTests.json("{}")), projectId: nil)["worktreeKeepWhen"] == nil)
    }
}
