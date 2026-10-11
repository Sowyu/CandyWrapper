import AppKit
import DesignSystem
import T3Protocol

/// A view that records key presses: the app's shortcut monitor lets keys through while it captures.
@MainActor public protocol ShortcutCaptureResponder: AnyObject {
    var isCapturing: Bool { get }
}

/// Settings > Keybindings (KeybindingsSettings.tsx `KeybindingsSettingsPanel`): the toolbar (search, Add
/// keybinding, Open keybindings.json), the new-binding row, then one section per command area. Rows come
/// from the primary environment's resolved rules merged with T3's defaults; saves and removals go to every
/// connected environment in the scope (`server.upsertKeybinding`, `server.removeKeybinding`).
public final class KeybindingsSettingsView: SettingsPageBase {
    private let sentence: SettingsScopeSentenceView
    let search = InputGroupView(placeholder: "Search keybindings", leading: .icon(.search))
    private let addButton = ButtonView("Add keybinding", icon: .plus, variant: .outline)
    private let fileButton = ButtonView(nil, icon: .fileJson, variant: .outline, size: .icon)
    private let toolbar: SettingsSectionView
    private let readOnly = SettingsNoticeView("This connection can view keybindings but cannot change them.", size: 12)
    private var newRow: SettingsGroupView?
    private var groupViews: [SettingsSectionView] = []
    private let empty: SettingsGroupView
    private var rowViews: [String: KeybindingRowView] = [:]
    public private(set) var rows: [KeybindingRow] = []
    /// The command being saved (`savingCommand`): its rows' actions wait.
    public var savingCommand: String? { didSet { rowViews.values.forEach { $0.isSaving = $0.row.command == savingCommand }; newRowView?.isSaving = savingCommand != nil } }
    private weak var newRowView: NewKeybindingRowView?
    var query = "" { didSet { if query != oldValue { rebuild() } } }

    public override init(context: SettingsPageContext) {
        sentence = SettingsScopeSentenceView(context: context)
        let bar = ToolbarRow(search: search, add: addButton, file: fileButton)
        toolbar = SettingsSectionView(title: SettingsSearch.title("keybindings"), rows: [bar])
        empty = SettingsGroupView(rows: [EmptyMessageRow("No keybindings match your search.")])
        super.init(context: context)
        anchors["keybindings"] = toolbar
        search.input.setAccessibilityLabel("Search keybindings")
        search.input.size = .sm
        search.input.onChange = { [weak self] text in self?.query = text }
        // The page's Escape goes back; in the box it clears, then leaves the field.
        search.input.onCommand = { [weak self] selector in
            guard let self, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if !self.query.isEmpty { self.search.input.text = ""; self.query = "" } else { self.window?.makeFirstResponder(self.superview) }
            return true
        }
        addButton.action = { [weak self] in self?.showNewRow() }
        fileButton.setAccessibilityLabel("Open keybindings.json")
        _ = TooltipController.attach(to: fileButton, text: "Open keybindings.json")
        fileButton.action = { [weak self] in self?.context.openKeybindingsFile?() }
        binder.add { [weak self] in self?.rebuild() }
    }

    /// Mod+F focuses the search from anywhere on the page.
    public func focusSearch() {
        window?.makeFirstResponder(search.input)
        search.input.selectAll(nil)
    }

    private var keybindings: [ResolvedKeybindingRule] { Keymap.merged(withServer: context.serverKeybindings).rules }

    /// A search jump to a command clears the page filter so its row exists (KeybindingsSettings.tsx:1335-1341).
    public override func anchor(_ id: String) -> NSView? {
        if id.hasPrefix("keybinding-"), !query.isEmpty { search.input.text = ""; query = "" }
        return super.anchor(id)
    }

