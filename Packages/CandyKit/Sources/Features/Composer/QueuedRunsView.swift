import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The "Queued" strip docked above the composer (QueuedRunsControl.tsx, ComposerBanner.tsx):
/// a header that folds the list, then one row per queued message with the text,
/// Send now, Edit and Remove. J-composer-visuals section 7, behavior I-composer-flow 4.5 to 4.7.
///
/// The surface is T3's shared `ComposerBanner.Root` (neutral), so this is a `ComposerBannerView`
/// like the approval and question panels. The parent places it `overlap` points into whatever
/// sits below it (the composer or a request panel) and `drawerInset` in from each side.
public final class QueuedRunsView: ComposerBannerView {
    static let row: CGFloat = 24, pad: CGFloat = 4, listMax: CGFloat = 128

    public var state = ComposerLogic.QueueState() { didSet { if state != oldValue { rebuild() } } }
    /// The run whose message the composer edits: its row is highlighted with only Cancel.
    public var editingRunId: RunId? { didSet { if editingRunId != oldValue { rebuild() } } }
    /// A queue command is in flight: every row action is disabled (`busyRunId`).
    public var isBusy = false { didSet { if isBusy != oldValue { rebuild() } } }
    public var editBlockedReason: String? { didSet { if editBlockedReason != oldValue { rebuild() } } }
    public private(set) var expanded = true

    public var attachmentMediaURL: (@Sendable (String) async -> URL?)?
    public var threadTitle: ((ThreadId) -> String?)?
    public var senderThreadTitles: [String: String] = [:] { didSet { if senderThreadTitles != oldValue { rebuild() } } }
    public var scheduledTaskTitles: [String: String] = [:] { didSet { if scheduledTaskTitles != oldValue { rebuild() } } }
    public var onOpenThread: ((ThreadId) -> Void)?
    public var onOpenScheduledTask: ((String) -> Void)?
    public var onEdit: ((ComposerLogic.QueueState.Item) -> Void)?
    public var onCancelEdit: (() -> Void)?
    public var onSteer: ((RunId) -> Void)?
    public var onRemove: ((RunId) -> Void)?
    public var onReorder: ((RunId, RunId?) -> Void)?
    /// The height or the count changed (Redesign's pill shows the count while the list is closed).
    public var onHeightChange: (() -> Void)?
    /// `thread.editQueuedMessage` and `thread.steerQueuedMessage` labels for the last row's Edit and
    /// the first row's Steer tooltips (ChatView.tsx:11638-11647, QueuedRunsControl.tsx:442, :468).
    public var editShortcutLabel: String? = "\u{2325}Up"
    public var steerShortcutLabel: String? = "\u{21E7}\u{2318}Enter"

    /// The strip's full height including the hidden overlap; 0 with nothing queued.
    public var preferredHeight: CGFloat {
        guard !state.items.isEmpty else { return 0 }
        if modern { return height(forWidth: bounds.width > 0 ? bounds.width : 736) }
        return Self.pad * 2 + Self.row + listHeight + Self.overlap
    }

    private var listHeight: CGFloat {
        guard expanded, !state.items.isEmpty else { return 0 }
        return min(Self.listMax, state.items.reduce(CGFloat(0)) { $0 + rowHeight($1) + 1 } - 1)
    }

    private func rowHeight(_ item: ComposerLogic.QueueState.Item) -> CGFloat { !modern || item.message == nil ? Self.row : Self.row + 18 }

    private var showAllQueue = false
    private let more = QueueInlineAction()
    private var visibleCount: Int { modern && state.items.count > 3 && !showAllQueue ? 2 : state.items.count }

    public func height(forWidth width: CGFloat) -> CGFloat {
        guard modern else { return preferredHeight }
        let visible = rows.prefix(visibleCount).compactMap { $0 as? ModernQueuedRowView }
        return visible.reduce(CGFloat(0)) { $0 + $1.height(forWidth: width) } + CGFloat(max(0, visible.count - 1)) * 12
            + (state.items.count > 3 ? 24 : 0) + (state.items.isEmpty ? 0 : 16)
    }

