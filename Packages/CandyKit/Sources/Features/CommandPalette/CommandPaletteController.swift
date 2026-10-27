import AppKit
import DesignSystem
import T3Protocol

/// The palette's state and keyboard handling (CommandPalette.tsx `OpenCommandPaletteDialog`): a view
/// stack of submenus, the query, the tracked highlight and item execution. The app supplies the
/// entries; this class only renders and routes them.
@MainActor
public final class CommandPaletteController {
    /// Where the entries come from. Called again whenever the palette refreshes.
    public struct Source {
        /// `buildRootGroups`: Actions and Recent Threads.
        public var rootGroups: () -> [PaletteGroup]
        /// `projectSearchItems`.
        public var projectItems: () -> [PaletteEntry]
        /// `allThreadItems`: every visible thread, ranked by `filter`.
        public var threadItems: (String) -> [PaletteEntry]
        /// `threadMessageItems`: threads whose messages match the query, best first, cut to what the palette shows.
        public var threadMessageItems: (String) -> [PaletteEntry]
        /// When the palette opened, which ranking is relative to, so rows don't reorder as time passes.
        public var now: Double
        /// True while the thread message search for the query has not settled.
        public var threadSearchPending: (String) -> Bool
        /// `settingsSearchItems`: settings matching a non-empty query.
        public var settingsItems: (String) -> [PaletteEntry]
        public init(rootGroups: @escaping () -> [PaletteGroup], projectItems: @escaping () -> [PaletteEntry] = { [] },
                    threadItems: @escaping (String) -> [PaletteEntry] = { _ in [] }, threadSearchPending: @escaping (String) -> Bool = { _ in false },
                    settingsItems: @escaping (String) -> [PaletteEntry] = { _ in [] },
                    threadMessageItems: @escaping (String) -> [PaletteEntry] = { _ in [] }, now: Double = 0) {
            self.rootGroups = rootGroups; self.projectItems = projectItems
            self.threadMessageItems = threadMessageItems; self.now = now
            self.threadItems = threadItems; self.threadSearchPending = threadSearchPending
            self.settingsItems = settingsItems
        }
    }

    public let view = CommandPaletteView()
    public var source: Source

    /// A palette mode other than commands (`SearchOverlayMode` "files", CommandPalette.tsx:440-450):
    /// its own rows for the query, labels and empty text. Escape goes back to commands.
    public struct Mode {
        public var name: String
        public var placeholder: String
        public var footerActionLabel: String
        /// The groups for a query, in the order to show, and the empty state's message.
        public var results: (String) -> (groups: [PaletteGroup], empty: String)
        /// A mode with its own body (`panelSize="fill"`), such as Search project contents.
        public var custom: Custom?
        /// Return before the rows get it: the query, the highlighted row and the modifier keys; true when used
        /// (browse adds the typed path, New project creates).
        public var onSubmit: ((_ query: String, _ highlighted: PaletteEntry?, _ flags: NSEvent.ModifierFlags) -> Bool)?
        /// Base UI's `autoHighlight="always"`: false in browse and the add-project steps.
        public var autoHighlight = true
        /// The control inside the input's end (the browse "Add" button).
        public var accessory: NSView?
        /// A footer action after the key hints ("Open in Finder").
        public var footerTrailing: NSView?
        /// The Enter hint's label for the highlighted row, when it depends on it; nil hides the hint.
        public var footerLabel: ((PaletteEntry?) -> String?)?
        /// A status line in place of the rows while there are none ("Loading folders...").
        public var status: ((String) -> String?)?
        /// The Escape hint's label: "Back" to commands, "Close" for a dialog of its own (the project icon picker).
        public var escapeLabel = "Back"
        /// The input's start addon outside submenus (browse shows the folder-plus).
        public var startIcon: IconName = .search
        public init(name: String, placeholder: String, footerActionLabel: String, results: @escaping (String) -> (groups: [PaletteGroup], empty: String)) {
            self.name = name; self.placeholder = placeholder; self.footerActionLabel = footerActionLabel; self.results = results
        }
        public init(name: String, placeholder: String, footerActionLabel: String, custom: Custom) {
            self.init(name: name, placeholder: placeholder, footerActionLabel: footerActionLabel, results: { _ in ([], "") })
            self.custom = custom
        }
    }

