import AppKit
import Foundation
import Testing
import T3Store
@testable import Features

/// Right panel tabs reorder by drag (410793042) and a maximized panel stays maximized per thread (71f6f1db8).
@MainActor
struct RightPanelTabDragTests {
    private func makePanel() -> (NSWindow, ThreadPanelView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        panel.referenceViewportWidth = 1400
        window.contentView = panel
        panel.mutatePanel { $0.open(.diff); $0.open(.files); $0.open(.pullRequests); return [] }
        panel.layoutSubtreeIfNeeded()
        return (window, panel)
    }

    private func tabs(_ view: NSView) -> [PanelTabView] {
        view.subviews.flatMap { ($0 as? PanelTabView).map { [$0] } ?? tabs($0) }.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func mouse(_ type: NSEvent.EventType, _ tab: PanelTabView, dx: CGFloat) -> NSEvent {
        let start = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [], timestamp: 0,
                                  windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func dragReordersAndReportsTheNewOrder() throws {
        let (window, panel) = makePanel()
        _ = window
        var reported: RightPanelState?
        panel.onPanelChange = { state, _ in reported = state }
        #expect(panel.panelState.activeSurfaceId == "pull-requests")
        // Under 6px it is a click: nothing moves and the tab activates on release.
        let clicked = tabs(panel.rightPanel)[0]
        clicked.mouseDown(with: mouse(.leftMouseDown, clicked, dx: 0))
        clicked.mouseDragged(with: mouse(.leftMouseDragged, clicked, dx: 5))
        #expect(clicked.layer?.affineTransform().tx == 0)
        #expect(panel.panelState.activeSurfaceId == "pull-requests")
        clicked.mouseUp(with: mouse(.leftMouseUp, clicked, dx: 5))
        #expect(panel.panelState.activeSurfaceId == "diff")
        #expect(panel.panelState.surfaces.map(\.id) == ["diff", "files", "pull-requests"])
        panel.layoutSubtreeIfNeeded()

        let before = tabs(panel.rightPanel)
        #expect(before.count == 3)
        let first = before[0], distance = before[2].frame.midX - first.frame.midX, startX = first.frame.minX

        // A drag past the last tab's center: the tab follows the pointer, the others slide left by its width and the gap.
        first.mouseDown(with: mouse(.leftMouseDown, first, dx: 0))
        first.mouseDragged(with: mouse(.leftMouseDragged, first, dx: distance))
        #expect(first.frame.minX == startX + distance)
        #expect(before[1].layer?.affineTransform().tx == -(first.frame.width + 4))
        #expect(before[2].layer?.affineTransform().tx == -(first.frame.width + 4))
        first.mouseUp(with: mouse(.leftMouseUp, first, dx: distance))
        #expect(panel.panelState.surfaces.map(\.id) == ["files", "pull-requests", "diff"])
        // The drag selected nothing new, and the new order goes to the owner to keep.
        #expect(panel.panelState.activeSurfaceId == "diff")
        #expect(reported?.surfaces.map(\.id) == ["files", "pull-requests", "diff"])
        let after = tabs(panel.rightPanel)
        #expect(after.allSatisfy { $0.layer?.affineTransform() == .identity })

        // A drag far left clamps to the strip and lands first.
        let last = after[2]
        last.mouseDown(with: mouse(.leftMouseDown, last, dx: 0))
        last.mouseDragged(with: mouse(.leftMouseDragged, last, dx: -2000))
        #expect(last.frame.minX == 0)
        last.mouseUp(with: mouse(.leftMouseUp, last, dx: -2000))
        #expect(panel.panelState.surfaces.map(\.id) == ["diff", "files", "pull-requests"])
    }

    @Test func orderAndMaximizeSurviveTheRoundTrip() throws {
        let (window, panel) = makePanel()
        _ = window
        panel.toggleMaximized()
        #expect(panel.rightPanelMaximized)
        // Closing and opening again keeps it maximized; so does restoring the thread's saved state.
        panel.toggleRightPanel()
        panel.toggleRightPanel()
        #expect(panel.rightPanelMaximized)
        var state = panel.panelState
        state.move("pull-requests", to: 0)
        let saved = try JSONDecoder().decode(RightPanelState.self, from: JSONEncoder().encode(state))
        #expect(saved == state && saved.maximized == true && saved.surfaces.first?.id == "pull-requests")
        panel.setPanelState(RightPanelState())
        #expect(!panel.rightPanelMaximized)
        panel.setPanelState(saved)
        #expect(panel.rightPanelMaximized && panel.rightPanel.frame.width == 1400)
        // State saved before 2994 has no `maximized` key.
        let legacy = try JSONDecoder().decode(RightPanelState.self, from: Data(#"{"isOpen":true,"activeSurfaceId":"diff","surfaces":[]}"#.utf8))
        #expect(legacy.maximized == nil)
        // Out of range or unknown moves change nothing.
        var same = saved
        same.move("pull-requests", to: 9); same.move("nope", to: 0)
        #expect(same == saved)
    }
}
