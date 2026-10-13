import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Glass Native's sidebar rows, T3 Mobile's anatomy (thread-list-v2-items.tsx) at about 0.875 of its iPad sizes.
/// Frame layout, plain labels and symbol attachments keep each row to a handful of views.
@MainActor
enum NativeSidebarMetrics {
    static let pad: CGFloat = 8
    static let vPad: CGFloat = 8
    static let line1: CGFloat = 16
    static let titleLine: CGFloat = 18
    static let line3: CGFloat = 15
    static let gap: CGFloat = 3

    static var projectFont: NSFont { DSFont.ui(12, weight: .medium) }
    static var statusFont: NSFont { DSFont.ui(11.5, weight: .semibold) }
    static var titleFont: NSFont { DSFont.ui(14, weight: .medium) }
    static var detailFont: NSFont { DSFont.ui(11.5) }
    static var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
    static var timeFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular) }
    static var slimTitleFont: NSFont { DSFont.ui(13.5) }
    static var headerFont: NSFont { DSFont.ui(11.5, weight: .medium) }

    static func cardHeight(twoLines: Bool, line3: Bool) -> CGFloat {
        vPad * 2 + line1 + gap + titleLine * (twoLines ? 2 : 1) + (line3 ? gap + Self.line3 : 0)
    }

    static func height(_ item: SidebarItem, twoLines: Bool, line3: Bool) -> CGFloat {
        switch item {
        case .row(let r): r.variant == .card ? cardHeight(twoLines: twoLines, line3: line3) : 34
        case .shelfHeader: 30
        case .showMore: 30
        case .draft: vPad * 2 + line1 + gap + titleLine
        case .draftDivider: 1
        case .searchResult(let r): r.match == nil ? 34 : 50
        case .emptyText: 60
        case .noProjects: 84
        }
    }

    static func label(_ font: NSFont, _ color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = font
        f.textColor = color
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        f.cell?.truncatesLastVisibleLine = true
        f.usesSingleLineMode = lines == 1
        f.allowsDefaultTighteningForTruncation = false
        return f
    }

    /// Rows ask for the same few symbols over and over, so each is made once.
    // ponytail: never evicted; a dozen symbols in a few colors, bound it if row content ever brings arbitrary symbols
    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
        let key = "\(name) \(size) \(weight.rawValue) \(color.hash)"
        if let image = symbols[key] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        symbols[key] = image
        return image
    }

    /// An SF Symbol, a space, then the text, in one string: one label instead of an image view and a label.
    static func symbolText(_ name: String?, _ text: String, font: NSFont, color: NSColor, symbolColor: NSColor? = nil,
                           weight: NSFont.Weight = .regular) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if let name, let image = symbol(name, size: font.pointSize * 0.9, weight: weight, color: symbolColor ?? color) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image.size
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
            s.append(NSAttributedString(attachment: attachment))
            if !text.isEmpty { s.append(NSAttributedString(string: " ")) }
        }
        s.append(NSAttributedString(string: text))
        s.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: s.length))
        return s
    }
}

/// A flipped cell with frame layout. Labels only change when their text does.
class NativeSidebarCell: NSTableCellView {
    override var isFlipped: Bool { true }
    var item: SidebarItem?
    func configure(_ item: SidebarItem, list: NativeSidebarListView) { self.item = item }

    static func set(_ field: NSTextField, _ text: String) { if field.stringValue != text { field.stringValue = text } }
    static func set(_ field: NSTextField, _ text: NSAttributedString) {
        if !field.attributedStringValue.isEqual(to: text) { field.attributedStringValue = text }
    }
}

