import AppKit
import DesignSystem
import T3Protocol

/// The commit dialog (GitActionsControl.tsx:1983-2134): "Commit changes", the summary card (branch, the
/// default-branch warning, the changed files with Edit to exclude some, the totals of the selected files), the
/// optional message, and Cancel, "Commit on new branch" and Commit. The caller presents `dialog` in a `ModalHost`
/// and reads `selection` and `message.text` when a button runs.
@MainActor
public final class CommitDialog {
    public static let title = "Commit changes"
    public static let description = "Review and confirm your commit. Leave the message blank to auto-generate one."

    public let dialog: DialogView
    public let cancel = ButtonView("Cancel", variant: .outline, size: .sm)
    public let commitOnNewBranch = ButtonView("Commit on new branch", variant: .outline, size: .sm)
    public let commit = ButtonView("Commit", variant: .default, size: .sm)
    public let message = TextareaView(placeholder: "Leave empty to auto-generate", size: .sm)
    public let summary: CommitSummaryView
    public var selection: GitActionsLogic.CommitSelection { summary.selection }
    /// Opens a file in the editor (the file buttons).
    public var onOpenFile: (@MainActor (String) -> Void)? {
        get { summary.onOpenFile }
        set { summary.onOpenFile = newValue }
    }

    public init(branch: String?, isDefaultRef: Bool, files: [VcsStatus.File]?, canChangeBranch: Bool, canWrite: Bool) {
        summary = CommitSummaryView(branch: branch, isDefaultRef: isDefaultRef, files: files)
        dialog = DialogView(kind: .dialog, title: Self.title, message: Self.description)
        let messageGroup = CommitMessageGroup(textarea: message)
        dialog.panelContent = [summary, messageGroup]
        dialog.footerVariant = .bare
        dialog.footerButtons = [cancel, commitOnNewBranch, commit]
        summary.onChange = { [weak self] in self?.updateButtons(canChangeBranch: canChangeBranch, canWrite: canWrite) }
        updateButtons(canChangeBranch: canChangeBranch, canWrite: canWrite)
    }

    private func updateButtons(canChangeBranch: Bool, canWrite: Bool) {
        commitOnNewBranch.isEnabled = canChangeBranch && !selection.noneSelected
        commit.isEnabled = canWrite && !selection.noneSelected
        dialog.needsLayout = true
    }

    /// The trimmed message, nil when blank (the server writes one).
    public var commitMessage: String? {
        let m = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? nil : m
    }
}

/// "Commit message (optional)" over the small textarea (`space-y-1`).
final class CommitMessageGroup: DSView {
    private let label = LabelView("Commit message (optional)", font: DSFont.ui(14, weight: .medium))
    let textarea: TextareaView

    init(textarea: TextareaView) {
        self.textarea = textarea
        super.init(frame: .zero)
        label.lineHeight = 20
        addSubview(label)
        addSubview(textarea)
        textarea.onChange = { [weak self] _ in self?.invalidateIntrinsicContentSize(); self?.superview?.needsLayout = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24 + textareaHeight)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        textarea.frame = NSRect(x: 0, y: 24, width: bounds.width, height: textareaHeight)
    }

    private var textareaHeight: CGFloat {
        textarea.setFrameSize(NSSize(width: bounds.width, height: textarea.frame.height))
        return textarea.intrinsicContentSize.height
    }

    override func updateLayer() { label.color = Themed.color(\.contrastForeground) }
}

/// The summary card (`space-y-3 rounded-xl bg-zinc-25 p-3 text-sm ring-1 ring-black/5`, dark `white/3.5%` and
/// `white/5`): the branch row, the files header with Edit or Done, the 176pt file list
/// (`h-44 rounded-lg bg-card ring-1`) and the selected totals.
public final class CommitSummaryView: BoxView {
    public private(set) var selection: GitActionsLogic.CommitSelection
    var onChange: (@MainActor () -> Void)?
    var onOpenFile: (@MainActor (String) -> Void)?
    private(set) var isEditing = false

