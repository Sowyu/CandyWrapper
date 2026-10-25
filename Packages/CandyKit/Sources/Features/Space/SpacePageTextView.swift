import AppKit
import DesignSystem
import SpaceModel

/// The page's text view. The editor owns every rule; this routes keys, clicks, paste, copy and undo to it.
public final class SpacePageTextView: NSTextView {
    weak var editor: SpacePageEditor?
    private lazy var hover = SpaceHoverControls(textView: self)
    private var tracking: NSTrackingArea?

    /// AppKit's own typing undo stays off: the editor's stack writes inverse changes instead, through `undo(_:)`.
    public override var undoManager: UndoManager? { nil }

    @objc func undo(_ sender: Any?) { editor?.performUndo() }
    @objc func redo(_ sender: Any?) { editor?.performRedo() }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return editor?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return editor?.undo.canRedo ?? false }
        // Images paste as image blocks, which plain NSTextView validation doesn't know about.
        if item.action == #selector(paste(_:)), SpacePageEditor.hasImage(NSPasteboard.general) { return isEditable }
        return super.validateUserInterfaceItem(item)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let editor else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (mods, key) {
        case ([.command], "v"): paste(nil); return true
        case ([.command], "z"): editor.performUndo(); return true
        case ([.command, .shift], "z"): editor.performRedo(); return true
        case ([.command], "b"): editor.toggleMark(.spaceBold); return true
        case ([.command], "i"): editor.toggleMark(.spaceItalic); return true
        case ([.command], "u"): editor.toggleMark(.underlineStyle); return true
        case ([.command], "e"): editor.toggleMark(.spaceCode); return true
        case ([.command, .shift], "x"): editor.toggleMark(.strikethroughStyle); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    public override func keyDown(with event: NSEvent) {
        hover.hide()
        super.keyDown(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if editor?.handleClick(at: p) == true { return }
        super.mouseDown(with: event)
    }

    public override func paste(_ sender: Any?) {
        if editor?.paste(from: .general) != true { super.paste(sender) }
    }

    public override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let ok = super.writeSelection(to: pboard, types: types)
        if let markdown = editor?.markdown(for: selectedRange()) { pboard.setString(markdown, forType: .string) }
        return ok
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? 0
        guard p.x > origin.x - 64, p.x < origin.x + width + 16, let target = editor.hoverTarget(at: p) else { hover.hide(); return }
        hover.show(for: target.key, line: target.line, x: origin.x)
        if let fragment = editor.fragment(at: p) {
            let local = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            let t = fragment.targets()
            let clickable = [t.checkbox, t.due, t.addRow, t.keep, t.discard].contains { $0?.contains(local) == true }
                || (target.key.isItem && !editor.isTodoRow(target.key))
            if clickable { NSCursor.pointingHand.set() }
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let p = convert(event.locationInWindow, from: nil)
        if !hover.frame.insetBy(dx: -4, dy: -4).contains(p) { hover.hide() }
    }
}

/// The 16pt + and drag handle to a block's left (docs/space.md "Page view"), shown while the pointer is over it.
final class SpaceHoverControls: DSView {
    private weak var textView: SpacePageTextView?
    private let plus = SpaceHoverButton(icon: .plus, label: "Add a block below")
    private let grip = SpaceHoverButton(icon: .gripVertical, label: "Drag to move")
    private(set) var key: SpaceParagraphKey?

    init(textView: SpacePageTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        isHidden = true
        addSubview(plus)
        addSubview(grip)
        plus.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        grip.frame = NSRect(x: 20, y: 0, width: 20, height: 20)
        plus.onPress = { [weak self] _ in
            guard let self, let key = self.key else { return }
            self.hide()
            self.textView?.editor?.plus(after: key)
        }
        grip.onPress = { [weak self] event in self?.drag(event) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(for key: SpaceParagraphKey, line: CGRect, x: CGFloat) {
        if superview == nil { textView?.addSubview(self) }
        self.key = key
        frame = NSRect(x: x - 46, y: (line.midY - 10).rounded(), width: 40, height: 20)
        isHidden = false
    }

    func hide() { isHidden = true }

    /// Drags the block with an accent drop line, then moves its record before the paragraph under the line.
    private func drag(_ event: NSEvent) {
        guard let textView, let editor = textView.editor, let key, let window = textView.window else { return }
        let line = DSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = SpacePageMetrics.accent.cgColor(in: textView)
        line.layer?.cornerRadius = 1
        textView.addSubview(line)
        var target: SpaceParagraphKey?? = nil
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = textView.convert(e.locationInWindow, from: nil)
            if let drop = editor.dropTarget(at: p) {
                let origin = textView.textContainerOrigin
                line.frame = NSRect(x: origin.x, y: drop.y + origin.y - 1, width: textView.textContainer?.size.width ?? 0, height: 2)
                target = .some(drop.before)
            }
            textView.autoscroll(with: e)
            if e.type == .leftMouseUp { break }
        }
        line.removeFromSuperview()
        hide()
        if case .some(let before) = target, before != key { editor.move(key, before: before) }
    }
}

final class SpaceHoverButton: DSView {
    var onPress: (NSEvent) -> Void = { _ in }
    private let icon: IconView
    private var hovering = false { didSet { needsDisplay = true; icon.strokeColor = hovering ? Themed.color(\.foreground) : Themed.color(\.iconMuted) } }

    init(icon name: IconName, label: String) {
        icon = IconView(name: name, size: 16, strokeColor: Themed.color(\.iconMuted))
        super.init(frame: .zero)
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.backgroundColor = hovering ? Themed.color(\.foreground, 0.08).cgColor(in: self) : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress(event) }
    override func accessibilityPerformPress() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        onPress(event)
        return true
    }
}

// MARK: - Menus

/// What the / menu offers (docs/space.md "Page view").
struct SpaceBlockCommand {
    enum Action: Equatable { case type(BlockType), todo, divider, image, file, page(ViewType) }
    var title: String
    var icon: IconName
    var aliases: [String]
    var action: Action

    static let all: [SpaceBlockCommand] = [
        .init(title: "Text", icon: .text, aliases: ["p", "paragraph", "plain"], action: .type(.p)),
        .init(title: "Heading 1", icon: .type, aliases: ["h1", "title"], action: .type(.h1)),
        .init(title: "Heading 2", icon: .type, aliases: ["h2"], action: .type(.h2)),
        .init(title: "Heading 3", icon: .type, aliases: ["h3"], action: .type(.h3)),
        .init(title: "Bulleted list", icon: .rows3, aliases: ["ul", "bullet", "list"], action: .type(.bullet)),
        .init(title: "Numbered list", icon: .listOrdered, aliases: ["ol", "number", "list"], action: .type(.number)),
        .init(title: "To-do", icon: .listChecks, aliases: ["todo", "checkbox", "task", "check"], action: .todo),
        .init(title: "Quote", icon: .quote, aliases: ["blockquote"], action: .type(.quote)),
        .init(title: "Code", icon: .code, aliases: ["snippet", "pre"], action: .type(.code)),
        .init(title: "Divider", icon: .minus, aliases: ["hr", "line", "rule", "separator"], action: .divider),
        .init(title: "Image", icon: .image, aliases: ["picture", "photo", "img"], action: .image),
        .init(title: "File", icon: .paperclip, aliases: ["attachment", "upload"], action: .file),
        .init(title: "Page", icon: .fileText, aliases: ["subpage", "child"], action: .page(.page)),
        .init(title: "Board", icon: .columns2, aliases: ["kanban"], action: .page(.board)),
        .init(title: "Table", icon: .table2, aliases: ["database", "grid"], action: .page(.table)),
        .init(title: "Timetable", icon: .calendar, aliases: ["calendar", "schedule", "week"], action: .page(.timetable)),
    ]

    /// Commands whose title words or aliases start with the query.
    static func matching(_ query: String) -> [SpaceBlockCommand] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { c in
            c.title.lowercased().hasPrefix(q) || c.title.lowercased().split(separator: " ").contains { $0.hasPrefix(q) }
                || c.aliases.contains { $0.hasPrefix(q) }
        }
    }
}

