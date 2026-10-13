import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Glass Native's sidebar, phase 2 (docs/glass-native.md): T3 Mobile's order, the swipe action sets, the drop
/// targets, and the native list's incremental updates.
@MainActor
struct NativeSidebarTests {
    static func row(_ id: String, _ section: SidebarSection, canSnooze: Bool = true) -> SidebarRowModel {
        let variant: SidebarRowModel.Variant = section == .snoozed || section == .settled ? .slim : .card
        let action: SidebarRowModel.Action = section == .snoozed ? .unsnooze : section == .settled ? .unsettle : .settle
        return SidebarRowModel(id: ThreadId(id), variant: variant, action: action, section: section, title: id, projectLabel: nil, projectTitle: nil,
                               branch: nil, hasWorktree: false, status: .ready, topStatus: nil, isGoal: false, isUnread: false, isWoke: false,
                               isPinned: section == .pinned, recedes: false, isActive: false, isRegeneratingTitle: false, timeLabel: "1m",
                               snoozeLabel: nil, workingStartedMs: nil, providerIcon: "claude", canSnooze: canSnooze)
    }

    static func draft(_ id: String) -> SidebarItem {
        .draft(SidebarDraftRowModel(id: id, projectLabel: nil, projectTitle: nil, preview: "draft \(id)", isActive: false))
    }