    let hasStatus: Bool
    private let branchKey = LabelView("Branch", font: DSFont.ui(14))
    private let branchName = LabelView("", font: DSFont.ui(14, weight: .medium))
    private let defaultBranch = LabelView("Default branch", font: DSFont.ui(14))
    private let filesKey = LabelView("Files", font: DSFont.ui(14))
    private let filesCount = LabelView("", font: DSFont.ui(14))
    let allBox = CheckboxView()
    let edit = ButtonView("Edit", variant: .ghost, size: .xs)
    private let none = LabelView("none", font: DSFont.ui(14, weight: .medium))
    let list = CommitFileListView()
    private let totals = SlashTotalsView()

    init(branch: String?, isDefaultRef: Bool, files: [VcsStatus.File]?) {
        selection = GitActionsLogic.CommitSelection(files: files ?? [])
        hasStatus = files != nil
        super.init(frame: .zero)
        var box = BoxStyle()
        box.radius = 14
        box.fill = Themed.pick(light: WindowGlass.paneFill, dark: Themed.white(0.035))
        box.shadows = [BoxShadow(spread: 1, color: Themed.pick(light: Themed.black(0.05), dark: Themed.white(0.05)))]
        boxStyle = box
        branchName.text = branch ?? "(detached HEAD)"
        defaultBranch.isHidden = !isDefaultRef
        for l in [branchKey, branchName, defaultBranch, filesKey, filesCount, none] { l.lineHeight = 20; addSubview(l) }
        addSubview(allBox)
        addSubview(edit)
        addSubview(list)
        addSubview(totals)
        edit.action = { [weak self] in self?.toggleEditing() }
        allBox.onChange = { [weak self] _ in self?.selection.toggleAll(); self?.refresh() }
        list.onToggle = { [weak self] path in self?.selection.toggle(path); self?.refresh() }
        list.onOpen = { [weak self] path in self?.onOpenFile?(path) }
        refresh()
    }

    private var hasFiles: Bool { hasStatus && !selection.files.isEmpty }

    private func toggleEditing() {
        isEditing.toggle()
        refresh()
    }

    private func refresh() {
        edit.title = isEditing ? "Done" : "Edit"
        edit.isHidden = selection.files.isEmpty
        allBox.isHidden = !(isEditing && !selection.files.isEmpty)
        allBox.value = selection.allSelected ? .on : selection.noneSelected ? .off : .mixed
        filesCount.text = "(\(selection.selected.count) of \(selection.files.count))"
        filesCount.isHidden = selection.allSelected || isEditing
        none.isHidden = hasFiles
        list.isHidden = !hasFiles
        totals.isHidden = !hasFiles
        list.update(files: selection.files, excluded: selection.excluded, editing: isEditing)
        let t = selection.totals
        totals.insertions = t.insertions
        totals.deletions = t.deletions
        needsLayout = true
        onChange?()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 12 + 20 + 12 + 24 + 4 + (hasFiles ? 176 + 8 + 20 : 20) + 12)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width - 24
        // `grid-cols-[auto_1fr] gap-x-2`.
        let keyW = ceil(branchKey.textWidth)
        branchKey.frame = NSRect(x: 12, y: 12, width: keyW, height: 20)
        let defW = defaultBranch.isHidden ? 0 : ceil(defaultBranch.textWidth)
        defaultBranch.frame = NSRect(x: 12 + w - defW, y: 12, width: defW, height: 20)
        branchName.frame = NSRect(x: 12 + keyW + 8, y: 12, width: max(0, w - keyW - 8 - (defW > 0 ? defW + 8 : 0)), height: 20)
        var y: CGFloat = 12 + 20 + 12
        var x: CGFloat = 12
        if !allBox.isHidden {
            allBox.frame = NSRect(x: x, y: y + 4, width: 16, height: 16)
            x += 16 + 8
        }
        filesKey.frame = NSRect(x: x, y: y + 2, width: ceil(filesKey.textWidth), height: 20)
        x += ceil(filesKey.textWidth) + 8
        filesCount.frame = NSRect(x: x, y: y + 2, width: ceil(filesCount.textWidth), height: 20)
        let ew = edit.intrinsicContentSize.width
        edit.frame = NSRect(x: 12 + w - ew, y: y, width: ew, height: 24)
        y += 24 + 4
        none.frame = NSRect(x: 12, y: y, width: w, height: 20)
        list.frame = NSRect(x: 12, y: y, width: w, height: 176)
        y += 176 + 8
        let tw = totals.intrinsicContentSize.width
        totals.frame = NSRect(x: 12 + w - tw, y: y, width: tw, height: 20)
    }

    public override func updateLayer() {
        super.updateLayer()
        branchKey.color = Themed.color(\.contrastMutedForeground)
        filesKey.color = Themed.color(\.contrastMutedForeground)
        filesCount.color = Themed.color(\.contrastMutedForeground)
        branchName.color = Themed.color(\.contrastForeground)
        none.color = Themed.color(\.contrastForeground)
        defaultBranch.color = Themed.color(\.warning)
    }
}

