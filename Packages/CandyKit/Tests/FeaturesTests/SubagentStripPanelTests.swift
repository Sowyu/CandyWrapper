import AppKit
import Foundation
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// The Redesign subagent panel: the header names the shared model once, rows show a status mark, the title and a time
/// that ticks once a minute only while the panel shows, and the panel stops growing at six rows.
@MainActor
struct SubagentStripPanelTests {
    static let start: Int64 = 1_000_000_000_000

    static func row(_ key: String, _ status: SubagentStrip.Status, model: String = "claude-opus-5-5", started: Int64? = start,
                    completed: Int64? = nil, canStop: Bool = false) -> SubagentStrip.Row {
        func ts(_ ms: Int64?) -> T3Timestamp? {
            ms.map { T3Timestamp(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1000))) }
        }
        return SubagentStrip.Row(id: key, key: key, number: 1, childThreadId: nil, title: "Task \(key)", status: status,
                                 driver: "claudeAgent", providerInstanceId: "claudeAgent", model: model, canStop: canStop,
                                 startedAt: ts(started), completedAt: ts(completed))
    }

    /// `n` finished rows, two minutes each, for the cap and the many-rows render.
    static func finishedRows(_ n: Int) -> [SubagentStrip.Row] {
        let titles = ["Port timeline perf bucket b3", "Sidebar slim rows", "Gallery missing tiles", "Composer footer chips",
                      "Diff viewer wrap", "Settings search", "Browser mini player", "Queue reorder", "Terminal tabs", "Git panel"]
        return (0..<n).map { i in
            let base = T3Timestamp("2026-10-23T12:00:00.000Z").epochMs! + Int64(i) * 120_000
            let r = row("done\(i)", i == 3 ? .failed : .done, started: base, completed: base + Int64(60 + 37 * i) * 1000)
            return SubagentStrip.Row(id: r.id, key: r.key, number: i + 3, childThreadId: nil, title: titles[i % titles.count],
                                     status: r.status, driver: r.driver, providerInstanceId: r.providerInstanceId, model: r.model,
                                     canStop: false, startedAt: r.startedAt, completedAt: r.completedAt)
        }
    }

    static func panel(_ rows: [SubagentStrip.Row], models: [String]? = nil, now: Int64 = start + 200_000) -> SubagentStripPanelView {
        let panel = SubagentStripPanelView()
        panel.nowMs = now
        panel.items = rows.enumerated().map { i, r in .init(row: r, modelName: models?[i] ?? "Claude Opus 5.5") }
        return panel
    }

    @Test func headerNamesTheSharedModelOnceAndCounts() {
        let shared = Self.panel([Self.row("a", .running), Self.row("b", .done, completed: Self.start + 1000), Self.row("c", .failed, completed: Self.start + 1000)])
        #expect(shared.headerText == "Claude Opus 5.5")
        #expect(shared.countText == "1 working · 1 done · 1 failed")
        let mixed = Self.panel([Self.row("a", .running), Self.row("b", .waiting)], models: ["Claude Opus 5.5", "GPT-6 Astra"])
        #expect(mixed.headerText == "Subagents")
        #expect(mixed.countText == "2 working")
        let finished = Self.panel([Self.row("a", .done, completed: Self.start + 1000)])
        #expect(finished.countText == "1 done")
        // Failed rows count on their own, and zero parts drop out.
        let many = Self.panel([Self.row("live", .running)] + Self.finishedRows(10))
        #expect(many.countText == "1 working · 9 done · 1 failed")
        let failedOnly = Self.panel([Self.row("a", .failed, completed: Self.start + 1000)])
        #expect(failedOnly.countText == "1 failed")
    }

    @Test func rowTimesFloorToTheMinuteWhileWorkingAndShowRunTimeOnceFinished() {
        let s = Self.start
        #expect(Self.row("a", .running).elapsedLabel(nowMs: s + 59_999) == "<1m")
        #expect(Self.row("a", .running).elapsedLabel(nowMs: s + 60_000) == "1m")
        #expect(Self.row("a", .running).elapsedLabel(nowMs: s + 3 * 60_000 + 59_000) == "3m")
        #expect(Self.row("a", .done, completed: s + 45_000).elapsedLabel(nowMs: s + 900_000) == "45s")
        #expect(Self.row("a", .failed, completed: s + 4 * 60_000 + 10_000).elapsedLabel(nowMs: s) == "4m")
        #expect(Self.row("a", .done, completed: nil).elapsedLabel(nowMs: s) == nil)
        #expect(Self.row("a", .running, started: nil).elapsedLabel(nowMs: s) == nil)
    }

    @Test func rowShowsMarkTitleAndTimeAndTradesTheTimeForStop() throws {
        let panel = Self.panel([Self.row("a", .running, canStop: true)], now: Self.start + 3 * 60_000 + 5_000)
        panel.frame = NSRect(x: 0, y: 0, width: 600, height: panel.preferredHeight(maxHeight: 1000))
        panel.layoutSubtreeIfNeeded()
        let row = try #require(Self.rows(in: panel).first)
        row.layoutSubtreeIfNeeded()
        #expect(row.title.text == "Task a")
        #expect(row.time.text == "3m")
        #expect(!row.time.isHidden)
        #expect(row.toolTip == "Claude Opus 5.5")
        #expect(row.frame.height == SubagentStripPanelView.row)
        row.setHovered(true)
        row.layoutSubtreeIfNeeded()
        #expect(row.time.isHidden && !row.stop.isHidden)
        #expect(row.title.frame.maxX <= row.stop.frame.minX)
    }

    @Test func theTickWaitsForTheNextMinuteOfAnyLiveRow() {
        let s = Self.start
        let a = Self.row("a", .running, started: s), b = Self.row("b", .waiting, started: s + 20_000)
        #expect(SubagentStrip.nextTimeChangeMs(rows: [a], nowMs: s + 45_000) == 15_000)
        #expect(SubagentStrip.nextTimeChangeMs(rows: [a, b], nowMs: s + 70_000) == 10_000)
        #expect(SubagentStrip.nextTimeChangeMs(rows: [a, b], nowMs: s + 79_000) == 1_000)
        // Finished rows and rows that never started don't tick.
        let done = Self.row("c", .done, completed: s + 1000), unstarted = Self.row("d", .running, started: nil)
        #expect(SubagentStrip.nextTimeChangeMs(rows: [done, unstarted], nowMs: s) == nil)
    }

    @Test func theTickRunsOnlyOnScreenWithALiveRow() {
        let live = [Self.row("a", .running)], done = [Self.row("b", .done, completed: Self.start + 1000)]
        #expect(SubagentStripPanelView.wantsTick(onScreen: true, rows: live, nowMs: Self.start))
        #expect(!SubagentStripPanelView.wantsTick(onScreen: false, rows: live, nowMs: Self.start))
        #expect(!SubagentStripPanelView.wantsTick(onScreen: true, rows: done, nowMs: Self.start))
        #expect(!SubagentStripPanelView.wantsTick(onScreen: true, rows: [], nowMs: Self.start))
        // Out of a window the panel holds no timer, even with a running row.
        let panel = Self.panel(live)
        #expect(!panel.isOnScreen)
        #expect(!panel.isTicking)
    }

    @Test func theTickStartsInAShownWindowAndStopsWhenHiddenOrFinished() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let panel = Self.panel([Self.row("a", .running)])
        window.contentView?.addSubview(panel)
        window.orderFrontRegardless()
        // A headless runner may report the window occluded; the rule is then that nothing ticks.
        #expect(panel.isTicking == panel.isOnScreen)
        panel.isHidden = true
        #expect(!panel.isTicking)
        panel.isHidden = false
        #expect(panel.isTicking == panel.isOnScreen)
        panel.items = [.init(row: Self.row("a", .done, completed: Self.start + 1000), modelName: "Claude Opus 5.5")]
        #expect(!panel.isTicking)
        panel.removeFromSuperview()
        #expect(!panel.isTicking)
    }

    @Test func heightSizesToRowsThenCapsAtSixAndTheWindowShare() {
        let pad = SubagentStripPanelView.pad, header = SubagentStripPanelView.header, row = SubagentStripPanelView.row
        let two = Self.panel(Self.finishedRows(2))
        #expect(two.preferredHeight(maxHeight: 1000) == 2 * pad + header + 2 * row)
        let eleven = Self.panel(Self.finishedRows(10) + [Self.row("live", .running)])
        #expect(eleven.preferredHeight(maxHeight: 1000) == 2 * pad + header + 6 * row)
        #expect(eleven.preferredHeight(maxHeight: 120) == 120)
        // The rows past the cap scroll under the pinned header.
        eleven.frame = NSRect(x: 0, y: 0, width: 600, height: eleven.preferredHeight(maxHeight: 1000))
        eleven.layoutSubtreeIfNeeded()
        let rows = Self.rows(in: eleven)
        #expect(rows.count == 11)
        #expect(rows.last.map { $0.frame.maxY } == 11 * row)
    }

    static func rows(in panel: NSView) -> [SubagentStripRowView] {
        var out: [SubagentStripRowView] = []
        func walk(_ v: NSView) {
            if let r = v as? SubagentStripRowView { out.append(r); return }
            v.subviews.forEach(walk)
        }
        walk(panel)
        return out.sorted { $0.frame.minY < $1.frame.minY }
    }
}