    private let header = HeaderRow()
    private let scroll = NSScrollView()
    private let list = DSView()
    private var rows: [DSView] = []
    private var modern: Bool { !ThemeRuntime.isDither(dark: effectiveAppearance.isDark) && !ThemeRuntime.isGlass(dark: effectiveAppearance.isDark) }
    private var drag: (index: Int, insert: Int?)?
    private let insertLine = DSView()

    public init() {
        super.init(variant: .neutral)
        header.action = { [weak self] in self?.toggle() }
        addSubview(header)
        addSubview(more)
        more.action = { [weak self] in self?.toggle() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.useT3Scrollbars(.overlay) // ComposerBanner.Scroll is a ScrollArea (QueuedRunsControl.tsx:272)
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
        insertLine.isHidden = true
        insertLine.layer?.cornerRadius = 1
        list.addSubview(insertLine)
        setAccessibilityRole(.group)
    }

    /// `setExpanded(true)` before editing the latest queued message.
    public func expand() { if modern { showAllQueue = true; needsLayout = true; onHeightChange?() } else if !expanded { toggle() } }

    /// Redesign shows the list as a panel over its Queued pill: open while expanded, the pill and the header toggle it.
    public func toggle() {
        if modern { showAllQueue.toggle(); needsLayout = true; onHeightChange?(); return }
        expanded.toggle()
        header.expanded = expanded
        scroll.isHidden = !expanded
        needsLayout = true
        onHeightChange?()
    }

    // MARK: Rows

    private func rebuild() {
        let before = preferredHeight, count = rows.count
        // Redesign's panel starts closed each time the queue fills; the pill shows the count (the user, 2026-10-22).
        if rows.isEmpty, !state.items.isEmpty, placement == .floating, expanded { toggle() }
        header.count = state.items.count
        setAccessibilityLabel("\(state.items.count) queued message\(state.items.count == 1 ? "" : "s")")
        if let row = rows.first, (row is ModernQueuedRowView) != modern {
            rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
        }
        if modern {
        while rows.count < state.items.count {
            let row = ModernQueuedRowView()
            row.owner = self
            list.addSubview(row)
            rows.append(row)
        }
        while rows.count > state.items.count { rows.removeLast().removeFromSuperview() }
        let queued = state.items.filter { $0.runId != nil }.count
        for (i, item) in state.items.enumerated() {
            let row = rows[i] as! ModernQueuedRowView
            row.index = i
            row.configure(item, editing: item.runId != nil && item.runId == editingRunId,
                          busy: isBusy || item.runId == nil,
                          canSend: state.canSendNow || state.canPromoteToSteer,
                          editBlocked: editBlockedReason != nil,
                          editTip: editBlockedReason ?? "Edit in the composer" + (i == queued - 1 && item.runId != nil ? editShortcutLabel.map { " (\($0))" } ?? "" : ""),
                          steerTip: (state.canSendNow ? "Start a turn with this message" : state.promoteSkipsCompaction ? "Skip compaction and send this message" : "Send into the current turn")
                            + (i == 0 ? steerShortcutLabel.map { " (\($0))" } ?? "" : ""))
        }
        } else {
        while rows.count < state.items.count {
            let row = QueuedRowView()
            row.owner = self
            list.addSubview(row, positioned: .below, relativeTo: insertLine)
            rows.append(row)
        }
        // Rows are reused by position; a focused grip follows its run, as React's keyed rows do.
        let legacyRows = rows.compactMap { $0 as? QueuedRowView }
        let focused = legacyRows.first { $0.window?.firstResponder === $0.grip && $0.runId != nil }
        let focusedRun = focused?.runId, focusedVisibly = focused?.grip.state.focusVisible == true
        while rows.count > state.items.count { rows.removeLast().removeFromSuperview() }
        let queued = state.items.filter { $0.runId != nil }.count
        for (i, item) in state.items.enumerated() {
            let row = rows[i] as! QueuedRowView
            row.index = i
            row.configure(item, editing: item.runId != nil && item.runId == editingRunId,
                          canReorder: state.canReorder && item.runId != nil, busy: isBusy || item.runId == nil,
                          canSend: state.canSendNow || state.canPromoteToSteer, sendNow: state.canSendNow,
                          editBlocked: editBlockedReason != nil,
                          editTip: editBlockedReason ?? "Edit in the composer" + (i == queued - 1 && item.runId != nil ? editShortcutLabel.map { " (\($0))" } ?? "" : ""),
                          steerTip: (state.canSendNow ? "Start a turn with this message" : "Send as a steer instead")
                            + (i == 0 ? steerShortcutLabel.map { " (\($0))" } ?? "" : ""))
        }
        if let focusedRun, let row = legacyRows.first(where: { $0.runId == focusedRun }), row !== focused, let window {
            window.makeFirstResponder(row.grip)
            if focusedVisibly { var s = row.grip.state; s.focusVisible = true; row.grip.previewState(s) }
        }
        }
        needsLayout = true
        if preferredHeight != before || state.items.count != count { onHeightChange?() }
    }

    func edit(_ i: Int) { if editBlockedReason == nil, !isBusy, state.items.indices.contains(i), state.items[i].isEditable { onEdit?(state.items[i]) } }
    fileprivate func cancelEdit() { onCancelEdit?() }
    fileprivate func steer(_ i: Int) { if let id = state.items[safe: i]?.runId { onSteer?(id) } }
    fileprivate func remove(_ i: Int) { if let id = state.items[safe: i]?.runId { onRemove?(id) } }

    // MARK: Keyboard reorder (QueuedRunsControl.tsx:350-359)

    /// ArrowUp on a focused grip moves the run before the previous one; ArrowDown moves it before the
    /// run two below (or to the end). Nothing happens at the edges or while a queue command runs.
    func moveByKey(_ i: Int, up: Bool) -> Bool {
        let queued = state.items.compactMap(\.runId)
        guard state.canReorder, !isBusy, let runId = state.items[safe: i]?.runId, let index = queued.firstIndex(of: runId) else { return false }
        if up {
            guard index > 0 else { return false }
            onReorder?(runId, queued[index - 1])
        } else {
            guard index < queued.count - 1 else { return false }
            onReorder?(runId, queued[safe: index + 2])
        }
        return true
    }

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

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    public override func updateLayer() {
        quietTimelineLine = modern
        super.updateLayer()
        insertLine.layer?.backgroundColor = Themed.color(\.primary, 0.7).cgColor(in: self)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        header.isHidden = modern
        more.isHidden = !modern || state.items.count <= 3
        if modern {
            scroll.isHidden = false
            scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, bounds.height - 16))
            list.frame = scroll.bounds
            var y: CGFloat = 0
            for (i, row) in rows.enumerated() {
                row.isHidden = i >= visibleCount
                guard !row.isHidden, let row = row as? ModernQueuedRowView else { continue }
                let height = row.height(forWidth: w)
                row.frame = NSRect(x: 0, y: y, width: w, height: height)
                y += height + 12
            }
            more.title = showAllQueue ? "Show fewer" : "Show all \(state.items.count) queued"
            let size = more.intrinsicContentSize
            more.frame = NSRect(x: max(0, w - 4 - size.width), y: max(0, y - 4), width: size.width, height: 16)
            return
        }
        scroll.isHidden = !expanded
        let inner = w - 2 * Self.pad
        header.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: Self.row)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad + Self.row, width: inner, height: listHeight)
        let full = max(0, state.items.reduce(CGFloat(0)) { $0 + rowHeight($1) + 1 } - 1)
        // ponytail: no scroll fade and no `pe-2` scrollbar gutter when the list overflows 128pt; add with long queues
        list.frame = NSRect(x: 0, y: 0, width: inner, height: full)
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let height = rowHeight(state.items[i])
            row.frame = NSRect(x: 0, y: y, width: inner, height: height)
            y += height + 1
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

