import AppKit
import DesignSystem
import T3Protocol

/// The Add/Edit Action dialog (projectScriptEditor.tsx `ProjectScriptEditorDialog`): name with the icon
/// picker, shortcut, command, preview URL, the four run switches, the validation error, and Delete,
/// Cancel and Save in the footer.
@MainActor
public final class ProjectActionEditor {
    public let dialog: DialogView
    let form: ProjectActionForm
    private let delete = ButtonView("Delete", variant: .destructiveOutline)
    private let cancel = ButtonView("Cancel", variant: .outline)
    private let save: ButtonView
    private let isEditing: Bool
    public var onSubmit: ((ProjectScriptInput) -> Void)?
    public var onCancel: (() -> Void)?
    public var onDelete: (() -> Void)?

    public var isSaving = false {
        didSet {
            save.title = isSaving ? "Saving…" : isEditing ? "Save changes" : "Save action"
            save.isEnabled = !isSaving
            delete.isEnabled = !isSaving
            form.isEnabled = !isSaving
        }
    }

    public var error: String? { get { form.error } set { form.error = newValue } }

    public init(script: ProjectScript?, keybinding: String?) {
        isEditing = script != nil
        dialog = DialogView(title: script == nil ? "Add Action" : "Edit Action",
                            message: "Actions are project-scoped commands you can run from the top bar or keybindings.")
        let initial = ProjectScriptInput(name: script?.name ?? "", command: script?.command ?? "", icon: script?.icon ?? "play",
                                         runOnWorktreeCreate: script?.runOnWorktreeCreate ?? false,
                                         waitForSetup: (script?.runOnWorktreeCreate ?? false) && script?.async == false,
                                         runOnSettle: script?.runOnSettle ?? false, keybinding: keybinding, previewUrl: script?.previewUrl,
                                         autoOpenPreview: script?.autoOpenPreview ?? false)
        form = ProjectActionForm(initial)
        save = ButtonView(script == nil ? "Save action" : "Save changes")
        initialKeybinding = keybinding
        isNew = script == nil
        dialog.panelContent = [form]
        dialog.footerVariant = .bare
        dialog.footerButtons = isEditing ? [delete, cancel, save] : [cancel, save]
        dialog.footerLeadingCount = isEditing ? 1 : 0
        form.onHeightChange = { [weak dialog] in dialog?.invalidateIntrinsicContentSize(); dialog?.needsLayout = true; dialog?.superview?.needsLayout = true }
        cancel.action = { [weak self] in self?.onCancel?() }
        delete.action = { [weak self] in self?.onDelete?() }
        save.action = { [weak self] in self?.submit() }
        form.onReturn = { [weak self] in self?.submit() }
    }

    private let initialKeybinding: String?
    private let isNew: Bool

    /// `submit`: required name and command, then the shortcut only when it changed or the action is new.
    private func submit() {
        guard !isSaving else { return }
        switch ProjectScripts.validate(form.input) {
        case .failure(let e): form.error = e.message
        case .success(var input):
            let typed = (form.input.keybinding ?? "").trimmingCharacters(in: .whitespaces)
            let changed = (typed.isEmpty ? nil : typed) != (initialKeybinding?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            input.keybinding = isNew || changed ? typed : nil
            form.error = nil
            onSubmit?(input)
        }
    }
}

/// The dialog's panel (`fieldset space-y-4`).
final class ProjectActionForm: DSView {
    private let nameLabel = ProjectActionForm.FieldLabel("Name")
    let iconButton = ButtonView(nil, icon: .play, variant: .outline)
    let name = InputView(placeholder: "Test", text: "")
    private let keyLabel = ProjectActionForm.FieldLabel("Keybinding")
    let keybinding = ShortcutRecorderView()
    private let keyHelp = ProjectActionForm.HelpText("Press a shortcut. Use Backspace to clear. Shortcuts are environment-wide. Projects using the same action share its shortcut.")
    private let commandLabel = ProjectActionForm.FieldLabel("Command")
    let command = TextareaView(placeholder: "bun test")
    private let previewLabel = ProjectActionForm.FieldLabel("Preview URL (optional)")
    let previewUrl = InputView(placeholder: "http://localhost:5173", text: "")
    private let previewHelp = ProjectActionForm.HelpText("Open this URL in the in-app preview when this action runs.")
    let runOnCreate = SwitchRow("Run automatically on worktree creation")
    let waitForSetup = SwitchRow("Wait for it to finish before the agent starts")
    let runOnSettle = SwitchRow("Run in the thread's worktree when the thread settles")
    let autoOpenPreview = SwitchRow("Open preview automatically when this action runs")
    private let errorText = TextBlockView()
    private var icon = "play" { didSet { iconButton.icon = ProjectActionRowView.icon(icon) } }
    var onHeightChange: (() -> Void)?
    var onReturn: (() -> Void)?

