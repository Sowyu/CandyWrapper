import AppKit
import DesignSystem
import T3Protocol

/// The "Queued" strip docked above the composer (QueuedRunsControl.tsx, ComposerBanner.tsx):
/// a header that folds the list, then one row per queued message with a reorder grip, the text,
/// Edit, Steer and Remove. J-composer-visuals section 7, behavior I-composer-flow 4.5 to 4.7.
///
/// The banner surface is the composer's glass with a 1px outline and 18px top corners; its
/// bottom 17px slide under the composer (`-mb-[calc(1rem+1px)]`) and the bottom 16px of the
/// fill are masked away. The parent places it `overlap` points into the composer and 22 in from
/// each side, below the composer in z-order.
// ponytail: draws its own banner surface; share it with the approval and question panels (Composer/Panels) once both land
public final class QueuedRunsView: DSView {
    /// `--chat-composer-attachment-overlap`: 1rem + 1px under the composer.
    public static let overlap: CGFloat = 17
    /// `--chat-composer-drawer-inset`: 1.375rem on each side.
    public static let inset: CGFloat = 22
    static let row: CGFloat = 24, pad: CGFloat = 4, listMax: CGFloat = 128

    public var state = ComposerLogic.QueueState() { didSet { if state != oldValue { rebuild() } } }
    /// The run whose message the composer edits: its row is highlighted with only Cancel.
    public var editingRunId: RunId? { didSet { if editingRunId != oldValue { rebuild() } } }
    /// A queue command is in flight: every row action is disabled (`busyRunId`).
    public var isBusy = false { didSet { if isBusy != oldValue { rebuild() } } }
    public private(set) var expanded = true

    public var onEdit: ((ComposerLogic.QueueState.Item) -> Void)?
    public var onCancelEdit: (() -> Void)?
    public var onSteer: ((RunId) -> Void)?
    public var onRemove: ((RunId) -> Void)?
    /// Move a run before another, or to the end (nil).
    public var onReorder: ((RunId, RunId?) -> Void)?
    public var onHeightChange: (() -> Void)?

    /// The strip's full height including the hidden overlap; 0 with nothing queued.
    public var preferredHeight: CGFloat {
        guard !state.items.isEmpty else { return 0 }
        return Self.pad * 2 + Self.row + listHeight + Self.overlap
    }

    private var listHeight: CGFloat {
        guard expanded, !state.items.isEmpty else { return 0 }
        let n = CGFloat(state.items.count)
        return min(Self.listMax, n * Self.row + (n - 1))
    }

    // Surface: the clip cuts the glass and outline 16px above the bottom (`mask-t-from-4`).
    private let clip = DSView()
    private let glass = DSView()
    private let outline = DSView()
    /// Dark only: `composer-seam-above`, 10px of black/18% fading up from the overlap line.
    private let seam = CAGradientLayer()

