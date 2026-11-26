import AppKit
import Testing
@testable import DesignSystem

/// Hide and restore the sidebar by dragging (T3 5258 ui/sidebar.tsx:485-648, #29546). The real pointer is never
/// used here: the rail and the handle's mouse events and the layout's drag steps are driven directly.
@MainActor
struct SidebarDragCollapseTests {
    func layout() -> SidebarLayoutView {
        let layout = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.sidebar-drag.\(UUID().uuidString)")!, viewport: 1100)
        layout.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        layout.layoutSubtreeIfNeeded()
        return layout
    }

    func mouse(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 400), modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// `rawWidth < minWidth * (1 - 0.75)`: under 52pt at the 208pt minimum.
    @Test func collapseThresholdIsAQuarterOfTheMinimum() {
        #expect(SidebarMetrics.collapses(rawWidth: 51.9, minimum: 208))
        #expect(!SidebarMetrics.collapses(rawWidth: 52, minimum: 208))
    }

    @Test func railDragPastTheThresholdPreviewsAndHides() {
        let layout = layout()
        layout.rail.mouseDown(with: mouse(.leftMouseDown, x: 256))
        layout.rail.mouseDragged(with: mouse(.leftMouseDragged, x: 100))
        #expect(!layout.dragCollapsed && layout.sidebar.frame.minX == 0 && layout.main.frame.minX == 208)
        layout.rail.mouseDragged(with: mouse(.leftMouseDragged, x: 40))
        // The preview: the sidebar off to the left, the main panel full width, still open until release.
        #expect(layout.dragCollapsed && layout.isOpen)
        #expect(layout.sidebar.frame.minX == -208 && layout.main.frame.minX == 0)
        // Back over the threshold undoes the preview.
        layout.rail.mouseDragged(with: mouse(.leftMouseDragged, x: 120))
        #expect(!layout.dragCollapsed && layout.main.frame.minX == 208)
        layout.rail.mouseDragged(with: mouse(.leftMouseDragged, x: 10))
        layout.rail.mouseUp(with: mouse(.leftMouseUp, x: 10))
        #expect(!layout.isOpen && !layout.dragCollapsed && layout.main.frame.minX == 0)
        #expect(!layout.restoreHandle.isHidden)
        #expect(layout.restoreHandle.frame == NSRect(x: 8, y: 358, width: 16, height: 64))
    }

    @Test func interruptedCollapseKeepsTheSidebar() {
        let layout = layout()
        layout.previewCollapse(true)
        layout.finishCollapse(commit: false)
        #expect(layout.isOpen && layout.main.frame.minX > 0 && layout.restoreHandle.isHidden)
    }

    @Test func restoreHandleOpensPast48AtTheDraggedWidth() {
        let layout = layout()
        layout.setOpen(false)
        let handle = layout.restoreHandle
        handle.mouseDown(with: mouse(.leftMouseDown, x: 16))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 56))
        #expect(layout.restorePreviewWidth == nil && layout.main.frame.minX == 0)
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 316))
        #expect(layout.restorePreviewWidth == 300 && layout.sidebar.frame.minX == 0 && layout.main.frame.minX == 300)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 316))
        #expect(layout.isOpen && layout.width == 300 && SidebarWidth.load(layout.defaults) == 300)
        #expect(layout.restoreHandle.isHidden)
    }

    @Test func shortRestoreDragStaysHiddenAndAClickOpens() {
        let layout = layout()
        layout.setOpen(false)
        let handle = layout.restoreHandle
        handle.mouseDown(with: mouse(.leftMouseDown, x: 16))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 40))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 40))
        #expect(!layout.isOpen)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 16))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 16))
        #expect(layout.isOpen)
    }
}
