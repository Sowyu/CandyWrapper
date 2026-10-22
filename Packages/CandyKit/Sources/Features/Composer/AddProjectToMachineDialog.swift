import AppKit
import DesignSystem
import T3Protocol

/// `AddProjectToMachineDialog` (apps/web/src/components/AddProjectToMachineDialog.tsx:192-382): the source and the
/// machine with a "git clone" arrow between them, "Clone over" SSH or HTTPS, the folder on the other machine, and the
/// ignored files to copy along. The app supplies the file list and runs the clone.
@MainActor
public enum AddProjectToMachineDialog {
    public struct Source {
        public var label: String
        public var machine: String
        public var workspaceRoot: String
        /// `repositoryIdentity.displayName ?? title`.
        public var displayName: String
        public var remoteUrl: String
        public init(label: String, machine: String, workspaceRoot: String, displayName: String, remoteUrl: String) {
            self.label = label; self.machine = machine; self.workspaceRoot = workspaceRoot
            self.displayName = displayName; self.remoteUrl = remoteUrl
        }
    }

    /// A reason the clone could not start, shown under the form.
    public struct Failure: LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Submission {
        public var target: AddProjectToMachine.Target
        public var remoteUrl: String
        public var destinationPath: String
        public var files: [String]
    }

    /// Shows the dialog over `window`. `listFiles` is nil when the source server cannot list ignored files
    /// (`ignoredFileListing`). `submit` throws a message to show; the dialog closes once it returns.
    // ponytail: the targets are read when the dialog opens, where T3 follows them live; a machine that drops off
    // fails the clone request with its own error. Follow the list if that shows up.
    @discardableResult
    public static func present(in window: NSWindow, source: Source, targets: [AddProjectToMachine.Target], initialTargetId: String?,
                               defaultDestination: @escaping @MainActor (AddProjectToMachine.Target) -> String,
                               listFiles: (@MainActor () async throws -> (files: [AddProjectToMachine.IgnoredFile], truncated: Bool))?,
                               submit: @escaping @MainActor (Submission) async throws -> Void) -> ModalHost {
        let dialog = DialogView(title: "Add to another machine",
                                message: "Clone \(source.displayName) and bring the local files git does not track.")
        dialog.maxWidth = 576 // `sm:max-w-xl`
        let form = AddProjectToMachineForm(source: source, targets: targets, initialTargetId: initialTargetId,
                                           defaultDestination: defaultDestination, listsFiles: listFiles != nil)
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        let clone = ButtonView("")
        dialog.footerButtons = [cancel, clone]
        let host = ModalHost.present(dialog, in: window)
        var finished = false
        let finish: @MainActor () -> Void = { [weak host] in
            guard !finished else { return }
            finished = true
            host?.close()
        }
        host.onDismiss = { finish() }
        dialog.onClose = { finish() }
        cancel.action = { finish() }
        let sync: @MainActor () -> Void = { [weak form, weak clone, weak dialog] in
            guard let form, let clone else { return }
            clone.title = form.submitting ? "Starting\u{2026}" : "Clone to \(form.target?.label ?? "machine")"
            clone.isEnabled = !form.unavailable && !form.submitting
            dialog?.needsLayout = true
        }
        let run: @MainActor () -> Void = { [weak form] in
            guard let form, !finished, let request = form.submission() else { sync(); return }
            form.submitting = true
            sync()
            Task { @MainActor [weak form] in
                do {
                    try await submit(request)
                    finish()
                } catch {
                    form?.error = (error as? LocalizedError)?.errorDescription ?? "Could not start the clone."
                    form?.submitting = false
                    sync()
                }
            }
        }
        clone.action = run
        form.onSubmit = run
        form.onChange = sync
        sync()
        if let listFiles {
            Task { @MainActor [weak form] in
                do {
                    let result = try await listFiles()
                    form?.filesLoaded(result.files, truncated: result.truncated)
                } catch {
                    form?.filesFailed((error as? LocalizedError)?.errorDescription ?? "Could not list ignored files.")
                }
                sync()
            }
        }
        return host
    }
}

