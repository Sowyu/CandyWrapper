import AppKit
import T3Store

/// The single native adapter for thread, file, branch and media context menus.
@MainActor
public enum NativeItemContextMenu {
    public static func make(_ items: [ThreadMenuItem], choose: @escaping @MainActor (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // ElectronMenu.ts:147-187: the first destructive item starts its own section unless an explicit separator
        // already did, and a destructive leaf wears the 12pt template "trash" image.
        var destructiveSeparated = false, sectionFromSeparator = false
        for item in items {
            if item.separatorBefore {
                if menu.items.last.map({ !$0.isSeparatorItem }) == true { menu.addItem(.separator()) }
                sectionFromSeparator = true
            }
            if item.destructive, !destructiveSeparated, !sectionFromSeparator, menu.items.last.map({ !$0.isSeparatorItem }) == true {
                menu.addItem(.separator())
                destructiveSeparated = true
            }
            let native = NativeItemContextMenuAction(title: item.label, action: nil, keyEquivalent: "")
            if item.destructive, item.children.isEmpty {
                native.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
                #if compiler(>=6.4)
                if #available(macOS 27, *) { native.preferredImageVisibility = .visible }
                #endif
            }
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