    var error: String? {
        didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; invalidateIntrinsicContentSize(); needsLayout = true; onHeightChange?() }
    }

    var isEnabled = true {
        didSet { for c in [iconButton, name, previewUrl, keybinding] as [NSView] { (c as? ControlView)?.isEnabled = isEnabled; (c as? FieldView)?.isEnabled = isEnabled } }
    }

    init(_ initial: ProjectScriptInput) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        name.text = initial.name
        command.text = initial.command
        previewUrl.text = initial.previewUrl ?? ""
        keybinding.value = initial.keybinding ?? ""
        keybinding.emptyText = "Press shortcut"
        keybinding.deleteClears = true
        icon = initial.icon
        iconButton.iconSize = 18
        iconButton.setAccessibilityLabel("Choose icon")
        iconButton.action = { [weak self] in self?.openIcons() }
        runOnCreate.toggle.isOn = initial.runOnWorktreeCreate
        waitForSetup.toggle.isOn = initial.waitForSetup
        runOnSettle.toggle.isOn = initial.runOnSettle
        autoOpenPreview.toggle.isOn = initial.autoOpenPreview
        runOnCreate.toggle.onChange = { [weak self] _ in self?.syncDependents() }
        previewUrl.onChange = { [weak self] _ in self?.syncDependents() }
        name.onSubmit = { [weak self] in self?.onReturn?() }
        command.onChange = { [weak self] _ in self?.invalidateIntrinsicContentSize(); self?.needsLayout = true; self?.onHeightChange?() }
        errorText.font = DSFont.ui(14)
        errorText.lineHeight = 20
        errorText.color = Themed.color(\.destructive)
        errorText.isHidden = true
        for v in [nameLabel, iconButton, name, keyLabel, keybinding, keyHelp, commandLabel, command, previewLabel, previewUrl, previewHelp,
                  runOnCreate, waitForSetup, runOnSettle, autoOpenPreview, errorText] as [NSView] { addSubview(v) }
        syncDependents()
    }

    /// `opacity-60` and disabled switches while their trigger is off.
    private func syncDependents() {
        waitForSetup.isOn = runOnCreate.toggle.isOn
        autoOpenPreview.isOn = !previewUrl.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var input: ProjectScriptInput {
        ProjectScriptInput(name: name.text, command: command.text, icon: icon, runOnWorktreeCreate: runOnCreate.toggle.isOn,
                           waitForSetup: waitForSetup.toggle.isOn, runOnSettle: runOnSettle.toggle.isOn, keybinding: keybinding.value,
                           previewUrl: previewUrl.text, autoOpenPreview: autoOpenPreview.toggle.isOn)
    }

    /// The icon popover (`grid grid-cols-3 gap-2` of labelled tiles).
    private func openIcons() {
        let grid = IconGrid(selected: icon)
        let popup = PopoverView(content: grid, width: .auto).show(from: iconButton, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4))
        grid.onPick = { [weak self] id in
            guard let self else { return }
            self.icon = id
            if let popup { self.iconButton.popupHost?.close(popup) }
        }
    }

    private var rows: [(NSView, CGFloat)] { [] }

    private func frames(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        func place(_ v: NSView, _ h: CGFloat, x: CGFloat = 0, w: CGFloat? = nil, gapAfter: CGFloat) {
            v.frame = NSRect(x: x, y: y, width: w ?? width, height: h)
            y += h + gapAfter
        }
        place(nameLabel, 16, gapAfter: 6)
        iconButton.frame = NSRect(x: 0, y: y, width: 36, height: 36)
        name.frame = NSRect(x: 44, y: y + 2, width: width - 44, height: 32)
        y += 36 + 16
        place(keyLabel, 16, gapAfter: 6)
        place(keybinding, 32, gapAfter: 6)
        place(keyHelp, keyHelp.height(forWidth: width), gapAfter: 16)
        place(commandLabel, 16, gapAfter: 6)
        command.setFrameSize(NSSize(width: width, height: command.frame.height))
        place(command, command.intrinsicContentSize.height, gapAfter: 16)
        place(previewLabel, 16, gapAfter: 6)
        place(previewUrl, 32, gapAfter: 6)
        place(previewHelp, previewHelp.height(forWidth: width), gapAfter: 16)
        for r in [runOnCreate, waitForSetup, runOnSettle, autoOpenPreview] { place(r, 38, gapAfter: 16) }
        if !errorText.isHidden { place(errorText, errorText.height(forWidth: width), gapAfter: 16) }
        return y - 16
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: frames(width: max(1, bounds.width))) }
    override func layout() { super.layout(); _ = frames(width: bounds.width) }

    /// `Label`: 14px medium.
    static func FieldLabel(_ text: String) -> LabelView {
        let l = LabelView(text, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        l.lineHeight = 16
        return l
    }

    /// `text-xs text-muted-foreground`.
    static func HelpText(_ text: String) -> TextBlockView {
        let t = TextBlockView()
        t.text = text
        t.font = DSFont.ui(12)
        t.lineHeight = 16
        t.color = Themed.color(\.mutedForeground)
        return t
    }

    /// `label flex items-center justify-between gap-3 rounded-md border border-border/70 px-3 py-2 text-sm`.
    final class SwitchRow: BoxView {
        let toggle = SwitchView(isOn: false)
        private let text = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground))
        /// Off dims the row to .6 and disables the switch.
        var isOn = true { didSet { alphaValue = isOn ? 1 : 0.6; toggle.isEnabled = isOn } }
        init(_ title: String) {
            super.init(frame: .zero)
            text.text = title
            text.lineHeight = 20
            addSubview(text)
            addSubview(toggle)
            toggle.setAccessibilityLabel(title)
            var style = BoxStyle()
            style.radius = 6
            style.border = Themed.color(\.border, 0.7)
            boxStyle = style
        }
        override func layout() {
            super.layout()
            let s = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: bounds.width - 12 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            text.frame = NSRect(x: 12, y: (bounds.height - 20) / 2, width: max(0, toggle.frame.minX - 12 - 12), height: 20)
        }
    }

    /// The six `SCRIPT_ICONS` tiles.
    final class IconGrid: DSView {
        static let icons: [(String, String)] = [("play", "Play"), ("test", "Test"), ("lint", "Lint"), ("configure", "Configure"),
                                                ("build", "Build"), ("debug", "Debug")]
        var onPick: ((String) -> Void)?
        init(selected: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: 3 * 72 + 2 * 8, height: 2 * 56 + 8))
            for (i, (id, label)) in Self.icons.enumerated() {
                let b = ButtonView(label, icon: ProjectActionRowView.icon(id), variant: id == selected ? .secondary : .outline, size: .sm)
                b.action = { [weak self] in self?.onPick?(id) }
                b.frame = NSRect(x: CGFloat(i % 3) * 80, y: CGFloat(i / 3) * 64, width: 72, height: 56)
                addSubview(b)
            }
        }
        override var intrinsicContentSize: NSSize { frame.size }
    }
}