    /// A custom mode's body, the controls in its input, and where the query and keys go.
    public struct Custom {
        public var view: NSView
        public var accessory: NSView?
        public var onQuery: (String) -> Void
        /// Arrows and Return; true when handled.
        public var onCommand: (Selector) -> Bool
        public init(view: NSView, accessory: NSView? = nil, onQuery: @escaping (String) -> Void, onCommand: @escaping (Selector) -> Bool) {
            self.view = view; self.accessory = accessory; self.onQuery = onQuery; self.onCommand = onCommand
        }
    }
    public private(set) var mode: Mode?
    /// Escape in a mode: the app switches back to commands (`toggleMode("command")`).
    public var onLeaveMode: (() -> Void)?
    /// The query's own mode on a page without one (`isBrowsing`: a path typed at the root or in a
    /// submenu lists folders), nil for the page's rows.
    public var browse: ((String) -> Mode?)?

    /// The rows' mode: the overlay mode, else the open page's own, else the query's browse mode.
    private var activeMode: Mode? { mode ?? stack.last?.mode ?? browse?(query) }

    /// Enters `mode` with an empty query, or back to commands with nil. A mode a palette item opened ("Go to file",
    /// "Search project contents") gives the query that led there back when it leaves (`OpenChildSearch` and
    /// `BackToCommand`, CommandPalette.logic.ts:114-124, CommandPalette.tsx:1389,1402). Shortcuts open modes with none.
    public func setMode(_ mode: Mode?) {
        let restored = mode == nil ? parentQuery : nil
        parentQuery = mode == nil ? nil : runningQuery
        self.mode = mode
        stack = []
        setQuery(restored ?? "")
        highlightedValue = nil
        highlightCleared = false
        if let restored { onQueryChange?(restored) }
        refresh()
    }
    /// The command query a child mode returns to, and the query while a palette item runs.
    private var parentQuery: String?
    private var runningQuery: String?
    /// The palette asks to close (Escape, an item that doesn't keep it open).
    public var onClose: (() -> Void)?
    /// The query changed: the app may start a message search for it.
    public var onQueryChange: ((String) -> Void)?

    private(set) var stack: [PalettePage] = []
    public private(set) var query = ""
    /// `highlightedItemValue`.
    private(set) var highlightedValue: String?
    /// Typing or entering a submenu hides the highlight; Enter still runs the first row and the
    /// first ArrowDown lands on it (CommandPalette.tsx:710-717, 3166-3183).
    private var highlightCleared = false
    private(set) var displayed: [PaletteGroup] = []
    private var flat: [PaletteEntry] = []
    private var settingText = false

    public init(source: Source) {
        self.source = source
        view.input.onChange = { [weak self] text in self?.queryChanged(text) }
        view.input.onCommand = { [weak self] selector in self?.handleCommand(selector) ?? false }
        view.onExecute = { [weak self] index in self?.execute(at: index) }
        view.onHighlight = { [weak self] index in
            guard let self, index < self.flat.count else { return }
            self.highlightCleared = false
            self.highlightedValue = self.flat[index].value
        }
        view.onBack = { [weak self] in self?.pop() }
        refresh()
        // Base UI's `autoHighlight="always"` puts the first row on show.
        highlightedValue = firstEnabled?.value
        applyHighlight()
    }

    public var isInSubmenu: Bool { !stack.isEmpty }
    private var firstEnabled: PaletteEntry? { flat.first { !$0.isDisabled } }

    // MARK: State