    /// Pinned, then active, then drafts, then the Working, Snoozed and Settled shelves; no draft divider.
    @Test func ordersLikeTheMobileList() {
        let items: [SidebarItem] = [
            Self.draft("d1"), Self.draft("d2"), .draftDivider,
            .row(Self.row("p1", .pinned)), .row(Self.row("a1", .active)), .row(Self.row("a2", .active)),
            .shelfHeader(.working, label: "Working (1)", expanded: false),
            .shelfHeader(.snoozed, label: "Snoozed", expanded: true), .row(Self.row("z1", .snoozed)),
            .shelfHeader(.settled, label: "Settled", expanded: true), .row(Self.row("s1", .settled)), .showMore(count: 25),
        ]
        let keys = NativeSidebarRules.displayOrder(items).map { items[$0].key }
        #expect(keys == ["thread:p1", "thread:a1", "thread:a2", "draft:d1", "draft:d2", "shelf:working", "shelf:snoozed", "thread:z1",
                         "shelf:settled", "thread:s1", "show-more"])
        // Without shelves the drafts go last; without drafts nothing moves.
        let short: [SidebarItem] = [Self.draft("d1"), .draftDivider, .row(Self.row("a1", .active))]
        #expect(NativeSidebarRules.displayOrder(short).map { short[$0].key } == ["thread:a1", "draft:d1"])
        #expect(NativeSidebarRules.displayOrder(Array(items[3...])) == Array(0..<(items.count - 3)))
    }

    /// Cards settle or snooze, settled rows un-settle, snoozed rows wake, and a server without settlement archives.
    @Test func swipeActionSets() {
        typealias R = NativeSidebarRules
        #expect(R.swipeActions(Self.row("a", .active), settlement: true, snooze: true) == [.settle, .snooze])
        #expect(R.swipeActions(Self.row("p", .pinned), settlement: true, snooze: true) == [.settle, .snooze])
        #expect(R.swipeActions(Self.row("w", .working), settlement: true, snooze: true) == [.settle, .snooze])
        #expect(R.swipeActions(Self.row("a", .active, canSnooze: false), settlement: true, snooze: true) == [.settle])
        #expect(R.swipeActions(Self.row("a", .active), settlement: true, snooze: false) == [.settle])
        #expect(R.swipeActions(Self.row("s", .settled), settlement: true, snooze: true) == [.unsettle])
        #expect(R.swipeActions(Self.row("z", .snoozed), settlement: true, snooze: true) == [.wake])
        #expect(R.swipeActions(Self.row("a", .active), settlement: false, snooze: true) == [.archive])
        #expect(R.swipeActions(Self.row("s", .settled), settlement: false, snooze: true) == [.archive])
    }

    /// A drop next to a pin joins the pins at that place; next to an inbox row, the inbox; elsewhere nothing.
    @Test func dropTargets() {
        let rows: [(id: ThreadId, section: SidebarSection)?] = [
            (ThreadId("p1"), .pinned), (ThreadId("p2"), .pinned), (ThreadId("a1"), .active), (ThreadId("a2"), .active), nil,
            (ThreadId("s1"), .settled),
        ]
        let reorder = NativeSidebarRules.dropTarget(rows, moving: ThreadId("p2"), at: 0)
        #expect(reorder?.section == .pinned && reorder?.pinnedOrder.map(\.rawValue) == ["p2", "p1"])
        let pin = NativeSidebarRules.dropTarget(rows, moving: ThreadId("a2"), at: 2)
        #expect(pin?.section == .pinned && pin?.pinnedOrder.map(\.rawValue) == ["p1", "p2", "a2"] && pin?.activeOrder.map(\.rawValue) == ["a1"])
        let move = NativeSidebarRules.dropTarget(rows, moving: ThreadId("a1"), at: 4)
        #expect(move?.section == .active && move?.activeOrder.map(\.rawValue) == ["a2", "a1"])
        #expect(NativeSidebarRules.dropTarget(rows, moving: ThreadId("a1"), at: 6) == nil)
    }

    static func nativeContent(_ snap: ShellSnapshot, now: @escaping () -> Date) -> (SidebarContentView, NSWindow) {
        let content = SidebarContentView()
        content.now = now
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.frame = NSRect(x: 0, y: 0, width: 320, height: 780)
        content.hidesCustomChrome = true
        content.state.settledExpanded = true
        content.state.settledVisibleCount = 2_000
        content.setSnapshot(snap, animated: false)
        content.layoutSubtreeIfNeeded()
        return (content, window)
    }

    /// The native list keeps `SidebarLoadTests`' promise at 1,580 threads: a one-thread change and a clock step patch
    /// their rows, configure at most the changed cell, and leave the list equal to a fresh build.
    @Test func nativeListPatchesTheList() throws {
        var now = SidebarPreview.referenceNow
        var snap = SidebarLoadTests.loadSnapshot()
        let (content, window) = Self.nativeContent(snap, now: { now })
        defer { window.contentView = nil }
        let native = try #require(content.nativeList)
        let cache = try #require(content.listCache)
        func fresh() -> [SidebarItem] { SidebarListBuilder.items(snapshot: snap, state: content.state, nowMs: TimestampFormat.nowMs(now)) }
        #expect(content.list.items.isEmpty) // the classic list holds nothing
        #expect(native.items == fresh())
        #expect(native.table.numberOfRows == native.items.count)
        // Only the rows on screen got cells.
        #expect(native.createdCells < 40)
        let generation = cache.generation, built = cache.rowModelBuilds, configured = native.configureCount
        snap.threads[1_400].title = "Renamed on screen"
        content.setSnapshot(snap, animated: false, changedThreadIds: [snap.threads[1_400].id])
        #expect(cache.generation == generation)
        #expect(cache.rowModelBuilds == built + 1)
        #expect(native.configureCount <= configured + 1)
        #expect(native.items == fresh())
        let row = try #require(native.rowIndex(snap.threads[1_400].id))
        let cell = try #require(native.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeThreadCardCell)
        #expect(cell.title.stringValue == "Renamed on screen")
        now = now.addingTimeInterval(3_600)
        content.setSnapshot(snap, animated: false)
        #expect(cache.generation == generation)
        #expect(native.items == fresh())
    }

    /// The native list shows the active thread as the table's selection, groups shelves under headers, and goes
    /// away again when the classic presentation returns.
    @Test func nativeListSelectionShelvesAndSwapBack() throws {
        let snap = SidebarLoadTests.loadSnapshot()
        let (content, window) = Self.nativeContent(snap, now: { SidebarPreview.referenceNow })
        defer { window.contentView = nil }
        let native = try #require(content.nativeList)
        content.state.activeThreadId = ThreadId("a1500")
        let row = try #require(native.rowIndex(ThreadId("a1500")))
        #expect(native.table.selectedRowIndexes == IndexSet(integer: row))
        // Cards above the settled shelf, slim rows under it, and the header between.
        let kinds = (0..<native.table.numberOfRows).compactMap { native.item(atRow: $0) }
        let header = try #require(kinds.firstIndex { if case .shelfHeader(.settled, _, _) = $0 { true } else { false } })
        #expect(kinds[..<header].allSatisfy { if case .row(let r) = $0 { r.variant == .card } else { false } })
        #expect(kinds[(header + 1)...].allSatisfy { if case .row(let r) = $0 { r.variant == .slim } else { true } })
        // Collapsing the shelf through the header leaves its count in the label.
        native.open(kinds[header])
        #expect(native.items.contains { if case .shelfHeader(.settled, let label, false) = $0 { label == "Settled (1400)" } else { false } })
        // The swipe on a card comes from the table delegate: Settle, then Snooze.
        let card = try #require(native.rowIndex(ThreadId("a1500")))
        #expect(native.tableView(native.table, rowActionsForRow: card, edge: .trailing).map(\.title) == ["Settle", "Snooze"])
        #expect(native.tableView(native.table, rowActionsForRow: card, edge: .leading).isEmpty)
        content.hidesCustomChrome = false
        #expect(content.nativeList == nil && native.superview == nil)
        #expect(content.list.items == SidebarListBuilder.items(snapshot: snap, state: content.state, nowMs: TimestampFormat.nowMs(SidebarPreview.referenceNow)))
    }
}