/// `+N / -N` in mono, `diff-addition` and `diff-deletion` around a muted slash.
final class SlashTotalsView: DSView {
    private let plus = LabelView(), slash = LabelView(" / "), minus = LabelView()
    var insertions = 0 { didSet { plus.text = "+\(insertions)"; invalidateIntrinsicContentSize(); needsLayout = true } }
    var deletions = 0 { didSet { minus.text = "-\(deletions)"; invalidateIntrinsicContentSize(); needsLayout = true } }
    var excludedText: String? { didSet { needsLayout = true; invalidateIntrinsicContentSize() } }
    private let excluded = LabelView("Excluded")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [plus, slash, minus, excluded] { l.font = DSFont.mono(14); l.lineHeight = 20; addSubview(l) }
        plus.text = "+0"; minus.text = "-0"
    }

    private var parts: [LabelView] { excludedText != nil ? [excluded] : [plus, slash, minus] }

    override var intrinsicContentSize: NSSize { NSSize(width: parts.reduce(0) { $0 + $1.textWidth }.rounded(.up), height: 20) }

    override func layout() {
        super.layout()
        excluded.isHidden = excludedText == nil
        for l in [plus, slash, minus] { l.isHidden = excludedText != nil }
        var x: CGFloat = 0
        for l in parts { l.frame = NSRect(x: x, y: 0, width: ceil(l.textWidth), height: 20); x += l.textWidth }
    }

    override func updateLayer() {
        plus.color = Themed.color(\.diffAddition)
        minus.color = Themed.color(\.diffDeletion)
        slash.color = Themed.color(\.contrastMutedForeground)
        excluded.color = Themed.color(\.contrastMutedForeground)
    }
}

/// The scrolling file list: `p-1 space-y-1`, rows `px-2 py-1 rounded-md font-mono hover:bg-accent/50` with a
/// checkbox while editing, the path truncated at its start, and the file's totals or "Excluded".
final class CommitFileListView: BoxView {
    var onToggle: (@MainActor (String) -> Void)?
    var onOpen: (@MainActor (String) -> Void)?
    private let clip = DSView()
    private var rows: [CommitFileRowView] = []
    private var offset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var box = BoxStyle()
        box.radius = 10
        box.fill = Themed.pick(light: Themed.color(\.card), dark: Themed.white(0.025))
        box.shadows = [BoxShadow(spread: 1, color: Themed.pick(light: Themed.black(0.05), dark: Themed.white(0.05)))]
        boxStyle = box
        clip.clipsToBounds = true
        addSubview(clip)
    }

    func update(files: [VcsStatus.File], excluded: Set<String>, editing: Bool) {
        if rows.map(\.path) != files.map(\.path) {
            rows.forEach { $0.removeFromSuperview() }
            rows = files.map { CommitFileRowView(file: $0) }
            for row in rows {
                row.onToggle = { [weak self] p in self?.onToggle?(p) }
                row.action = { [weak self, path = row.path] in self?.onOpen?(path) }
                clip.addSubview(row)
            }
        }
        for row in rows { row.configure(excluded: excluded.contains(row.path), editing: editing) }
        needsLayout = true
    }

    private var contentHeight: CGFloat { 8 + CGFloat(rows.count) * 28 + CGFloat(max(0, rows.count - 1)) * 4 }

    override func layout() {
        super.layout()
        clip.frame = bounds
        offset = min(offset, max(0, contentHeight - bounds.height))
        var y = 4 - offset
        for row in rows {
            row.frame = NSRect(x: 4, y: y, width: bounds.width - 8, height: 28)
            y += 32
        }
    }

    override func scrollWheel(with event: NSEvent) {
        offset = min(max(0, offset - event.scrollingDeltaY), max(0, contentHeight - bounds.height))
        needsLayout = true
    }
}

