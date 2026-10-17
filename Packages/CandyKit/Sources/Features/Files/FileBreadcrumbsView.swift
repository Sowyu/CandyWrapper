import AppKit
import DesignSystem

/// FileBreadcrumbs.tsx: project, folders and the file, 12px, separated by 14px chevrons at 60%
/// muted. Folder crumbs open a menu of that folder's entries (folders first) that walks into
/// subfolders, with "Back to <parent>"; the current file is the checked radio item. The row
/// keeps its tail visible when it overflows (`scrollIntoView({ inline: "end" })`).
final class FileBreadcrumbsView: DSView {
    var onOpenFile: (@MainActor (String) -> Void)?
    var browse: ((String) async -> [ProjectEntry]?)?
    private var crumbs: [FileBreadcrumbs.Crumb] = []
    private var labels: [CrumbButton] = []
    private var chevrons: [ButtonView] = []
    private var path = ""
    private var trail = ""
    private var project = ""

    func set(projectName: String, path: String) {
        self.path = path == "." ? "" : path
        let isParent = self.path.isEmpty || trail.hasPrefix(self.path == "/" ? "/" : self.path + "/")
        if project != projectName || !isParent { trail = self.path }
        project = projectName
        crumbs = FileBreadcrumbs.crumbs(projectName: projectName, path: trail)
        labels.forEach { $0.removeFromSuperview() }
        chevrons.forEach { $0.removeFromSuperview() }
        let host = path.hasPrefix("/")
        labels = crumbs.map { crumb in
            let b = CrumbButton(crumb.label, current: crumb.path == self.path, interactive: crumb.path != self.path)
            b.toolTip = crumb.path.isEmpty ? projectName : crumb.path
            b.onClick = { [weak self] in
                guard let self else { return }
                self.onOpenFile?(crumb.path.isEmpty ? "." : crumb.path)
            }
            return b
        }
        chevrons = crumbs.dropLast().map { crumb in
            let button = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconXs)
            button.iconSize = 14
            button.isEnabled = !host
            button.setAccessibilityLabel("Browse " + crumb.label)
            button.action = { [weak self, weak button] in
                guard let self, let button else { return }
                self.openMenu(directory: crumb.path, root: crumb.path, from: button)
            }
            return button
        }
        labels.forEach(addSubview)
        chevrons.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Folder crumbs are a `px-0.5` button around a `px-0.5` label; the current file is the label alone.
        var widths = labels.map { min(160, $0.label.textWidth + ($0.interactive ? 8 : 4)) }
        let total = widths.reduce(0, +) + CGFloat(chevrons.count) * 22
        // Overflow scrolls in T3; here the leading crumbs give way so the file stays in view.
        var x = min(0, bounds.width - total)
        for (i, b) in labels.enumerated() {
            if i > 0 {
                chevrons[i - 1].frame = NSRect(x: x + 4, y: (bounds.height - 14) / 2, width: 14, height: 14)
                x += 22
            }
            widths[i] = max(0, widths[i])
            b.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: widths[i], height: 16)
            x += widths[i]
        }
    }

    private func openMenu(directory: String, root: String, from anchor: NSView) {
        guard let browse else { return }
        Task { [weak self] in
            let entries = await browse(directory)
            guard let self else { return }
            var items: [MenuItem] = []
            if directory != root, let parent = FileBreadcrumbs.parent(directory),
               root.isEmpty || parent == root || parent.hasPrefix(root + "/") {
                let name = parent.split(separator: "/").last.map(String.init) ?? crumbs.first?.label ?? ""
                var back = MenuItem("Back to \(name)", icon: .arrowLeft)
                back.action = { [weak self, weak anchor] in if let self, let anchor { self.openMenu(directory: parent, root: root, from: anchor) } }
                items += [back, .separator]
            }
            if let entries {
                let children = FileBreadcrumbs.children(entries, of: directory)
                if children.isEmpty { items.append(MenuItem("This folder is empty.", disabled: true)) }
                for entry in children {
                    let name = String(entry.path.dropFirst(directory.isEmpty ? 0 : directory.count + 1))
                    if entry.isDirectory {
                        var item = MenuItem(name, icon: .folder)
                        item.badge = nil
                        item.action = { [weak self, weak anchor] in if let self, let anchor { self.openMenu(directory: entry.path, root: root, from: anchor) } }
                        items.append(item)
                    } else {
                        var item = MenuItem(name, kind: .radio(entry.path == self.path))
                        item.glyph = FileTypeIcon.definition(for: entry.path)
                        item.closesOnClick = true
                        item.action = { [weak self] in self?.onOpenFile?(entry.path) }
                        items.append(item)
                    }
                }
            } else {
                items.append(MenuItem("This folder is no longer available.", disabled: true))
            }
            MenuPopupView.show(items, from: anchor, placement: .dropdown)
        }
    }
}

/// One crumb: `max-w-40 truncate rounded-sm px-0.5`; folders get `hover:bg-accent hover:text-foreground`.
final class CrumbButton: DSView {
    let label: LabelView
    let current: Bool
    let interactive: Bool
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    private var tracking: NSTrackingArea?

    init(_ text: String, current: Bool, interactive: Bool) {
        label = LabelView(text, font: DSFont.ui(12, weight: current ? .medium : .regular))
        self.current = current
        self.interactive = interactive
        super.init(frame: .zero)
        label.lineHeight = 16
        layer?.cornerRadius = 4
        addSubview(label)
        setAccessibilityRole(interactive ? .button : .staticText)
        setAccessibilityLabel(interactive ? "Browse \(text)" : text)
        restyle()
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        label.color = Themed.color(current || hovered ? \.foreground : \.mutedForeground)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: interactive ? 4 : 2, dy: 0)
    }

    override func updateLayer() {
        layer?.backgroundColor = hovered ? Themed.color(\.accent).cgColor(in: self) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard interactive else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { if interactive { onClick?() } }
}

