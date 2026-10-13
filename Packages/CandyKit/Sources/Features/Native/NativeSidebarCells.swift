import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's sidebar rows: T3 Code desktop's rows (the classic `SidebarRowViews` are the map), with the same
/// information in the same places and sizes, drawn with labels, SF Symbols and the table's own selection.
@MainActor
enum NativeSidebarMetrics {
    /// The cell's inset; the source list row adds its own around it.
    static let pad: CGFloat = 8

    /// Row heights without the table's 2pt row gap: the classic rows' heights (`SidebarItem.height`) less 2.
    static func height(_ item: SidebarItem) -> CGFloat {
        switch item {
        case .draftDivider: item.height
        default: item.height - 2
        }
    }

    static func label(_ font: NSFont, _ color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = font
        f.textColor = color
        f.maximumNumberOfLines = 1
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        return f
    }

    /// Rows ask for the same few symbols over and over, so each is made once. Template images, tinted by their view.
    // ponytail: never evicted; about a dozen symbols, bound it if rows ever show arbitrary symbols
    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name) \(size) \(weight.rawValue)"
        if let image = symbols[key] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        symbols[key] = image
        return image
    }

    static func imageView() -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyDown
        return v
    }

    /// T3's Lucide status glyphs (`SB.statusIcon`) as SF Symbols.
    static func statusSymbol(_ s: SidebarTopStatus) -> String? {
        switch s {
        case .working: "circle.dashed"
        case .input: "questionmark.bubble"
        case .approval: "exclamationmark.shield"
        case .failed, .limited: "exclamationmark.circle"
        case .done: "checkmark.circle"
        case .woke: "alarm"
        case .waiting: nil
        }
    }
}

/// A flipped cell with frame layout. Labels change only when their text does. On the emphasized (key) selection
/// the text turns to the selection's text color.
class NativeSidebarCell: NSTableCellView {
    override var isFlipped: Bool { true }
    var item: SidebarItem?
    weak var list: NativeSidebarListView?

    func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        self.item = item
        self.list = list
    }

    var emphasized: Bool { backgroundStyle == .emphasized }

    /// `color`, or the emphasized selection's text color.
    func ink(_ color: NSColor) -> NSColor { emphasized ? .alternateSelectedControlTextColor : color }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue, let item, let list { configure(item, list: list) } }
    }

    static func set(_ field: NSTextField, _ text: String) { if field.stringValue != text { field.stringValue = text } }
}