final class CommitFileRowView: ControlView {
    let path: String
    private let file: VcsStatus.File
    private let box = CheckboxView()
    private let label = LabelView()
    private let totals = SlashTotalsView()
    private let fill = CALayer()
    private var editing = false
    private var excluded = false
    var onToggle: (@MainActor (String) -> Void)?

    init(file: VcsStatus.File) {
        self.file = file
        path = file.path
        super.init(frame: .zero)
        scalesWhenPressed = false
        fill.cornerRadius = 8
        fill.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
        label.text = file.path
        label.font = DSFont.mono(14)
        label.lineHeight = 20
        label.truncation = .start
        totals.insertions = file.insertions
        totals.deletions = file.deletions
        box.onChange = { [weak self] _ in guard let self else { return }; self.onToggle?(self.path) }
        addSubview(box)
        addSubview(label)
        addSubview(totals)
        TooltipController.attach(to: label, text: file.path)
        setAccessibilityLabel("Open \(file.path) in editor")
    }

    func configure(excluded: Bool, editing: Bool) {
        self.excluded = excluded
        self.editing = editing
        box.isHidden = !editing
        box.value = excluded ? .off : .on
        totals.excludedText = excluded ? "Excluded" : nil
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        var x: CGFloat = 8
        if editing {
            box.frame = NSRect(x: x, y: 6, width: 16, height: 16)
            x += 16 + 8
        }
        let tw = totals.intrinsicContentSize.width
        totals.frame = NSRect(x: bounds.width - 8 - tw, y: 4, width: tw, height: 20)
        label.frame = NSRect(x: x, y: 4, width: max(0, bounds.width - 8 - tw - 12 - x), height: 20)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func updateLayer() {
        fill.backgroundColor = state.hovered ? Themed.color(\.accent, 0.5).cgColor(in: self) : nil
        label.color = excluded ? Themed.color(\.contrastMutedForeground) : Themed.color(\.contrastForeground)
    }
}

/// The default-branch confirmation (GitActionsControl.tsx:2146-2190): `max-w-xl`, Abort at the start, the
/// continue label, and "Check out feature branch & continue".
@MainActor
public final class DefaultBranchDialog {
    public let dialog: DialogView
    public let abort = ButtonView("Abort", variant: .outline, size: .sm)
    public let proceed: ButtonView
    public let featureBranch = ButtonView("Check out feature branch & continue", variant: .default, size: .sm)

    public init(copy: GitActionsLogic.DialogCopy, canWrite: Bool, canChangeBranch: Bool) {
        dialog = DialogView(kind: .dialog, title: copy.title, message: copy.description)
        dialog.maxWidth = 576
        proceed = ButtonView(copy.continueLabel, variant: .outline, size: .sm)
        proceed.isEnabled = canWrite
        featureBranch.isEnabled = canChangeBranch
        dialog.footerVariant = .bare
        dialog.footerButtons = [abort, proceed, featureBranch]
        dialog.footerLeadingCount = 1
    }
}
