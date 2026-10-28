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

    public var threadTitle: ((ThreadId) -> String?)?
    public var senderThreadTitles: [String: String] = [:] { didSet { if senderThreadTitles != oldValue { rebuild() } } }
    public var scheduledTaskTitles: [String: String] = [:] { didSet { if scheduledTaskTitles != oldValue { rebuild() } } }
    public var onOpenThread: ((ThreadId) -> Void)?
    public var onOpenScheduledTask: ((String) -> Void)?
    public var onEdit: ((ComposerLogic.QueueState.Item) -> Void)?
    public var onCancelEdit: (() -> Void)?
    public var onSteer: ((RunId) -> Void)?
    public var onRemove: ((RunId) -> Void)?
    /// The height or the count changed (Redesign's pill shows the count while the list is closed).
    public var onHeightChange: (() -> Void)?
    /// `thread.editQueuedMessage` and `thread.steerQueuedMessage` labels for the last row's Edit and
    /// the first row's Steer tooltips (ChatView.tsx:11638-11647, QueuedRunsControl.tsx:442, :468).
    public var editShortcutLabel: String? = "\u{2325}Up"
    public var steerShortcutLabel: String? = "\u{21E7}\u{2318}Enter"

    /// The strip's full height including the hidden overlap; 0 with nothing queued.
    public var preferredHeight: CGFloat {
        guard !state.items.isEmpty else { return 0 }
        return Self.pad * 2 + Self.row + listHeight + Self.overlap
    }

    private var listHeight: CGFloat {
        guard expanded, !state.items.isEmpty else { return 0 }
        return min(Self.listMax, state.items.reduce(CGFloat(0)) { $0 + rowHeight($1) + 1 } - 1)
    }

    private func rowHeight(_ item: ComposerLogic.QueueState.Item) -> CGFloat { item.message == nil ? Self.row : Self.row + 18 }

    private let header = HeaderRow()
    private let scroll = NSScrollView()
    private let list = DSView()
    private var rows: [QueuedRowView] = []

    public init() {
        super.init(variant: .neutral)
        header.action = { [weak self] in self?.toggle() }
        addSubview(header)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.useT3Scrollbars(.overlay) // ComposerBanner.Scroll is a ScrollArea (QueuedRunsControl.tsx:272)
        scroll.contentView.drawsBackground = false
        scroll.documentView = list
        addSubview(scroll)
        setAccessibilityRole(.group)
    }

    /// `setExpanded(true)` before editing the latest queued message.
    public func expand() { if !expanded { toggle() } }

    /// Redesign shows the list as a panel over its Queued pill: open while expanded, the pill and the header toggle it.
    public func toggle() {
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
        while rows.count < state.items.count {
            let row = QueuedRowView()
            row.owner = self
            list.addSubview(row)
            rows.append(row)
        }
        while rows.count > state.items.count { rows.removeLast().removeFromSuperview() }
        let queued = state.items.filter { $0.runId != nil }.count
        for (i, item) in state.items.enumerated() {
            let row = rows[i]
            row.index = i
            row.configure(item, editing: item.runId != nil && item.runId == editingRunId,
                          busy: isBusy || item.runId == nil,
                          canSend: state.canSendNow || state.canPromoteToSteer,
                          editBlocked: editBlockedReason != nil,
                          editTip: editBlockedReason ?? "Edit in the composer" + (i == queued - 1 && item.runId != nil ? editShortcutLabel.map { " (\($0))" } ?? "" : ""),
                          steerTip: (state.canSendNow ? "Start a turn with this message" : state.promoteSkipsCompaction ? "Skip compaction and send this message" : "Send into the current turn")
                            + (i == 0 ? steerShortcutLabel.map { " (\($0))" } ?? "" : ""))
        }
        needsLayout = true
        if preferredHeight != before || state.items.count != count { onHeightChange?() }
    }

    func edit(_ i: Int) { if editBlockedReason == nil, !isBusy, state.items.indices.contains(i), state.items[i].isEditable { onEdit?(state.items[i]) } }
    fileprivate func cancelEdit() { onCancelEdit?() }
    fileprivate func steer(_ i: Int) { if let id = state.items[safe: i]?.runId { onSteer?(id) } }
    fileprivate func remove(_ i: Int) { if let id = state.items[safe: i]?.runId { onRemove?(id) } }

    // T3 3814 QueuedRunsControl.tsx:279-287 offers Send now without manual reordering.

    public override func layout() {
        super.layout()
        let w = bounds.width
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
private final class QueuedRowView: DSView {
    weak var owner: QueuedRunsView?
    var index = 0
    private(set) var runId: RunId?
    private let saving = IconView(name: .clock3, size: 12, strokeColor: Themed.color(\.mutedForeground, 0.6))
    private let text = bannerLabel(Themed.color(\.foreground, 0.8))
    /// `shrink-0 text-guest-foreground`, before a guest's text.
    private let guestName = bannerLabel(GuestColors.foreground)
    private let source = ButtonView(variant: .ghostMuted, size: .xs)
    private let timestamp = bannerLabel(Themed.color(\.mutedForeground))
    private var message: ChatMessage?
    private let edit = bannerButton(nil, icon: .pencil, variant: .ghostMuted, size: .iconXs, tip: "Edit in the composer")
    private let steer = bannerButton("Steer", icon: .arrowUp, variant: .ghostMuted, size: .xs, tip: "Send as a steer instead")
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
        [saving, guestName, text, source, timestamp, edit, steer, remove, cancel].forEach(addSubview)
        TooltipController.attach(to: remove, text: "Remove from queue")
        edit.action = { [weak self] in guard let self else { return }; owner?.edit(index) }
        steer.action = { [weak self] in guard let self else { return }; owner?.steer(index) }
        remove.action = { [weak self] in guard let self else { return }; owner?.remove(index) }
        cancel.action = { [weak self] in self?.owner?.cancelEdit() }
    }

    /// The controller chooses start or promote from the current workflow.
    func configure(_ item: ComposerLogic.QueueState.Item, editing: Bool, busy: Bool, canSend: Bool,
                   editBlocked: Bool, editTip: String, steerTip steerText: String) {
        self.editing = editing
        message = item.message
        let presentation = item.message.map(UserMessagePresentation.resolve)
        // T3 3814 QueuedRunsControl.tsx:393-525 uses the sent message's attribution and timestamp.
        let senderTitle = item.message?.senderThreadId.flatMap { owner?.senderThreadTitles[$0] ?? owner?.threadTitle?(ThreadId($0)) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = switch presentation?.attribution {
        case .automation: presentation?.scheduledTaskId.flatMap { owner?.scheduledTaskTitles[$0] }.map { "Automation: " + $0 } ?? "Automation"
        case .agent: senderTitle?.isEmpty == false ? senderTitle : "Agent"
        case .t3code: "Sent by T3 Code"
        default: nil
        }
        source.title = title ?? ""
        source.isHidden = title == nil
        source.isEnabled = presentation?.scheduledTaskId != nil || item.message?.senderThreadId != nil
        source.action = { [weak self] in
            guard let self, let message else { return }
            if let task = UserMessagePresentation.resolve(message).scheduledTaskId { owner?.onOpenScheduledTask?(task) }
            else if let sender = message.senderThreadId { owner?.onOpenThread?(ThreadId(sender)) }
        }
        timestamp.text = item.message.map { TL.dayAwareTimestamp($0.createdAt, now: Date()) } ?? ""
        timestamp.isHidden = item.message == nil
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
        for b in [edit, steer, remove] { b.isHidden = editing; b.isEnabled = !busy }
        steer.isEnabled = !busy && canSend
        steer.title = "Send now"
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
        let h: CGFloat = QueuedRunsView.row
        let top = message == nil ? CGFloat(0) : 18
        source.frame = NSRect(x: 2, y: 0, width: min(ceil(source.intrinsicContentSize.width), max(0, bounds.width - 90)), height: 18)
        let tw = ceil(timestamp.textWidth)
        timestamp.frame = NSRect(x: max(0, bounds.width - tw - 4), y: 1, width: tw, height: 16)
        // Actions right to left with `gap-1`.
        var right = bounds.width
        let visible = editing ? [cancel] : [remove, steer, edit]
        for b in visible {
            let s = b.intrinsicContentSize
            right -= s.width
            b.frame = NSRect(x: right, y: top + (h - s.height) / 2, width: s.width, height: s.height)
            right -= 4
        }
        var x: CGFloat = 6
        if !saving.isHidden {
            saving.frame = NSRect(x: x, y: top + (h - 12) / 2, width: 12, height: 12)
            x += 12 + 4
        }
        if !guestName.isHidden {
            let gw = min(ceil(guestName.textWidth) + 1, max(0, right - x))
            guestName.frame = NSRect(x: x, y: top + (h - 16) / 2, width: gw, height: 16)
            x += gw + 4
        }
        text.frame = NSRect(x: x, y: top + (h - 16) / 2, width: max(0, right - x), height: 16)
    }
}
