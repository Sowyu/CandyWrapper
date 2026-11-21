import AppKit
import DesignSystem

/// `FileExplorerPane` with `resizable` (4928 files/FileExplorerPane.tsx, #28244): the file list
/// column beside a diff. The Changes list and the PR Code list share one saved width
/// (`t3code:diff-file-tree-width`); a width the reader chose overrides the responsive default.
public enum FileListWidth {
    public static let storageKey = "t3code:diff-file-tree-width"
    static let maxWidth: CGFloat = 560
    /// What the diff keeps beside the list.
    static let contentMinWidth: CGFloat = 256

    public struct Sizing: Equatable, Sendable {
        public var defaultWidth: CGFloat
        public var fraction: CGFloat?
        public var minWidth: CGFloat
        /// Where the chosen width is saved.
        public var storageKey = FileListWidth.storageKey
        /// Changes: `defaultWidthFraction={0.4}` over the 256 default, minimum 160.
        public static let changes = Sizing(defaultWidth: 256, fraction: 0.4, minWidth: 160)
        /// PR Code: 320 at most 40% of the row, minimum 192.
        public static let pullRequestCode = Sizing(defaultWidth: 320, fraction: 0.4, minWidth: 192)
        /// The Files explorer beside an open file (FileExplorerPane.tsx defaults, #25737): 256, minimum 160, saved apart.
        public static let filesExplorer = Sizing(defaultWidth: 256, fraction: nil, minWidth: 160, storageKey: "t3code.fileExplorerWidth")
    }

    /// `measure` (FileExplorerPane.tsx:50-62): the initial width and the largest one for a row.
    public static func bounds(row: CGFloat, _ s: Sizing) -> (initial: CGFloat, max: CGFloat) {
        let initial = max(s.minWidth, min(s.defaultWidth, row * (s.fraction ?? 1)))
        // A responsive default must not shrink to make room for the content reserve.
        let available = max(row - contentMinWidth, s.fraction == nil ? s.minWidth : initial)
        return (initial, max(s.minWidth, min(maxWidth, available)))
    }

    /// `useResizableWidth`'s clamp over the saved width, or the default.
    public static func width(row: CGFloat, _ s: Sizing, saved: CGFloat?) -> CGFloat {
        let b = bounds(row: row, s)
        guard let saved, saved.isFinite else { return b.initial }
        return max(s.minWidth, min(b.max, saved))
    }

    public static var saved: CGFloat? {
        get { saved(storageKey) }
        set { save(newValue, storageKey) }
    }
    public static func saved(_ key: String) -> CGFloat? { (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) } }
    public static func save(_ width: CGFloat?, _ key: String) { UserDefaults.standard.set(width.map(Double.init), forKey: key) }
    /// Tells every open list that the shared width changed.
    public static let didChange = Notification.Name("FileListWidth.didChange")
}

/// `RightPanelResizeHandle` on the list's left edge (RightPanelResizeHandle.tsx:18-39): an 8pt hit
/// area centered on the border, a 1px line that turns `border` on hover and `primary/60` while
/// dragging, focusable with Left and Right (16pt), Home and End (FileExplorerPane.tsx:85-110).
public final class FileListResizeHandle: DSView {
    /// The width the drag or key asks for; the owner clamps and lays out.
    public var onResize: ((CGFloat) -> Void)?
    /// The drag ended (or a key moved it): persist now, not every frame.
    public var onCommit: (() -> Void)?
    public var currentWidth: () -> CGFloat = { 0 }
    public var limits: () -> (min: CGFloat, max: CGFloat) = { (0, 0) }
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var moved = false
    private let line = CALayer()
    private var hovered = false { didSet { if hovered != oldValue { redisplay(transitioning: [.background]) } } }
    private var pressed = false { didSet { if pressed != oldValue { redisplay(transitioning: [.background]) } } }

    public init(label: String) {
        super.init(frame: .zero)
        line.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(label)
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }

    public override func accessibilityValue() -> Any? { Int(currentWidth()) }
    public override func accessibilityPerformIncrement() -> Bool { step(16); return true }
    public override func accessibilityPerformDecrement() -> Bool { step(-16); return true }

    public override func layout() {
        super.layout()
        line.frame = NSRect(x: (bounds.width / 2).rounded(.down), y: 0, width: 1, height: bounds.height)
    }

    public override func updateLayer() {
        let color: NSColor? = pressed ? Themed.color(\.primary, 0.6) : hovered ? Themed.color(\.border) : nil
        Motion.setBackground(line, color?.cgColor(in: self))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true }
    public override func mouseExited(with event: NSEvent) { hovered = false }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    public override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x; startWidth = currentWidth(); moved = false; pressed = true
    }
    public override func mouseDragged(with event: NSEvent) {
        // The list grows as the left edge moves left.
        let b = limits()
        let next = max(b.min, min(b.max, startWidth + startX - event.locationInWindow.x))
        moved = true
        onResize?(next)
    }
    public override func mouseUp(with event: NSEvent) {
        pressed = false
        hovered = bounds.contains(convert(event.locationInWindow, from: nil))
        if moved { onCommit?() }
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        let b = limits()
        switch event.keyCode {
        case 123: step(16)
        case 124: step(-16)
        case 115: onResize?(b.min); onCommit?()
        case 119: onResize?(b.max); onCommit?()
        default: super.keyDown(with: event)
        }
    }

    private func step(_ delta: CGFloat) {
        let b = limits()
        onResize?(max(b.min, min(b.max, currentWidth() + delta)))
        onCommit?()
    }
}

