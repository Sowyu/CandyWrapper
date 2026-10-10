import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// `ChangedFilesCard` (ChangedFilesTree.tsx:24-122) under the answer of a run that changed files:
/// a 10px-radius card, the "N changed files +A -D" header with the fold-all and Open diff buttons,
/// and the tree (`p-2`, 28px rows). Folder state comes from `TimelineRowUI`, so it survives
/// recycling; clicks go to the context's model.
final class ChangedFilesCardView: DSView {
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 28
    /// Directory rows: the 11px name has no paired line height and inherits 1.5 (16.5px).
    // ponytail: no reference shows a folder row; measure one when a capture has directories
    static let folderRowHeight: CGFloat = 28.5

    struct Row: Equatable {
        var node: TurnDiffTreeNode
        var depth: Int
        var expanded: Bool
    }

    private let title = LabelView("", font: TL.font(12, .medium), color: TL.c(\.foreground))
    private let total = DiffStatView()
    private let foldAll = ButtonView(nil, icon: .chevronsUpDown, variant: .ghostMuted, size: .iconXs)
    private let openDiff = ButtonView("Open diff", icon: .fileDiff, variant: .ghostMuted, size: .xs)
    private var rowViews: [ChangedFileRowView] = []
    private(set) var rows: [Row] = []
    private var summary: TurnDiffSummary?
    private var hasDirectories = false
    weak var model: ThreadViewModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 10
        title.lineHeight = 16
        foldAll.iconSize = 12
        openDiff.iconSize = 12
        openDiff.toolTip = "Open the full diff"
        openDiff.setAccessibilityLabel("Open diff")
        [title, total, foldAll, openDiff].forEach(addSubview)
        foldAll.action = { [weak self] in
            guard let self, let run = summary?.runId else { return }
            model?.toggleChangedFiles(run)
        }
        openDiff.action = { [weak self] in
            guard let self, let summary else { return }
            model?.onOpenTurnDiff?(summary.runId, summary.files.first?.path)
        }
    }

    /// The visible tree rows: children of open folders, depth first (`renderTreeNode`).
    static func rows(_ files: [CheckpointFile], allExpanded: Bool, overrides: [String: Bool]) -> [Row] {
        var out: [Row] = []
        func walk(_ nodes: [TurnDiffTreeNode], _ depth: Int) {
            for node in nodes {
                guard case .directory(_, let path, _, let children) = node else {
                    out.append(Row(node: node, depth: depth, expanded: false))
                    continue
                }
                let open = overrides[path] ?? allExpanded
                out.append(Row(node: node, depth: depth, expanded: open))
                if open { walk(children, depth + 1) }
            }
        }
        walk(TurnDiffTree.build(files), 0)
        return out
    }

    static func height(_ files: [CheckpointFile], allExpanded: Bool, overrides: [String: Bool]) -> CGFloat {
        rows(files, allExpanded: allExpanded, overrides: overrides).reduce(headerHeight + 16) {
            if case .directory = $1.node { return $0 + folderRowHeight }
            return $0 + rowHeight
        }
    }

    func configure(_ summary: TurnDiffSummary, allExpanded: Bool, overrides: [String: Bool]) {
        self.summary = summary
        let files = summary.files
        title.text = "\(files.count) changed file\(files.count == 1 ? "" : "s")"
        let stat = TurnDiffTree.totalStat(files)
        total.isHidden = !stat.isNonZero
        total.setInline(additions: stat.additions, deletions: stat.deletions, size: 12)
        hasDirectories = files.contains { $0.path.contains("/") || $0.path.contains("\\") }
        foldAll.isHidden = !hasDirectories
        foldAll.icon = allExpanded ? .chevronsDownUp : .chevronsUpDown
        foldAll.iconSize = 12
        let label = allExpanded ? "Collapse all folders" : "Expand all folders"
        foldAll.setAccessibilityLabel(label)
        foldAll.toolTip = label
        rows = Self.rows(files, allExpanded: allExpanded, overrides: overrides)
        let anyDirectory = rows.contains { if case .directory = $0.node { true } else { false } }
        while rowViews.count < rows.count {
            let view = ChangedFileRowView()
            rowViews.append(view)
            addSubview(view)
        }
        for (i, view) in rowViews.enumerated() {
            view.isHidden = i >= rows.count
            guard i < rows.count else { continue }
            let row = rows[i]
            view.configure(row, spacer: anyDirectory || row.depth > 0)
            view.action = { [weak self] in
                guard let self, let run = self.summary?.runId else { return }
                if case .directory(_, let path, _, _) = row.node { model?.toggleChangedFolder(run, path) } else { model?.onOpenTurnDiff?(run, row.node.path) }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let midY = Self.headerHeight / 2
        title.frame = NSRect(x: 12, y: midY - 8, width: ceil(title.textWidth), height: 16)
        // `gap-x-3`; the label's `leading-4` line on the same row.
        total.frame = NSRect(x: 12 + title.textWidth + 12, y: midY - 8, width: total.preferredWidth, height: 16)
        // "Open diff" shows its words only when the card is at least 24rem wide (`@[24rem]`).
        openDiff.title = bounds.width >= 384 ? "Open diff" : nil
        var x = bounds.width - 12
        let open = openDiff.intrinsicContentSize
        x -= open.width
        openDiff.frame = NSRect(x: x, y: midY - 12, width: open.width, height: 24)
        foldAll.frame = NSRect(x: x - 4 - 24, y: midY - 12, width: 24, height: 24)
        var y = Self.headerHeight + 8
        for (i, row) in rows.enumerated() {
            let h: CGFloat = if case .directory = row.node { Self.folderRowHeight } else { Self.rowHeight }
            rowViews[i].frame = NSRect(x: 8, y: y, width: max(0, bounds.width - 16), height: h)
            y += h
        }
    }

    override func updateLayer() {
        // `bg-secondary dark:bg-input/20`; the dark header's `bg-background` plus the same overlay
        // composites to the card's own color.
        layer?.backgroundColor = Themed.color(light: \.secondary, dark: \.input, 0.2).cgColor(in: self)
    }
}

/// One tree row: a button with `py-1.5 pr-2`, `gap-2`, left padding `8 + depth * 14`, the stat at
/// the right, and `bg-accent/60` on hover.
final class ChangedFileRowView: DSView {
    private let chevron = IconView(name: .chevronRight, size: 14, strokeColor: TL.c(\.mutedForeground, 0.7))
    private let folderOpen = IconView(name: .folder, size: 14, strokeColor: TL.c(\.mutedForeground, 0.75))
    private let folderClosed = IconView(name: .folderClosed, size: 14, strokeColor: TL.c(\.mutedForeground, 0.75))
    private var fileIcon: IconView?
    private var fileToken = ""
    private let fileName = MiddleTruncateView("", font: DSFont.mono(12))
    private let folderName = LabelView("", font: DSFont.mono(11), color: TL.c(\.mutedForeground, 0.9))
    private let stat = DiffStatView()
    private var row: ChangedFilesCardView.Row?
    private var spacer = false
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    private var tracking: NSTrackingArea?
    var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 8
        fileName.lineHeight = 16
        fileName.showsTitle = false
        folderName.lineHeight = 16.5
        [chevron, folderOpen, folderClosed, fileName, folderName, stat].forEach(addSubview)
        setAccessibilityRole(.button)
        restyle()
    }

    func configure(_ row: ChangedFilesCardView.Row, spacer: Bool) {
        self.row = row
        self.spacer = spacer
        let isDirectory: Bool
        switch row.node {
        case .directory(let name, _, let s, _):
            isDirectory = true
            folderName.text = name
            stat.isHidden = !s.isNonZero
            stat.setAligned(additions: s.additions, deletions: s.deletions, size: 10)
            chevron.frameCenterRotation = 0
            setAccessibilityExpanded(row.expanded)
        case .file(let name, let path, let s):
            isDirectory = false
            fileName.value = name
            stat.isHidden = s == nil
            if let s { stat.setAligned(additions: s.additions, deletions: s.deletions, size: 10) }
            let token = FileTypeIcon.token(for: path)
            if token != fileToken || fileIcon == nil {
                fileIcon?.removeFromSuperview()
                let icon = FileTypeIcon.view(for: path)
                addSubview(icon)
                fileIcon = icon
                fileToken = token
            }
        }
        chevron.isHidden = !isDirectory
        folderOpen.isHidden = !isDirectory || !row.expanded
        folderClosed.isHidden = !isDirectory || row.expanded
        folderName.isHidden = !isDirectory
        fileName.isHidden = isDirectory
        fileIcon?.isHidden = isDirectory
        setAccessibilityLabel(row.node.path)
        restyle()
        needsLayout = true
    }

    private func restyle() {
        fileName.color = TL.c(\.foreground, hovered ? 1 : 0.85)
        folderName.color = hovered ? TL.c(\.foreground, 0.9) : TL.c(\.mutedForeground, 0.9)
        chevron.strokeColor = hovered ? TL.c(\.foreground, 0.8) : TL.c(\.mutedForeground, 0.7)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let midY = bounds.height / 2
        var x = 8 + CGFloat(row.depth) * 14
        let statWidth = stat.isHidden ? 0 : stat.preferredWidth
        stat.frame = NSRect(x: bounds.width - 8 - statWidth, y: 0, width: statWidth, height: bounds.height)
        let nameMax = max(0, stat.frame.minX - (statWidth > 0 ? 8 : 0))
        if case .directory = row.node {
            // The chevron turns 90 degrees about its center when open.
            chevron.frameCenterRotation = 0
            chevron.frame = NSRect(x: x, y: midY - 7, width: 14, height: 14)
            if row.expanded { chevron.frameCenterRotation = 90 }
            x += 14 + 8
            folderOpen.frame = NSRect(x: x, y: midY - 7, width: 14, height: 14)
            folderClosed.frame = folderOpen.frame
            x += 14 + 8
            folderName.frame = NSRect(x: x, y: midY - 16.5 / 2, width: max(0, min(ceil(folderName.textWidth), nameMax - x)), height: 16.5)
        } else {
            if spacer { x += 14 + 8 }
            fileIcon?.frame = NSRect(x: x, y: midY - 7, width: 14, height: 14)
            x += 14 + 8
            fileName.frame = NSRect(x: x, y: midY - 8, width: max(0, min(fileName.intrinsicContentSize.width, nameMax - x)), height: 16)
        }
    }

    override func updateLayer() {
        layer?.backgroundColor = hovered ? TL.c(\.accent, 0.6).cgColor(in: self) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func viewDidHide() { super.viewDidHide(); hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}