/// DelimitedTablePreview.tsx: a bounded table, 12px, header `bg-muted/60 font-medium` with a
/// border, body rows `even:bg-muted/30` with `border-border/60`, cells `px-3 py-1.5 max-w-80`,
/// wrapping. Only the visible part is drawn, into a viewport-sized canvas over the scroller, so
/// a 100 x 30 table costs one window-sized layer.
final class DelimitedTableView: NSView {
    let rows: [[String]]
    let truncated: Bool
    private let scroll = NSScrollView()
    private let document = FlippedFileView()
    private let canvas = TableCanvas()
    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var laidOutWidth: CGFloat = -1

    static var font: NSFont { DSFont.ui(12) }
    static var headerFont: NSFont { DSFont.ui(12, weight: .medium) }

    init(text: String, delimiter: Character) {
        let parsed = DelimitedTable.parse(text, delimiter: delimiter)
        rows = parsed.rows
        truncated = parsed.truncated
        super.init(frame: .zero)
        scroll.documentView = document
        scroll.useT3Scrollbars(.native, vertical: true, horizontal: true) // `overflow-auto` (DelimitedTablePreview.tsx:25)
        scroll.drawsBackground = false
        addSubview(scroll)
        canvas.table = self
        addSubview(canvas)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipScrolled() { canvas.needsDisplay = true }

    override var isFlipped: Bool { true }

    static func size(_ text: String, font: NSFont, maxWidth: CGFloat) -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return NSSize(width: ceil(r.width), height: ceil(r.height / 16) * 16)
    }

    private func measure(width: CGFloat) {
        let columns = rows.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: columns)
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let natural = Self.size(cell, font: r == 0 ? Self.headerFont : Self.font, maxWidth: 320 - 24).width + 24
                widths[c] = max(widths[c], min(320, natural))
            }
        }
        // `min-w-full`: spare width spreads over the columns.
        let total = widths.reduce(0, +)
        if total < width, total > 0 { widths = widths.map { $0 * width / total } }
        columnWidths = widths.map { $0.rounded(.down) }
        rowHeights = rows.enumerated().map { r, row in
            let lines = row.enumerated().map { c, cell in
                Self.size(cell, font: r == 0 ? Self.headerFont : Self.font, maxWidth: max(1, columnWidths[c] - 24)).height
            }.max() ?? 16
            return max(16, lines) + 12 + 1
        }
        laidOutWidth = width
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        // Each overflowing axis gives its scrollbar a 6px lane, which can make the other axis overflow.
        let lane = ScrollAreaScroller.laneWidth
        var width = bounds.width
        if laidOutWidth != width { measure(width: width) }
        let wide = columnWidths.reduce(0, +) > width
        if rowHeights.reduce(0, +) > bounds.height - (wide ? lane : 0) {
            width -= lane
            if laidOutWidth != width { measure(width: width) }
        }
        document.frame = NSRect(x: 0, y: 0, width: max(width, columnWidths.reduce(0, +)), height: rowHeights.reduce(0, +))
        scroll.tile()
        // The table draws over the scroll view, so it stops at the clip view and leaves the lanes to the scrollbars.
        canvas.frame = scroll.contentView.frame
        canvas.needsDisplay = true
    }

    fileprivate func draw(in ctx: NSRect, offset: NSPoint) {
        let fg = Themed.color(\.foreground)
        let tableWidth = columnWidths.reduce(0, +)
        // The header sticks to the top (`sticky top-0`); body rows draw under it.
        func drawRow(_ r: Int, at top: CGFloat) {
            let h = rowHeights[r]
            if r == 0 {
                Themed.color(\.background).setFill()
                NSRect(x: -offset.x, y: top, width: tableWidth, height: h).fill()
                Themed.color(\.muted, 0.6).setFill()
                NSRect(x: -offset.x, y: top, width: tableWidth, height: h).fill(using: .sourceOver)
                Themed.color(\.border).setFill()
            } else {
                if r % 2 == 0 {
                    Themed.color(\.muted, 0.3).setFill()
                    NSRect(x: -offset.x, y: top, width: tableWidth, height: h).fill(using: .sourceOver)
                }
                Themed.color(\.border, 0.6).setFill()
            }
            NSRect(x: -offset.x, y: top + h - 1, width: tableWidth, height: 1).fill(using: .sourceOver)
            var x = -offset.x
            for (c, cell) in rows[r].enumerated() where c < columnWidths.count {
                let rect = NSRect(x: x + 12, y: top + 6, width: max(1, columnWidths[c] - 24), height: h - 13)
                (cell as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: r == 0 ? Self.headerFont : Self.font, .foregroundColor: fg])
                x += columnWidths[c]
            }
        }
        var top = (rowHeights.first ?? 0) - offset.y
        for r in rows.indices.dropFirst() {
            if top > ctx.maxY { break }
            if top + rowHeights[r] >= 0 { drawRow(r, at: top) }
            top += rowHeights[r]
        }
        if !rows.isEmpty { drawRow(0, at: 0) }
    }

    fileprivate var contentOffset: NSPoint { scroll.contentView.bounds.origin }
}

final class TableCanvas: NSView {
    weak var table: DelimitedTableView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let table else { return }
        NSGraphicsContext.current?.cgContext.clip(to: bounds)
        effectiveAppearance.performAsCurrentDrawingAppearance { table.draw(in: bounds, offset: table.contentOffset) }
    }
}
