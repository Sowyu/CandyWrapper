import Foundation
import Testing
@testable import T3Store

/// The right panel's tab store and the closed tab stack against rightPanelStore.ts and
/// closedViewStore.ts behavior.
struct RightPanelStateTests {
    @Test func openFileReplacesExplorerAndCountsReveals() {
        var s = RightPanelState()
        s.open(.files)
        #expect(s.isOpen && s.activeSurfaceId == "files")
        s.openFile("src/a.ts", line: 0)
        #expect(s.surfaces == [.file(path: "src/a.ts", revealLine: 1, revealRequestId: 1)])
        s.open(.diff)
        s.openFile("src/a.ts/", line: 12)
        // Same tab, same place, one more reveal.
        #expect(s.surfaces.first == .file(path: "src/a.ts", revealLine: 12, revealRequestId: 2))
        #expect(s.activeSurfaceId == "file:src/a.ts")
        s.openFile(".")
        #expect(s.activeSurfaceId == "files")
    }

    @Test func closeActivatesNeighborAndClosesPanelWithLastTab() {
        var s = RightPanelState()
        s.open(.diff); s.openFile("a"); s.openFile("b")
        s.activate("file:a")
        #expect(s.close("file:a") == [.file(path: "a", revealLine: nil, revealRequestId: 1)])
        #expect(s.activeSurfaceId == "file:b")
        s.close("file:b")
        #expect(s.activeSurfaceId == "diff" && s.isOpen)
        s.close("diff")
        #expect(!s.isOpen && s.activeSurfaceId == nil && s.isEmpty)
    }

    @Test func closeOthersAndToRightRememberActiveLast() {
        var s = RightPanelState()
        s.open(.diff); s.openFile("a"); s.openFile("b"); s.openFile("c")
        s.activate("file:b")
        let right = s.closeToRight("file:a")
        #expect(right.map(\.id) == ["file:c", "file:b"])
        #expect(s.activeSurfaceId == "file:a")
        let others = s.closeOthers("diff")
        #expect(others.map(\.id) == ["file:a"])
        #expect(s.surfaces == [.diff])
        #expect(s.closeAll().map(\.id) == ["diff"])
    }

    @Test func toggleClosesWhenShowingKind() {
        var s = RightPanelState()
        s.toggle(.diff)
        #expect(s.isOpen && s.active == .diff)
        s.toggle(.diff)
        #expect(!s.isOpen && s.surfaces == [.diff])
        s.toggle(.files)
        #expect(s.isOpen && s.active == .files)
    }

    @Test func closedTabsDedupeCapAndSkipOpen() {
        var c = ClosedPanelTabs()
        for i in 0..<25 { c.remember(.file(path: "f\(i)", revealLine: nil, revealRequestId: 1), threadKey: "t") }
        c.remember(.file(path: "f24", revealLine: 3, revealRequestId: 2), threadKey: "t")
        #expect(c.entries.count == 20)
        #expect(c.entries[0].surface == .file(path: "f24", revealLine: 3, revealRequestId: 2))
        c.remember(.diff, threadKey: "gone")
        var open = RightPanelState()
        open.openFile("f24")
        let next = c.popNext(threadExists: { $0 == "t" }, panel: { _ in open })
        // The deleted thread's entry and the already open tab are dropped.
        #expect(next?.surface.id == "file:f23")
        var restored = RightPanelState()
        ClosedPanelTabs.restore(next!.surface, into: &restored)
        #expect(restored.active?.filePath == "f23")
    }

    @Test func codableRoundTrip() throws {
        var s = RightPanelState()
        s.open(.diff); s.openFile("x/y.md", line: 4)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RightPanelState.self, from: data) == s)
    }
}