    private func showNewRow() {
        guard newRow == nil else { return }
        let r = NewKeybindingRowView(commands: KeybindingsLogic.commandOptions(keybindings))
        r.allRows = { [weak self] in self?.rows ?? [] }
        r.onSave = { [weak self] target in self?.context.saveKeybinding?(target, nil) }
        r.onCancel = { [weak self] in self?.hideNewRow() }
        newRowView = r
        newRow = SettingsGroupView(rows: [r])
        rebuildItems()
        onHeightChange?()
        DispatchQueue.main.async { [weak r] in r?.focusCommand() }
    }

    /// The save went through (`setIsAddingBinding(false)` on success).
    public func hideNewRow() {
        newRow = nil
        newRowView = nil
        rebuildItems()
        onHeightChange?()
    }

    private func rebuild() {
        sentence.refresh()
        let all = keybindings
        rows = KeybindingsLogic.rows(all, query: query)
        let canWrite = context.scope.canWrite
        addButton.isEnabled = newRow == nil && canWrite
        fileButton.isEnabled = context.keybindingsConfigPath != nil
        readOnly.isHidden = canWrite
        // Rows are rebuilt per change; their drafts reset like T3's remount on new bindings.
        var views: [String: KeybindingRowView] = [:]
        var firstOfCommand = Set<String>()
        groupViews = KeybindingsLogic.group(rows).map { group in
            let rowViews = group.rows.map { row -> KeybindingRowView in
                let v = rowViews[row.id].flatMap { $0.row == row ? $0 : nil } ?? KeybindingRowView(row: row)
                v.allRows = { [weak self] in self?.rows ?? [] }
                v.onSave = { [weak self] target, replace in self?.context.saveKeybinding?(target, replace) }
                v.onRemove = { [weak self] row in self?.context.removeKeybinding?(row) }
                v.onReset = { [weak self] row in
                    guard let (target, replace) = KeybindingsLogic.resetInput(row) else { return }
                    self?.context.saveKeybinding?(target, replace)
                }
                v.isEditable = canWrite
                v.isSaving = savingCommand == row.command
                views[row.id] = v
                if firstOfCommand.insert(row.command).inserted { anchors[KeybindingsLogic.anchorId(row.command)] = v }
                return v
            }
            let s = SettingsSectionView(title: group.title, rows: rowViews)
            anchors["keybindings-\(group.id)"] = s
            return s
        }
        rowViews = views
        rebuildItems()
    }

    private func rebuildItems() {
        var list: [NSView & SettingsGroupRow] = [sentence, toolbar, readOnly]
        if let newRow { list.append(newRow) }
        if groupViews.isEmpty { list.append(empty) } else { list.append(contentsOf: groupViews) }
        items = list
        addButton.isEnabled = newRow == nil && context.scope.canWrite
    }

    /// The toolbar inside the section card (`flex flex-wrap gap-2 px-4 py-3`).
    final class ToolbarRow: DSView, SettingsGroupRow {
        let search: InputGroupView, add: ButtonView, file: ButtonView
        init(search: InputGroupView, add: ButtonView, file: ButtonView) {
            self.search = search; self.add = add; self.file = file
            super.init(frame: .zero)
            [search, add, file].forEach(addSubview)
        }
        func height(forWidth width: CGFloat) -> CGFloat { 12 + 32 + 12 }
        override func layout() {
            super.layout()
            let fw: CGFloat = 32, aw = add.intrinsicContentSize.width
            file.frame = NSRect(x: bounds.width - 16 - fw, y: 12, width: fw, height: 32)
            add.frame = NSRect(x: file.frame.minX - 8 - aw, y: 12, width: aw, height: 32)
            search.frame = NSRect(x: 16, y: 14, width: max(0, add.frame.minX - 8 - 16), height: 28)
        }
    }

    /// `px-4 py-12 text-center text-sm text-muted-foreground`.
    final class EmptyMessageRow: DSView, SettingsGroupRow {
        private let label = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
        init(_ text: String) { super.init(frame: .zero); label.text = text; label.alignment = .center; label.lineHeight = 20; addSubview(label) }
        func height(forWidth width: CGFloat) -> CGFloat { 48 + 20 + 48 }
        override func layout() { super.layout(); label.frame = NSRect(x: 16, y: 48, width: bounds.width - 32, height: 20) }
    }
}

