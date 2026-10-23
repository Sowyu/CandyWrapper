import AppKit
import DesignSystem

/// Redesign's header controls, after Capy's tab bar: one slim frosted pill at the right of the window's tab band, so the
/// tabs keep the room. It holds the cost, the actions button (the header's details toggle, drawn as an ellipsis), the
/// terminal toggle, the diff totals and the right panel toggle. The actions button opens one menu with what the retired
/// details card offered: Open in editor, the project scripts, the git actions and Lineage. Each controller fills its own
/// section. `ThreadHeaderView` owns the pill and moves its cost and toggles in; the app hands it to the tab strip.
public final class DitherHeaderPillView: DSView {
    /// The working tree's totals; a click shows the diff, as the card's Changes row did.
    public let changes = ButtonView(nil, variant: .ghost, size: .xs)
    public let totals = DiffTotalsView()
    /// The agent image gallery's toggle, between the actions and the terminal toggle. Shown while the thread has images.
    public let gallery = ToggleView(nil, icon: .image, variant: .ghost, size: .xs)
    public var galleryCount = 0 { didSet { if (galleryCount > 0) != (oldValue > 0) { resized() } } }
    /// A dot on the toggle while images arrived since the gallery last showed.
    public var galleryUnseen = false { didSet { if galleryUnseen != oldValue { galleryDot.isHidden = !galleryUnseen } } }
    private let galleryDot = CALayer()

    /// Whether the totals show: a checkout that is a repository.
    public var showsVersionControl = false { didSet { if showsVersionControl != oldValue { resized() } } }
    public var isRepo = true { didSet { if isRepo != oldValue { resized() } } }

    /// The actions menu's sections, in this order, each separated from the last. An empty section is left out.
    public enum MenuSection: CaseIterable, Sendable { case editor, scripts, git, lineage }
    public var menuSections: [MenuSection: @MainActor () -> [MenuItem]] = [:]

    /// The actions menu's rows as of now.
    public func menuItems() -> [MenuItem] {
        var items: [MenuItem] = []
        for section in MenuSection.allCases {
            let rows = menuSections[section]?() ?? []
            guard !rows.isEmpty else { continue }
            if !items.isEmpty { items.append(.separator) }
            items += rows
        }
        return items
    }

    /// The header's views placed among the pill's own: cost, the actions and terminal toggles, the totals, then the
    /// right panel toggle.
    var cost: NSView?
    var toggles: [NSView] = []

    private let frost = BackdropBlurView()
    /// As tall as the tabs, with 24pt controls 2pt in, so their hover fills stay inside the rim.
    private static let inset: CGFloat = 2, control: CGFloat = 24

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(frost)
        changes.accessory = totals
        totals.glyphOffset = 1
        changes.setAccessibilityLabel("Show changes")
        changes.toolTip = "Show changes"
        addSubview(changes)
        gallery.toolTip = "Agent images (⇧⌘I)"
        gallery.setAccessibilityLabel("Agent images")
        galleryDot.isHidden = true
        galleryDot.cornerRadius = 3
        gallery.layer?.addSublayer(galleryDot)
        addSubview(gallery)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Thread controls")
    }

    public func resized() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The views in order, each with its visibility now.
    private var arranged: [(NSView, Bool)] {
        var views: [(NSView, Bool)] = []
        if let cost = cost as? ThreadCostPillView { views.append((cost, cost.breakdown != nil)) }
        if toggles.count == 3 {
            views += [(toggles[0], true), (gallery, galleryCount > 0), (toggles[1], true), (changes, showsVersionControl && isRepo), (toggles[2], true)]
        }
        return views.filter { $0.0.superview === self }
    }

    public override var intrinsicContentSize: NSSize {
        let shown = arranged.filter(\.1).map { $0.0.intrinsicContentSize.width }
        guard !shown.isEmpty else { return NSSize(width: 0, height: DitherTabStripView.tabHeight) }
        return NSSize(width: shown.reduce(0, +) + 2 * Self.inset, height: DitherTabStripView.tabHeight)
    }

    public override func layout() {
        super.layout()
        var x = Self.inset
        for (view, shown) in arranged {
            view.isHidden = !shown
            guard shown else { continue }
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: x, y: ((bounds.height - Self.control) / 2).rounded(), width: size.width, height: Self.control)
            x += size.width
        }
        // The cost appearing or a toggle hiding changes the width the tab strip gives the pill.
        if abs(intrinsicContentSize.width - bounds.width) > 0.5 { superview?.needsLayout = true }
        frost.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        galleryDot.frame = NSRect(x: gallery.bounds.width - 8, y: 3, width: 6, height: 6)
        galleryDot.backgroundColor = Themed.color(\.primary).cgColor(in: self)
        CATransaction.commit()
        frost.cornerRadius = DitherChrome.controlRadius
        frost.layer?.borderWidth = 1
        frost.layer?.borderColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