/// One queued message with Send now, Edit and Remove, or Cancel while editing.
/// 3814 QueuedRunsControl.tsx:238-555: an unsent turn in a dashed bubble, then its actions.
private final class ModernQueuedRowView: DSView {
    weak var owner: QueuedRunsView?
    var index = 0
    private let bubble = DSView()
    private let outline = CAShapeLayer()
    private let text = TextBlockView()
    private let fold = FoldedMessageHeaderView()
    private let sender = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))
    private let timestamp = LabelView("", font: SB.tabular(12), color: Themed.color(\.mutedForeground))
    private let source = QueueInlineAction()
    private let edit = bannerButton(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs, tip: "Edit queued message")
    private let send = bannerButton("Send now", icon: .arrowUp, variant: .ghostMuted, size: .xs, tip: "Send now")
    private let remove = bannerButton(nil, icon: .x, variant: .ghostMuted, size: .iconXs, tip: "Remove from queue")
    private let cancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private var message: ChatMessage?
    private var thumbnailIds: [String] = []
    private var thumbnails: [DSView] = []
    private var thumbnailTask: Task<Void, Never>?
    private var folded = false, open = false, editing = false, guest = false
    private var tracking: NSTrackingArea?
    private var hovered = false
    private lazy var sendTip = TooltipController.attach(to: send, text: "")
    private lazy var editTip = TooltipController.attach(to: edit, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.font = DSFont.ui(14); text.lineHeight = 20
        sender.lineHeight = 16; timestamp.lineHeight = 16; status.lineHeight = 16
        bubble.layer?.addSublayer(outline)
        outline.fillColor = nil; outline.lineWidth = 1; outline.lineDashPattern = [3, 3]
        outline.actions = ["path": NSNull(), "strokeColor": NSNull()]
        bubble.addSubview(text); bubble.addSubview(fold)
        for view in [bubble, sender, timestamp, source, send, edit, remove, cancel, status] as [NSView] { addSubview(view) }
        for button in [send, edit, remove, cancel] { button.smoothsFont = true }
        send.action = { [weak self] in guard let self else { return }; owner?.steer(index) }
        edit.action = { [weak self] in guard let self else { return }; owner?.edit(index) }
        remove.action = { [weak self] in guard let self else { return }; owner?.remove(index) }
        cancel.action = { [weak self] in self?.owner?.cancelEdit() }
        fold.action = { [weak self] in
            guard let self else { return }; open.toggle(); needsLayout = true; owner?.needsLayout = true; owner?.onHeightChange?()
        }
    }

    func configure(_ item: ComposerLogic.QueueState.Item, editing: Bool, busy: Bool, canSend: Bool,
                   editBlocked: Bool, editTip: String, steerTip: String) {
        if item.runId != message?.runId { open = false }
        let imageIds = item.message?.attachments.compactMap { $0["type"]?.stringValue == "image" ? $0["id"]?.stringValue : nil } ?? []
        if imageIds != thumbnailIds {
            thumbnailTask?.cancel(); thumbnailIds = imageIds
            thumbnails.forEach { $0.removeFromSuperview() }; thumbnails = imageIds.map { _ in DSView() }
            for tile in thumbnails { tile.layer?.cornerRadius = 6; tile.layer?.masksToBounds = true; tile.layer?.borderWidth = 1; tile.layer?.contentsGravity = .resizeAspectFill; bubble.addSubview(tile) }
            loadThumbnails()
        }
        message = item.message; self.editing = editing; guest = item.guestName != nil
        let presentation = item.message.map(UserMessagePresentation.resolve)
        let attribution = presentation?.attribution
        folded = attribution == .automation || attribution == .agent
        text.text = ComposerInlineTokens.citationsToPlainText(ComposerInlineTokens.contextLabels(item.text)).trimmingCharacters(in: .whitespacesAndNewlines)
        text.color = Themed.color(editing ? \.foreground : \.mutedForeground)
        let label = attribution == .automation ? "Automation" : item.message?.senderThreadId.flatMap { owner?.senderThreadTitles[$0] ?? owner?.threadTitle?(ThreadId($0)) } ?? "Agent"
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = attribution == .automation ? presentation?.scheduledTaskId.flatMap { owner?.scheduledTaskTitles[$0] } ?? text.text : text.text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        fold.configure(automation: attribution == .automation, label: cleanLabel.isEmpty ? "Agent" : cleanLabel, summary: summary, expanded: open)
        for label in fold.subviews.compactMap({ $0 as? LabelView }) { label.color = Themed.color(\.mutedForeground) }
        fold.isHidden = !folded; text.isHidden = folded && !open
        sender.text = item.guestName ?? (attribution == .t3code ? "Sent by T3 Code" : "")
        sender.color = item.guestName == nil ? Themed.color(\.mutedForeground, 0.7) : Themed.color(\.guestForeground)
        sender.isHidden = sender.text.isEmpty
        send.isHidden = !canSend || editing; edit.isHidden = editing; remove.isHidden = editing; cancel.isHidden = !editing
        status.text = editing ? "Editing in the composer" : item.runId == nil ? "Saving" : ""
        status.color = Themed.color(editing ? \.foreground : \.mutedForeground)
        status.isHidden = status.text.isEmpty
        for button in [send, edit, remove] { button.isEnabled = !busy }
        edit.isEnabled = !busy && item.isEditable && !editBlocked
        self.editTip.text = editTip; sendTip.text = steerTip
        timestamp.text = item.message.map { TL.dayAwareTimestamp($0.createdAt, now: Date()) } ?? ""
        source.title = attribution == .agent ? "Open thread" : presentation?.scheduledTaskId != nil ? "Open automation" : ""
        source.action = { [weak self] in
            guard let self else { return }
            if let id = presentation?.scheduledTaskId { owner?.onOpenScheduledTask?(id) }
            else if let id = item.message?.senderThreadId { owner?.onOpenThread?(ThreadId(id)) }
        }
        setAccessibilityLabel("Queued message \(index + 1), not sent: \(text.text)")
        needsLayout = true; needsDisplay = true
    }

    private func bubbleSize(_ width: CGFloat) -> NSSize {
        let maximum = max(26, width * 0.8)
        let natural = text.text.components(separatedBy: .newlines).map { TextLine(NSAttributedString(string: $0, attributes: [.font: DSFont.ui(14)])).width }.max() ?? 0
        let w = folded ? (open ? maximum : min(maximum, fold.naturalWidth + 2)) : min(maximum, max(natural + 26, thumbnails.isEmpty ? 0 : CGFloat(thumbnails.count) * 36 - 4 + 26))
        let shelf: CGFloat = thumbnails.isEmpty ? 0 : ceil(CGFloat(thumbnails.count) / max(1, floor((w - 26 + 4) / 36))) * 36 + 4
        let h: CGFloat = folded ? 38 + (open ? text.height(forWidth: max(1, w - 26)) + shelf + 8 : 0) : text.height(forWidth: max(1, w - 26)) + shelf + 18
        return NSSize(width: w, height: h)
    }
    func height(forWidth width: CGFloat) -> CGFloat { bubbleSize(width).height + 4 + 24 + (sender.isHidden ? 0 : 20) }

    override func updateLayer() {
        let color = editing ? Themed.color(\.primary, 0.6) : guest ? Themed.color(\.guest, 0.5) : Themed.color(\.mutedForeground, 0.4)
        outline.strokeColor = color.cgColor(in: self)
        for tile in thumbnails { tile.layer?.backgroundColor = Themed.color(\.muted, 0.6).cgColor(in: self); tile.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self) }
    }
    override func layout() {
        super.layout()
        let size = bubbleSize(bounds.width), top: CGFloat = sender.isHidden ? 0 : 20
        bubble.frame = NSRect(x: bounds.width - size.width, y: top, width: size.width, height: size.height)
        outline.frame = bubble.bounds
        outline.path = CGPath(roundedRect: bubble.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 15.5, cornerHeight: 15.5, transform: nil)
        fold.frame = NSRect(x: 1, y: 1, width: max(0, size.width - 2), height: 36)
        var shelfHeight: CGFloat = 0
        let columns = max(1, Int(floor((size.width - 26 + 4) / 36)))
        for (i, tile) in thumbnails.enumerated() {
            tile.isHidden = folded && !open
            tile.frame = NSRect(x: 13 + CGFloat(i % columns) * 36, y: (folded ? 37 : 9) + CGFloat(i / columns) * 36, width: 32, height: 32)
        }
        if !thumbnails.isEmpty { shelfHeight = CGFloat((thumbnails.count + columns - 1) / columns) * 36 + 4 }
        text.frame = NSRect(x: 13, y: (folded ? 37 : 9) + shelfHeight, width: max(0, size.width - 26), height: max(0, size.height - (folded ? 46 : 18) - shelfHeight))
        sender.frame = NSRect(x: max(0, bounds.width - ceil(sender.textWidth) - 4), y: 0, width: ceil(sender.textWidth), height: 16)
        let y = bubble.frame.maxY + 4
        var right = bounds.width - 4
        for view in [remove, edit, cancel, status, send] as [NSView] where !view.isHidden {
            let w = view === status ? ceil(status.textWidth) + 8 : view.intrinsicContentSize.width
            right -= w; view.frame = NSRect(x: right, y: y + (24 - (view === status ? 16 : 24)) / 2, width: w, height: view === status ? 16 : 24); right -= 2
        }
        timestamp.isHidden = !hovered || message == nil
        source.isHidden = !hovered || source.title.isEmpty
        let tw = ceil(timestamp.textWidth)
        timestamp.frame = NSRect(x: right - tw - 8, y: y + 4, width: tw, height: 16)
        let sw = source.intrinsicContentSize.width
        source.frame = NSRect(x: timestamp.frame.minX - sw - 8, y: y + 4, width: sw, height: 16)
    }
    private func loadThumbnails() {
        thumbnailTask?.cancel(); thumbnailTask = nil
        guard window != nil, !isHiddenOrHasHiddenAncestor, let resolve = owner?.attachmentMediaURL else {
            thumbnails.forEach { $0.layer?.contents = nil }; return
        }
        let ids = thumbnailIds
        thumbnailTask = Task { [weak self] in
            for (i, id) in ids.enumerated() {
                guard let source = await resolve(id) else { continue }
                let image = await ComposerImageIO.thumbnail(source, side: 64, cover: true)
                guard !Task.isCancelled, let self, ids == thumbnailIds, thumbnails.indices.contains(i) else { return }
                thumbnails[i].layer?.contents = image
            }
        }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loadThumbnails() }
    override func viewDidHide() { super.viewDidHide(); loadThumbnails() }
    override func viewDidUnhide() { super.viewDidUnhide(); loadThumbnails() }
    deinit { thumbnailTask?.cancel() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsLayout = true }
}