/// `KeybindingPill`: the shortcut as Kbd keys (⌘, ⇧, ⌥, ⌃, letters uppercased) in a ghost button that
/// starts recording (`h-7 px-1.5 rounded-md`, hover `border-border/70 bg-accent`).
final class KeybindingPillButton: ControlView {
    private let decoration = BoxDecorationLayer()
    private var group = KbdGroupView(keys: [])
    var value = "" {
        didSet {
            group.removeFromSuperview()
            group = KbdGroupView(keys: KeybindingsLogic.pillParts(value))
            addSubview(group)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        transitions = .colors // KeybindingsSettings.tsx:821
        decoration.host = self
        layer?.addSublayer(decoration)
        layer?.masksToBounds = false
        addSubview(group)
        setAccessibilityRole(.button)
        restyle()
    }

    /// `-mr-1.5`: the pill hangs 6pt past the control column, so its keys end where the column does.
    override var intrinsicContentSize: NSSize { NSSize(width: group.intrinsicContentSize.width + 14 - 6, height: 28) }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 6
        box.border = state.hoverOrPressed ? Themed.color(\.border, 0.7) : .clear
        box.fill = state.hoverOrPressed ? Themed.color(\.accent) : nil
        decoration.boxStyle = box
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: NSSize(width: bounds.width + 6, height: bounds.height))
        let s = group.intrinsicContentSize
        group.frame = NSRect(x: 7, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }
}

/// The capture input (`Input size="sm" font="mono" w-44`): while focused it records the next shortcut
/// (`keybindingFromKeyboardEvent`); Escape restores the old value; typing edits the text directly is not
/// supported, as recording takes every key.
final class ShortcutRecorderView: ControlView, ShortcutCaptureResponder {
    private let decoration = BoxDecorationLayer()
    private let label = LabelView("", font: DSFont.mono(14), color: Themed.color(\.contrastForeground))
    var value = "" { didSet { sync() } }
    private(set) var isCapturing = false { didSet { sync(); restyle() } }
    var onRecord: ((String) -> Void)?
    var onModifierPair: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onEnd: (() -> Void)?
    /// The text when nothing is recorded (the action editor says "Press shortcut").
    var emptyText = "Unassigned" { didSet { sync() } }
    /// Backspace and Delete clear the value (the action editor's `captureKeybinding`).
    var deleteClears = false
    /// The width when laid out by its intrinsic size.
    var preferredWidth: CGFloat = 176

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        decoration.host = self
        layer?.addSublayer(decoration)
        label.lineHeight = 20
        addSubview(label)
        setAccessibilityRole(.textField)
        sync()
        restyle()
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: 28) }
    override func becomeFirstResponder() -> Bool { isCapturing = true; return true }
    override func resignFirstResponder() -> Bool { isCapturing = false; onEnd?(); return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    private func sync() {
        label.text = isCapturing && value.isEmpty ? "Press shortcut" : isCapturing && !deleteClears ? "Press shortcut" : (value.isEmpty ? emptyText : value)
        label.color = isCapturing || value.isEmpty ? Themed.color(\.contrastPlaceholder) : Themed.color(\.contrastForeground)
    }

    private func restyle() { decoration.boxStyle = FieldStyles.frame(state: FieldView.State(focused: isCapturing), radius: 10) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            onCancel?()
            window?.makeFirstResponder(superview)
            return
        }
        if deleteClears, event.keyCode == 51 || event.keyCode == 117 {
            value = ""
            onRecord?("")
            return
        }
        guard let stroke = KeyStroke(event), let binding = KeybindingsLogic.binding(from: stroke) else { return }
        value = binding
        onRecord?(binding)
        window?.makeFirstResponder(superview)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing, let onModifierPair else { return }
        for modifier in ["shift", "meta", "control", "alt"] {
            var state = SnapShotShortcutState()
            if state.update(flags: UInt64(event.modifierFlags.rawValue), shortcut: .object(["kind": .string("modifier-pair"), "modifier": .string(modifier)])) {
                onModifierPair(modifier)
                window?.makeFirstResponder(superview)
                return
            }
        }
    }

    override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        label.frame = NSRect(x: 10, y: (bounds.height - 20) / 2, width: bounds.width - 20, height: 20)
    }
}