/// The / block menu, the @ page picker and the due date menu, all in the window's PopupHost. While / or @ is open,
/// typing keeps going to the text view and filters the list; arrows, Return and Escape go to the menu.
@MainActor
final class SpaceEditorMenus {
    enum Kind { case slash, mention }
    private(set) var kind: Kind?
    private var start = 0
    private var popup: OpenPopup?
    private weak var host: PopupHost?
    private var menu: MenuPopupView?

    var isOpen: Bool { kind != nil }

    @discardableResult
    func closeAll() -> Bool {
        guard let popup, let host else { kind = nil; return false }
        host.close(popup, returnFocus: false)
        reset()
        return true
    }

    private func reset() {
        kind = nil
        popup = nil
        menu = nil
    }

    func textChanged(_ editor: SpacePageEditor) {
        let tv = editor.textView
        guard let ms = tv.textStorage?.mutableString else { return }
        let caret = tv.selectedRange().location
        if let kind {
            guard caret > start, start < ms.length, ms.character(at: start) == (kind == .slash ? 0x2F : 0x40) else { closeAll(); return }
            let query = ms.substring(with: NSRange(location: start + 1, length: caret - start - 1))
            if query.contains("\n") || query.hasSuffix("  ") || query.count > 32 { closeAll(); return }
            refresh(editor, query)
            if menu?.items.isEmpty == true, query.hasSuffix(" ") { closeAll() }
            return
        }
        guard caret > 0, let p = editor.paragraph(at: caret - 1) else { return }
        let c = ms.character(at: caret - 1)
        guard c == 0x2F || c == 0x40 else { return }
        if editor.paragraphs[p.key]?.type == .code { return }
        let before: unichar? = caret - 1 > p.range.location ? ms.character(at: caret - 2) : nil
        guard before == nil || before == 0x20 || before == 0x09 else { return }
        if c == 0x2F && p.key.isItem { return }
        open(c == 0x2F ? .slash : .mention, editor, at: caret - 1)
    }

