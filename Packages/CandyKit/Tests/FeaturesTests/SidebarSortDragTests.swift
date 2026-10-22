import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Dragging a thread row to reorder it (Sidebar.tsx:3460-4160). The planner has its own tests
/// (SidebarSortPlannerTests); these check what the list does with a drag: Escape puts every row back
/// and sends nothing, a drop sends one reorder with the planned order.
@MainActor
struct SidebarSortDragTests {
    /// AppKit makes real sessions only inside its drag loop. The list reads the pasteboard on cancel and
    /// swaps the drag image when the pointer leaves the list; both are inert here.
    final class FakeDragSession: NSDraggingSession {
        let board = NSPasteboard(name: NSPasteboard.Name("cw-test-\(UUID().uuidString)"))
        override var draggingPasteboard: NSPasteboard { board }
        override func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                             classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                             using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }

    struct Fixture {
        let window: NSWindow
        let content: SidebarContentView
        let session: FakeDragSession
        var list: SidebarListView { content.list }
    }

    /// Three active threads, newest first: a1, a2, a3. a1 is lifted and the pointer moves onto a3.
    func liftFirstAndDragOntoLast(drops: @escaping (ThreadId, SidebarSection, SidebarDropTarget) -> Void) throws -> (Fixture, [String: CGFloat]) {
        _ = NSApplication.shared
        let content = SidebarContentView()
        content.now = { SidebarPreview.referenceNow }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 255, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 255, height: 780)
        content.setSnapshot(SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo")], threads: [
            SidebarPreview.thread("a1", "First", project: "p1", kind: .read, minutesAgo: 10),
            SidebarPreview.thread("a2", "Second", project: "p1", kind: .read, minutesAgo: 20),
            SidebarPreview.thread("a3", "Third", project: "p1", kind: .read, minutesAgo: 30),
        ]), animated: false)
        content.layoutSubtreeIfNeeded()
        let list = content.list
        list.layoutSubtreeIfNeeded()
        list.canSortDrop = { _, _, _ in true }
        list.onSortDrop = drops
        let keys = ["thread:a1", "thread:a2", "thread:a3"]
        var resting: [String: CGFloat] = [:]
        for k in keys { resting[k] = try #require(list.rowView(k)).frame.minY }
        let first = try #require(list.rowView("thread:a1")), last = try #require(list.rowView("thread:a3"))
        let id = ThreadId("a1")

        let session = FakeDragSession()
        list.sort = SidebarSortSession(id: id, section: .active, grabOffset: first.frame.height / 2, sortable: true,
                                       session: session, ghost: NSImage(size: NSSize(width: 10, height: 10)))
        list.rebuildSortPlan(animated: false)
        // The pointer sits over the middle of the last row, well inside the list's sides.
        let target = NSPoint(x: list.bounds.midX, y: last.frame.midY + 2)
        list.moveSort(to: list.convert(target, to: nil))
        return (Fixture(window: window, content: content, session: session), resting)
    }

    @Test func escapeSendsNothingAndPutsEveryRowBack() throws {
        var drops = 0
        let (f, resting) = try liftFirstAndDragOntoLast { _, _, _ in drops += 1 }
        // The drag moved rows: the preview opened room for the lifted one.
        #expect(f.list.sort?.target != nil)
        #expect(resting.contains { key, y in f.list.rowView(key)?.frame.minY != y })

        f.list.cancelSort()
        #expect(f.list.sort == nil)
        #expect(drops == 0)
        for (key, y) in resting { #expect(f.list.rowView(key)?.frame.minY == y, "\(key)") }
        #expect(f.list.rowView("thread:a1")?.lift == nil)
        // AppKit's drag goes on with nothing on the pasteboard, so no other view takes the thread.
        #expect(f.session.draggingPasteboard.pasteboardItems?.isEmpty ?? true)
        // The drag's end, after the cancel, doesn't drop either.
        f.list.draggingSession(f.session, endedAt: .zero, operation: [])
        #expect(drops == 0)
        f.window.contentView = nil
    }

    @Test func dropSendsOneReorderWithThePlannedOrder() throws {
        var drops: [(ThreadId, SidebarSection, SidebarDropTarget)] = []
        let (f, _) = try liftFirstAndDragOntoLast { drops.append(($0, $1, $2)) }
        let planned = try #require(f.list.sort?.target)
        f.list.draggingSession(f.session, endedAt: .zero, operation: .move)
        #expect(drops.count == 1)
        #expect(drops.first?.0.rawValue == "a1")
        #expect(drops.first?.1 == .active)
        #expect(drops.first?.2 == planned)
        #expect(planned.section == .active)
        #expect(planned.activeOrder.map(\.rawValue).last == "a1")
        #expect(f.list.sort == nil)
        f.window.contentView = nil
    }

    /// A drop the app can't store (`canSortDrop` false) sends nothing.
    @Test func refusedDropSendsNothing() throws {
        var drops = 0
        let (f, _) = try liftFirstAndDragOntoLast { _, _, _ in drops += 1 }
        f.list.canSortDrop = { _, _, _ in false }
        f.list.draggingSession(f.session, endedAt: .zero, operation: .move)
        #expect(drops == 0)
        f.window.contentView = nil
    }
}