    private let header = HeaderRow()
    private let scroll = NSScrollView()
    private let list = DSView()
    private var rows: [QueuedRowView] = []
    private var drag: (index: Int, insert: Int?)?
    private let insertLine = DSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clip.clipsToBounds = true
        addSubview(clip)
        // The composer's glass: `card` / `surface-raised` at 80% over a 12px blur, saturate 1.14.
        glass.layerUsesCoreImageFilters = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 12]),
           let saturate = CIFilter(name: "CIColorControls", parameters: ["inputSaturation": 1.14, "inputBrightness": 0, "inputContrast": 1]) {
            glass.layer?.backgroundFilters = [saturate, blur]
        }
        clip.addSubview(glass)
        outline.layer?.cornerRadius = 18
        outline.layer?.borderWidth = 1
        clip.addSubview(outline)
        clip.layer?.addSublayer(seam)

        header.action = { [weak self] in self?.toggle() }
        addSubview(header)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
        insertLine.isHidden = true
        insertLine.layer?.cornerRadius = 1
        list.addSubview(insertLine)
        setAccessibilityRole(.group)
    }

    private func toggle() {
        expanded.toggle()
        header.expanded = expanded
        scroll.isHidden = !expanded
        needsLayout = true
        onHeightChange?()
    }

    // MARK: Rows

    private func rebuild() {
        let before = preferredHeight
        header.count = state.items.count
        setAccessibilityLabel("\(state.items.count) queued message\(state.items.count == 1 ? "" : "s")")
        while rows.count < state.items.count {
            let row = QueuedRowView()
            row.owner = self
            list.addSubview(row, positioned: .below, relativeTo: insertLine)
            rows.append(row)
        }
        while rows.count > state.items.count { rows.removeLast().removeFromSuperview() }
        for (i, item) in state.items.enumerated() {
            let row = rows[i]
            row.index = i
            row.configure(item, editing: item.runId != nil && item.runId == editingRunId,
                          canReorder: state.canReorder && item.runId != nil, busy: isBusy || item.runId == nil,
                          canSteer: state.canPromoteToSteer)
        }
        needsLayout = true
        if preferredHeight != before { onHeightChange?() }
    }

    fileprivate func edit(_ i: Int) { if state.items.indices.contains(i) { onEdit?(state.items[i]) } }
    fileprivate func cancelEdit() { onCancelEdit?() }
    fileprivate func steer(_ i: Int) { if let id = state.items[safe: i]?.runId { onSteer?(id) } }
    fileprivate func remove(_ i: Int) { if let id = state.items[safe: i]?.runId { onRemove?(id) } }

    // MARK: Drag to reorder (QueuedRunsControl.tsx:168-206)

    fileprivate func dragMoved(_ i: Int, event: NSEvent) {
        let y = list.convert(event.locationInWindow, from: nil).y
        // The half of the row under the pointer picks the insert position.
        let slot = Int(((y + 0.5) / (Self.row + 1)).rounded(.down))
        let within = y - CGFloat(slot) * (Self.row + 1)
        let insert = max(0, min(state.items.count, within < Self.row / 2 ? slot : slot + 1))
        drag = (i, insert)
        rows[safe: i]?.alphaValue = 0.5
        insertLine.isHidden = false
        let lineY = insert < state.items.count ? CGFloat(insert) * (Self.row + 1) : CGFloat(state.items.count) * (Self.row + 1) - 1 - 2
        insertLine.frame = NSRect(x: 0, y: lineY, width: list.bounds.width, height: 2)
    }

    fileprivate func dragEnded() {
        guard let (i, insert) = drag else { return }
        drag = nil
        rows[safe: i]?.alphaValue = 1
        insertLine.isHidden = true
        guard let insert, let runId = state.items[safe: i]?.runId,
              case .some(let before) = ComposerLogic.QueueState.reorderTarget(state.items, moving: i, to: insert) else { return }
        onReorder?(runId, before)
    }

    // MARK: Drawing and layout

    public override func updateLayer() {
        let dark = effectiveAppearance.isDark
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glass.layer?.backgroundColor = Themed.color(light: \.card, 0.8, dark: \.surfaceRaised, 0.8).cgColor(in: self)
        outline.layer?.borderColor = (dark ? Themed.white(0.05) : Themed.black(0.08)).cgColor
        seam.isHidden = !dark
        seam.colors = [Themed.black(0).cgColor, Themed.black(0.18).cgColor]
        insertLine.layer?.backgroundColor = Themed.color(\.primary, 0.7).cgColor(in: self)
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        clip.frame = NSRect(x: 0, y: 0, width: w, height: max(0, h - 16))
        glass.frame = NSRect(x: 0, y: 0, width: w, height: h)
        outline.frame = glass.frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Flipped: the gradient runs from y (top, clear) to the overlap line (black/18%).
        seam.frame = CGRect(x: 0, y: h - Self.overlap - 10, width: w, height: 10)
        CATransaction.commit()
        let inner = w - 2 * Self.pad
        header.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: Self.row)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad + Self.row, width: inner, height: listHeight)
        let n = CGFloat(rows.count)
        let full = max(0, n * Self.row + (n - 1))
        // ponytail: no scroll fade and no `pe-2` scrollbar gutter when the list overflows 128pt; add with long queues
        list.frame = NSRect(x: 0, y: 0, width: inner, height: full)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (Self.row + 1), width: inner, height: Self.row)
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Labels on the glass draw without font smoothing, like Chromium on backdrop-filter layers.
private func bannerLabel(_ color: NSColor, weight: NSFont.Weight = .regular) -> LabelView {
    let label = LabelView("", font: DSFont.ui(12, weight: weight), color: color)
    label.lineHeight = 16
    label.smoothsFont = false
    return label
}

private func bannerButton(_ title: String?, icon: IconName, variant: ButtonView.Variant, size: ButtonView.Size, tip: String) -> ButtonView {
    let button = ButtonView(title, icon: icon, variant: variant, size: size)
    button.smoothsFont = false
    button.setAccessibilityLabel(tip)
    return button
}

/// The header button: list icon, "Queued", the count and the fold chevron (24px ghost box).
private final class HeaderRow: ControlView {
    private let icon = IconView(name: .listOrdered, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let title = bannerLabel(Themed.color(\.mutedForeground))
    private let countLabel = bannerLabel(Themed.color(\.mutedForeground), weight: .medium)
    /// `ChevronDownIcon` turned 180 degrees while folded: the up chevron.
    private let chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.foreground))
    private let chevronUp = IconView(name: .chevronUp, size: 14, strokeColor: Themed.color(\.foreground))
    var count = 0 { didSet { countLabel.text = "\(count)"; needsLayout = true } }
    var expanded = true {
        didSet {
            chevron.isHidden = !expanded
            chevronUp.isHidden = expanded
            setAccessibilityLabel(expanded ? "Collapse queued messages" : "Expand queued messages")
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        title.text = "Queued"
        chevronUp.isHidden = true
        [icon, title, countLabel, chevron, chevronUp].forEach(addSubview)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Collapse queued messages")
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        title.frame = NSRect(x: 28, y: 4, width: max(0, w - 28 - 56), height: 16)
        // Actions (`gap-1`): the count centered in 24, then the 24px toggle box.
        let cw = max(24, ceil(countLabel.textWidth))
        countLabel.frame = NSRect(x: w - 24 - 4 - cw + (cw - ceil(countLabel.textWidth)) / 2, y: 4, width: ceil(countLabel.textWidth), height: 16)
        chevron.frame = NSRect(x: w - 24 + 5, y: 5, width: 14, height: 14)
        chevronUp.frame = chevron.frame
    }
}