/// The "When" line under a binding's title: a muted label and the clause trigger (`Button size="micro"`,
/// ghost when set, ghost-muted for "Always", mono text and a chevron) that opens the expression editor.
final class WhenLineView: DSView {
    private let label = LabelView("When", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.7))
    let trigger = ButtonView("Always", variant: .ghostMuted, size: .micro)
    var expression = "" { didSet { trigger.title = expression.isEmpty ? "Always" : expression; trigger.variant = expression.isEmpty ? .ghostMuted : .ghost; needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        label.lineHeight = 12
        trigger.trailingIcon = .chevronDown
        trigger.monospaced = true
        addSubview(label)
        addSubview(trigger)
    }

    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: 0, y: 6, width: lw, height: 12)
        let tw = min(trigger.intrinsicContentSize.width, max(0, bounds.width - lw - 6))
        trigger.frame = NSRect(x: lw + 6, y: 2, width: tw, height: 20)
    }
}

/// `WhenExpressionBuilder`: "When" with + Condition and + Group, the expression input with its parse error.
// ponytail: the visual node editor below the input is left out; the expression text covers every clause. Add it if editing by hand proves hard
final class WhenEditorView: DSView {
    private let title = LabelView("When", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let addCondition = ButtonView("Condition", icon: .plus, variant: .outline, size: .compact)
    private let addGroup = ButtonView("Group", icon: .plus, variant: .outline, size: .compact)
    let input = InputView(placeholder: "Always", text: "", size: .compact, font: .mono)
    private let error = LabelView("", font: DSFont.ui(11), color: Themed.color(\.destructive))
    private let unknown = LabelView("", font: DSFont.ui(11), color: Themed.color(\.warning))
    var onChange: ((KeybindingWhenNode?, Bool) -> Void)?
    private var value: KeybindingWhenNode?

    init(value: KeybindingWhenNode?) {
        self.value = value
        super.init(frame: NSRect(x: 0, y: 0, width: 544, height: 10))
        title.lineHeight = 20
        error.lineHeight = 16
        unknown.lineHeight = 16
        [title, addCondition, addGroup, input, error, unknown].forEach(addSubview)
        input.text = KeybindingsLogic.expression(value)
        input.setAccessibilityLabel("When expression")
        input.onChange = { [weak self] text in self?.edited(text) }
        addCondition.action = { [weak self] in self?.append(.identifier(KeybindingsLogic.defaultWhenVariable)) }
        addGroup.action = { [weak self] in
            self?.append(.or(.identifier(KeybindingsLogic.defaultWhenVariable), .identifier(KeybindingsLogic.defaultWhenVariable)))
        }
        sync(parseError: nil)
    }

    private func append(_ node: KeybindingWhenNode) {
        let next: KeybindingWhenNode = value.map { .and($0, node) } ?? node
        value = next
        input.text = KeybindingsLogic.expression(next)
        sync(parseError: nil)
        onChange?(next, true)
    }

    private func edited(_ text: String) {
        switch KeybindingsLogic.parseWhen(text) {
        case .ok(let node):
            value = node
            sync(parseError: nil)
            onChange?(node, true)
        case .invalid(let message):
            sync(parseError: message)
            onChange?(value, false)
        }
    }

    private func sync(parseError: String?) {
        error.text = parseError ?? ""
        error.isHidden = parseError == nil
        input.isInvalid = parseError != nil
        let names = parseError == nil ? KeybindingsLogic.unknownVariables(value) : []
        unknown.text = names.isEmpty ? "" : names.count == 1 ? "Unknown condition: \(names[0])" : "Unknown conditions: \(names.joined(separator: ", "))"
        unknown.isHidden = names.isEmpty
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 544, height: 28 + 12 + 30 + (error.isHidden ? 0 : 22) + (unknown.isHidden ? 0 : 22))
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 4, width: 60, height: 20)
        let gw = addGroup.intrinsicContentSize.width, cw = addCondition.intrinsicContentSize.width
        addGroup.frame = NSRect(x: bounds.width - gw, y: 0, width: gw, height: 28)
        addCondition.frame = NSRect(x: addGroup.frame.minX - 8 - cw, y: 0, width: cw, height: 28)
        input.frame = NSRect(x: 0, y: 40, width: bounds.width, height: 30)
        var y: CGFloat = 76
        if !error.isHidden { error.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16); y += 22 }
        if !unknown.isHidden { unknown.frame = NSRect(x: 0, y: y, width: bounds.width, height: 16) }
    }
}

