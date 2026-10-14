import AppKit
import DesignSystem

/// Glass Native's visual spec in code (docs/glass-native.md, "Visual spec"). Every native view takes its insets,
/// sizes and icon style from here.
@MainActor
enum NativeSpec {
    /// The sidebar's surfaces (search field, row fills, footer buttons) start this far from the column's edges.
    static let edge: CGFloat = 8
    /// Text and glyphs inside a row fill start this far in from the fill.
    static let rowPad: CGFloat = 10
    /// Icon buttons: a square hit target with the glyph centered, 28 in the search row and 32 in the footer, as
    /// classic has them (`size-7` and `size-8`).
    static let iconButton: CGFloat = 28
    static let footerButton: CGFloat = 32
    /// SF Symbols in the sidebar's search row and footer.
    static let iconPointSize: CGFloat = 14
    static let iconWeight: NSFont.Weight = .regular
    /// Hover, pressed and selected fills share one corner radius; text fields and buttons take the small one.
    static let radiusSmall: CGFloat = 6
    static let radiusRow: CGFloat = 8

    /// T3's own Lucide glyph as a template image, for an icon SF Symbols has no legible match for at this size
    /// (git-pull-request-arrow). Stroked at Lucide's 2 units, round caps and joins.
    static func lucide(_ name: IconName, _ label: String, size: CGFloat = 16) -> NSImage {
        let definition = name.definition
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let vb = definition.viewBox
            let scale = min(rect.width / vb.width, rect.height / vb.height)
            for element in definition.elements {
                guard let path = try? element.shape.cgPath() else { continue }
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                cg.translateBy(x: -vb.x + element.paint.offsetX, y: -vb.y + element.paint.offsetY)
                cg.addPath(path)
                cg.setLineWidth(element.paint.strokeWidth)
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.setStrokeColor(NSColor.black.cgColor)
                cg.strokePath()
                cg.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// The search row's and footer's glyph, from the shared cache. The button carries the label.
    static func icon(_ symbol: String, _ label: String) -> NSImage? {
        NativeSidebarMetrics.symbol(symbol, size: iconPointSize, weight: iconWeight)
    }
}

/// A plain icon button in T3's ghost style: no bezel, a muted glyph, and the sidebar's hover and pressed fills
/// (`hover:bg-accent`). Tracking areas only, so it costs nothing while idle.
final class NativeIconButton: NSButton {
    private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    /// A filled state for toggles such as the scoped project filter.
    var isOn = false { didSet { if isOn != oldValue { restyle() } } }
    private var tracking: NSTrackingArea?

    /// `text` puts a word after the glyph, as on the rows' Settle button.
    /// The glyph comes from the shared symbol cache: a fresh symbol image per button costs about 40 KB in its
    /// representation and raster, and every card has two of these.
    convenience init(_ symbol: String, _ label: String, text: String? = nil, pointSize: CGFloat = NativeSpec.iconPointSize) {
        self.init(image: NativeSidebarMetrics.symbol(symbol, size: pointSize, weight: NativeSpec.iconWeight), label, text: text)
    }

    init(image: NSImage?, _ label: String, text: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: NativeSpec.iconButton, height: NativeSpec.iconButton))
        self.image = image
        isBordered = false
        bezelStyle = .accessoryBarAction
        if let text {
            title = text
            font = SB.font(12, .medium)
            imagePosition = .imageLeading
            imageHugsTitle = true
        } else {
            title = ""
            imagePosition = .imageOnly
        }
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = NativeSpec.radiusSmall
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    /// A button hidden under the pointer (the footer on a utility page) gets no exit event.
    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
    }
    override var isHighlighted: Bool { didSet { if isHighlighted != oldValue { restyle() } } }
    override var isEnabled: Bool { didSet { restyle() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let fill: NSColor? = !isEnabled ? nil : isHighlighted ? SB.c(\.sidebarRowActive) : hovered || isOn ? SB.c(\.accent) : nil
        layer?.backgroundColor = fill?.cgColor(in: self)
        contentTintColor = !isEnabled ? SB.c(\.mutedForeground, 0.5) : isOn ? .controlAccentColor
            : hovered ? SB.c(\.foreground) : SB.c(\.mutedForeground)
    }
}

/// The sidebar's search row in Glass Native, where T3 Code desktop has it (SidebarThreadHeader.tsx): the search
/// field, then the project filter, Add project and New thread.
final class NativeSidebarChrome: NSView, NSSearchFieldDelegate {
    let search = NSSearchField()
    let filter = NativeIconButton("folder", "Filter threads by project")
    let addProject = NativeIconButton("folder.badge.plus", "Add project")
    let newThread = NativeIconButton("square.and.pencil", "New thread")
    var onChange: ((String) -> Void)?
    /// The field's key commands (arrows, Return, Escape) while searching; true when handled.
    var onCommand: ((Selector) -> Bool)?
    /// Without projects there is nothing to scope or add to (SidebarThreadHeader.tsx:127-135).
    var hasProjects = true { didSet { if hasProjects != oldValue { needsLayout = true } } }
    static let height: CGFloat = 28

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = true
        search.controlSize = .large
        search.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        for v in [search, filter, addProject, newThread] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The project scope applies: the folder fills and names the project.
    func setScope(_ label: String?) {
        filter.image = NativeSpec.icon(label == nil ? "folder" : "folder.fill", "Filter threads by project")
        filter.isOn = label != nil
        let text = label.map { "Filter threads by project: \($0)" } ?? "Filter threads by project"
        filter.toolTip = text
        filter.setAccessibilityLabel(text)
    }

