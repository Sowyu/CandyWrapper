import Foundation
import Testing
import T3Protocol
@testable import T3Store

/// Terminal split groups (terminalUiStateStore.test.ts:40-262) and terminal tabs (rightPanelStore.ts:737-815).
struct TerminalSplitGroupTests {
    @Test func splitJoinsTheActiveGroup() {
        var s = TerminalDrawerState()
        s.newTerminal("term-1")
        s.split("terminal-2", direction: .horizontal)
        #expect(s.open && s.terminalIds == ["term-1", "terminal-2"] && s.activeTerminalId == "terminal-2")
        #expect(s.terminalGroups == [TerminalGroup(id: "group-term-1", terminalIds: ["term-1", "terminal-2"])])
        #expect(s.visibleTerminalIds == ["term-1", "terminal-2"] && s.hasTerminalList && s.showGroupHeaders)
    }

    @Test func verticalSplitStacks() {
        var s = TerminalDrawerState()
        s.newTerminal("term-1")
        s.split("terminal-2", direction: .vertical)
        #expect(s.terminalGroups == [TerminalGroup(id: "group-term-1", terminalIds: ["term-1", "terminal-2"], splitDirection: .vertical)])
        #expect(s.visibleSplitDirection == .vertical)
    }

    @Test func splitsCapAtFour() {
        var s = TerminalDrawerState()
        for n in 2...6 { s.split("terminal-\(n)", direction: .horizontal) }
        #expect(s.terminalIds == ["terminal-2", "terminal-3", "terminal-4", "terminal-5"])
        #expect(s.terminalGroups == [TerminalGroup(id: "group-terminal-2", terminalIds: ["terminal-2", "terminal-3", "terminal-4", "terminal-5"])])
        #expect(s.hasReachedSplitLimit)
    }

    @Test func splitInsertsAfterTheActiveTerminal() {
        var s = TerminalDrawerState()
        s.newTerminal("a")
        s.split("b", direction: .horizontal)
        s.activate("a")
        s.split("c", direction: .horizontal)
        #expect(s.terminalGroups[0].terminalIds == ["a", "c", "b"])
    }

    @Test func newTerminalGetsItsOwnGroup() {
        var s = TerminalDrawerState()
        s.newTerminal("terminal-2")
        #expect(s.terminalIds == ["terminal-2"] && s.activeTerminalGroupId == "group-terminal-2")
        s.newTerminal("terminal-3")
        #expect(s.resolvedGroups.map(\.id) == ["group-terminal-2", "group-terminal-3"])
        #expect(s.visibleTerminalIds == ["terminal-3"] && s.hasTerminalList && s.showGroupHeaders)
        s.activate("terminal-2")
        #expect(s.visibleTerminalIds == ["terminal-2"] && s.activeTerminalGroupId == "group-terminal-2")
    }

    @Test func closingTheActiveSplitTerminalKeepsAValidOne() {
        var s = TerminalDrawerState()
        s.split("terminal-2", direction: .horizontal)
        s.split("terminal-3", direction: .horizontal)
        s.close("terminal-3")
        #expect(s.activeTerminalId == "terminal-2" && s.terminalIds == ["terminal-2"])
        #expect(s.terminalGroups == [TerminalGroup(id: "group-terminal-2", terminalIds: ["terminal-2"])])
        s.close("terminal-2")
        #expect(s == TerminalDrawerState())
    }

    @Test func reconcileFollowsTheServerOrder() {
        var s = TerminalDrawerState()
        s.newTerminal("term-1")
        s.reconcile(["term-a", "term-b"])
        #expect(s.terminalIds == ["term-a", "term-b"] && s.activeTerminalId == "term-a")
        #expect(s.terminalGroups == [TerminalGroup(id: "group-term-a", terminalIds: ["term-a"]), TerminalGroup(id: "group-term-b", terminalIds: ["term-b"])])
    }

    @Test func oldSavedStatesDecodeWithGroups() throws {
        let json = #"{"open":true,"height":300,"terminalIds":["term-1","term-2"],"activeTerminalId":"term-2"}"#
        let s = try JSONDecoder().decode(TerminalDrawerState.self, from: Data(json.utf8))
        #expect(s.terminalGroups.map(\.id) == ["group-term-1", "group-term-2"] && s.activeTerminalGroupId == "group-term-2")
        let round = try JSONDecoder().decode(TerminalDrawerState.self, from: JSONEncoder().encode(s))
        #expect(round == s)
    }

    @Test func terminalTabs() {
        var p = RightPanelState()
        p.openTerminal("term-3")
        #expect(p.isOpen && p.activeSurfaceId == "terminal:term-3" && p.active?.title == "Terminal 3")
        p.splitTerminal("terminal:term-3", terminalId: "term-4", direction: .vertical)
        #expect(p.active?.terminal == TerminalPanelSurface(resourceId: "term-3", terminalIds: ["term-3", "term-4"], activeTerminalId: "term-4", splitDirection: .vertical))
        #expect(p.panelTerminalIds == ["term-3", "term-4"])
        p.activateTerminal("terminal:term-3", terminalId: "term-3")
        #expect(p.active?.terminal?.activeTerminalId == "term-3")
        p.closeTerminal("terminal:term-3", terminalId: "term-3")
        #expect(p.active?.terminal?.terminalIds == ["term-4"] && p.active?.terminal?.activeTerminalId == "term-4" && p.active?.id == "terminal:term-3")
        p.closeTerminal("terminal:term-3", terminalId: "term-4")
        #expect(p.surfaces.isEmpty && !p.isOpen)
        // Terminal tabs never go to the reopen stack.
        var closed = ClosedPanelTabs()
        closed.remember(.terminal(TerminalPanelSurface(terminalId: "term-9")), threadKey: "t")
        #expect(closed.entries.isEmpty)
    }
}