    /// Rebuilds the rows from the source for the current view and query.
    public func refresh() {
        refreshPending = false
        if let mode, let custom = mode.custom {
            if view.inputAccessory !== custom.accessory { view.inputAccessory = custom.accessory }
            displayed = []
            flat = []
            if case .custom(let v) = view.content, v === custom.view {} else { view.content = .custom(custom.view) }
            view.input.placeholder = mode.placeholder
            view.showsBackButton = false
            view.showsBackHint = false
            view.footerActionLabel = mode.footerActionLabel
            view.escapeLabel = "Back"
            view.superview?.needsLayout = true
            return
        }
        if let active = activeMode {
            let result = active.results(query)
            displayed = result.groups
            flat = displayed.flatMap(\.items)
            let status = flat.isEmpty ? active.status?(query) : nil
            if let status {
                view.content = .loading(status)
            } else if displayed.isEmpty {
                view.content = .empty(message: result.empty, actionsOnly: false)
            } else {
                view.content = .results(displayed.map { CommandPaletteGroup($0.label.isEmpty ? nil : $0.label, $0.items.map(Self.item)) })
            }
            view.input.placeholder = active.placeholder
            let overlay = mode != nil
            view.showsBackButton = !overlay && isInSubmenu
            view.showsBackHint = !overlay && isInSubmenu
            view.escapeLabel = overlay ? active.escapeLabel : "Close"
            if view.inputAccessory !== active.accessory { view.inputAccessory = active.accessory }
            // The accessory reads the app's state when it lays out (its label and enabled state).
            if let accessory = active.accessory { accessory.needsLayout = true; accessory.layoutSubtreeIfNeeded(); view.needsLayout = true }
            if view.footerTrailing !== active.footerTrailing { view.footerTrailing = active.footerTrailing }
            view.startIcon = active.startIcon
            // `autoHighlight="always"`: the first row stays highlighted as results change.
            if let value = highlightedValue, flat.contains(where: { $0.value == value && !$0.isDisabled }) {} else {
                highlightedValue = active.autoHighlight ? firstEnabled?.value : nil
            }
            view.footerActionLabel = active.footerLabel.map { $0(highlightedEntry) } ?? active.footerActionLabel
            view.superview?.needsLayout = true
            applyHighlight()
            return
        }
        if view.inputAccessory != nil { view.inputAccessory = nil }
        if view.footerTrailing != nil { view.footerTrailing = nil }
        view.startIcon = .search
        view.escapeLabel = "Close"
        let active = stack.last?.groups ?? source.rootGroups()
        let searching = !isInSubmenu && !query.hasPrefix(">")
        let hasQuery = searching && !PaletteSearch.normalize(query).isEmpty
        let hasText = !query.trimmingCharacters(in: .whitespaces).isEmpty
        displayed = PaletteSearch.filter(active, query: query, isInSubmenu: isInSubmenu,
                                         rootGroups: hasText && stack.last?.mode == nil ? source.rootGroups() : nil,
                                         projectItems: searching || hasText ? source.projectItems() : [],
                                         settingsItems: hasQuery || (isInSubmenu && hasText) ? source.settingsItems(query) : [],
                                         threadItems: hasQuery || (isInSubmenu && hasText) ? source.threadItems(query) : [],
                                         threadMessageItems: hasQuery || (isInSubmenu && hasText) ? source.threadMessageItems(query) : [],
                                         now: source.now)
        flat = displayed.flatMap(\.items)
        if displayed.isEmpty {
            let pending = searching && source.threadSearchPending(query)
            view.content = .empty(message: pending ? "Searching thread messages\u{2026}" : nil, actionsOnly: query.hasPrefix(">"))
        } else {
            view.content = .results(displayed.map { CommandPaletteGroup($0.label.isEmpty ? nil : $0.label, $0.items.map(Self.item)) })
        }
        view.input.placeholder = PaletteSearch.placeholder(inSubmenu: isInSubmenu)
        view.showsBackButton = isInSubmenu
        view.showsBackHint = isInSubmenu
        view.footerActionLabel = "Select"
        if let value = highlightedValue, !flat.contains(where: { $0.value == value && !$0.isDisabled }) { highlightedValue = nil }
        view.superview?.needsLayout = true
        applyHighlight()
    }

    /// The row the view draws for an entry.
    static func item(_ entry: PaletteEntry) -> CommandPaletteItem {
        var item = CommandPaletteItem(entry.title, icon: entry.icon, description: entry.description,
                                      shortcut: entry.shortcutCommand.flatMap { ActiveKeymap.keymap.label(for: $0) },
                                      timestamp: entry.timestamp, isSubmenu: entry.isSubmenu, isDisabled: entry.isDisabled,
                                      titleEmphasis: entry.titleEmphasis, match: entry.matchLine?.text, note: entry.note)
        item.matchIsUser = entry.matchIsUser
        item.matchHighlights = entry.matchLine.map(\.highlights)
        item.matchHintLabelLength = entry.matchLine?.hintLabelLength
        item.glyph = entry.glyph
        if let source = entry.projectIcon { item.makeIcon = { ProjectMonogramView(source) } }
        item.titleHighlights = entry.titleHighlights
        item.descriptionHighlights = entry.descriptionHighlights
        item.isStatic = entry.isStatic
        item.trailingIcon = entry.trailingIcon
        item.trailingCheckbox = entry.trailingCheckbox
        item.noteIsWarning = entry.noteIsWarning
        if let badge = entry.pullRequestBadge {
            let settled = entry.pullRequestBadgeSettled
            item.makeTrailing = { SearchPullRequestBadgeView(badge, settled: settled) }
        }
        return item
    }

