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
                if (self.window?.firstResponder as? ShortcutCaptureResponder)?.isCapturing == true { return false }
                if self.handleSnapShot(event) { return true }
                if self.quitHoldKey(event) { return true }
                return event.type == .keyDown && self.handle(event)
            }
            return used ? nil : event
        }
    }

    private var snapShotMonitor: Any?
    private var snapShotState = SnapShotShortcutState()
    private var snapShotShortcut: JSONValue?
    private var snapShotAction: (() -> Void)?

    func configureSnapShot(enabled: Bool, shortcut: JSONValue, action: @escaping () -> Void) {
        if let snapShotMonitor { NSEvent.removeMonitor(snapShotMonitor); self.snapShotMonitor = nil }
        snapShotState.reset()
        snapShotShortcut = enabled ? shortcut : nil
        snapShotAction = enabled ? action : nil
        guard enabled else { return }
        snapShotMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { _ = self?.handleSnapShot(event) }
        }
    }

    private func handleSnapShot(_ event: NSEvent) -> Bool {
        guard let shortcut = snapShotShortcut, (window?.firstResponder as? ShortcutCaptureResponder)?.isCapturing != true else { return false }
        let kind = shortcut["kind"]?.stringValue
        if kind == "modifier-pair" || kind == "both-shift-keys" {
            guard event.type == .flagsChanged else { return false }
            if snapShotState.update(flags: UInt64(event.modifierFlags.rawValue), shortcut: shortcut) { snapShotAction?(); return true }
        } else if event.type == .keyDown, !event.isARepeat {
            let flags = event.modifierFlags
            guard event.charactersIgnoringModifiers?.lowercased() == shortcut["key"]?.stringValue?.lowercased(),
                  flags.contains(.command) == (shortcut["metaKey"]?.boolValue == true || shortcut["modKey"]?.boolValue == true),
                  flags.contains(.control) == (shortcut["ctrlKey"]?.boolValue == true),
                  flags.contains(.option) == (shortcut["altKey"]?.boolValue == true),
                  flags.contains(.shift) == (shortcut["shiftKey"]?.boolValue == true) else { return false }
            snapShotAction?()
            return true
        }
        return false
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

    /// Commands named at run time (`script.<id>.run`): the handler sees every command with the prefix.
    func on(prefix: String, _ handler: @escaping (Invocation) -> Bool) { prefixHandlers.append((prefix, handler)) }
    private var prefixHandlers: [(String, (Invocation) -> Bool)] = []

    /// Every keydown in the window, before resolution (the notification sound's unlock gesture).
    var onKeyDown: (() -> Void)?

    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        onKeyDown?()
        // A shortcut recorder takes every key while it captures.
        if (window?.firstResponder as? ShortcutCaptureResponder)?.isCapturing == true { return false }
        // A focused agent page or file preview keeps its keys, as a focused iframe does in T3. An HTML render passes
        // app shortcuts back itself (`run(_:)`, BrowserDocumentFrame.tsx in 3105).
        if ThreadWebFrames.holdKeyboard(in: window) { return false }
        // A held undo key undoes once. Its repeats stop here so they cannot fall through to an editor's own undo,
        // even after the last notice is gone (`ThreadUndoShortcut`, AppSidebarLayout.tsx:264-317 in 3473).
        if event.isARepeat {
            if event.keyCode == heldUndoKey { return true }
        } else {
            heldUndoKey = nil
        }
        // Any key but the undo one hands Mod+Z back to text fields before a component can take it, so a key the
        // composer handles itself, like Mod+B, releases the claim too (AppSidebarLayout.tsx:273-297 in 3473).
        let stroke = KeyStroke(event)
        if stroke.flatMap(resolve) != "thread.undo" { releaseUndoShortcut() }
        let paletteOpen = paletteOpen()
        if !paletteOpen, keyHandlers.contains(where: { $0(event) }) { return true }
        guard let stroke else { return false }
        let used = run(stroke, paletteOpen: paletteOpen)
        if used, lastCommand == "thread.undo" { heldUndoKey = event.keyCode }
        return used
    }

    /// The command a key event runs now, for a mode that takes a command over (Space mode's ⌘N and ⌘P).
    func command(for event: NSEvent) -> String? { KeyStroke(event).flatMap(resolve) }

    /// Whether the sidebar's undo notice owns Mod+Z inside text fields (`threadUndoClaimsShortcut` while the sidebar shows).
    var undoClaimsShortcut: () -> Bool = { false }
    /// Hands Mod+Z back to text fields (`releaseThreadUndoShortcut`).
    var releaseUndoShortcut: () -> Void = {}
    private var heldUndoKey: UInt16?
    private var lastCommand: String?
    private var textChangeObserver: Any?

    /// Pastes from a menu, dictation and drops edit text without a keypress, and release the claim too
    /// (AppSidebarLayout.tsx:307-310 in 3473).
    func observeTextEdits() {
        textChangeObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSView)?.window === self.window else { return }
                self.releaseUndoShortcut()
            }
        }
    }

    /// Runs the command a key resolves to: a key event, or a chord a focused HTML render replayed (the replay
    /// dispatches on the frame element and bubbles to the window's listeners, where T3 resolves it).
    @discardableResult
    func run(_ stroke: KeyStroke, paletteOpen: Bool? = nil) -> Bool {
        let paletteOpen = paletteOpen ?? self.paletteOpen()
        let command = resolve(stroke)
        if command != "thread.undo" { releaseUndoShortcut() }
        lastCommand = command
        guard let command else { return false }
        let invocation = Invocation(command: command, isRepeat: stroke.isRepeat)
        if paletteOpen {
            if !Self.commandsWhilePaletteOpen.contains(command) { return paletteCommand?(invocation) ?? false }
        }
        if let handler = handlers[command] { return handler(invocation) }
        return prefixHandlers.first { command.hasPrefix($0.0) }?.1(invocation) ?? false
    }

    /// The command a stroke runs. Right after a thread action Mod+Z undoes it even from the composer: `thread.undo`
    /// resolves as if no text field had focus. Any other key hands the field its own undo back (AppSidebarLayout.tsx:286-299 in 3473).
    private func resolve(_ stroke: KeyStroke) -> String? {
        var context = context()
        let command = ActiveKeymap.keymap.resolve(stroke, context: context)
        if command != "thread.undo", context["editableFocus"], undoClaimsShortcut() {
            context["editableFocus"] = false
            if ActiveKeymap.keymap.resolve(stroke, context: context) == "thread.undo" { return "thread.undo" }
        }
        return command
    }

    /// `editableFocus`: a text field or editor has the keyboard (lib/editableFocus.ts).
    static func editableFocused(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.isEditable == true
    }
}