/// One binding (`KeybindingSettingsRow`): the command label with its source badge, the When line, and on
/// the right the conflict warning, the hover menu (Reset to default, Remove) and the pill or recorder with Save.
final class KeybindingRowView: DSView, SettingsGroupRow, FocusWithinObserver {
    let row: KeybindingRow
    private let settingsRow: SettingsRowView
    private let pill = KeybindingPillButton()
    private let recorder = ShortcutRecorderView()
    private let save = ButtonView("Save", size: .sm)
    private let actionsButton = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconSm).menuTrigger()
    private let warning = ButtonView(nil, icon: .triangleAlert, variant: .ghostMuted, size: .iconMicro).transitioning(.colors) // KeybindingsSettings.tsx:233
    private let when = WhenLineView()
    private let badge: BadgeView?
    private let controls: SettingsControlGroup
    private var warningTip: TooltipController?
    private var hovering = false { didSet { updateMenu() } }
    private var focusWithin = false { didSet { updateMenu() } }
    func focusWithinChanged(_ focused: Bool) { focusWithin = focused }

    var allRows: () -> [KeybindingRow] = { [] }
    var onSave: ((KeybindingTarget, KeybindingTarget?) -> Void)?
    var onRemove: ((KeybindingRow) -> Void)?
    var onReset: ((KeybindingRow) -> Void)?
    var isEditable = true { didSet { update() } }
    var isSaving = false { didSet { update() } }

    // The draft (`KeybindingRowDraftState`).
    private var keyDraft: String
    private var whenDraft: KeybindingWhenNode?
    private var whenValid = true
    private var recording = false

    init(row: KeybindingRow) {
        self.row = row
        keyDraft = row.key
        whenDraft = row.binding.whenAst
        badge = row.source == .default ? nil : BadgeView(row.source.rawValue, variant: .outline, size: .sm)
        controls = SettingsControlGroup([warning, actionsButton, save, pill, recorder], gap: 6)
        settingsRow = SettingsRowView(title: KeybindingsLogic.commandLabel(row.command), control: controls)
        super.init(frame: .zero)
        settingsRow.detailView = when
        settingsRow.accessories = badge.map { [$0] } ?? []
        settingsRow.toolTip = row.command
        addSubview(settingsRow)
        warning.iconColor = Themed.color(\.warning)
        warning.iconSize = 14
        warningTip = TooltipController.attach(to: warning, text: "")
        actionsButton.iconSize = 14
        actionsButton.setAccessibilityLabel("Actions for \(KeybindingsLogic.commandLabel(row.command))")
        actionsButton.action = { [weak self] in self?.openMenu() }
        pill.value = row.key
        pill.setAccessibilityLabel("Edit shortcut for \(KeybindingsLogic.commandLabel(row.command)): \(row.binding.shortcut.label)")
        pill.action = { [weak self] in self?.startRecording() }
        recorder.setAccessibilityLabel("Keybinding for \(KeybindingsLogic.commandLabel(row.command))")
        recorder.onRecord = { [weak self] key in self?.keyDraft = key; self?.recording = false; self?.update() }
        recorder.onCancel = { [weak self] in guard let self else { return }; self.keyDraft = self.row.key; self.recording = false; self.update() }
        recorder.onEnd = { [weak self] in self?.recording = false; self?.update() }
        save.action = { [weak self] in self?.commit() }
        when.expression = row.when
        when.trigger.setAccessibilityLabel("Edit when clause for \(KeybindingsLogic.commandLabel(row.command))")
        when.trigger.action = { [weak self] in self?.openWhen() }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        update()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var whenExpression: String { KeybindingsLogic.expression(whenDraft) }
    private var isDirty: Bool { keyDraft != row.key || whenExpression != row.when }

    private func startRecording() {
        guard isEditable else { return }
        recording = true
        update()
        window?.makeFirstResponder(recorder)
    }

    private func commit() {
        let (target, replace) = KeybindingsLogic.saveInput(row: row, key: keyDraft, when: whenExpression)
        onSave?(target, replace)
    }

    private func update() {
        let conflicts = KeybindingsLogic.conflictLabels(allRows(), rowId: row.id, key: keyDraft, when: whenExpression)
        let description = KeybindingsLogic.conflictDescription(conflicts)
        warning.isHidden = description == nil
        warningTip?.text = (description ?? "") + " The most recent matching binding wins when both conditions can apply."
        warning.setAccessibilityLabel(description ?? "")
        let showPill = !recording && keyDraft == row.key && !row.key.isEmpty && !isDirty
        pill.isHidden = !showPill
        recorder.isHidden = showPill
        recorder.value = keyDraft
        save.isHidden = !isDirty
        save.title = isSaving ? "Saving" : "Save"
        save.isEnabled = !isSaving && !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty && whenValid
        when.expression = whenExpression
        pill.isEnabled = isEditable
        when.trigger.isEnabled = isEditable
        updateMenu()
        controls.invalidateIntrinsicContentSize()
        settingsRow.needsLayout = true
    }

    /// `KeybindingHoverRowMenu`: fades in over 150 ms while the row is hovered, holds keyboard focus or has
    /// the menu open (KeybindingsSettings.tsx:989); only for rows it can act on.
    private func updateMenu() {
        let canAct = (row.source == .custom && row.defaultKey != nil) || row.source != .default
        actionsButton.isHidden = !canAct || !isEditable
        HoverReveal.fade([actionsButton], visible: hovering || focusWithin || actionsButton.state.popupOpen)
        actionsButton.isEnabled = !isSaving
    }

    private func openMenu() {
        var items: [MenuItem] = []
        if row.source == .custom && row.defaultKey != nil {
            var reset = MenuItem("Reset to default")
            reset.action = { [weak self] in guard let self else { return }; self.onReset?(self.row) }
            items.append(reset)
        }
        if row.source != .default {
            var remove = MenuItem("Remove", destructive: true)
            remove.action = { [weak self] in guard let self else { return }; self.onRemove?(self.row) }
            items.append(remove)
        }
        MenuPopupView.show(items, from: actionsButton, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4, fallbackAxisSide: .none))
    }

    private func openWhen() {
        let editor = WhenEditorView(value: whenDraft)
        editor.onChange = { [weak self] node, valid in
            guard let self else { return }
            self.whenValid = valid
            if valid { self.whenDraft = node }
            self.update()
        }
        let pop = PopoverView(content: editor, padding: .default, width: .auto)
        _ = pop.show(from: when.trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 6))
        window?.makeFirstResponder(editor.input)
    }

    func height(forWidth width: CGFloat) -> CGFloat { settingsRow.height(forWidth: width) }
    override func layout() { super.layout(); settingsRow.frame = bounds }
}

