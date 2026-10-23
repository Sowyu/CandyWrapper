import AppKit
import DesignSystem

/// Redesign's header controls, after Capy's tab bar: one frosted pill at the right of the window's tab band. It holds
/// what the header and the retired details card offered: the cost, Open in editor, the project scripts, the git
/// action (or Initialize Git), Lineage, the terminal toggle, and the right panel toggle with the diff totals before it.
/// `ThreadHeaderView` owns it and moves its cost and toggles in; the app hands it to the tab strip.
public final class DitherHeaderPillView: DSView {
    /// Open the workspace in the preferred editor; the chevron or a right click picks another.
    public let openIn = DetailsSplitControl()
    /// Run the primary project script; the chevron lists every script and "Add project script".
    public let scripts = DetailsSplitControl()
    /// The git quick action with its menu.
    public let gitActions = DetailsSplitControl()
    public let initGit = ButtonView("Initialize Git", icon: .gitBranchPlus, variant: .ghost, size: .sm)
    /// The working tree's totals; a click shows the diff, as the card's Changes row did.
    public let changes = ButtonView(nil, variant: .ghost, size: .sm)
    public let totals = DiffTotalsView()

    public var showsOpenIn = false { didSet { if showsOpenIn != oldValue { resized() } } }
    public var scriptsRow: ThreadDetailsCardView.ScriptsRow? { didSet { if scriptsRow != oldValue { updateScripts() } } }
    /// The git controls' inputs, as on the card: a checkout to show, a repository, a project for the actions.
    public var showsVersionControl = false { didSet { if showsVersionControl != oldValue { resized() } } }
    public var isRepo = true { didSet { if isRepo != oldValue { resized() } } }
    public var showsGitActions = true { didSet { if showsGitActions != oldValue { resized() } } }
    /// The Lineage toggle shows only while the thread has pull requests, automations or relatives.
    public var showsRelations = false { didSet { if showsRelations != oldValue { resized() } } }

    /// The header's views placed among the pill's own: cost first, then the details (Lineage) and terminal toggles
    /// after the git controls, then the right panel toggle after the totals.
    var cost: NSView?
    var toggles: [NSView] = []

    private let frost = BackdropBlurView()
    private static let gap: CGFloat = 2, inset: CGFloat = 2

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(frost)
        for split in [openIn, scripts, gitActions] {
            split.compact = true
            split.onResize = { [weak self] in self?.resized() }
            addSubview(split)
        }
        openIn.secondary.setAccessibilityLabel("Choose editor")
        scripts.secondary.setAccessibilityLabel("Script actions")
        changes.accessory = totals
        changes.setAccessibilityLabel("Show changes")
        changes.toolTip = "Show changes"
        initGit.smoothsFont = false
        for v in [initGit, changes] as [NSView] { addSubview(v) }
        updateScripts()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Thread controls")
    }

    private func updateScripts() {
        switch scriptsRow {
        case .run(let name, let icon):
            scripts.primary.icon = icon.definition
            scripts.primary.setAccessibilityLabel("Run \(name)")
            scripts.primary.toolTip = "Run \(name)"
        case .actions:
            scripts.primary.icon = IconName.wrench.definition
            scripts.primary.setAccessibilityLabel("Project actions")
            scripts.primary.toolTip = "Project actions"
        case .add:
            scripts.primary.icon = IconName.plus.definition
            scripts.primary.setAccessibilityLabel("Add project script")
            scripts.primary.toolTip = "Add project script"
        case nil:
            break
        }
        resized()
    }

    public func resized() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
    }

    /// The views in order, each with its visibility now.
    private var arranged: [(NSView, Bool)] {
        let git = showsVersionControl && showsGitActions
        var views: [(NSView, Bool)] = []
        if let cost = cost as? ThreadCostPillView { views.append((cost, cost.breakdown != nil)) }
        views += [(openIn, showsOpenIn), (scripts, scriptsRow != nil), (gitActions, git && isRepo), (initGit, git && !isRepo)]
        if toggles.count == 3 {
            views += [(toggles[0], showsRelations), (toggles[1], true), (changes, showsVersionControl && isRepo), (toggles[2], true)]
        }
        return views.filter { $0.0.superview === self }
    }

    private func width(_ view: NSView) -> CGFloat {
        (view as? DetailsSplitControl)?.preferredWidth ?? view.intrinsicContentSize.width
    }

    public override var intrinsicContentSize: NSSize {
        let shown = arranged.filter(\.1).map { width($0.0) }
        guard !shown.isEmpty else { return NSSize(width: 0, height: 32) }
        return NSSize(width: shown.reduce(0, +) + Self.gap * CGFloat(shown.count - 1) + 2 * Self.inset, height: 32)
    }

    public override func layout() {
        super.layout()
        var x = Self.inset
        for (view, shown) in arranged {
            view.isHidden = !shown
            guard shown else { continue }
            let w = width(view), h = view is DetailsSplitControl ? 28 : view.intrinsicContentSize.height
            view.frame = NSRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
            x += w + Self.gap
        }
        // The cost appearing or a toggle hiding changes the width the tab strip gives the pill.
        if abs(intrinsicContentSize.width - bounds.width) > 0.5 { superview?.needsLayout = true }
        frost.frame = bounds
        frost.cornerRadius = DitherChrome.controlRadius
        frost.layer?.borderWidth = 1
        frost.layer?.borderColor = DitherChrome.rim(dark: effectiveAppearance.isDark).cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
