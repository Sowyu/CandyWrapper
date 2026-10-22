import AppKit
import DesignSystem

/// The `/`, `@`, `$` and `#` menu (chat/ComposerCommandMenu.tsx): rows on the attached banner
/// glass (`ComposerBanner.Surface`, no row padding), docked like the request drawer, 22pt in from
/// the composer's sides with its bottom 17pt under the composer's top.
///
/// List: `p-2`, at most 288 tall (`max-h-72`), rows `min-h-7 px-2 py-1.5 gap-2 rounded-sm`, the
/// active row `bg-accent text-accent-foreground`. A row is an icon (paths, threads, pull requests),
/// the label (`text-xs font-medium`, at most 45%), the description (`text-xs text-secondary-label`)
/// and, for skills, a source badge. With no rows: one `text-xs` line, `px-5 pt-3.5 pb-7`.
public final class ComposerCommandMenuView: ComposerBannerView {
    public var items: [ComposerMenuItem] = [] { didSet { if items != oldValue { rebuild() } } }
    public var activeItemId: String? { didSet { if activeItemId != oldValue { updateActive(scroll: true) } } }
    /// Shown when `items` is empty.
    public var emptyText = "" { didSet { empty.text = emptyText } }
    /// Mouse hover moves the highlight; a click picks.
    public var onHighlight: ((String) -> Void)?
    public var onSelect: ((ComposerMenuItem) -> Void)?

    static let listPad: CGFloat = 8, maxListHeight: CGFloat = 288

    /// `min-h-7`; a skill's 18pt badge plus `py-1.5` makes its row 30.
    static func rowHeight(_ item: ComposerMenuItem) -> CGFloat {
        if case .skill = item.kind { return 30 }
        return 28
    }

    private var contentHeight: CGFloat { items.reduce(0) { $0 + Self.rowHeight($1) } + 2 * Self.listPad }

    private let document = FlippedView()
    private lazy var scroll = ScrollAreaView(documentView: document, scrollFade: true)
    private var rows: [MenuRowView] = []
    private let empty = glassLabel(font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)

    public init() {
        super.init(variant: .neutral)
        // Under a full-size content view AppKit would inset the list by the titlebar's safe area.
        scroll.scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        addSubview(empty)
        setAccessibilityRole(.list)
    }

