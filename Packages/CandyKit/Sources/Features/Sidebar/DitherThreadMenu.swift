import AppKit
import DesignSystem
import T3Store

/// Dither's thread menu (after Capy's row menu): the same actions as T3's `ThreadActionMenu`, reordered with an icon on
/// every row and single-key hints. Settle and Snooze lead, then the thread's own actions, then Mark as unread, Archive
/// and Delete. Capy's Share, Move to, Tags and Copy link have nothing behind them here, so they are left out.
@MainActor
public enum DitherThreadMenu {
    /// The leading group, the middle group in this order, and the closing group. Ids not listed (none today) join the middle.
    static let leading: [String] = ["settle", "unsettle", "snooze", "unsnooze"]
    static let middle: [String] = ["open-new-tab", "pin", "unpin", "rename", "regenerate-title", "copy", "new-thread-on-branch",
                                   "filter-by-project", "auto-settle", "project-settings", "hands-off"]
    static let closing: [String] = ["mark-unread", "archive", "delete"]

    static let keys: [String: String] = ["settle": "S", "unsettle": "S", "snooze": "Z", "unsnooze": "Z",
                                         "mark-unread": "U", "archive": "A", "delete": "D"]
    static let icons: [String: IconName] = [
        "settle": .check, "unsettle": .undo2, "snooze": .clock, "unsnooze": .alarmClockOff, "open-new-tab": .arrowUpRight,
        "pin": .pin, "unpin": .pinOff, "rename": .squarePen, "regenerate-title": .rotateCw, "copy": .copy,
        "new-thread-on-branch": .gitBranchPlus, "filter-by-project": .listFilter, "auto-settle": .circleCheck,
        "project-settings": .settings, "mark-unread": .mail, "archive": .archive, "delete": .trash2,
    ]
    /// Capy's shorter labels; the rest keep T3's.
    static let titles: [String: String] = ["settle": "Settle", "unsettle": "Un-settle", "unsnooze": "Wake", "pin": "Pin",
                                           "unpin": "Unpin", "rename": "Rename", "mark-unread": "Mark as unread",
                                           "archive": "Archive", "open-new-tab": "Open in new tab"]

    /// The menu rows and, by lowercase key, the row each hint picks. `openInNewTab` adds that row when the caller can.
    public static func items(_ source: [ThreadMenuItem], presets: [SnoozePreset], openInNewTab: Bool,
                             choose: @escaping @MainActor (String) -> Void) -> (items: [MenuItem], keys: [String: Int]) {
        var all = source
        if openInNewTab { all.append(ThreadMenuItem("open-new-tab", "Open in new tab")) }
        let known = Set(leading + middle + closing)
        let groups = [leading, middle + all.map(\.id).filter { !known.contains($0) }, closing].map { ids in
            ids.compactMap { id in all.first { $0.id == id } }
        }.filter { !$0.isEmpty }
        var items: [MenuItem] = []
        var keyMap: [String: Int] = [:]
        for group in groups {
            if !items.isEmpty { items.append(.separator) }
            for t in group {
                if let key = keys[t.id], !t.disabled { keyMap[key.lowercased()] = items.count }
                items.append(row(t, presets: presets, choose: choose))
            }
        }
        return (items, keyMap)
    }

    private static func row(_ t: ThreadMenuItem, presets: [SnoozePreset], choose: @escaping @MainActor (String) -> Void) -> MenuItem {
        let title = titles[t.id] ?? t.label
        if !t.children.isEmpty {
            var m = MenuItem.submenu(title, icon: icons[t.id], t.children.flatMap { child(t.id, $0, presets: presets, choose: choose) })
            m.shortcut = keys[t.id]
            m.isDisabled = t.disabled
            return m
        }
        var m: MenuItem
        if let checked = t.checked {
            // A setting: the same label either way, with a check while it's on.
            m = .checkbox(title, checked: checked) { _ in choose(t.id) }
            m.closesOnClick = true
            m.isDisabled = t.disabled
        } else {
            m = MenuItem(title, icon: icons[t.id], shortcut: keys[t.id], destructive: t.destructive, disabled: t.disabled) { choose(t.id) }
        }
        m.subtitle = t.detail
        m.tooltip = t.detail
        m.widensForSubtitle = t.detail != nil
        return m
    }

    private static func child(_ parent: String, _ t: ThreadMenuItem, presets: [SnoozePreset],
                              choose: @escaping @MainActor (String) -> Void) -> [MenuItem] {
        var m: MenuItem
        if let checked = t.checked {
            m = .radio(t.label, checked: checked) { _ in choose(t.id) }
            m.closesOnClick = true
        } else if let preset = presets.first(where: { "snooze:\($0.id)" == t.id }) {
            // The time sits in the shortcut column, as in the row's own Snooze menu.
            m = MenuItem(preset.label, shortcut: preset.whenLabel) { choose(t.id) }
        } else {
            m = MenuItem(t.label) { choose(t.id) }
        }
        m.isDisabled = t.disabled
        return t.separatorBefore ? [.separator, m] : [m]
    }

    /// Opens the menu: under `anchor` (the row's ⋯) or at `point` in `view` (a right click), with the key hints live.
    @discardableResult
    public static func show(_ built: (items: [MenuItem], keys: [String: Int]), from anchor: NSView? = nil,
                            in view: NSView, at point: CGPoint) -> MenuPopupView? {
        let menu = anchor.map {
            MenuPopupView.show(built.items, from: $0, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
        } ?? MenuPopupView.showContextMenu(built.items, in: view, at: point)
        guard let menu else { return nil }
        menu.characterOverride = { [weak menu] c in
            guard let menu, let i = built.keys[c.lowercased()] else { return false }
            menu.activate(i, byKeyboard: true)
            return true
        }
        return menu
    }
}
