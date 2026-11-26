import DesignSystem
import T3Store

/// The open thread's menu as palette rows (T3 5258 CommandPaletteThreadActions.tsx, #40742).
@MainActor
public enum PaletteThreadActions {
    /// CommandPaletteThreadActions.tsx:31-48 at 5258: the menu icons the palette draws. Find, rename, guest share, the
    /// project filter and project settings map to none. Rewrite title keeps the menus' own glyph.
    public static let icons: [String: IconName] = [
        "archive": .archive, "settle": .circleCheck, "unsettle": .circleCheck, "snooze": .clock, "unsnooze": .clock,
        "copy": .copy, "copy-path": .folder, "turn-into-project": .folderPlus, "copy-branch": .gitBranch, "copy-thread-id": .hash,
        "mark-unread": .mailOpen, "copy-thread": .messageSquare, "new-thread-on-branch": .messageSquarePlus, "pin": .pin,
        "unpin": .pinOff, "rewrite-title": .pencilLine, "auto-settle": .timer, "delete": .trash,
    ]
    /// CommandPaletteThreadActions.tsx:53-59: the rows that show their shortcut.
    public static let shortcuts = [
        "settle": "thread.settle", "unsettle": "thread.settle", "pin": "thread.pin", "unpin": "thread.pin", "rewrite-title": "thread.regenerateTitle",
    ]

    public static func entries(_ items: [ThreadMenuItem], run: @escaping @MainActor (String) -> Void) -> [PaletteEntry] {
        func entry(_ item: ThreadMenuItem) -> PaletteEntry? {
            if item.id == "rename" || item.id == "project-settings" { return nil }
            let value = "thread-action:\(item.id)", icon = icons[item.id]
            let description = item.detail ?? item.tooltip
            guard item.children.isEmpty else {
                // Search lists children directly, so they take the parent's disabled state.
                let children = item.children.compactMap { child -> PaletteEntry? in
                    var child = child
                    if item.disabled { child.disabled = true }
                    return entry(child)
                }
                if children.isEmpty { return nil }
                let page = PalettePage(addonIcon: icon ?? .ellipsis, groups: [PaletteGroup(value: value, label: item.label, items: children)])
                return PaletteEntry(value: value, searchTerms: [], title: item.label, description: description, icon: icon,
                                    isDisabled: item.disabled, action: .submenu(page))
            }
            return PaletteEntry(value: value, searchTerms: [], title: item.label, description: description, icon: icon,
                                isDisabled: item.disabled, shortcutCommand: shortcuts[item.id],
                                action: .run({ run(item.id) }, keepOpen: false))
        }
        return items.compactMap(entry)
    }
}