/// A card row for active and pinned threads (thread-list-v2-items.tsx:972-1180): favicon, project and status or
/// time; a title of up to two lines; branch · environment with the PR chip and the provider.
final class NativeThreadCardCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let project = NativeSidebarMetrics.label(NativeSidebarMetrics.projectFont, .secondaryLabelColor)
    let status = NativeSidebarMetrics.label(NativeSidebarMetrics.statusFont)
    let title = NativeSidebarMetrics.label(NativeSidebarMetrics.titleFont, .labelColor, lines: 2)
    let detail = NativeSidebarMetrics.label(NativeSidebarMetrics.detailFont, .secondaryLabelColor)
    let chip = NativeSidebarMetrics.label(NativeSidebarMetrics.monoFont)
    let provider = ProviderGlyphView()
    private var twoLines = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        favicon.scale = 14 / 16
        status.alignment = .right
        chip.alignment = .right
        for v in [favicon, project, status, title, detail, chip, provider] as [NSView] { addSubview(v) }
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .row(let r) = item else { return }
        typealias M = NativeSidebarMetrics
        favicon.source = r.projectIcon
        if r.projectIcon == nil { favicon.projectTitle = r.projectTitle ?? "" }
        Self.set(project, r.projectLabel ?? "")
        // Line 1's end: the status label, or the time when there is none. A pinned row leads it with a pin.
        let pin = r.isPinned ? "pin.fill" : nil
        if let top = r.topStatus, let label = r.statusLabel {
            let s = NativeSidebarRules.status(top)
            let text = NSMutableAttributedString()
            if let pin { text.append(M.symbolText(pin, "", font: M.statusFont, color: .tertiaryLabelColor)); text.append(NSAttributedString(string: "  ")) }
            text.append(M.symbolText(s.symbol, label, font: M.statusFont, color: s.color, weight: .semibold))
            Self.set(status, text)
        } else {
            Self.set(status, M.symbolText(pin, r.timeLabel, font: M.timeFont, color: .secondaryLabelColor, symbolColor: .tertiaryLabelColor))
        }
        Self.set(title, r.isRenaming ? "" : r.title)
        Self.set(detail, list.detailLine(r))
        if let badge = r.pullRequestBadge {
            Self.set(chip, M.symbolText("arrow.triangle.pull", badge.text, font: M.monoFont, color: NativeSidebarRules.pullRequestColor(badge.tone)))
            chip.toolTip = badge.label
        } else {
            Self.set(chip, "")
        }
        chip.isHidden = r.pullRequestBadge == nil
        provider.driver = r.providerIcon
        twoLines = list.titleNeedsTwoLines(r.title)
        alphaValue = r.recedes ? 0.55 : 1
        setAccessibilityLabel([r.title, r.statusLabel, r.projectLabel].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        typealias M = NativeSidebarMetrics
        let w = bounds.width, x = M.pad
        var y = M.vPad
        let statusWidth = min(ceil(status.intrinsicContentSize.width) + 2, w / 2)
        status.frame = NSRect(x: w - M.pad - statusWidth, y: y, width: statusWidth, height: M.line1)
        favicon.frame = NSRect(x: x, y: y + 1, width: 14, height: 14)
        project.frame = NSRect(x: x + 20, y: y, width: max(0, status.frame.minX - 6 - x - 20), height: M.line1)
        y += M.line1 + M.gap
        let titleHeight = M.titleLine * (twoLines ? 2 : 1)
        title.frame = NSRect(x: x, y: y, width: w - 2 * x, height: titleHeight)
        y += titleHeight + M.gap
        provider.frame = NSRect(x: w - M.pad - 14, y: y, width: 14, height: 14)
        let chipWidth = chip.isHidden ? 0 : ceil(chip.intrinsicContentSize.width) + 2
        chip.frame = NSRect(x: provider.frame.minX - 6 - chipWidth, y: y, width: chipWidth, height: M.line3)
        detail.frame = NSRect(x: x, y: y, width: max(0, chip.frame.minX - 6 - x), height: M.line3)
    }

    /// The title's frame in the cell, for the rename field.
    var titleFrame: NSRect { title.frame }
}

/// A slim row for settled and snoozed threads (thread-list-v2-items.tsx:1240-1300): a faded favicon, a muted
/// title and the time, or the wake countdown.
final class NativeThreadSlimCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let title = NativeSidebarMetrics.label(NativeSidebarMetrics.slimTitleFont, .secondaryLabelColor)
    let time = NativeSidebarMetrics.label(NativeSidebarMetrics.timeFont, .tertiaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        favicon.scale = 14 / 16
        favicon.alphaValue = 0.4
        time.alignment = .right
        for v in [favicon, title, time] as [NSView] { addSubview(v) }
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .row(let r) = item else { return }
        favicon.source = r.projectIcon
        if r.projectIcon == nil { favicon.projectTitle = r.projectTitle ?? "" }
        Self.set(title, r.isRenaming ? "" : r.title)
        Self.set(time, r.snoozeLabel ?? r.timeLabel)
        alphaValue = r.recedes ? 0.55 : 1
        setAccessibilityLabel(r.title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, x = NativeSidebarMetrics.pad
        let timeWidth = ceil(time.intrinsicContentSize.width) + 2
        time.frame = NSRect(x: w - x - timeWidth, y: (h - 16) / 2, width: timeWidth, height: 16)
        favicon.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
        title.frame = NSRect(x: x + 22, y: (h - 18) / 2, width: max(0, time.frame.minX - 8 - x - 22), height: 18)
    }

    var titleFrame: NSRect { title.frame }
}

/// A shelf header (thread-list-v2-items.tsx:145-215): the label with its count, a rule and a chevron that
/// points down while collapsed and up while open.
final class NativeShelfHeaderCell: NativeSidebarCell {
    let label = NativeSidebarMetrics.label(NativeSidebarMetrics.headerFont, .secondaryLabelColor)
    let rule = NSBox()
    let chevron = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        rule.boxType = .separator
        chevron.contentTintColor = .tertiaryLabelColor
        for v in [label, rule, chevron] as [NSView] { addSubview(v) }
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .shelfHeader(_, let text, let expanded) = item else { return }
        Self.set(label, text)
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        setAccessibilityLabel(text)
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, x = NativeSidebarMetrics.pad, y = bounds.height - 18
        let labelWidth = ceil(label.intrinsicContentSize.width) + 2
        label.frame = NSRect(x: x, y: y, width: labelWidth, height: 16)
        chevron.frame = NSRect(x: w - x - 12, y: y + 2, width: 12, height: 12)
        rule.frame = NSRect(x: label.frame.maxX + 8, y: y + 8, width: max(0, chevron.frame.minX - 8 - label.frame.maxX - 8), height: 1)
    }
}

