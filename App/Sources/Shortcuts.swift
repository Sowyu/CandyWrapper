import AppKit
import Features
import T3Protocol

/// The app's one keyboard shortcut dispatcher. T3 resolves every keydown against the primary
/// environment's keybindings with `resolveShortcutCommand` (apps/web/src/keybindings.ts:155-171) in
/// several window listeners; here one local monitor resolves once and runs the handler registered
/// for the command. A handler returns false to leave the key alone (T3 skips `preventDefault`).
@MainActor
final class Shortcuts {
    struct Invocation {
        let command: String
        let isRepeat: Bool
    }

    private var handlers: [String: (Invocation) -> Bool] = [:]
    /// Component-level keys that are not keybindings (a question's digit options), tried first.
    private var keyHandlers: [(NSEvent) -> Bool] = []
    private weak var window: NSWindow?
    private var monitor: Any?
    /// The when-clause context (docs/user/keybindings.md "When conditions").
    var context: () -> KeybindingContext = { KeybindingContext() }
    /// While the palette is open only these commands run: T3's other listeners return early on
    /// `isCommandPaletteOpen()`, the palette's own listener (CommandPalette.tsx:518-575) and the
    /// sidebar toggle (AppSidebarLayout.tsx, capture phase) still see keys.
    var paletteOpen: () -> Bool = { false }
    /// The palette input's own commands (`handleKeyDown`, CommandPalette.tsx:3090-3122).
    var paletteCommand: ((Invocation) -> Bool)?
    static let commandsWhilePaletteOpen: Set<String> = [
        "commandPalette.toggle", "filePicker.toggle", "projectSearch.toggle", "appearance.cycle", "theme.select",
        "themeEditor.toggle", "usage.open", "sidebar.toggle", "navigation.back", "navigation.forward",
    ]

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if self.quitHoldKey(event) { return true }
                return event.type == .keyDown && self.handle(event)
            }
            return used ? nil : event
        }
    }

    /// Hold-to-quit sees the main window's keys before the menu does (T3's `before-input-event`,
    /// DesktopWindow.ts:642-679). The menu's Quit item stays immediate.
    var quitHold: QuitHoldController?
    private var commandDown = false

    private func quitHoldKey(_ event: NSEvent) -> Bool {
        guard let quitHold, event.window === window else { return false }
        let flags = event.modifierFlags
        let meta = flags.contains(.command), alt = flags.contains(.option), shift = flags.contains(.shift), control = flags.contains(.control)
        switch event.type {
        case .keyDown, .keyUp:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            return quitHold.handle(QuitHoldController.Key(event.type == .keyDown ? .down : .up, key, meta: meta, control: control, alt: alt,
                                                          shift: shift, isAutoRepeat: event.type == .keyDown && event.isARepeat))
        case .flagsChanged:
            // Electron reports modifier presses as keydowns of "Meta", "Shift", "Alt" or "Control".
            if meta != commandDown {
                commandDown = meta
                quitHold.handle(QuitHoldController.Key(meta ? .down : .up, "meta", meta: meta, control: control, alt: alt, shift: shift))
            } else if let key = [(55 as UInt16, "meta"), (54, "meta"), (56, "shift"), (60, "shift"), (58, "alt"), (61, "alt"),
                                 (59, "control"), (62, "control")].first(where: { $0.0 == event.keyCode })?.1, key != "meta" {
                let down = key == "shift" ? shift : key == "alt" ? alt : control
                if down { quitHold.handle(QuitHoldController.Key(.down, key, meta: meta, control: control, alt: alt, shift: shift)) }
            }
            return false
        default:
            return false
        }
    }

    func on(_ command: String, _ handler: @escaping (Invocation) -> Bool) { handlers[command] = handler }

    func on(_ commands: [String], _ handler: @escaping (Invocation) -> Bool) { for c in commands { handlers[c] = handler } }

    func onKey(_ handler: @escaping (NSEvent) -> Bool) { keyHandlers.append(handler) }

    /// Every keydown in the window, before resolution (the notification sound's unlock gesture).
    var onKeyDown: (() -> Void)?

    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        onKeyDown?()
        // A shortcut recorder takes every key while it captures.
        if (window?.firstResponder as? ShortcutCaptureResponder)?.isCapturing == true { return false }
        let paletteOpen = paletteOpen()
        if !paletteOpen, keyHandlers.contains(where: { $0(event) }) { return true }
        guard let command = ActiveKeymap.resolve(event, context: context()) else { return false }
        let invocation = Invocation(command: command, isRepeat: event.isARepeat)
        if paletteOpen {
            if !Self.commandsWhilePaletteOpen.contains(command) { return paletteCommand?(invocation) ?? false }
        }
        return handlers[command]?(invocation) ?? false
    }

    /// `editableFocus`: a text field or editor has the keyboard (lib/editableFocus.ts).
    static func editableFocused(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.isEditable == true
    }
}