/// `FileExplorerPane` holding `DiffFileTree` (4928 diffs/DiffFileTree.tsx:190-260): the list column
/// on the right of a diff, `border-l border-border/60`, an `h-10 border-b` header with "Files", the
/// count and expand or collapse all, the tree, an optional footer, and the drag handle on its edge.
/// The owner places it with `width(row:)`.
public final class FileListPane: DSView {
    public let tree = FileTreeView()
    private let scroll: ScrollAreaView
    private let title = LabelView("Files", font: DSFont.ui(12, weight: .medium))
    private let count = LabelView("", font: DSFont.ui(12))
    private let expansion = ButtonView(nil, icon: .chevronsDownUp, variant: .ghost, size: .iconXs)
    private let border = CALayer()
    private let headerBorder = CALayer()
    private let footerBorder = CALayer()
    public let handle: FileListResizeHandle
    public let sizing: FileListWidth.Sizing
    /// A footer under the tree (`border-t p-2`), such as PR Code's Load more files.
    public var footer: NSView? { didSet { oldValue?.removeFromSuperview(); footer.map(addSubview); needsLayout = true } }
    /// The width while a drag runs, before it is saved.
    private var live: CGFloat?
    private var rowWidth: CGFloat = 0
    private var observer: NSObjectProtocol?
    /// The width changed (a drag here, or the other list saved one): the owner lays out again.
    public var onWidthChange: (() -> Void)?

    public init(sizing: FileListWidth.Sizing, resizeLabel: String, listLabel: String) {
        self.sizing = sizing
        handle = FileListResizeHandle(label: resizeLabel)
        scroll = ScrollAreaView(documentView: tree)
        super.init(frame: .zero)
        for l in [border, headerBorder, footerBorder] {
            l.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
        }
        layer?.masksToBounds = false
        title.lineHeight = 16
        count.lineHeight = 16
        count.alignment = .right
        expansion.iconSize = 14
        expansion.action = { [weak self] in
            guard let self else { return }
            _ = self.tree.model.setAllExpanded(!self.tree.model.allExpanded)
            self.needsLayout = true
        }
        tree.setAccessibilityLabel(listLabel)
        [scroll, title, count, expansion].forEach(addSubview)
        handle.currentWidth = { [weak self] in self.map { $0.width(row: $0.rowWidth) } ?? 0 }
        handle.limits = { [weak self] in
            guard let self else { return (0, 0) }
            return (self.sizing.minWidth, FileListWidth.bounds(row: self.rowWidth, self.sizing).max)
        }
        handle.onResize = { [weak self] w in self?.live = w; self?.onWidthChange?() }
        handle.onCommit = { [weak self] in
            guard let self, let w = self.live else { return }
            self.live = nil
            FileListWidth.save(w, self.sizing.storageKey)
            NotificationCenter.default.post(name: FileListWidth.didChange, object: nil)
        }
        observer = NotificationCenter.default.addObserver(forName: FileListWidth.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWidthChange?() }
        }
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The width in a row this wide: the live drag, the saved width clamped, or the default.
    public func width(row: CGFloat) -> CGFloat {
        rowWidth = row
        return live ?? FileListWidth.width(row: row, sizing, saved: FileListWidth.saved(sizing.storageKey))
    }

    /// Places the pane at the right of `rect` and the handle over its left border, in `host`.
    public func place(in rect: NSRect, host: NSView) -> CGFloat {
        let w = width(row: rect.width)
        frame = NSRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height)
        if handle.superview !== host { host.addSubview(handle, positioned: .above, relativeTo: self) }
        handle.isHidden = isHidden
        handle.frame = NSRect(x: frame.minX - 4, y: rect.minY, width: 8, height: rect.height)
        return w
    }

    public override var isHidden: Bool { didSet { handle.isHidden = isHidden } }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let footerH: CGFloat = footer == nil ? 0 : 1 + 8 + 24 + 8
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        headerBorder.frame = CGRect(x: 1, y: 39, width: max(0, w - 1), height: 1)
        footerBorder.isHidden = footer == nil
        footerBorder.frame = CGRect(x: 1, y: bounds.height - footerH, width: max(0, w - 1), height: 1)
        CATransaction.commit()
        // `px-2`, "Files" in `px-1`, the count `ml-auto`, then the button.
        title.frame = NSRect(x: 13, y: 12, width: 60, height: 16)
        expansion.isHidden = tree.model.directoryPaths.isEmpty
        let right = expansion.isHidden ? w - 9 : w - 9 - 24 - 4
        expansion.frame = NSRect(x: w - 9 - 24, y: 8, width: 24, height: 24)
        expansion.icon = tree.model.allExpanded ? .chevronsDownUp : .chevronsUpDown
        expansion.setTooltip(tree.model.allExpanded ? "Collapse all folders" : "Expand all folders")
        expansion.setAccessibilityLabel(expansion.currentTooltip)
        count.text = String(tree.model.directories.values.flatMap { $0 }.filter { !$0.isDirectory }.count)
        count.frame = NSRect(x: right - 40, y: 12, width: 40, height: 16)
        scroll.frame = NSRect(x: 1, y: 40, width: max(0, w - 1), height: max(0, bounds.height - 40 - footerH))
        footer?.frame = NSRect(x: 9, y: bounds.height - footerH + 9, width: max(0, w - 17), height: 24)
    }

    public override func updateLayer() {
        layer?.backgroundColor = WindowGlass.ground.cgColor(in: self)
        for l in [border, headerBorder, footerBorder] { l.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }
        title.color = Themed.color(\.foreground)
        count.color = Themed.color(\.mutedForeground)
    }
}
