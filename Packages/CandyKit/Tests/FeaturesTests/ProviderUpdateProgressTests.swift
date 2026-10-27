import AppKit
import Foundation
import DesignSystem
import Testing
import T3Protocol
@testable import Features

@MainActor
struct ProviderUpdateProgressTests {
    private let start: TimeInterval = 1_793_145_600 // 2026-10-28T00:00:00Z
    private func iso(_ time: TimeInterval) -> String {
        Date(timeIntervalSince1970: time).ISO8601Format(.init(includingFractionalSeconds: true))
    }
    private func provider(started: TimeInterval? = nil) -> ServerProvider {
        var p = ServerProvider(instanceId: .init("opencode"), driver: "opencode")
        p.version = "1.0.0"
        p.latestVersion = "1.0.1"
        p.checkedAt = iso(start)
        p.updateState = .init(status: "running", message: "Installing update", startedAt: iso(started ?? start))
        return p
    }

    private func hasSpinner(_ view: NSView) -> Bool {
        view is SpinnerView || view.subviews.contains { hasSpinner($0) }
    }

    @Test func terminalResultsAndClearedStateStopTheSpinnerAndDeadline() throws {
        for (status, tone) in [("succeeded", SidebarProviderUpdatePillModel.Tone.success), ("failed", .error), ("unchanged", .warning)] {
            let pill = SidebarProviderUpdatePillView()
            var clock = start
            pill.now = { clock }
            var p = provider()
            pill.update([p], environmentId: "sandbox", snapshot: true)
            #expect(pill.shown?.tone == .loading)
            #expect(pill.scheduledProgressDeadline == start + 180)
            clock += 10
            p.updateState?.status = status
            p.updateState?.message = "Command finished"
            // An observed run must settle even if an older server omits finishedAt.
            pill.update([p])
            #expect(pill.shown?.tone == tone)
            #expect(!hasSpinner(pill))
            #expect(pill.scheduledProgressDeadline == nil)
            pill.progressDeadlineReached()
            #expect(pill.shown?.tone == tone)
            p.updateState = nil
            pill.update([p])
            #expect(pill.shown == nil)
            #expect(pill.scheduledProgressDeadline == nil)
        }
    }

    @Test func noPushOrUnchangedProbesExpireAtTheOriginalDeadline() {
        let pill = SidebarProviderUpdatePillView()
        var clock = start
        pill.now = { clock }
        var p = provider()
        pill.update([p])
        clock += 120
        p.checkedAt = iso(clock)
        pill.update([p])
        #expect(pill.scheduledProgressDeadline == start + 180)
        clock = start + 180
        // Fire the installed one-shot deadline with no new provider push.
        pill.progressDeadlineReached()
        #expect(pill.shown?.tone == .error)
        #expect(pill.shown?.title == "OpenCode update didn't finish")
        #expect(!hasSpinner(pill))
        #expect(pill.shown?.description.contains("No update progress for 3 minutes") == true)
        #expect(pill.shown?.dismissible == true)
        #expect(pill.scheduledProgressDeadline == nil)
        let expired = pill.shown
        clock += 100
        p.checkedAt = iso(clock)
        pill.update([p])
        #expect(pill.shown == expired)
        #expect(pill.scheduledProgressDeadline == nil)
    }

    @Test func progressAndNewAttemptsGetNewDeadlines() {
        var state = ProviderUpdateProgress()
        var p = provider()
        _ = state.reconcile([p], now: start)
        p.updateState?.message = "Verifying installation"
        _ = state.reconcile([p], now: start + 100)
        #expect(state.nextDeadline == start + 280)
        #expect(state.reconcile([p], now: start + 281).first?.updateState?.status == "failed")
        p.updateState?.startedAt = iso(start + 300)
        #expect(state.reconcile([p], now: start + 300).first?.updateState?.status == "running")
        #expect(state.nextDeadline == start + 480)
    }