/// "Show N more" under the settled shelf, "Searching…", "No threads found" and the other one-line rows.
final class NativeTextCell: NativeSidebarCell {
    let label = NativeSidebarMetrics.label(DSFont.ui(12), .secondaryLabelColor)
    let button = NSButton(title: "Add project", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        button.bezelStyle = .push
        button.controlSize = .small
        button.isHidden = true
        addSubview(label)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        button.isHidden = true
        switch item {
        case .showMore(let count):
            Self.set(label, "Show \(count) more")
            label.textColor = .controlAccentColor
        case .emptyText(let text, _):
            Self.set(label, text)
            label.textColor = .secondaryLabelColor
        case .noProjects:
            Self.set(label, "No projects yet")
            label.textColor = .secondaryLabelColor
            button.isHidden = false
            button.target = list
            button.action = #selector(NativeSidebarListView.addProjectPressed)
        default: break
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        if button.isHidden {
            label.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: w - 16, height: 16)
        } else {
            label.frame = NSRect(x: 8, y: 20, width: w - 16, height: 16)
            button.sizeToFit()
            button.frame.origin = NSPoint(x: (w - button.frame.width) / 2, y: 44)
        }
    }
}

/// A draft row: the project, "Draft", then the prompt's first line (T3 Mobile's pending tasks).
final class NativeDraftCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let project = NativeSidebarMetrics.label(NativeSidebarMetrics.projectFont, .secondaryLabelColor)
    let draftTag = NativeSidebarMetrics.label(NativeSidebarMetrics.statusFont, .tertiaryLabelColor)
    let preview = NativeSidebarMetrics.label(NativeSidebarMetrics.titleFont)

    override init(frame: NSRect) {
        super.init(frame: frame)
        favicon.scale = 14 / 16
        draftTag.alignment = .right
        draftTag.stringValue = "Draft"
        for v in [favicon, project, draftTag, preview] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .draft(let d) = item else { return }
        favicon.source = d.projectIcon
        if d.projectIcon == nil { favicon.projectTitle = d.projectTitle ?? "" }
        Self.set(project, d.projectLabel ?? "")
        Self.set(preview, d.preview)
        setAccessibilityLabel("Draft: \(d.preview)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        typealias M = NativeSidebarMetrics
        let w = bounds.width, x = M.pad, y = M.vPad
        draftTag.frame = NSRect(x: w - x - 40, y: y, width: 40, height: M.line1)
        favicon.frame = NSRect(x: x, y: y + 1, width: 14, height: 14)
        project.frame = NSRect(x: x + 20, y: y, width: max(0, draftTag.frame.minX - 6 - x - 20), height: M.line1)
        preview.frame = NSRect(x: x, y: y + M.line1 + M.gap, width: w - 2 * x, height: M.titleLine)
    }
}

/// A search result: favicon, title and time, and under it the server's message match as "You:" or "Agent:".
final class NativeSearchResultCell: NativeSidebarCell {
    let favicon = ProjectMonogramView()
    let title = NativeSidebarMetrics.label(DSFont.ui(13.5, weight: .medium))
    let time = NativeSidebarMetrics.label(NativeSidebarMetrics.timeFont, .tertiaryLabelColor)
    let excerpt = NativeSidebarMetrics.label(NativeSidebarMetrics.detailFont, .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        favicon.scale = 14 / 16
        time.alignment = .right
        for v in [favicon, title, time, excerpt] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ item: SidebarItem, list: NativeSidebarListView) {
        super.configure(item, list: list)
        guard case .searchResult(let r) = item else { return }
        favicon.source = r.projectIcon
        if r.projectIcon == nil { favicon.projectTitle = r.projectTitle ?? "" }
        Self.set(title, r.title)
        Self.set(time, r.timeLabel)
        if let match = r.match {
            let snippet = match.snippet.replacingOccurrences(of: "\n", with: " ")
            Self.set(excerpt, "\(match.isUser ? "You" : "Agent"): \(snippet)")
        }
        excerpt.isHidden = r.match == nil
        setAccessibilityLabel(r.title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, x = NativeSidebarMetrics.pad, y: CGFloat = excerpt.isHidden ? (bounds.height - 18) / 2 : 7
        let timeWidth = ceil(time.intrinsicContentSize.width) + 2
        time.frame = NSRect(x: w - x - timeWidth, y: y + 1, width: timeWidth, height: 16)
        favicon.frame = NSRect(x: x, y: y + 2, width: 14, height: 14)
        title.frame = NSRect(x: x + 22, y: y, width: max(0, time.frame.minX - 8 - x - 22), height: 18)
        excerpt.frame = NSRect(x: x + 22, y: y + 20, width: max(0, w - 2 * x - 22), height: 16)
    }
}