/// `NewKeybindingSettingsRow`: "New keybinding" with its When line, then the command select, the conflict
/// warning, the recorder, Save and a cancel button, on `bg-muted/15`.
final class NewKeybindingRowView: DSView, SettingsGroupRow {
    private let settingsRow: SettingsRowView
    private let command: SelectView
    private let commands: [String]
    private let recorder = ShortcutRecorderView()
    private let save = ButtonView("Save", size: .sm)
    private let cancel = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconSm)
    private let warning = ButtonView(nil, icon: .triangleAlert, variant: .ghostMuted, size: .iconMicro).transitioning(.colors) // KeybindingsSettings.tsx:233
    private let when = WhenLineView()
    private var warningTip: TooltipController?
    var allRows: () -> [KeybindingRow] = { [] }
    var onSave: ((KeybindingTarget) -> Void)?
    var onCancel: (() -> Void)?
    var isSaving = false { didSet { update() } }
    private var keyDraft = ""
    private var whenDraft: KeybindingWhenNode?
    private var whenValid = true

    init(commands: [String]) {
        self.commands = commands
        command = SelectView(options: commands.map(KeybindingsLogic.commandLabel), placeholder: "Command", size: .sm)
        command.alignItemWithTrigger = false
        command.frame.size = NSSize(width: 224, height: 28)
        let group = SettingsControlGroup([command, warning, recorder, save, cancel])
        settingsRow = SettingsRowView(title: "New keybinding", control: group)
        super.init(frame: .zero)
        settingsRow.detailView = when
        settingsRow.fill = Themed.color(\.muted, 0.15)
        addSubview(settingsRow)
        warning.iconColor = Themed.color(\.warning)
        warning.iconSize = 14
        warningTip = TooltipController.attach(to: warning, text: "")
        cancel.iconSize = 14
        cancel.setAccessibilityLabel("Cancel new keybinding")
        _ = TooltipController.attach(to: cancel, text: "Cancel")
        cancel.action = { [weak self] in self?.onCancel?() }
        command.onChange = { [weak self] _ in self?.update() }
        recorder.onRecord = { [weak self] key in self?.keyDraft = key; self?.update() }
        recorder.onCancel = { [weak self] in self?.keyDraft = ""; self?.update() }
        save.action = { [weak self] in self?.commit() }
        when.trigger.action = { [weak self] in self?.openWhen() }
        update()
    }

    func focusCommand() { window?.makeFirstResponder(recorder) }

    private var selectedCommand: String? { command.selectedIndex.map { commands[$0] } }
    private var whenExpression: String { KeybindingsLogic.expression(whenDraft) }

    private func commit() {
        guard let c = selectedCommand else { return }
        onSave?(KeybindingTarget(command: c, key: keyDraft.trimmingCharacters(in: .whitespaces), when: whenExpression.isEmpty ? nil : whenExpression))
    }

    private func update() {
        let conflicts = KeybindingsLogic.conflictLabels(allRows(), rowId: "new", key: keyDraft, when: whenExpression)
        let description = KeybindingsLogic.conflictDescription(conflicts)
        warning.isHidden = description == nil
        warningTip?.text = (description ?? "") + " The most recent matching binding wins when both conditions can apply."
        recorder.value = keyDraft
        let label = selectedCommand.map(KeybindingsLogic.commandLabel) ?? "new keybinding"
        recorder.setAccessibilityLabel("Keybinding for \(label)")
        when.trigger.setAccessibilityLabel("Edit when clause for \(label)")
        when.expression = whenExpression
        save.title = isSaving ? "Saving" : "Save"
        save.isEnabled = !isSaving && selectedCommand != nil && !keyDraft.isEmpty && whenValid
        cancel.isEnabled = !isSaving
        (settingsRow.control as? SettingsControlGroup)?.invalidateIntrinsicContentSize()
        settingsRow.needsLayout = true
    }

    private func openWhen() {
        let editor = WhenEditorView(value: whenDraft)
        editor.onChange = { [weak self] node, valid in
            guard let self else { return }
            self.whenValid = valid
            if valid { self.whenDraft = node }
            self.update()
        }
        _ = PopoverView(content: editor).show(from: when.trigger, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 6))
        window?.makeFirstResponder(editor.input)
    }

    func height(forWidth width: CGFloat) -> CGFloat { settingsRow.height(forWidth: width) }
    override func layout() { super.layout(); settingsRow.frame = bounds }
}