    @Test func versionChangeSettlesAnObsoleteRunningStateUntilTheServerCatchesUp() {
        let pill = SidebarProviderUpdatePillView()
        var clock = start
        pill.now = { clock }
        var p = provider()
        pill.update([p])
        clock += 15
        p.version = "1.0.1"
        pill.update([p])
        #expect(pill.shown?.tone == .success)
        #expect(pill.shown?.title == "OpenCode updated: v1.0.1")
        #expect(pill.scheduledProgressDeadline == nil)
        p.updateState?.message = "Checking installation"
        pill.update([p])
        #expect(pill.shown?.tone == .success)
        // An explicit server result takes precedence over the inferred version change.
        p.updateState?.status = "failed"
        p.updateState?.finishedAt = iso(clock)
        pill.update([p])
        #expect(pill.shown?.tone == .error)
    }

    @Test func reconnectWaitsForAFreshSnapshotAndClearsMissingOrTerminalUpdates() {
        for status in [nil, "succeeded", "failed"] as [String?] {
            let pill = SidebarProviderUpdatePillView()
            var clock = start
            pill.now = { clock }
            var p = provider()
            pill.update([p], environmentId: "sandbox", snapshot: true)
            pill.connectionChanged(connected: false, environmentId: "sandbox")
            #expect(pill.shown == nil && pill.scheduledProgressDeadline == nil)
            clock += 30
            pill.connectionChanged(connected: true, environmentId: "sandbox")
            pill.update([p], environmentId: "sandbox") // A cached config is not the new snapshot.
            #expect(pill.shown == nil && pill.scheduledProgressDeadline == nil)
            p.updateState = status.map { .init(status: $0, finishedAt: iso(clock)) }
            pill.update([p], environmentId: "sandbox", snapshot: true)
            #expect(pill.shown?.tone == (status == "failed" ? .error : status == "succeeded" ? .success : nil))
            #expect(pill.scheduledProgressDeadline == nil)
        }
    }

    @Test func reconnectDoesNotRenewAnOldRunAndFreshLaunchRejectsOldStartedAt() {
        let pill = SidebarProviderUpdatePillView()
        var clock = start
        pill.now = { clock }
        let p = provider()
        pill.update([p], environmentId: "sandbox", snapshot: true)
        pill.connectionChanged(connected: false, environmentId: "sandbox")
        clock += 200
        pill.connectionChanged(connected: true, environmentId: "sandbox")
        pill.update([p], environmentId: "sandbox", snapshot: true)
        #expect(pill.shown?.tone == .error)
        #expect(pill.scheduledProgressDeadline == nil)
        let fresh = SidebarProviderUpdatePillView()
        fresh.now = { clock }
        var futureProbe = p
        futureProbe.checkedAt = iso(clock + 1000)
        fresh.update([futureProbe], environmentId: "sandbox", snapshot: true)
        #expect(fresh.shown?.tone == .error)
        #expect(fresh.scheduledProgressDeadline == nil)
        fresh.update([], environmentId: "sandbox", snapshot: true)
        #expect(fresh.shown == nil)
    }

    @Test func missingStartTimeIsBoundedAndInstancesHaveIndependentProgress() {
        var state = ProviderUpdateProgress()
        var p = provider()
        p.updateState?.startedAt = nil
        var other = provider()
        other.instanceId = .init("claude-work"); other.driver = "claudeAgent"
        _ = state.reconcile([p, other], now: start)
        other.updateState?.message = "Downloading"
        _ = state.reconcile([p, other], now: start + 100)
        let result = state.reconcile([p, other], now: start + 180)
        #expect(result[0].updateState?.status == "failed")
        #expect(result[1].updateState?.status == "running")
        #expect(state.nextDeadline == start + 280)
    }

    @Test func wireDecodeRetainsTheAttemptStart() throws {
        let json = """
        {"instanceId":"opencode","driver":"opencode","enabled":true,"status":"ready","updateState":
        {"status":"running","startedAt":"2026-10-28T00:00:00.000Z","finishedAt":null,"message":"Installing"}}
        """
        let p = try JSONDecoder().decode(ServerProvider.self, from: Data(json.utf8))
        #expect(p.updateState?.startedAt == "2026-10-28T00:00:00.000Z")
        var state = ProviderUpdateProgress()
        let decodedStart = try #require(T3Timestamp(p.updateState!.startedAt!).epochMs)
        #expect(state.reconcile([p], now: Double(decodedStart) / 1000 + 181).first?.updateState?.status == "failed")
    }
}