/// The card row for pinned, active and Working threads (Sidebar.tsx:1955-2217, classic `SidebarCardRowView`):
/// favicon and project, then the status or the time; the title; the branch, then the terminal, pull request,
/// remote machine and provider glyphs.
final class NativeThreadCardCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let project = NativeSidebarMetrics.label(SB.font(12, .medium))
    let pin = NativeSidebarMetrics.imageView()
    let statusIcon = NativeSidebarMetrics.imageView()
    let status = NativeSidebarMetrics.label(SB.font(12, .medium))
    let duration = NativeSidebarMetrics.label(SB.tabular(12))
    let title = NativeSidebarMetrics.label(SB.font(14, .medium))
    let worktree = NativeSidebarMetrics.imageView()
    let branch = NativeSidebarMetrics.label(SB.font(12))
    let scratchMachine = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    let terminal = TerminalStatusGlyph()
    let pullRequest = PullRequestBadgeView()
    let machine = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let provider = ProviderGlyphView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pin.image = NativeSidebarMetrics.symbol("pin", size: 10)
        worktree.image = NativeSidebarMetrics.symbol("folder", size: 10)
        terminal.isHidden = true
        for v in [favicon, project, pin, statusIcon, status, duration, title, worktree, branch, scratchMachine, terminal, pullRequest,
                  machine, provider] as [NSView] { addSubview(v) }
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var row: SidebarRowModel? { if case .row(let r)? = item { r } else { nil } }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .row(let r) = item else { return }
        favicon.isHidden = r.projectTitle == nil && r.projectLabel == nil
        favicon.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        favicon.source = r.projectIcon
        Self.set(project, r.projectLabel ?? "")
        project.font = SB.font(12, r.recedes ? .regular : .medium)
        project.textColor = ink(SB.c(\.secondaryLabel))
        pin.isHidden = !r.isPinned
        pin.contentTintColor = ink(SB.c(\.mutedForeground))
        if let top = r.topStatus {
            let color = ink(SB.status(top))
            statusIcon.image = NativeSidebarMetrics.statusSymbol(top).flatMap { NativeSidebarMetrics.symbol($0, size: 12, weight: .medium) }
            statusIcon.contentTintColor = color
            Self.set(status, r.statusLabel ?? "")
            status.textColor = color
            Self.set(duration, r.status == .working ? r.workingStartedMs.map {
                SidebarModel.formatWorkingDurationLabel(elapsedMs: Double(list.nowMs - $0)) } ?? "" : "")
            duration.font = SB.tabular(12, .medium)
            duration.textColor = color
        } else {
            statusIcon.image = nil
            Self.set(status, "")
            Self.set(duration, r.timeLabel)
            duration.font = SB.tabular(12)
            duration.textColor = ink(SB.c(\.secondaryLabel))
        }
        statusIcon.isHidden = statusIcon.image == nil
        Self.set(title, r.isRenaming ? "" : r.title)
        title.font = SB.font(14, r.recedes ? .regular : .medium)
        title.textColor = ink(r.recedes ? SB.c(\.secondaryLabel)
            : r.isUnread || r.isWoke || r.status == .input ? SB.c(\.foreground)
            : r.status == .failed ? SB.c(\.foreground, 0.95) : SB.c(\.foreground, 0.9))
        title.alphaValue = r.isRegeneratingTitle ? 0.55 : 1
        let showsScratch = r.branch == nil && r.scratchMachineLabel != nil
        Self.set(branch, r.branch ?? (showsScratch ? r.scratchMachineLabel ?? "" : ""))
        branch.textColor = ink(SB.c(\.mutedForeground, 0.4))
        worktree.isHidden = !(r.branch != nil && r.hasWorktree)
        worktree.contentTintColor = ink(SB.c(\.mutedForeground, 0.4))
        scratchMachine.kind = showsScratch ? r.scratchMachine : nil
        scratchMachine.isHidden = !showsScratch
        scratchMachine.color = ink(SB.c(\.mutedForeground, 0.4))
        terminal.count = r.terminalProcessCount
        pullRequest.badge = r.pullRequestBadge
        pullRequest.onClick = { [weak list] in list?.actions.openPullRequest(r.id) }
        pullRequest.onOpenURL = { [weak list] url in list?.actions.openPullRequestURL(r.id, url) }
        machine.kind = r.environmentMachine
        machine.isHidden = r.environmentMachine == nil || showsScratch
        machine.color = ink(SB.c(\.sidebarMutedForeground, 0.7))
        provider.driver = r.providerIcon
        // Background work fades as a whole row (`opacity-70`, Sidebar.tsx:1596-1598).
        alphaValue = r.recedes && r.status == .working ? 0.7 : 1
        setAccessibilityLabel([r.title, r.isRegeneratingTitle ? "Regenerating title" : nil, r.statusLabel, r.projectLabel]
            .compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    /// Re-applies the clock to a Working duration.
    func tick() {
        guard let r = row, r.status == .working, let start = r.workingStartedMs, let list else { return }
        Self.set(duration, SidebarModel.formatWorkingDurationLabel(elapsedMs: Double(list.nowMs - start)))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The classic card's content box: line 1, the title 24pt below, line 3 46pt below (of an 82pt row).
        let left = NativeSidebarMetrics.pad, right = bounds.width - NativeSidebarMetrics.pad, top: CGFloat = 8
        var x = left
        if !favicon.isHidden { favicon.frame = NSRect(x: x, y: top + 2, width: 16, height: 16); x += 16 + 6 }
        var sx = right
        if !duration.stringValue.isEmpty {
            let dw = ceil(duration.intrinsicContentSize.width) + 4
            duration.frame = NSRect(x: sx - dw, y: top + 2, width: dw, height: 16)
            sx -= dw + (status.stringValue.isEmpty ? 0 : 4)
        }
        if !status.stringValue.isEmpty {
            let lw = ceil(status.intrinsicContentSize.width) + 4
            status.frame = NSRect(x: sx - lw, y: top + 2, width: lw, height: 16)
            sx -= lw
            if !statusIcon.isHidden { statusIcon.frame = NSRect(x: sx - 4 - 14, y: top + 3, width: 14, height: 14); sx -= 18 }
        }
        var slotRight = right - max(32, right - sx) // `min-w-8`
        if !pin.isHidden { pin.frame = NSRect(x: slotRight - 6 - 12, y: top + 4, width: 12, height: 12); slotRight -= 18 }
        project.frame = NSRect(x: x, y: top + 2, width: max(0, slotRight - 6 - x), height: 16)
        title.frame = NSRect(x: left, y: top + 24, width: right - left, height: 20)
        let y3 = top + 46
        provider.frame = NSRect(x: right - 14, y: y3 + 1, width: 14, height: 14)
        var trailing = right - 14
        if !machine.isHidden { machine.frame = NSRect(x: trailing - 4 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 18 }
        if !pullRequest.isHidden {
            let pw = pullRequest.preferredWidth
            pullRequest.frame = NSRect(x: trailing - 6 - pw, y: y3, width: pw, height: 16); trailing -= pw + 6
        }
        if !terminal.isHidden { terminal.frame = NSRect(x: trailing - 6 - 14, y: y3 + 1, width: 14, height: 14); trailing -= 20 }
        var bx = left
        if !worktree.isHidden { worktree.frame = NSRect(x: bx, y: y3 + 2, width: 12, height: 12); bx += 18 }
        if !scratchMachine.isHidden { scratchMachine.frame = NSRect(x: bx, y: y3 + 2, width: 12, height: 12); bx += 18 }
        branch.frame = NSRect(x: bx, y: y3, width: max(0, trailing - 6 - bx), height: 16)
    }

    var titleFrame: NSRect { title.frame }
}

/// The slim row for snoozed and settled threads (Sidebar.tsx:1791-1953, classic `SidebarSlimRowView`): favicon,
/// title, then the pin, terminal and pull request glyphs, then the time or the wake countdown.
final class NativeThreadSlimCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let title = NativeSidebarMetrics.label(SB.font(14))
    let pin = NativeSidebarMetrics.imageView()
    let terminal = TerminalStatusGlyph()
    let pullRequest = PullRequestBadgeView()
    let time = NativeSidebarMetrics.label(SB.tabular(12))

    override init(frame: NSRect) {
        super.init(frame: frame)
        pin.image = NativeSidebarMetrics.symbol("pin", size: 10)
        terminal.isHidden = true
        for v in [favicon, title, pin, terminal, pullRequest, time] as [NSView] { addSubview(v) }
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .row(let r) = item else { return }
        favicon.projectTitle = r.projectTitle ?? r.projectLabel ?? ""
        favicon.source = r.projectIcon
        // Dimmed favicon at rest (Sidebar.tsx:1827-1830); macOS rows have no hover to restore it.
        let dim = !r.isActive || r.action == .unsettle
        favicon.dimmed = dim
        favicon.alphaValue = dim ? 0.4 : 1
        Self.set(title, r.isRenaming ? "" : r.title)
        title.textColor = ink(r.recedes ? SB.c(\.secondaryLabel, 0.7)
            : r.isActive || r.isWoke || r.status == .input ? SB.c(\.foreground)
            : r.isUnread ? SB.c(\.mutedForeground) : SB.c(\.secondaryLabel, 0.7))
        title.alphaValue = r.isRegeneratingTitle ? 0.55 : 1
        pin.isHidden = !r.isPinned
        pin.contentTintColor = ink(SB.c(\.mutedForeground))
        terminal.count = r.terminalProcessCount
        pullRequest.badge = r.pullRequestBadge
        pullRequest.onClick = { [weak list] in list?.actions.openPullRequest(r.id) }
        pullRequest.onOpenURL = { [weak list] url in list?.actions.openPullRequestURL(r.id, url) }
        Self.set(time, r.snoozeLabel ?? r.timeLabel)
        time.textColor = ink(r.snoozeLabel != nil ? SB.c(\.infoForeground) : SB.c(\.secondaryLabel))
        setAccessibilityLabel([r.title, r.isRegeneratingTitle ? "Regenerating title" : nil].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, pad = NativeSidebarMetrics.pad
        favicon.frame = NSRect(x: pad, y: (h - 16) / 2, width: 16, height: 16)
        let x = pad + 16 + 10
        let tw = ceil(time.intrinsicContentSize.width) + 4
        time.frame = NSRect(x: w - pad - tw, y: (h - 16) / 2, width: tw, height: 16)
        var right = w - pad - max(32, tw) - 10
        if !pullRequest.isHidden {
            let pw = pullRequest.preferredWidth
            pullRequest.frame = NSRect(x: right - pw, y: (h - 16) / 2, width: pw, height: 16); right -= pw + 10
        }
        if !terminal.isHidden { terminal.frame = NSRect(x: right - 14, y: (h - 14) / 2, width: 14, height: 14); right -= 14 + 10 }
        if !pin.isHidden { pin.frame = NSRect(x: right - 12, y: (h - 12) / 2, width: 12, height: 12); right -= 12 + 10 }
        title.frame = NSRect(x: x, y: (h - 20) / 2, width: max(0, right - x), height: 20)
    }

    var titleFrame: NSRect { title.frame }
}

/// A shelf header (classic `SidebarShelfRowView`): "Settled (12)", a rule and a chevron that points down while
/// collapsed and up while open. Snoozed wears the info tone.
final class NativeShelfHeaderCell: NativeSidebarCell {
    let label = NativeSidebarMetrics.label(SB.font(12, .medium))
    let rule = NSBox()
    let chevron = NativeSidebarMetrics.imageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        rule.boxType = .separator
        for v in [label, rule, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .shelfHeader(let shelf, let text, let expanded) = item else { return }
        Self.set(label, text)
        let tone = shelf == .snoozed ? SB.c(\.infoForeground) : SB.c(\.mutedForeground)
        label.textColor = tone
        chevron.image = NativeSidebarMetrics.symbol(expanded ? "chevron.up" : "chevron.down", size: 10, weight: .semibold)
        chevron.contentTintColor = tone
        setAccessibilityLabel(text)
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, mid = bounds.height / 2, x: CGFloat = 8
        let labelWidth = ceil(label.intrinsicContentSize.width) + 4
        label.frame = NSRect(x: x, y: mid - 8, width: labelWidth, height: 16)
        chevron.frame = NSRect(x: w - 8 - 12, y: mid - 6, width: 12, height: 12)
        rule.frame = NSRect(x: label.frame.maxX + 8, y: mid - 0.5, width: max(8, chevron.frame.minX - 8 - label.frame.maxX - 8), height: 1)
    }
}

/// "Show N more" with its plus (classic `SidebarShowMoreRowView`), the draft divider, the centered status lines
/// and "No projects yet" with its Add project button.
final class NativeTextCell: NativeSidebarCell {
    let icon = NativeSidebarMetrics.imageView()
    let label = NativeSidebarMetrics.label(SB.font(12))
    let rule = NSBox()
    let button = NSButton(title: "Add project", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        rule.boxType = .separator
        button.bezelStyle = .push
        button.controlSize = .small
        for v in [icon, label, rule, button] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        button.isHidden = true
        icon.isHidden = true
        rule.isHidden = true
        label.isHidden = false
        label.alignment = .center
        switch item {
        case .showMore(let count):
            Self.set(label, "Show \(count) more")
            label.font = SB.font(14)
            label.alignment = .left
            label.textColor = SB.c(\.sidebarMutedForeground, 0.55)
            icon.isHidden = false
            icon.image = NativeSidebarMetrics.symbol("plus", size: 12)
            icon.contentTintColor = SB.c(\.sidebarMutedForeground, 0.55)
        case .emptyText(let text, _):
            Self.set(label, text)
            label.font = SB.font(12)
            label.textColor = SB.c(\.mutedForeground)
        case .noProjects:
            Self.set(label, "No projects yet")
            label.font = SB.font(12)
            label.textColor = SB.c(\.mutedForeground)
            button.isHidden = false
            button.target = list
            button.action = #selector(NativeSidebarListView.addProjectPressed)
        case .draftDivider:
            label.isHidden = true
            rule.isHidden = false
        default: break
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        if !rule.isHidden { rule.frame = NSRect(x: 2, y: (h - 1) / 2, width: w - 4, height: 1); return }
        if !icon.isHidden {
            icon.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
            label.frame = NSRect(x: 36, y: (h - 20) / 2, width: w - 46, height: 20)
        } else if button.isHidden {
            label.frame = NSRect(x: 8, y: (h - 16) / 2, width: w - 16, height: 16)
        } else {
            label.frame = NSRect(x: 8, y: 24, width: w - 16, height: 16)
            button.sizeToFit()
            button.frame.origin = NSPoint(x: (w - button.frame.width) / 2, y: 48)
        }
    }
}

/// A draft row (classic `SidebarDraftRowView`): the pen, favicon and project, then the prompt's first line.
/// Right click discards it.
final class NativeDraftCell: NativeSidebarCell {
    let pen = NativeSidebarMetrics.imageView()
    let favicon = ProjectMonogramView()
    let project = NativeSidebarMetrics.label(SB.font(12, .medium))
    let preview = NativeSidebarMetrics.label(SB.font(14, .medium))

    override init(frame: NSRect) {
        super.init(frame: frame)
        pen.image = NativeSidebarMetrics.symbol("square.and.pencil", size: 10)
        for v in [pen, favicon, project, preview] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .draft(let d) = item else { return }
        favicon.isHidden = d.projectTitle == nil && d.projectLabel == nil
        favicon.projectTitle = d.projectTitle ?? d.projectLabel ?? ""
        favicon.source = d.projectIcon
        pen.contentTintColor = ink(SB.c(\.secondaryLabel))
        Self.set(project, d.projectLabel ?? "")
        project.textColor = ink(SB.c(\.secondaryLabel))
        Self.set(preview, d.preview)
        preview.textColor = ink(SB.c(\.foreground, 0.9))
        setAccessibilityLabel("Draft: \(d.preview)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left = NativeSidebarMetrics.pad, right = bounds.width - NativeSidebarMetrics.pad, top: CGFloat = 8
        var x = left
        pen.frame = NSRect(x: x, y: top + 4, width: 12, height: 12); x += 12 + 6
        if !favicon.isHidden { favicon.frame = NSRect(x: x, y: top + 2, width: 16, height: 16); x += 16 + 6 }
        project.frame = NSRect(x: x, y: top + 2, width: max(0, right - x), height: 16)
        preview.frame = NSRect(x: left, y: top + 22, width: right - left, height: 20)
    }
}

/// A search result (Sidebar.tsx:2229-2380): favicon, title and time, and under it the server's message match as
/// "You:" or "Agent:".
final class NativeSearchResultCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let title = NativeSidebarMetrics.label(SB.font(14))
    let time = NativeSidebarMetrics.label(SB.tabular(12))
    let excerpt = NativeSidebarMetrics.label(SB.font(12))

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [favicon, title, time, excerpt] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .searchResult(let r) = item else { return }
        favicon.projectTitle = r.projectTitle ?? ""
        favicon.source = r.projectIcon
        Self.set(title, r.title)
        title.textColor = ink(SB.c(\.foreground))
        Self.set(time, r.timeLabel)
        time.textColor = ink(SB.c(\.secondaryLabel))
        if let match = r.match {
            Self.set(excerpt, "\(match.isUser ? "You" : "Agent"): \(match.snippet.replacingOccurrences(of: "\n", with: " "))")
        }
        excerpt.textColor = ink(SB.c(\.mutedForeground))
        excerpt.isHidden = r.match == nil
        setAccessibilityLabel(r.title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, pad = NativeSidebarMetrics.pad
        let y: CGFloat = excerpt.isHidden ? (bounds.height - 20) / 2 : 3
        let tw = ceil(time.intrinsicContentSize.width) + 4
        time.frame = NSRect(x: w - pad - tw, y: y + 2, width: tw, height: 16)
        favicon.frame = NSRect(x: pad, y: y + 2, width: 16, height: 16)
        title.frame = NSRect(x: pad + 24, y: y, width: max(0, time.frame.minX - 8 - pad - 24), height: 20)
        excerpt.frame = NSRect(x: pad + 24, y: y + 20, width: max(0, w - 2 * pad - 24), height: 16)
    }
}
