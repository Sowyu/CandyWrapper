import AppKit
import DesignSystem
import T3Protocol
import T3Store
import Testing
@testable import Features

/// Threads are never drawn as bots (docs/orchestrator-phase1.md, step 6): with the Orchestrator on, every thread row
/// keeps T3's own look, icons and status, pixel for pixel.
@MainActor
struct OrchestratorThreadRowTests {
    static let threads = ["w1", "a1", "d1", "f1"]

    /// Each thread row's pixels in Redesign, with the Orchestrator's pinned row and hidden thread as the app sets them
    /// when the toggle is on, or without them.
    func rows(orchestrator: Bool, dark: Bool) throws -> [String: Data] {
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 900)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("w1", "Working on it", project: "p1", kind: .working, minutesAgo: 2),
            SidebarPreview.thread("a1", "Wants to run a command", project: "p1", kind: .approval, minutesAgo: 4),
            SidebarPreview.thread("d1", "Finished work", project: "p1", kind: .done, minutesAgo: 6),
            SidebarPreview.thread("f1", "Broke", project: "p1", kind: .failed, minutesAgo: 8),
            SidebarPreview.thread("orch", "Orchestrator", project: "p1", kind: .read, minutesAgo: 1),
        ]), animated: false)
        if orchestrator {
            content.orchestrator = OrchestratorSidebarInfo(name: "Orchestrator", machine: "miniko", machineKind: "mac-mini", bot: .orchestrator, needsYou: 1,
                                                           working: true, started: true, isOpen: false)
            content.state.hiddenThreadIds = [ThreadId("orch")]
        }
        content.layoutSubtreeIfNeeded()
        content.list.layoutSubtreeIfNeeded()
        var out: [String: Data] = [:]
        for id in Self.threads {
            let row = try #require(content.list.rowView("thread:\(id)"))
            row.layoutSubtreeIfNeeded()
            let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: rep)
            out[id] = rep.tiffRepresentation
            #expect(!row.subviews.contains { $0 is BotView }, "\(id) wears a bot")
        }
        #expect((content.list.rowView("thread:orch") == nil) == orchestrator)
        window.contentView = nil
        return out
    }

    @Test(arguments: [false, true])
    func threadRowsLookTheSameWithTheToggleOnAndOff(dark: Bool) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        let off = try rows(orchestrator: false, dark: dark), on = try rows(orchestrator: true, dark: dark)
        for id in Self.threads { #expect(off[id] != nil && off[id] == on[id], "\(id) differs with the Orchestrator on") }
    }
}