    private func applyHighlight() {
        view.highlightedIndex = highlightedValue.flatMap { value in flat.firstIndex { $0.value == value } }
        view.scrollHighlightIntoView()
    }

    private func queryChanged(_ text: String) {
        guard !settingText else { return }
        query = text
        if let custom = mode?.custom { custom.onQuery(text); return }
        highlightCleared = true
        highlightedValue = nil
        // `nextQuery === "" && currentView?.initialQuery`: an empty initial query keeps its page.
        if mode == nil, text.isEmpty, !(stack.last?.initialQuery ?? "").isEmpty { pop(); return }
        onQueryChange?(text)
        // The typed glyph commits first and the rows follow on the next turn, so a key never waits for the search
        // (14 to 30 ms a key with 1,000 threads), and keys that arrive together search once.
        if !refreshPending {
            refreshPending = true
            AfterCommit.run { [weak self] in self?.flushRefresh() }
        }
    }

    private var refreshPending = false

    /// A search still waiting from the last key runs now, so Enter, the arrows and jumps act on its rows.
    func flushRefresh() {
        if refreshPending { refresh() }
    }

    private func setQuery(_ text: String) {
        settingText = true
        view.input.text = text
        settingText = false
        query = text
    }

    public func push(_ page: PalettePage) {
        stack.append(page)
        highlightCleared = true
        highlightedValue = nil
        setQuery(page.initialQuery ?? "")
        refresh()
    }

    public func pop() {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        highlightedValue = nil
        setQuery("")
        refresh()
    }

    // MARK: Keys

    /// The input's editing commands: arrows move the highlight, Return runs it, Backspace on an
    /// empty query leaves a submenu, Escape closes (CommandPalette.tsx:3160-3201).
    func handleCommand(_ selector: Selector) -> Bool {
        flushRefresh()
        if let custom = mode?.custom, selector != #selector(NSResponder.cancelOperation(_:)) { return custom.onCommand(selector) }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if highlightCleared || highlightedValue == nil, let first = firstEnabled {
                highlightCleared = false
                highlightedValue = first.value
                applyHighlight()
            } else {
                move(1)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if highlightCleared { highlightCleared = false; highlightedValue = nil }
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let active = activeMode
            if let submit = active?.onSubmit, submit(query, highlightedEntry, NSApp.currentEvent?.modifierFlags ?? []) { return true }
            if let entry = highlightedEntry ?? ((active?.autoHighlight ?? true) ? firstEnabled : nil) { execute(entry) }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard query.isEmpty, isInSubmenu else { return false }
            pop()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if mode != nil, let onLeaveMode { onLeaveMode(); return true }
            onClose?()
            return true
        default:
            return false
        }
    }

    /// The highlighted row's value (`highlightedItemValue`), nil while none is.
    public var highlightedItemValue: String? { highlightedValue }

    /// Replaces the typed query (browse navigation, the clone destination), as typing it would.
    public func replaceQuery(_ text: String) {
        setQuery(text)
        highlightCleared = true
        highlightedValue = nil
        onQueryChange?(text)
        refresh()
    }

    private var highlightedEntry: PaletteEntry? {
        highlightedValue.flatMap { value in flat.first { $0.value == value && !$0.isDisabled } }
    }

    private func move(_ delta: Int) {
        view.moveHighlight(by: delta)
        highlightedValue = view.highlightedIndex.map { flat[$0].value }
    }

    /// Palette-level keybindings while it is open (`handleKeyDown`, CommandPalette.tsx:2313-2339):
    /// `thread.jump.N` runs the item showing that shortcut, and a new-thread shortcut runs its item when one
    /// shows, unless an input method is composing. Returns true when used.
    public func handleJump(_ command: String) -> Bool {
        let isJump = Keymap.jumpIndex(command, prefix: "thread.jump.") != nil
        let isNewThread = Self.newThreadCommands.contains(command) && !view.input.hasMarkedText
        guard isJump || isNewThread else { return false }
        flushRefresh()
        guard let item = flat.first(where: { $0.shortcutCommand == command }) else { return isJump }
        execute(item)
        return true
    }
    static let newThreadCommands: Set<String> = ["chat.new", "chat.newLocal", "chat.newWithoutProject"]

    // MARK: Running

    private func execute(at index: Int) {
        guard index < flat.count else { return }
        execute(flat[index])
    }

    /// `executeItem` (CommandPalette.tsx:3203-3225).
    public func execute(_ entry: PaletteEntry) {
        guard !entry.isDisabled else { return }
        switch entry.action {
        case .submenu(let page):
            push(page)
        case .run(let run, let keepOpen):
            if !keepOpen { onClose?() }
            runningQuery = mode == nil && stack.isEmpty ? query : nil
            defer { runningQuery = nil }
            run()
        }
    }
}

