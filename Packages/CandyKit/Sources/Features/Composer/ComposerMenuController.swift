import AppKit

/// Runs the composer's `/`, `@`, `$` and `#` menu: follows the trigger under the caret, keeps the
/// highlight, takes ArrowUp, ArrowDown, Return, Tab and Escape while the menu is open, and puts a
/// pick into the prompt (ChatComposer.tsx:3976-4160, 4440-4470).
///
/// The app supplies the rows (`itemsProvider`, called again through `reload()` when async results
/// land) and acts on picks that do more than insert text (`onPick`, called before the insert so
/// records exist when the chip draws).
@MainActor
public final class ComposerMenuController {
    public struct Content {
        public var items: [ComposerMenuItem]
        public var emptyText: String
        public init(items: [ComposerMenuItem], emptyText: String) { self.items = items; self.emptyText = emptyText }
    }

    public var itemsProvider: ((ComposerTrigger) -> Content)?
    public var onPick: ((ComposerMenuItem) -> Void)?
    /// The trigger changed (the app starts or drops searches).
    public var onTriggerChange: ((ComposerTrigger?) -> Void)?
    /// The menu opened, closed or changed height.
    public var onLayoutChange: (() -> Void)?

    private let composer: ComposerView
    public let menu: ComposerCommandMenuView
    private var state = ComposerTriggerState()
    private var highlighted: (id: String, key: String)?
    public private(set) var items: [ComposerMenuItem] = []
    private var pickLock = false

    public var trigger: ComposerTrigger? { state.trigger }
    public var isOpen: Bool { state.trigger != nil }

    init(composer: ComposerView, menu: ComposerCommandMenuView) {
        self.composer = composer
        self.menu = menu
        menu.isHidden = true
        menu.onHighlight = { [weak self] id in
            guard let self, let key = searchKey else { return }
            highlighted = (id, key)
            menu.activeItemId = id
        }
        menu.onSelect = { [weak self] item in self?.select(item) }
        composer.editor.onMenuKey = { [weak self] key in self?.handle(key) ?? false }
        composer.onCaretChange = { [weak self] in self?.update() }
    }

    private var searchKey: String? {
        state.trigger.map { "\($0.kind.rawValue):\($0.query.trimmingCharacters(in: .whitespaces).lowercased())" }
    }

    /// The trigger at the caret: none while a request is open, with a selection, or mid-composition.
    private func detect() -> ComposerTrigger? {
        let editor = composer.editor
        let selection = editor.selectedRange()
        guard composer.pending == .none, editor.isEditable, selection.length == 0, !editor.hasMarkedText() else { return nil }
        return ComposerTriggers.detect(editor.string, cursor: selection.location)
    }

    /// Re-reads the trigger after an edit or a caret move.
    func update() {
        let before = state.trigger
        state.set(detect())
        if state.trigger != before { onTriggerChange?(state.trigger) }
        reload()
    }

    /// Rebuilds the rows for the current trigger (new search results, skills or pull requests).
    public func reload() {
        let wasOpen = !menu.isHidden, oldHeight = menu.preferredHeight
        guard let trigger = state.trigger, let content = itemsProvider?(trigger) else {
            items = []
            menu.isHidden = true
            if wasOpen { onLayoutChange?() }
            return
        }
        items = content.items
        menu.items = items
        menu.emptyText = content.emptyText
        menu.activeItemId = ComposerMenus.activeItemId(items: items, highlighted: highlighted?.id, sameQuery: highlighted?.key == searchKey)
        menu.isHidden = false
        if !wasOpen || menu.preferredHeight != oldHeight { onLayoutChange?() }
    }

    /// Escape closes the menu until the caret leaves the token.
    public func dismiss() {
        guard state.trigger != nil else { return }
        state.dismiss()
        onTriggerChange?(nil)
        reload()
    }

    private func handle(_ key: ComposerEditor.MenuKey) -> Bool {
        guard state.trigger != nil else { return false }
        switch key {
        case .escape:
            dismiss()
            return true
        case .up, .down:
            guard !items.isEmpty else { return false }
            let index = items.firstIndex { $0.id == menu.activeItemId } ?? (key == .down ? -1 : 0)
            let next = (index + (key == .down ? 1 : -1) + items.count) % items.count
            highlighted = (items[next].id, searchKey ?? "")
            menu.activeItemId = items[next].id
            return true
        case .select, .tab:
            guard let item = items.first(where: { $0.id == menu.activeItemId }) ?? items.first else { return false }
            select(item)
            return true
        }
    }

    /// `onSelectComposerItem`: the pick replaces the trigger token. A pick ending in a space takes
    /// the space already after the token, so the caret lands after exactly one.
    public func select(_ item: ComposerMenuItem) {
        guard !pickLock, let trigger = detect() ?? state.trigger else { return }
        // One pick per frame (`composerSelectLockRef`).
        pickLock = true
        DispatchQueue.main.async { [weak self] in self?.pickLock = false }
        let text = composer.editor.string
        let replacement = ComposerMenus.replacement(for: item)
        let end = ComposerTriggers.replacementEnd(text, rangeEnd: trigger.rangeEnd, replacement: replacement)
        highlighted = nil
        onPick?(item)
        composer.editor.replace(NSRange(location: trigger.rangeStart, length: end - trigger.rangeStart), with: replacement)
    }
}
