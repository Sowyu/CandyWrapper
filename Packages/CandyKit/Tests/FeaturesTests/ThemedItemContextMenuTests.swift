import AppKit
import DesignSystem
import Testing
import T3Store
@testable import Features

/// The themed thread menus keep every item of T3's menus, in order, with T3's separators, icons, checks and submenus,
/// and each row still fires its own id.
@MainActor
@Suite("Themed thread context menu")
struct ThemedItemContextMenuTests {
    private func titles(_ items: [MenuItem]) -> [String] { items.map { if case .separator = $0.kind { "—" } else { $0.title } } }

    @Test func singleThreadMenuKeepsEveryItem() {
        var state = ThreadActionMenu.State()
        state.branch = "main"
        state.projectFilter = (label: "Sandbox", isActive: false)
        state.isSettled = true
        state.snoozePresets = SnoozePresets.resolve(now: Date(timeIntervalSince1970: 1_800_000_000))
        let source = ThreadActionMenu.items(state)
        var chosen: [String] = []
        let items = ThemedItemContextMenu.items(source) { chosen.append($0) }
        #expect(titles(items) == ["New thread on main", "Pin thread", "Un-settle thread", "Snooze", "—", "Rename thread",
                                  "Regenerate title", "Mark unread", "Filter by Sandbox", "Auto-settle behavior", "—", "Copy",
                                  "Project settings", "—", "Archive thread", "Delete"])
        let rows = items.filter { if case .separator = $0.kind { false } else { true } }
        // Every leaf fires its own id; submenus carry their children.
        for (row, item) in zip(rows, source) {
            if case .submenu(let children) = row.kind {
                #expect(children.filter { if case .separator = $0.kind { false } else { true } }.count == item.children.count)
            } else {
                row.action?()
                #expect(chosen.last == item.id)
            }
        }
        #expect(rows.first { $0.title == "Archive thread" }?.icon == .archive)
        #expect(rows.last?.isDestructive == true && rows.last?.icon == .trash)
        guard case .submenu(let autoSettle)? = rows.first(where: { $0.title == "Auto-settle behavior" })?.kind,
              case .radio(true) = autoSettle[0].kind else { Issue.record("auto-settle should be a checked radio"); return }
        autoSettle[1].onToggle?(true)
        #expect(chosen.last == "auto-settle:disabled")
        guard case .submenu(let snooze)? = rows.first(where: { $0.title == "Snooze" })?.kind else { Issue.record("no Snooze submenu"); return }
        #expect(titles(snooze).suffix(2) == ["—", "Custom…"])
    }

    @Test func bulkMenuOffersArchiveAndUnsettle() {
        let source = ThreadActionMenu.bulkItems(count: 10, pinnedCount: 0, settlingCount: 0, canSnooze: true, titleSupportedCount: 10,
                                                titleActionableCount: 10, archivableCount: 10, snoozePresets: [])
        var chosen: [String] = []
        let items = ThemedItemContextMenu.items(source) { chosen.append($0) }
        #expect(titles(items) == ["Unsettle (10)", "Snooze (10)", "Regenerate titles (10)", "Mark unread (10)", "—", "Archive (10)", "Delete (10)"])
        items.first { $0.title == "Archive (10)" }?.action?()
        items.first { $0.title == "Unsettle (10)" }?.action?()
        #expect(chosen == ["archive", "unsettle"])
    }
}
