import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The "Queued" strip docked above the composer (QueuedRunsControl.tsx, ComposerBanner.tsx):
/// one row per queued message with the text, Send now, Edit and Remove; past three, two show until "Show all". J-composer-visuals section 7, behavior I-composer-flow 4.5 to 4.7.
///
/// The surface is T3's shared `ComposerBanner.Root` (neutral), so this is a `ComposerBannerView`
/// like the approval and question panels. The parent places it `overlap` points into whatever
/// sits below it (the composer or a request panel) and `drawerInset` in from each side.
public final class QueuedRunsView: ComposerBannerView {
    public var state = ComposerLogic.QueueState() { didSet { if state != oldValue { rebuild() } } }
    /// The run whose message the composer edits: its row is highlighted with only Cancel.
    public var editingRunId: RunId? { didSet { if editingRunId != oldValue { rebuild() } } }
    /// A queue command is in flight: every row action is disabled (`busyRunId`).
    public var isBusy = false { didSet { if isBusy != oldValue { rebuild() } } }
    public var editBlockedReason: String? { didSet { if editBlockedReason != oldValue { rebuild() } } }

    public var attachmentMediaURL: (@Sendable (String) async -> URL?)?
    /// A queued image thumbnail was clicked: its message's images and the clicked one (#33298, QueuedRunsControl.tsx at 4928).
    public var onExpandImage: (([ExpandedImagePreviewView.Item], Int) -> Void)?
    public var threadTitle: ((ThreadId) -> String?)?
    public var senderThreadTitles: [String: String] = [:] { didSet { if senderThreadTitles != oldValue { rebuild() } } }
    public var scheduledTaskTitles: [String: String] = [:] { didSet { if scheduledTaskTitles != oldValue { rebuild() } } }
    public var onOpenThread: ((ThreadId) -> Void)?
    public var onOpenScheduledTask: ((String) -> Void)?
    public var onEdit: ((ComposerLogic.QueueState.Item) -> Void)?
    public var onCancelEdit: (() -> Void)?
    public var onSteer: ((RunId) -> Void)?
    public var onRemove: ((RunId) -> Void)?
    /// The height or the count changed.
    public var onHeightChange: (() -> Void)?
    /// `thread.editQueuedMessage` and `thread.steerQueuedMessage` labels for the last row's Edit and
    /// the first row's Steer tooltips (ChatView.tsx:11638-11647, QueuedRunsControl.tsx:442, :468).
    public var editShortcutLabel: String? = "\u{2325}Up"
    public var steerShortcutLabel: String? = "\u{21E7}\u{2318}Enter"

    /// The strip's full height including the hidden overlap; 0 with nothing queued.
    public var preferredHeight: CGFloat {
        guard !state.items.isEmpty else { return 0 }
        return height(forWidth: bounds.width > 0 ? bounds.width : 736)
    }

    private var showAllQueue = false
    private let more = QueueInlineAction()
    private var visibleCount: Int { state.items.count > 3 && !showAllQueue ? 2 : state.items.count }

    public func height(forWidth width: CGFloat) -> CGFloat {
        let visible = rows.prefix(visibleCount).compactMap { $0 as? ModernQueuedRowView }
        return visible.reduce(CGFloat(0)) { $0 + $1.height(forWidth: width) } + CGFloat(max(0, visible.count - 1)) * 12
            + (state.items.count > 3 ? 24 : 0) + (state.items.isEmpty ? 0 : 16)
    }

    private let scroll = NSScrollView()
    private let list = DSView()
    private var rows: [DSView] = []

    public init() {
        super.init(variant: .neutral)
        addSubview(more)
        more.action = { [weak self] in self?.toggle() }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.useT3Scrollbars(.overlay) // ComposerBanner.Scroll is a ScrollArea (QueuedRunsControl.tsx:272)
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
        setAccessibilityRole(.group)
    }

    /// `setExpanded(true)` before editing the latest queued message.
    public func expand() { showAllQueue = true; needsLayout = true; onHeightChange?() }

    /// "Show all" and "Show fewer".
    public func toggle() { showAllQueue.toggle(); needsLayout = true; onHeightChange?() }

