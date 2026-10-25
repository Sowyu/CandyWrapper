import Foundation
import Testing
import T3Protocol
@testable import Features

struct OnboardingSnapShotTests {
    private func live() -> FirstRunDecision.Evidence {
        var e = FirstRunDecision.Evidence()
        e.bootstrapped = true; e.primaryLive = true; e.workspaceLive = true
        e.catalogReady = true; e.configAvailable = true; e.primaryId = "local"
        e.welcome = .object(["bootstrapStatus": .string("complete"), "cwd": .string("/sandbox")])
        return e
    }
    @Test func firstRunWaitsForAuthoritativeProvenance() {
        var e = live()
        #expect(FirstRunDecision.resolve(e).route == .wizard)
        e.welcome = .object(["bootstrapStatus": .string("pending")])
        #expect(FirstRunDecision.resolve(e).route == .pending)
        e.welcome = nil
        #expect(FirstRunDecision.resolve(e).route == .pending)
        e.completed = true
        #expect(FirstRunDecision.resolve(e).route == .app)
    }
    @Test func cachedWorkspaceNeverCompletesSetup() {
        var e = live()
        e.projects = [.object([:]), .object([:])]
        e.workspaceLive = false
        let result = FirstRunDecision.resolve(e)
        #expect(result.route == .app)
        #expect(!result.persist)
        e.workspaceLive = true
        #expect(FirstRunDecision.resolve(e).persist)
        e.hydrated = false
        #expect(FirstRunDecision.resolve(e).route == .pending)
    }
    @Test func bootstrapMustBelongToThisStartupAndEnvironment() {
        var e = live()
        e.projects = [.object(["id": .string("p"), "environmentId": .string("local"), "workspaceRoot": .string("/sandbox/")])]
        #expect(!FirstRunDecision.fresh(e))
        e.welcome = .object(["cwd": .string("/sandbox"), "bootstrapProjectId": .string("p"), "bootstrapProjectCreated": .bool(true)])
        #expect(FirstRunDecision.fresh(e))
        e.primaryId = "remote"
        #expect(!FirstRunDecision.fresh(e))
    }
    @Test func coordinateResizeClipsAndPreservesTree() throws {
        let source = try JSONValue(parsing: Data(#"{"kind":"snap-shot","accessibility":{"format":"element-tree","imageSize":{"width":200,"height":100},"root":{"role":"AXWindow","bounds":{"x":180,"y":80,"width":50,"height":40},"children":[{"role":"AXButton","bounds":{"x":200,"y":20,"width":5,"height":5},"children":[]}]}}}"#.utf8))
        let resized = SnapShotSource.resized(source, width: 100, height: 50)
        #expect(resized["accessibility"]?["root"]?["bounds"]?["width"]?.intValue == 10)
        #expect(resized["accessibility"]?["root"]?["bounds"]?["height"]?.intValue == 10)
        #expect(resized["accessibility"]?["root"]?["children"]?.arrayValue?.first?["bounds"] == .null)
        #expect(SnapShotSource.details(resized)?.contains("AXButton") == true)
    }
    @Test func sourceSurvivesPendingRecoveryAndWireEncoding() throws {
        var a = ComposerAttachment(kind: .image, name: "Snapshot.png", mimeType: "image/png", sizeBytes: 42,
                                   fileURL: URL(fileURLWithPath: "/sandbox/capture.png"), status: .ready, attachmentId: "uploaded", environmentId: "env")
        a.snapShotSource = .object(["kind": .string("snap-shot"), "appName": .string("Editor")])
        #expect(a.chatAttachment?["source"] == a.snapShotSource)
        let record = try #require(SnapShotPendingCapture(draftKey: "draft", attachment: a))
        let restored = try JSONDecoder().decode(SnapShotPendingCapture.self, from: JSONEncoder().encode(record))
        #expect(restored == record)
        #expect(restored.attachment.snapShotSource == a.snapShotSource)
        #expect(restored.attachment.attachmentId == nil)
        #expect(restored.attachment.status != .ready)
    }
    @Test func deliveredCaptureDeletesOnlyItsOwnedFile() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent(".snapshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture.png")
        let ordinary = directory.appendingPathComponent("user.png")
        try Data([1]).write(to: capture)
        try Data([2]).write(to: ordinary)
        var a = ComposerAttachment(kind: .image, name: "capture.png", mimeType: "image/png", sizeBytes: 1,
                                   fileURL: capture, status: .ready, attachmentId: "uploaded", environmentId: "env")
        a.snapShotSource = .object(["kind": .string("snap-shot")])
        let b = ComposerAttachment(kind: .image, name: "user.png", mimeType: "image/png", sizeBytes: 1,
                                   fileURL: ordinary, status: .ready, attachmentId: "other", environmentId: "env")
        SnapShotPendingCapture.removeDeliveredFiles([a, b])
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(FileManager.default.fileExists(atPath: ordinary.path))
        SnapShotPendingCapture.removeDeliveredFiles([a])
    }

    @Test func readinessPrefersUsableNonDefaultInstance() {
        let absent = ServerProvider(instanceId: .init("default"), driver: "codex", installed: false, status: .error)
        let ready = ServerProvider(instanceId: .init("custom"), driver: "codex")
        #expect(OnboardingProviderReadiness.select([absent, ready], driver: "codex")?.instanceId == ready.instanceId)
    }
    @MainActor @Test func failedSettingsReadPreservesSavedData() {
        let suite = "wp716b-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let broken = Data("{".utf8)
        defaults.set(broken, forKey: "clientSettings.v1")
        let store = ClientSettingsStore(defaults: defaults)
        #expect(store.readFailed)
        store.update(["onboardingCompletedAt": .string("date")])
        #expect(defaults.data(forKey: "clientSettings.v1") == broken)
        defaults.set(Data("{}".utf8), forKey: "clientSettings.v1")
        store.retryRead()
        #expect(!store.readFailed)
    }
    @Test func providerUpdatesDeduplicateAndRejectUnsupportedVersions() {
        var p = ServerProvider(instanceId: .init("codex"), driver: "codex")
        p.latestVersion = "1.2"; p.versionAdvisory = .object(["status": .string("behind_latest")])
        #expect(ProviderUpdateCandidates.candidates([p, p]).count == 1)
        p.compatibilityAdvisory = .object(["latestVersionStatus": .string("broken")])
        #expect(ProviderUpdateCandidates.candidates([p]).isEmpty)
    }
}
