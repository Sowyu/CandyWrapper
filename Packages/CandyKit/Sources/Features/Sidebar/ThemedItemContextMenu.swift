import AppKit
import DesignSystem
import T3Store

/// The sidebar's thread menus drawn as T3's own themed context menu (apps/web/src/contextMenuFallback.ts) on the app's
/// glass menu surface, instead of an NSMenu: a separator only where `separatorBefore` asks, an icon per action as
/// threadActionMenu.logic.ts names it, checks for `checked`, submenus for children, and the menu's arrow-key navigation.
@MainActor
public enum ThemedItemContextMenu {
    /// threadActionMenu.logic.ts:115-235. Bulk ids ("archive", "settle", …) share their single-thread icon.
    static let icons: [String: IconName] = [
        "new-thread-on-branch": .messageSquarePlus, "pin": .pin, "unpin": .pinOff, "settle": .circleCheck,
        "unsettle": .circleCheck, "snooze": .clock, "unsnooze": .clock, "rename": .pencil, "regenerate-title": .refreshCw,
        "mark-unread": .mailOpen, "share-guest": .userPlus, "filter-by-project": .folderTree, "auto-settle": .timer,
        "copy": .copy, "copy-path": .folder, "copy-branch": .gitBranch, "copy-thread": .messageSquare, "copy-thread-id": .hash,
        "project-settings": .settings, "archive": .archive, "delete": .trash,
    ]

    public static func items(_ source: [ThreadMenuItem], choose: @escaping @MainActor (String) -> Void) -> [MenuItem] {
        var out: [MenuItem] = []
        for item in source {
            if item.separatorBefore, !out.isEmpty { out.append(.separator) }
            out.append(row(item, choose: choose))
        }
        return out
    }

    private static func row(_ t: ThreadMenuItem, choose: @escaping @MainActor (String) -> Void) -> MenuItem {
        var m: MenuItem
        if !t.children.isEmpty {
            m = .submenu(t.label, icon: icons[t.id], items(t.children, choose: choose))
        } else if let checked = t.checked {
            m = .radio(t.label, checked: checked) { _ in choose(t.id) }
            m.closesOnClick = true
        } else {
            // contextMenuFallback.ts:405-406: a leaf named "delete" is destructive even when the item doesn't say so.
            m = MenuItem(t.label, icon: icons[t.id], destructive: t.destructive || t.id == "delete") { choose(t.id) }
        }
        m.isDisabled = t.disabled
        m.subtitle = t.detail
        m.tooltip = t.detail
        m.widensForSubtitle = t.detail != nil
        return m
    }

    /// Opens the menu at `point` in `view`, or with its top left at `anchor` when given.
    @discardableResult
    public static func show(_ source: [ThreadMenuItem], in view: NSView, at point: CGPoint,
                            choose: @escaping @MainActor (String) -> Void) -> MenuPopupView? {
        MenuPopupView.showContextMenu(items(source, choose: choose), in: view, at: point)
    }
}