    func selectionChanged(_ editor: SpacePageEditor) {
        guard kind != nil else { return }
        let sel = editor.textView.selectedRange()
        let end = editor.paragraph(at: start).map { NSMaxRange($0.range) } ?? start
        if sel.length > 0 || sel.location <= start || sel.location > end { closeAll() }
    }

    private func open(_ kind: Kind, _ editor: SpacePageEditor, at location: Int) {
        let tv = editor.textView
        guard let window = tv.window else { return }
        closeAll()
        let menu = MenuPopupView(items: [], style: .combobox)
        menu.minimumWidth = kind == .slash ? 240 : 260
        menu.emptyText = kind == .slash ? "No blocks match" : "No pages match"
        self.kind = kind
        self.start = location
        self.menu = menu
        refresh(editor, "")
        let host = PopupHost.host(for: window)
        let popup = host.open(menu, trigger: tv, anchorRect: caretRect(tv, location), placement: .dropdown, returnsFocus: false)
        menu.hostPopup = popup
        popup.onClose = { [weak self, weak popup] in
            if let self, self.popup === popup { self.reset() }
        }
        self.popup = popup
        self.host = host
    }

    private func caretRect(_ tv: NSTextView, _ location: Int) -> CGRect {
        var actual = NSRange()
        let screen = tv.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: &actual)
        guard let window = tv.window, screen != .zero else { return CGRect(x: 0, y: 0, width: 1, height: 20) }
        let inWindow = window.convertFromScreen(screen)
        return tv.convert(inWindow, from: nil)
    }

    private func refresh(_ editor: SpacePageEditor, _ query: String) {
        guard let menu, let kind else { return }
        let start = self.start
        var items: [MenuItem] = []
        switch kind {
        case .slash:
            for command in SpaceBlockCommand.matching(query) {
                items.append(MenuItem(command.title, icon: command.icon) { [weak editor] in
                    editor?.runBlockCommand(command.action, replacing: start)
                })
            }
        case .mention:
            let words = SpaceSearch.words(query)
            let pages = editor.store.pages.filter { $0.key != editor.page && editor.store.isLive($0.key) && SpaceSearch.matches($0.value.title, words) }
                .sorted { ($0.value.title.lowercased(), $0.key.rawValue) < ($1.value.title.lowercased(), $1.key.rawValue) }
                .prefix(8)
            for (id, record) in pages {
                items.append(MenuItem(record.title.isEmpty ? "Untitled" : record.title, icon: SpacePageIcons.viewIcon(record.view)) { [weak editor] in
                    editor?.insertMention(id, title: record.title, replacing: start)
                })
            }
        }
        menu.setItems(items)
        menu.highlightedIndex = items.isEmpty ? nil : 0
        if let popup, let host { host.reposition(popup) }
    }

    /// Today, Tomorrow, Next week, a calendar, or no date.
    func openDue(_ editor: SpacePageEditor, key: SpaceParagraphKey, anchor: CGRect) {
        let tv = editor.textView
        guard let window = tv.window else { return }
        closeAll()
        let zone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func day(_ offset: Int, from base: Date = Date()) -> DateValue? {
            guard let date = calendar.date(byAdding: .day, value: offset, to: base), let point = try? DatePoint.from(date, in: zone, timed: false) else { return nil }
            return try? DateValue(start: point)
        }
        let weekday = calendar.component(.weekday, from: Date())
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        var items: [MenuItem] = [
            MenuItem("Today", icon: .calendar) { [weak editor] in editor?.setDue(key, day(0)) },
            MenuItem("Tomorrow", icon: .calendarArrowUp) { [weak editor] in editor?.setDue(key, day(1)) },
            MenuItem("Next week", icon: .calendarClock) { [weak editor] in editor?.setDue(key, day(toMonday)) },
            MenuItem("Pick a date…", icon: .calendarArrowDown) { [weak self, weak editor] in
                // Open after the menu's own click finishes, so the calendar gets the next click.
                DispatchQueue.main.async {
                    guard let self, let editor else { return }
                    self.openCalendar(editor, key: key, anchor: anchor)
                }
            },
        ]
        if let due = editor.paragraphs[key]?.due {
            items.append(.separator)
            items += SpaceReminderDialog.menuItems(due, open: { [weak editor] in
                guard let editor, let window = editor.textView.window, let due = editor.paragraphs[key]?.due else { return }
                SpaceReminderDialog.present(in: window, due: due, current: { [weak editor] in editor?.paragraphs[key]?.due }) { [weak editor] in
                    editor?.setDue(key, $0)
                }
            }, set: { [weak editor] in editor?.setDue(key, $0) })
            items.append(MenuItem("Remove date", icon: .x) { [weak editor] in editor?.setDue(key, nil) })
        }
        let menu = MenuPopupView(items: items, style: .menu)
        menu.minimumWidth = 180
        menu.hostPopup = PopupHost.host(for: window).open(menu, trigger: tv, anchorRect: anchor,
                                                          placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                                                          swallowsOutsideClick: true, returnsFocus: false)
    }

    /// The Redesign calendar in a popover under the due label.
    private func openCalendar(_ editor: SpacePageEditor, key: SpaceParagraphKey, anchor: CGRect) {
        let tv = editor.textView
        guard let window = tv.window else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let due = editor.paragraphs[key]?.due.map { DateComponents(year: $0.start.year, month: $0.start.month, day: $0.start.day) }
        let view = CalendarView(month: due ?? today, selected: due, today: today)
        view.setAccessibilityLabel("Due date")
        let popover = PopoverView(content: view, padding: .compact)
        let host = PopupHost.host(for: window)
        let open = host.open(popover, trigger: tv, anchorRect: anchor,
                             placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none),
                             motion: .popover, swallowsOutsideClick: true, returnsFocus: false)
        view.onSelect = { [weak editor, weak host] parts in
            host?.close(open, returnFocus: false)
            guard let date = calendar.date(from: parts), let point = try? DatePoint.from(date, in: .current, timed: false) else { return }
            editor?.setDue(key, try? DateValue(start: point))
        }
    }
}