/// The dialog viewport around the palette (`CommandDialogPopup`, ui/command.tsx:50-80): the dialog
/// backdrop, the popup centered horizontally at `py-[10vh]`, `max-w-xl`, `px-4`. A click outside
/// closes it, as does the controller (Escape, a run item).
@MainActor
public final class CommandPaletteOverlay: DSView {
    public let controller: CommandPaletteController
    public var onDismiss: (() -> Void)?
    private let tint = CALayer()
    private let blurred = CALayer()
    private weak var previousResponder: NSResponder?
    private var isClosing = false
    private var snapshotPending = false
    /// The blurred window content behind the palette.
    var backdrop: CGImage? { blurred.contents.map { $0 as! CGImage } }

    public init(controller: CommandPaletteController) {
        self.controller = controller
        super.init(frame: .zero)
        layer?.addSublayer(blurred)
        layer?.addSublayer(tint)
        for l in [tint, blurred] { l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()] }
        blurred.contentsGravity = .resize
        addSubview(controller.view)
        setAccessibilityRole(.group)
    }

    /// Shows the palette over `window`'s content and focuses its input.
    public func present(in window: NSWindow) {
        guard let container = window.contentView else { return }
        previousResponder = window.firstResponder
        blurred.contents = ModalHost.blurredSnapshot(of: container)
        frame = container.bounds
        autoresizingMask = [.width, .height]
        container.addSubview(self)
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(controller.view.input)
        animate(entering: true)
        // T3's backdrop is a live `backdrop-filter`, so the sidebar toggled under the open palette (Mod+B) shows
        // its new layout. The views under the palette moving or resizing asks for a fresh snapshot, once per turn.
        for sibling in container.subviews where sibling !== self {
            NotificationCenter.default.addObserver(self, selector: #selector(siblingMoved), name: NSView.frameDidChangeNotification, object: sibling)
        }
    }

    @objc private func siblingMoved() {
        guard !snapshotPending, !isClosing else { return }
        snapshotPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.snapshotPending = false
            guard !self.isClosing, let container = self.superview else { return }
            self.blurred.contents = ModalHost.blurredSnapshot(of: container, excluding: self)
        }
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
    }

    public func close() {
        guard !isClosing else { return }
        isClosing = true
        stopObserving()
        if let window {
            if let previousResponder, previousResponder !== controller.view.input, (previousResponder as? NSView)?.window === window {
                window.makeFirstResponder(previousResponder)
            } else {
                window.makeFirstResponder(nil)
            }
        }
        animate(entering: false) { [weak self] in
            self?.removeFromSuperview()
            self?.onDismiss?()
        }
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        blurred.frame = bounds
        CATransaction.commit()
        let width = min(CommandPaletteView.width, bounds.width - 32)
        let top = max(16, (bounds.height * 0.1).rounded())
        let height = min(controller.view.intrinsicContentSize.height, bounds.height - 2 * top)
        controller.view.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: top, width: width, height: height)
    }

    public override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        tint.backgroundColor = Themed.color(\.background, dark ? 0.64 : 0.6).cgColor(in: self)
    }

    public override func mouseDown(with event: NSEvent) {
        if !controller.view.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    public override func scrollWheel(with event: NSEvent) {}

    /// The dialog popup's motion: scale from .98 and fade, backdrop fade, 200ms.
    private func animate(entering: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let layer, let panelLayer = controller.view.layer, !Motion.reduced else { completion?(); return }
        let f = controller.view.frame
        var hidden = CATransform3DMakeTranslation(f.width / 2, f.height / 2, 0)
        hidden = CATransform3DScale(hidden, 0.98, 0.98, 1)
        hidden = CATransform3DTranslate(hidden, -f.width / 2, -f.height / 2, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        for (target, key, from, to) in [
            (layer, "opacity", entering ? 0 : 1, entering ? 1 : 0) as (CALayer, String, Any, Any),
            (panelLayer, "transform", entering ? hidden : CATransform3DIdentity, entering ? CATransform3DIdentity : hidden),
        ] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.2
            a.timingFunction = Motion.easeInOut
            a.fillMode = .forwards
            a.isRemovedOnCompletion = entering
            target.add(a, forKey: key)
        }
        CATransaction.commit()
    }
}
