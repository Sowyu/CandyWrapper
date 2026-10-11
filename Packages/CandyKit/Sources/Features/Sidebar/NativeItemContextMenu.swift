import AppKit
import T3Store

/// The single native adapter for thread, file, branch and media context menus.
@MainActor
public enum NativeItemContextMenu {
    public static func make(_ items: [ThreadMenuItem], choose: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separatorBefore, menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
            let native = NativeItemContextMenuAction(title: item.label, action: nil, keyEquivalent: "")
            native.isEnabled = !item.disabled
            if let checked = item.checked { native.state = checked ? .on : .off }
            if item.children.isEmpty {
                native.handler = { choose(item.id) }
            } else {
                native.submenu = make(item.children, choose: choose)
            }
            menu.addItem(native)
        }
        return menu
    }
}

@MainActor
private final class NativeItemContextMenuAction: NSMenuItem {
    var handler: (@MainActor () -> Void)? {
        didSet { target = self; action = #selector(run) }
    }
    @objc private func run() { handler?() }
}