    /// The menu's height with its 17pt overlap under the composer.
    public var preferredHeight: CGFloat {
        if items.isEmpty { return 14 + 16 + 28 + Self.overlap }
        return min(Self.maxListHeight, contentHeight) + Self.overlap
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = MenuRowView(item)
            row.onHover = { [weak self] in self?.onHighlight?(item.id) }
            row.onClick = { [weak self] in self?.onSelect?(item) }
            document.addSubview(row)
            return row
        }
        scroll.isHidden = items.isEmpty
        empty.isHidden = !items.isEmpty
        scroll.scroll(to: .zero)
        needsLayout = true
        updateActive(scroll: false)
    }

    private func updateActive(scroll reveal: Bool) {
        for row in rows { row.isActive = row.item.id == activeItemId }
        guard reveal else { return }
        if bounds.height == 0 || needsLayout { pendingReveal = true; needsLayout = true; return }
        revealActive()
    }

    private var pendingReveal = false

    private func revealActive() {
        pendingReveal = false
        guard let row = rows.first(where: { $0.isActive }) else { return }
        // `scrollIntoView({ block: "nearest" })`, keeping the 8pt list padding (`scroll-py-2`).
        let visible = scroll.scrollView.contentView.bounds
        guard visible.height > 0 else { return }
        let target = row.frame.insetBy(dx: 0, dy: -Self.listPad)
        if target.minY < visible.minY {
            scroll.scroll(to: NSPoint(x: 0, y: max(0, target.minY)))
        } else if target.maxY > visible.maxY {
            scroll.scroll(to: NSPoint(x: 0, y: target.maxY - visible.height))
        }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        let listHeight = max(0, bounds.height - tail)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: listHeight)
        document.frame = NSRect(x: 0, y: 0, width: w, height: contentHeight)
        var y = Self.listPad
        for row in rows {
            let h = Self.rowHeight(row.item)
            row.frame = NSRect(x: Self.listPad, y: y, width: max(0, w - 2 * Self.listPad), height: h)
            y += h
        }
        empty.frame = NSRect(x: 20, y: 14, width: max(0, w - 40), height: 16)
        scroll.layoutSubtreeIfNeeded()
        // A scroll past the end (fewer rows than before) snaps back.
        let clip = scroll.scrollView.contentView.bounds
        if clip.maxY > document.frame.height { scroll.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - clip.height))) }
        if pendingReveal { revealActive() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One `ComposerCommandMenuItem` row.
private final class MenuRowView: DSView {
    let item: ComposerMenuItem
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true; restyle() } } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private var icon: IconView?
    private let label = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground), lineHeight: 16)
    /// `/skill:` before a skill's name in the `/` menu.
    private let prefix = glassLabel(font: DSFont.ui(12, weight: .medium), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private let detail = glassLabel(font: DSFont.ui(12), color: Themed.color(\.secondaryLabel), lineHeight: 16)
    private var badge: BadgeView?
    private var trackingArea: NSTrackingArea?

    init(_ item: ComposerMenuItem) {
        self.item = item
        super.init(frame: .zero)
        switch item.kind {
        case .path(let path, let isDirectory):
            let meta = FileLinkMeta(filePath: path, targetPath: path, workspaceRelativePath: path,
                                    basename: (path as NSString).lastPathComponent, line: nil, column: nil)
            let (definition, color) = isDirectory ? (IconName.folder.definition, FileChipStyle.iconMuted) : FileChipStyle.icon(for: meta)
            icon = IconView(definition: definition, size: 16, color: color)
        case .thread:
            icon = IconView(name: .messagesSquare, size: 16, strokeColor: Themed.color(\.secondaryLabel))
        case .pullRequest(let pr):
            let (name, color): (IconName, NSColor) = switch pr.displayState {
            // `PULL_REQUEST_STATE_PRESENTATION` tones.
            case "draft": (.gitPullRequestDraft, Themed.base("zinc-500", dark: "zinc-400", 0.8))
            case "closed": (.gitPullRequestClosed, Themed.base("red-600", dark: "red-300", 0.9))
            case "merged": (.gitMerge, Themed.base("violet-600", dark: "violet-300", 0.9))
            default: (.gitPullRequestArrow, Themed.base("emerald-600", dark: "emerald-300", 0.9))
            }
            icon = IconView(name: name, size: 16, strokeColor: color)
        case .skill(_, let source, let viaSlash):
            let (badgeIcon, title): (IconName, String) = switch source {
            case .app: (.blocks, "App")
            case .repo: (.folder, "Repo")
            case .project: (.folder, "Project")
            case .personal: (.userRound, "Personal")
            case .system: (.settings, "System")
            case .other: (.package, "Provider")
            }
            let b = BadgeView(viaSlash ? title : title + " Skill", variant: .secondary, icon: badgeIcon)
            badge = b
            if viaSlash {
                prefix.text = "/skill:"
                label.text = String(item.label.dropFirst("/skill:".count))
            }
        default: break
        }
        if label.text.isEmpty { label.text = item.label }
        detail.text = item.description
        [icon, prefix, label, detail, badge].compactMap { $0 }.forEach(addSubview)
        prefix.isHidden = prefix.text.isEmpty
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.label)
        restyle()
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        let midY = bounds.height / 2
        if let icon {
            icon.frame = NSRect(x: x, y: midY - 8, width: 16, height: 16)
            x += 16 + 8
        }
        var right = bounds.width - 8
        if let badge {
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: right - size.width, y: midY - size.height / 2, width: size.width, height: size.height)
        }
        // `max-w-[45%]` of the inner span (the badge is inside it, after the description).
        let span = max(0, right - x)
        let prefixWidth = prefix.isHidden ? 0 : prefix.textWidth
        let labelWidth = min(label.textWidth, max(0, span * 0.45 - prefixWidth))
        prefix.frame = NSRect(x: x, y: midY - 8, width: prefixWidth, height: 16)
        label.frame = NSRect(x: x + prefixWidth, y: midY - 8, width: labelWidth, height: 16)
        x += prefixWidth + labelWidth + 8
        if let badge { right = badge.frame.minX - 8 }
        detail.frame = NSRect(x: x, y: midY - 8, width: max(0, right - x), height: 16)
    }

    private func restyle() {
        label.color = isActive ? Themed.color(\.accentForeground) : Themed.color(\.foreground)
    }

    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = isActive ? Themed.color(\.accent).cgColor(in: self) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { if !isActive { onHover?() } }
    // `onMouseDown` prevents default so the editor keeps focus; the pick happens on click.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