/// One queued message: grip, text, then Edit, Steer and Remove, or Cancel while editing.
private final class QueuedRowView: DSView {
    weak var owner: QueuedRunsView?
    var index = 0
    private let grip = GripView()
    private let saving = IconView(name: .clock3, size: 12, strokeColor: Themed.color(\.mutedForeground, 0.6))
    private let text = bannerLabel(Themed.color(\.foreground, 0.8))
    private let edit = bannerButton(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs, tip: "Edit in the composer")
    private let steer = bannerButton("Steer", icon: .cornerUpRight, variant: .ghostMuted, size: .xs, tip: "Send as a steer instead")
    private let remove = bannerButton(nil, icon: .x, variant: .ghost, size: .iconXs, tip: "Remove from queue")
    private let cancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private var editing = false
    private lazy var textTip = TooltipController.attach(to: text, text: "")
    private lazy var steerTip = TooltipController.attach(to: steer, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 6
        cancel.smoothsFont = false
        cancel.setAccessibilityLabel("Cancel editing queued message")
        [grip, saving, text, edit, steer, remove, cancel].forEach(addSubview)
        TooltipController.attach(to: edit, text: "Edit in the composer")
        TooltipController.attach(to: remove, text: "Remove from queue")
        grip.onDrag = { [weak self] event in guard let self else { return }; owner?.dragMoved(index, event: event) }
        grip.onDragEnd = { [weak self] in self?.owner?.dragEnded() }
        edit.action = { [weak self] in guard let self else { return }; owner?.edit(index) }
        steer.action = { [weak self] in guard let self else { return }; owner?.steer(index) }
        remove.action = { [weak self] in guard let self else { return }; owner?.remove(index) }
        cancel.action = { [weak self] in self?.owner?.cancelEdit() }
    }

    func configure(_ item: ComposerLogic.QueueState.Item, editing: Bool, canReorder: Bool, busy: Bool, canSteer: Bool) {
        self.editing = editing
        text.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        textTip.text = text.text
        text.color = editing ? Themed.color(\.accentForeground) : Themed.color(\.foreground, 0.8)
        saving.isHidden = item.runId != nil
        grip.isHidden = !canReorder
        grip.isEnabled = !busy
        for b in [edit, steer, remove] { b.isHidden = editing; b.isEnabled = !busy }
        steer.isEnabled = !busy && canSteer
        steerTip.text = canSteer ? "Send as a steer instead" : "There is no active run to steer"
        cancel.isHidden = !editing
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        layer?.backgroundColor = editing ? Themed.color(\.accent).cgColor(in: self) : nil
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        grip.frame = NSRect(x: 0, y: 0, width: 24, height: h)
        // Actions right to left with `gap-1`.
        var right = bounds.width
        let visible = editing ? [cancel] : [remove, steer, edit]
        for b in visible {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: (h - s.height) / 2, width: s.width, height: s.height)
            right -= 4
        }
        var x: CGFloat = 28
        if !saving.isHidden {
            saving.frame = NSRect(x: x, y: (h - 12) / 2, width: 12, height: 12)
            x += 12 + 4
        }
        text.frame = NSRect(x: x, y: (h - 16) / 2, width: max(0, right - x), height: 16)
    }
}

/// The reorder grip, drawn like a 24px `ghost-muted icon-xs` button: `grip-vertical` 14px in
/// `muted`, hover fills `accent` and turns the icon `foreground`. A drag past 3pt moves its row.
// ponytail: no arrow-key reordering on a focused grip (QueuedRunsControl.tsx:350-359); add with keyboard focus for banner rows
private final class GripView: ControlView {
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private let icon = IconView(name: .gripVertical, size: 14, strokeColor: Themed.color(\.mutedForeground))
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.cornerRadius = 8
        addSubview(icon)
        setAccessibilityLabel("Reorder queued message (drag)")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    override func updateLayer() {
        layer?.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : nil
        icon.strokeColor = state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) < 3 { continue }
            if !dragging { dragging = true; NSCursor.closedHand.push() }
            onDrag?(next)
        }
        if dragging { NSCursor.pop(); dragging = false; onDragEnd?() }
    }
}
