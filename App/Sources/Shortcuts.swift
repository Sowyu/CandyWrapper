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
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    func on(_ command: String, _ handler: @escaping (Invocation) -> Bool) { handlers[command] = handler }

    func on(_ commands: [String], _ handler: @escaping (Invocation) -> Bool) { for c in commands { handlers[c] = handler } }

    func onKey(_ handler: @escaping (NSEvent) -> Bool) { keyHandlers.append(handler) }

    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
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