    @objc private func searchChanged() { onChange?(search.stringValue) }
    func controlTextDidChange(_ obj: Notification) { onChange?(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool { onCommand?(selector) ?? false }

    override func layout() {
        super.layout()
        // The field and the buttons share one 28pt line, the field's left edge on the rows' fill edge, the last
        // button's right edge on the fills' right edge.
        let side = NativeSpec.iconButton, h = Self.height
        var right = bounds.width - NativeSpec.edge
        for b in [newThread, addProject, filter] {
            b.isHidden = b !== newThread && !hasProjects
            if b.isHidden { continue }
            b.frame = NSRect(x: right - side, y: (bounds.height - side) / 2, width: side, height: side)
            right -= side
        }
        search.frame = NSRect(x: NativeSpec.edge, y: (bounds.height - h) / 2, width: max(0, right - 4 - NativeSpec.edge), height: h)
    }
}

/// The sidebar's footer in Glass Native, where T3 Code desktop has it (SidebarChrome.tsx): Settings, Pull Requests
/// and Usage as icon buttons, or Back on a utility page.
final class NativeSidebarFooter: NSView {
    let settings = NativeIconButton("gearshape", "Settings")
    let pullRequests = NativeIconButton(image: NativeSpec.lucide(.gitPullRequestArrow, "Pull Requests"), "Pull Requests")
    let usage = NativeIconButton("chart.bar", "Usage")
    /// Back shows only on Pull Requests and Usage, so it is made the first time one opens.
    private(set) var back: SidebarMenuButtonView?
    /// Set once by the sidebar, for Back when it is made.
    var onBack: (() -> Void)?
    var showsBack = false {
        didSet {
            if showsBack, back == nil { makeBack() }
            needsLayout = true
        }
    }
    var showsPullRequests = true { didSet { needsLayout = true } }
    /// Room the update pill takes at the right end.
    var trailingRoom: CGFloat = 0 { didSet { needsLayout = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [settings, pullRequests, usage] as [NSView] { addSubview(v) }
    }

    private func makeBack() {
        // T3's `SidebarMenuButton` (SidebarChrome.tsx:204-212): 14 pt text and a 16 pt arrow on the rows' 18 pt line, the same
        // row Settings shows in this window. An `NSButton` drew 13 pt text with its arrow at the fill's edge.
        let b = SidebarMenuButtonView("Back", icon: .arrowLeft)
        b.action = { [weak self] in self?.onBack?() }
        addSubview(b)
        back = b
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // `SidebarMenu`: icon buttons 4pt apart from the rows' fill edge, or Back across the row.
        let side = NativeSpec.footerButton, y = (bounds.height - side) / 2
        var x = NativeSpec.edge
        for b in [settings, pullRequests, usage] {
            b.isHidden = showsBack || b === pullRequests && !showsPullRequests
            if b.isHidden { continue }
            b.frame = NSRect(x: x, y: y, width: side, height: side)
            x += side + 4
        }
        back?.isHidden = !showsBack
        back?.frame = NSRect(x: NativeSpec.edge, y: y, width: max(0, bounds.width - 2 * NativeSpec.edge - trailingRoom), height: side)
    }
}
