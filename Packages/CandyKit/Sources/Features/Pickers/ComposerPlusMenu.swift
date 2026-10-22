import AppKit
import DesignSystem

/// Redesign's composer "+" menu, after Capy's (2026-10-22): icon rows with key hints at the right, in groups.
/// The app passes only what it can do.
public struct ComposerPlusMenuItem {
    public var title: String
    public var icon: IconName
    public var shortcut: String?
    /// A separator goes before this item.
    public var startsGroup: Bool
    public var action: @MainActor () -> Void
    public init(_ title: String, icon: IconName, shortcut: String? = nil, startsGroup: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title; self.icon = icon; self.shortcut = shortcut; self.startsGroup = startsGroup; self.action = action
    }
}

@MainActor
public enum ComposerPlusMenu {
    private static weak var open: OpenPopup?

    /// Opens the menu over `trigger`, or closes it when it is already open there.
    public static func toggle(from trigger: NSView, items: [ComposerPlusMenuItem]) {
        guard let host = trigger.popupHost else { return }
        if let popup = open, popup.trigger === trigger, host.popups.contains(where: { $0 === popup }) {
            host.close(popup)
            return
        }
        var entries: [PickerMenuEntry] = []
        for (i, item) in items.enumerated() {
            if item.startsGroup, i > 0 { entries.append(.separator) }
            var e = PickerMenuEntry.option(item.title, icon: item.icon, checked: false, onPick: item.action)
            e.shortcut = item.shortcut
            entries.append(e)
        }
        let menu = PickerMenuView(entries: entries, style: .menu, minimumWidth: 220)
        let popup = host.open(PickerPopupView(menu), trigger: trigger,
                              placement: PopupPlacement(side: .top, align: .start, sideOffset: 6, fallbackAxisSide: .none),
                              motion: .popover, swallowsOutsideClick: true)
        menu.onClose = { [weak host, weak popup] in if let popup { host?.close(popup, returnFocus: false) } }
        if NSApp.currentEvent?.type == .keyDown { menu.highlightedIndex = menu.selectable.first }
        open = popup
    }
}