private final class QueuedRowView: DSView {
    weak var owner: QueuedRunsView?
    var index = 0
    private(set) var runId: RunId?
    let grip = GripView()
    private let saving = IconView(name: .clock3, size: 12, strokeColor: Themed.color(\.mutedForeground, 0.6))
    private let text = bannerLabel(Themed.color(\.foreground, 0.8))
    /// `shrink-0 text-guest-foreground`, before a guest's text.
    private let guestName = bannerLabel(GuestColors.foreground)
    private let edit = bannerButton(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs, tip: "Edit in the composer")
    private let steer = bannerButton("Steer", icon: .cornerUpRight, variant: .ghostMuted, size: .xs, tip: "Send as a steer instead")
    private let remove = bannerButton(nil, icon: .x, variant: .ghost, size: .iconXs, tip: "Remove from queue")
    private let cancel = ButtonView("Cancel", variant: .ghost, size: .xs)
    private var editing = false
    private lazy var textTip = TooltipController.attach(to: text, text: "")
    private lazy var steerTip = TooltipController.attach(to: steer, text: "")
    private lazy var editTip = TooltipController.attach(to: edit, text: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 6
        cancel.smoothsFont = false
        cancel.setAccessibilityLabel("Cancel editing queued message")
        text.setAccessibilityElement(true)
        text.setAccessibilityRole(.staticText)
        saving.setAccessibilityElement(true)
        saving.setAccessibilityRole(.image)
        saving.setAccessibilityLabel("Saving queued message") // QueuedRunsControl.tsx:369-372
        [grip, saving, guestName, text, edit, steer, remove, cancel].forEach(addSubview)
        TooltipController.attach(to: remove, text: "Remove from queue")
        grip.onDrag = { [weak self] event in guard let self else { return }; owner?.dragMoved(index, event: event) }
        grip.onDragEnd = { [weak self] in self?.owner?.dragEnded() }
        grip.onArrow = { [weak self] up in guard let self else { return false }; return owner?.moveByKey(index, up: up) ?? false }
        edit.action = { [weak self] in guard let self else { return }; owner?.edit(index) }
        steer.action = { [weak self] in guard let self else { return }; owner?.steer(index) }
        remove.action = { [weak self] in guard let self else { return }; owner?.remove(index) }
        cancel.action = { [weak self] in self?.owner?.cancelEdit() }
    }