extension SpacePageEditor {
    public func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): return handleReturn()
        case #selector(NSResponder.insertTab(_:)): return handleTab(backwards: false)
        case #selector(NSResponder.insertBacktab(_:)): return handleTab(backwards: true)
        case #selector(NSResponder.deleteBackward(_:)): return handleBackspace()
        case #selector(NSResponder.insertLineBreak(_:)):
            return paragraph(at: tv.selectedRange().location)?.key.isItem ?? false
        case #selector(NSResponder.cancelOperation(_:)): return menus.closeAll()
        default: return false
        }
    }

    public func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.scheme == "space-page", let id = try? PageID(String(url.absoluteString.dropFirst("space-page:".count))) {
            flushTyping()
            onOpenPage(id)
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Runs a / menu command on the paragraph the menu opened in, after taking out "/query".
    func runBlockCommand(_ action: SpaceBlockCommand.Action, replacing start: Int) {
        let caret = textView.selectedRange().location
        if caret > start { textView.insertText("", replacementRange: NSRange(location: start, length: caret - start)) }
        guard let (key, r) = paragraph(at: start) else { return }
        let empty = r.length == 0
        switch action {
        case .type(let type):
            if case .block = key { setType(key, type) }
        case .todo:
            if case .block = key { convertToItem(key, view: .page, todo: true) }
        case .divider:
            if empty, case .block = key {
                setType(key, .divider)
                insertParagraph(after: key, SpaceParagraph())
            } else {
                insertParagraph(after: key, SpaceParagraph(type: .divider))
                if let divider = paragraph(at: textView.selectedRange().location)?.key { insertParagraph(after: divider, SpaceParagraph()) }
            }
        case .image: chooseFile(images: true)
        case .file: chooseFile(images: false)
        case .page(let view):
            if empty, case .block = key {
                convertToItem(key, view: view, todo: false)
            } else {
                var para = SpaceParagraph()
                para.view = view
                insertParagraph(after: key, para, item: true)
            }
        }
    }

    /// Replaces "@query" with a page mention and a space.
    func insertMention(_ id: PageID, title: String, replacing start: Int) {
        let caret = textView.selectedRange().location
        guard caret > start, let url = URL(string: "space-page:" + id.rawValue) else { return }
        var attrs = textView.typingAttributes
        attrs.removeValue(forKey: .link)
        let s = NSMutableAttributedString(string: title.isEmpty ? "Untitled" : title, attributes: attrs)
        s.addAttribute(.link, value: url, range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: " ", attributes: attrs))
        textView.insertText(s, replacementRange: NSRange(location: start, length: caret - start))
    }

    /// Where a dragged block lands: before the paragraph under the pointer's upper half, else after it.
    func dropTarget(at point: CGPoint) -> (before: SpaceParagraphKey?, y: CGFloat)? {
        let origin = textView.textContainerOrigin
        guard let fragment = fragment(at: point), let key = fragment.paragraphKey, let i = keys.firstIndex(of: key) else {
            return keys.isEmpty ? nil : (nil, (textView.textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0))
        }
        let f = fragment.layoutFragmentFrame
        if point.y - origin.y < f.midY { return (key, f.minY) }
        return (i + 1 < keys.count ? keys[i + 1] : nil, f.maxY)
    }
}