    // MARK: Rows

    private func rebuild() {
        let before = preferredHeight, count = rows.count
        setAccessibilityLabel("\(state.items.count) queued message\(state.items.count == 1 ? "" : "s")")
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
                          canSend: state.canSend(item),
                          editBlocked: editBlockedReason != nil,
                          editTip: editBlockedReason ?? "Edit in the composer" + (i == queued - 1 && item.runId != nil ? editShortcutLabel.map { " (\($0))" } ?? "" : ""),
                          steerTip: ComposerLogic.queuedSteerTip(state, item)
                            + (i == 0 ? steerShortcutLabel.map { " (\($0))" } ?? "" : ""))
        }
        needsLayout = true
        if preferredHeight != before || state.items.count != count { onHeightChange?() }
    }

    func edit(_ i: Int) { if editBlockedReason == nil, !isBusy, state.items.indices.contains(i), state.items[i].isEditable { onEdit?(state.items[i]) } }
    fileprivate func cancelEdit() { onCancelEdit?() }
    fileprivate func steer(_ i: Int) { if let id = state.items[safe: i]?.runId { onSteer?(id) } }
    fileprivate func remove(_ i: Int) { if let id = state.items[safe: i]?.runId { onRemove?(id) } }

    // MARK: Drawing and layout

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    public override func updateLayer() {
        quietTimelineLine = true
        super.updateLayer()
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        more.isHidden = state.items.count <= 3
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
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Buttons on the banner draw without font smoothing, like Chromium on backdrop-filter layers.
private func bannerButton(_ title: String?, icon: IconName, variant: ButtonView.Variant, size: ButtonView.Size, tip: String) -> ButtonView {
    let button = ButtonView(title, icon: icon, variant: variant, size: size)
    button.smoothsFont = false
    button.setAccessibilityLabel(tip)
    return button
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
            for tile in thumbnails {
                tile.layer?.cornerRadius = 6; tile.layer?.masksToBounds = true; tile.layer?.borderWidth = 1; tile.layer?.contentsGravity = .resizeAspectFill
                tile.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expandThumbnail(_:))))
                tile.setAccessibilityRole(.button)
                bubble.addSubview(tile)
            }
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
        // Redesign keeps its own card corner (RedesignTokens.Radius.card) on T3's dashed bubble.
        let radius = (ThemeRuntime.isDither(dark: effectiveAppearance.isDark) ? RedesignTokens.Radius.card : 16) - 0.5
        outline.path = CGPath(roundedRect: bubble.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
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
    /// `buildExpandedImagePreview(thumbnails, id)`: the message's images in the viewer, opened at the clicked one.
    /// A thumbnail that hasn't loaded yet is disabled (`disabled={!thumbnail.previewUrl}`).
    @objc private func expandThumbnail(_ gesture: NSClickGestureRecognizer) {
        guard let tile = gesture.view, let index = thumbnails.firstIndex(where: { $0 === tile }), tile.layer?.contents != nil,
              let owner, let resolve = owner.attachmentMediaURL else { return }
        let names = Dictionary(message?.attachments.compactMap { a in a["id"]?.stringValue.map { ($0, a["name"]?.stringValue ?? "Image") } } ?? [],
                               uniquingKeysWith: { a, _ in a })
        let items = thumbnailIds.map { id in
            ExpandedImagePreviewView.Item(key: "queued:" + id, name: names[id] ?? "Image") { side in
                guard let source = await resolve(id) else { return nil }
                return await ComposerImageIO.thumbnail(source, side: side, cover: false)
            }
        }
        owner.onExpandImage?(items, index)
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

private final class QueueInlineAction: ControlView {
    private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
    var title = "" { didSet { label.text = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize(); needsLayout = true } }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); scalesWhenPressed = false; label.lineHeight = 16; addSubview(label) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth), height: 16) }
    override func layout() { super.layout(); label.frame = bounds }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); label.color = Themed.color(state.hovered ? \.foreground : \.mutedForeground); label.isUnderlined = state.hovered }
}