    /// `sendNow`: the thread is stopped, so the button starts a turn with the message (QueuedRunsControl.tsx:447-462).
    func configure(_ item: ComposerLogic.QueueState.Item, editing: Bool, canReorder: Bool, busy: Bool, canSend: Bool, sendNow: Bool,
                   editBlocked: Bool, editTip: String, steerTip steerText: String) {
        self.editing = editing
        runId = item.runId
        self.editTip.text = editTip
        // Context links as their labels and citations as the quoted text (QueuedRunsControl.tsx:250-254).
        // ponytail: queued rows show no thumbnails, so image links keep their label; drop it when they do
        text.text = ComposerInlineTokens.citationsToPlainText(ComposerInlineTokens.contextLabels(item.text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        textTip.text = text.text
        // The `sr-only` "Editing queued message: " before the text (QueuedRunsControl.tsx:367).
        text.setAccessibilityLabel((editing ? "Editing queued message: " : "") + text.text)
        text.color = editing ? Themed.color(\.accentForeground) : Themed.color(\.foreground, 0.8)
        saving.isHidden = item.runId != nil
        guestName.text = item.guestName ?? ""
        guestName.isHidden = item.guestName == nil
        grip.isHidden = !canReorder
        grip.isEnabled = !busy
        for b in [edit, steer, remove] { b.isHidden = editing; b.isEnabled = !busy }
        steer.isEnabled = !busy && canSend
        steer.title = sendNow ? "Send now" : "Steer"
        edit.isEnabled = !busy && item.isEditable && !editBlocked
        edit.setAccessibilityHelp(editTip)
        steerTip.text = steerText
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
        if !guestName.isHidden {
            let gw = min(ceil(guestName.textWidth) + 1, max(0, right - x))
            guestName.frame = NSRect(x: x, y: (h - 16) / 2, width: gw, height: 16)
            x += gw + 4
        }
        text.frame = NSRect(x: x, y: (h - 16) / 2, width: max(0, right - x), height: 16)
    }
}

/// The reorder grip, drawn like a 24px `ghost-muted icon-xs` button: `grip-vertical` 14px in
/// `muted`, hover fills `accent` and turns the icon `foreground`. A drag past 3pt moves its row.
/// A click focuses it (Chromium focuses buttons on click), then ArrowUp and ArrowDown move the row.
final class GripView: ControlView {
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    /// ArrowUp (true) or ArrowDown; returns true when the key was used (`preventDefault`).
    var onArrow: ((Bool) -> Bool)?
    private let icon = IconView(name: .gripVertical, size: 14, strokeColor: Themed.color(\.mutedForeground))
    private let ring = CALayer()
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        ring.actions = ["borderColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        ring.cornerRadius = 11
        ring.borderWidth = 2
        layer?.addSublayer(ring)
        addSubview(icon)
        setAccessibilityLabel("Reorder queued message (drag, or press the arrow keys)")
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
    }

    override func updateLayer() {
        layer?.backgroundColor = state.hovered ? Themed.color(\.accent).cgColor(in: self) : nil
        icon.strokeColor = state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        // `focus-visible:ring-2 ring-ring ring-offset-1`.
        ring.isHidden = !state.focusVisible
        ring.borderColor = Themed.color(\.ring).cgColor(in: self)
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // ArrowUp 126, ArrowDown 125; the busy check lives in the strip (`busyRunId`).
        if [125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           onArrow?(event.keyCode == 126) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)
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

private final class QueueInlineAction: ControlView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
    var title = "" { didSet { label.text = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize(); needsLayout = true } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); scalesWhenPressed = false; label.lineHeight = 16; addSubview(label) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth), height: 16) }
    override func layout() { super.layout(); label.frame = bounds }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); label.color = Themed.color(state.hovered ? \.foreground : \.mutedForeground); label.isUnderlined = state.hovered }
}