/// The dialog's panel. Sections sit 16 apart (`DialogPanel`), each a label 6 above its control (`gap-1.5`).
final class AddProjectToMachineForm: DSView {
    var onChange: (@MainActor () -> Void)?
    var onSubmit: (@MainActor () -> Void)?

    private let source: AddProjectToMachineDialog.Source
    private let targets: [AddProjectToMachine.Target]
    private let defaultDestination: @MainActor (AddProjectToMachine.Target) -> String
    private let listsFiles: Bool
    private(set) var target: AddProjectToMachine.Target?
    private var proto: AddProjectToMachine.CloneProtocol?
    private var pathOverride: String?
    private var files: [AddProjectToMachine.IgnoredFile] = []
    private var truncated = false
    private var filesState: FilesState = .loading
    enum FilesState: Equatable { case loading, loaded, failed(String) }
    private var picked: Set<String>?
    var submitting = false
    var error: String? { didSet { errorText.text = error ?? ""; errorText.isHidden = error == nil; changed() } }

    // The source, the arrow and the machine (`grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] gap-3`).
    private let sourceIcon: IconView
    private let sourceLabel = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
    private let sourcePath: MiddleTruncateView
    private let arrowTop = AddProjectToMachineForm.caption("git clone")
    private let arrowLine = DSView()
    private let arrowHead = IconView(name: .arrowRight, size: 14)
    private let arrowBottom = AddProjectToMachineForm.caption("")
    private let targetSelect: SelectView
    private var targetIcon = IconView(name: .monitor, size: 14)
    private let targetLabel = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.contrastForeground))
    private let targetPath: MiddleTruncateView

    private let cloneLabel = FormLabel.make("Clone over")
    private let protocolToggle = ToggleGroupView(items: [("SSH", nil), ("HTTPS", nil)])
    private let urlLabel = LabelView("", font: DSFont.mono(12), color: Themed.color(\.contrastMutedForeground))

    private let folderLabel = FormLabel.make("")
    let folder = InputView()

    private let filesLabel = FormLabel.make("Copy ignored files")
    private let summary = AddProjectToMachineForm.caption("")
    private let allButton = ButtonView("All", variant: .ghost, size: .xs)
    private let status = AddProjectToMachineForm.caption("")
    private let listDocument = DSView()
    private lazy var listScroll = ScrollAreaView(documentView: listDocument)
    /// The list's `rounded-md border`, with the scroll area 1pt inside it.
    private let listFrame = DSView()
    private let listBox = BoxDecorationLayer()
    private var rows: [Row] = []
    private let truncatedNote = AddProjectToMachineForm.caption("")
    private let footnote = TextBlockView()
    private let errorText = TextBlockView()

    private static func caption(_ text: String) -> LabelView {
        let label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.contrastMutedForeground))
        label.lineHeight = 16
        return label
    }

    init(source: AddProjectToMachineDialog.Source, targets: [AddProjectToMachine.Target], initialTargetId: String?,
         defaultDestination: @escaping @MainActor (AddProjectToMachine.Target) -> String, listsFiles: Bool) {
        self.source = source
        self.targets = targets
        self.defaultDestination = defaultDestination
        self.listsFiles = listsFiles
        target = targets.first { $0.environmentId == initialTargetId } ?? targets.first
        proto = AddProjectToMachine.cloneUrlProtocol(source.remoteUrl)
        sourceIcon = IconView(definition: EnvironmentMachineIcon.definition(source.machine), size: 14)
        sourcePath = MiddleTruncateView(source.workspaceRoot, font: DSFont.mono(12))
        targetPath = MiddleTruncateView("", font: DSFont.mono(12))
        targetSelect = SelectView(options: targets.map(\.label), selected: targets.firstIndex { $0.environmentId == initialTargetId } ?? 0, size: .sm)
        super.init(frame: .zero)
        sourceLabel.lineHeight = 20
        sourceLabel.text = source.label
        for path in [sourcePath, targetPath] {
            path.lineHeight = 16
            path.color = Themed.color(\.contrastMutedForeground)
        }
        arrowTop.alignment = .center
        arrowBottom.alignment = .center
        arrowLine.wantsLayer = true
        arrowHead.setAccessibilityElement(false)
        targetSelect.setAccessibilityLabel("Machine to add the project to")
        targetSelect.optionGlyphs = targets.map { EnvironmentMachineIcon.definition($0.machine) }
        targetSelect.onChange = { [weak self] index in
            guard let self, self.targets.indices.contains(index) else { return }
            self.target = self.targets[index]
            self.syncTarget()
        }
        targetLabel.lineHeight = 20
        protocolToggle.setAccessibilityLabel("Clone protocol")
        protocolToggle.selectedIndex = proto == .ssh ? 0 : proto == .https ? 1 : nil
        protocolToggle.onChange = { [weak self] index in
            guard let self else { return }
            // Pressing the pressed item clears Base UI's value; T3 ignores that and keeps the protocol.
            guard let index else { self.protocolToggle.selectedIndex = self.proto == .ssh ? 0 : 1; return }
            self.proto = index == 0 ? .ssh : .https
            self.syncUrl()
        }
        urlLabel.lineHeight = 16
        folder.onChange = { [weak self] text in self?.pathOverride = text; self?.error = nil }
        folder.onSubmit = { [weak self] in self?.onSubmit?() }
        allButton.action = { [weak self] in
            guard let self else { return }
            self.picked = AddProjectToMachine.toggleAll(self.files, selected: self.selected)
            self.syncFiles()
        }
        listBox.host = listFrame
        listFrame.layer?.addSublayer(listBox)
        listFrame.addSubview(listScroll)
        truncatedNote.isHidden = true
        footnote.text = "Files are copied after the clone finishes. Folders git ignores whole, like node_modules, are left out."
        footnote.font = DSFont.ui(12)
        footnote.lineHeight = 16
        footnote.color = Themed.color(\.contrastMutedForeground)
        errorText.font = DSFont.ui(14)
        errorText.lineHeight = 20
        errorText.color = Themed.color(\.destructiveForeground)
        errorText.isHidden = true
        errorText.setAccessibilityRole(.staticText)
        for v in [sourceIcon, sourceLabel, sourcePath, arrowTop, arrowLine, arrowHead, arrowBottom, targetSelect, targetIcon, targetLabel, targetPath,
                  cloneLabel, protocolToggle, urlLabel, folderLabel, folder] as [NSView] { addSubview(v) }
        if listsFiles {
            for v in [filesLabel, summary, allButton, status, listFrame, truncatedNote, footnote] as [NSView] { addSubview(v) }
        }
        addSubview(errorText)
        restyle()
        syncTarget()
        syncUrl()
        syncFiles()
    }

    // MARK: State

    private var selected: Set<String> { picked ?? AddProjectToMachine.defaultSelection(files) }

    private var sshUrl: String? { AddProjectToMachine.cloneUrl(source.remoteUrl, for: .ssh) }
    private var httpsUrl: String? { AddProjectToMachine.cloneUrl(source.remoteUrl, for: .https) }
    private var showsToggle: Bool { sshUrl != nil && httpsUrl != nil }
    private var remoteUrl: String { AddProjectToMachine.remoteUrl(source: source.remoteUrl, protocol: proto) }
    private var destinationPath: String { pathOverride ?? target.map(defaultDestination) ?? "" }

    /// Submitting before the file list loads would quietly skip the default env copies
    /// (AddProjectToMachineDialog.tsx:120-125).
    var unavailable: Bool { target == nil || (listsFiles && filesState == .loading) }

    /// The request, or nil after showing why there is none.
    func submission() -> AddProjectToMachineDialog.Submission? {
        guard let target, !unavailable, !submitting else { return nil }
        let path = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { error = "Choose a folder on the other machine."; return nil }
        error = nil
        let picks = selected
        return .init(target: target, remoteUrl: remoteUrl, destinationPath: path, files: files.filter { picks.contains($0.path) }.map(\.path))
    }

    func filesLoaded(_ files: [AddProjectToMachine.IgnoredFile], truncated: Bool) {
        self.files = files
        self.truncated = truncated
        filesState = .loaded
        syncFiles()
    }

    func filesFailed(_ message: String) {
        filesState = .failed(message)
        syncFiles()
    }

    private func syncTarget() {
        let label = target?.label
        if let target {
            let icon = IconView(definition: EnvironmentMachineIcon.definition(target.machine), size: 14)
            icon.strokeColor = Themed.color(\.contrastForeground)
            replaceSubview(targetIcon, with: icon)
            targetIcon = icon
        }
        targetSelect.leading = targets.count > 1 && target != nil ? IconView(definition: EnvironmentMachineIcon.definition(target!.machine), size: 14) : nil
        targetLabel.text = label ?? "No machine available"
        targetSelect.isHidden = targets.count < 2
        targetLabel.isHidden = targets.count > 1
        targetIcon.isHidden = targets.count > 1 || target == nil
        folderLabel.text = "Folder on \(label ?? "the other machine")"
        folder.setAccessibilityLabel(folderLabel.text)
        if pathOverride == nil { folder.text = destinationPath }
        targetPath.value = destinationPath
        changed()
    }

    private func syncUrl() {
        protocolToggle.isHidden = !showsToggle
        urlLabel.text = remoteUrl
        changed()
    }

    private func syncFiles() {
        let picks = selected
        arrowBottom.text = AddProjectToMachine.filesCaption(picks.count)
        let copyable = files.filter { !$0.tooLarge }
        summary.isHidden = copyable.isEmpty
        allButton.isHidden = copyable.isEmpty
        summary.text = AddProjectToMachine.selectionSummary(files, selected: picks)
        allButton.title = picks.count == copyable.count ? "None" : "All"
        switch filesState {
        case .failed(let message):
            status.text = message
            status.color = Themed.color(\.destructiveForeground)
        case .loaded where files.isEmpty:
            status.text = "No ignored files to copy."
            status.color = Themed.color(\.contrastMutedForeground)
        case .loading:
            status.text = "Finding ignored files\u{2026}"
            status.color = Themed.color(\.contrastMutedForeground)
        case .loaded:
            status.text = ""
        }
        let showsList = filesState == .loaded && !files.isEmpty
        status.isHidden = showsList
        listFrame.isHidden = !showsList
        if rows.map(\.file) != files {
            rows.forEach { $0.removeFromSuperview() }
            rows = files.map { file in
                let row = Row(file: file)
                row.onToggle = { [weak self] on in
                    guard let self else { return }
                    var next = self.selected
                    if on { next.insert(file.path) } else { next.remove(file.path) }
                    self.picked = next
                    self.syncFiles()
                }
                listDocument.addSubview(row)
                return row
            }
        }
        for row in rows { row.checked = picks.contains(row.file.path) }
        truncatedNote.isHidden = !truncated
        truncatedNote.text = "Showing the first \(files.count) files."
        changed()
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        onChange?()
    }

    private func restyle() {
        arrowLine.layer?.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self)
        arrowHead.strokeColor = Themed.color(\.contrastMutedForeground)
        sourceIcon.strokeColor = Themed.color(\.contrastForeground)
        targetIcon.strokeColor = Themed.color(\.contrastForeground)
        var box = BoxStyle()
        box.radius = 8 // `rounded-md border`
        box.border = Themed.color(\.contrastBorder)
        listBox.boxStyle = box
        listBox.setNeedsDisplay()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    // MARK: Layout

    private static let listMaxHeight: CGFloat = 208 // `max-h-52`
    private var listHeight: CGFloat { min(Self.listMaxHeight, CGFloat(rows.count) * Row.height + CGFloat(max(0, rows.count - 1)) + 2) }
    private var lastWidth: CGFloat = 0

    private struct Frames {
        var items: [(NSView, NSRect)] = []
        var height: CGFloat = 0
    }

    private func frames(width w: CGFloat) -> Frames {
        var f = Frames()
        func put(_ v: NSView, _ r: NSRect) { f.items.append((v, r)) }
        // Grid row: the columns are centred on the tallest.
        let middle: CGFloat = 112 // `w-28`
        let col = max(0, (w - middle - 24) / 2)
        let rightHeight: CGFloat = (targets.count > 1 ? 28 : 20) + 4 + 16
        let gridHeight = max(40, rightHeight, 50)
        let ly = (gridHeight - 40) / 2
        put(sourceIcon, NSRect(x: 0, y: ly + 3, width: 14, height: 14))
        put(sourceLabel, NSRect(x: 20, y: ly, width: max(0, min(sourceLabel.intrinsicContentSize.width, col - 20)), height: 20))
        put(sourcePath, NSRect(x: 0, y: ly + 24, width: col, height: 16))
        let mx = col + 12, my = (gridHeight - 50) / 2
        put(arrowTop, NSRect(x: mx, y: my, width: middle, height: 16))
        put(arrowLine, NSRect(x: mx, y: my + 18 + 6.5, width: middle - 10, height: 1))
        put(arrowHead, NSRect(x: mx + middle - 14, y: my + 18, width: 14, height: 14))
        put(arrowBottom, NSRect(x: mx, y: my + 34, width: middle, height: 16))
        let rx = mx + middle + 12, ry = (gridHeight - rightHeight) / 2
        if targets.count > 1 {
            put(targetSelect, NSRect(x: rx, y: ry, width: col, height: 28))
            put(targetPath, NSRect(x: rx, y: ry + 32, width: col, height: 16))
        } else {
            put(targetIcon, NSRect(x: rx, y: ry + 3, width: 14, height: 14))
            let lx = target == nil ? rx : rx + 20
            put(targetLabel, NSRect(x: lx, y: ry, width: max(0, col - (lx - rx)), height: 20))
            put(targetPath, NSRect(x: rx, y: ry + 24, width: col, height: 16))
        }
        var y = gridHeight + 16

        put(cloneLabel, NSRect(x: 0, y: y, width: w, height: 16))
        y += 22
        if showsToggle {
            let size = protocolToggle.intrinsicContentSize
            put(protocolToggle, NSRect(x: 0, y: y, width: size.width, height: size.height))
            y += size.height + 6
        }
        put(urlLabel, NSRect(x: 0, y: y, width: w, height: 16))
        y += 16 + 16

        put(folderLabel, NSRect(x: 0, y: y, width: w, height: 16))
        put(folder, NSRect(x: 0, y: y + 22, width: w, height: 32))
        y += 22 + 32

        if listsFiles {
            y += 16
            // `flex items-center gap-2`: the label takes the rest, then the count and the 24pt button.
            var x = w
            if !allButton.isHidden {
                let bw = allButton.intrinsicContentSize.width
                x -= bw
                put(allButton, NSRect(x: x, y: y, width: bw, height: 24))
                let sw = summary.intrinsicContentSize.width
                x -= 8 + sw
                put(summary, NSRect(x: x, y: y + 4, width: sw, height: 16))
                x -= 8
            }
            put(filesLabel, NSRect(x: 0, y: y + 4, width: max(0, x), height: 16))
            y += 24 + 6
            if listFrame.isHidden {
                put(status, NSRect(x: 0, y: y, width: w, height: 16))
                y += 16
            } else {
                let h = listHeight
                put(listFrame, NSRect(x: 0, y: y, width: w, height: h))
                y += h
            }
            if truncated {
                put(truncatedNote, NSRect(x: 0, y: y + 6, width: w, height: 16))
                y += 22
            }
            let fh = footnote.height(forWidth: w)
            put(footnote, NSRect(x: 0, y: y + 6, width: w, height: fh))
            y += 6 + fh
        }
        if error != nil {
            let eh = errorText.height(forWidth: w)
            put(errorText, NSRect(x: 0, y: y + 16, width: w, height: eh))
            y += 16 + eh
        }
        f.height = y
        return f
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(width: max(1, bounds.width)).height)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        for (view, frame) in frames(width: w).items { view.frame = frame }
        // The list: rows inside the 1px border, `not-last:border-b` between them.
        let inner = max(0, w - 2)
        var ry: CGFloat = 0
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: ry, width: inner, height: Row.height + (i < rows.count - 1 ? 1 : 0))
            row.showsDivider = i < rows.count - 1
            ry += Row.height + 1
        }
        listDocument.frame = NSRect(x: 0, y: 0, width: inner, height: max(0, ry - 1))
        listScroll.frame = NSRect(x: 1, y: 1, width: inner, height: max(0, listFrame.bounds.height - 2))
        listBox.layout(boxSize: listFrame.bounds.size)
        if w != lastWidth {
            // The footnote wraps with the width, so the dialog measures again.
            lastWidth = w
            DispatchQueue.main.async { [weak self] in self?.changed() }
        }
    }

    /// One ignored file (`IgnoredFileRow`, AddProjectToMachineDialog.tsx:407-426): a clickable label with the checkbox,
    /// the path in mono and the size, or "Over 1 MB" on a file too large to copy, dimmed and disabled.
    final class Row: ControlView {
        static let height: CGFloat = 32 // `py-1.5` around a 20pt line; the divider adds 1 below
        let file: AddProjectToMachine.IgnoredFile
        var onToggle: (@MainActor (Bool) -> Void)?
        var checked = false { didSet { box.value = checked ? .on : .off } }
        var showsDivider = false { didSet { divider.isHidden = !showsDivider } }
        private let box = CheckboxView()
        private let path = LabelView("", font: DSFont.mono(12), color: Themed.color(\.contrastForeground))
        private let size = LabelView("", font: DSFont.ui(12).monospacedDigits, color: Themed.color(\.contrastMutedForeground))
        private let divider = CALayer()

        init(file: AddProjectToMachine.IgnoredFile) {
            self.file = file
            super.init(frame: .zero)
            scalesWhenPressed = false
            path.text = file.path
            path.lineHeight = 16
            size.text = file.tooLarge ? "Over 1 MB" : StorageCleanupReport.formatBytes(Double(file.byteLength))
            size.lineHeight = 16
            box.isEnabled = !file.tooLarge
            box.onChange = { [weak self] value in self?.onToggle?(value == .on) }
            isEnabled = !file.tooLarge
            alphaValue = file.tooLarge ? 0.64 : 1
            divider.actions = ["position": NSNull(), "bounds": NSNull()]
            layer?.addSublayer(divider)
            for v in [box, path, size] as [NSView] { addSubview(v) }
            setAccessibilityElement(false)
            box.setAccessibilityLabel(file.path)
        }

        override func performAction() {
            super.performAction()
            guard !file.tooLarge else { return }
            onToggle?(!checked)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            // `px-2.5 gap-2`.
            box.frame = NSRect(x: 10, y: 8, width: 16, height: 16)
            let sw = size.intrinsicContentSize.width
            size.frame = NSRect(x: w - 10 - sw, y: 8, width: sw, height: 16)
            path.frame = NSRect(x: 34, y: 8, width: max(0, w - 10 - sw - 8 - 34), height: 16)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            divider.frame = CGRect(x: 0, y: isFlipped ? Row.height : 0, width: w, height: 1)
            divider.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self)
            CATransaction.commit()
        }
    }
}
