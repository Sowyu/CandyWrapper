import AppKit
import DesignSystem

/// Fill under a hovered or open panel control (threadDetailsPanelStyles.ts:9-10): black 3.5% in light,
/// white 8% in dark.
@MainActor
func detailsHoverFill() -> NSColor { Themed.pick(light: Themed.black(0.035), dark: Themed.white(0.08)) }

/// `ThreadDetailsControl` in the panel (ThreadDetailsControl.tsx, threadDetailsPanelStyles.ts): a 32pt row,
/// radius 10, `px-2.5 gap-2.5`, a 16pt muted icon (or two, 2 apart), 13pt medium text in `foreground/80`.
/// `.select` ends in a 32pt chevron cell behind a 16pt `border/65` rule; `.locked` is the static row; `.row`
/// may carry a trailing view (the Changes totals). Hover and open fill with `detailsHoverFill`.
public final class DetailsRowControl: ControlView {
    public var onContextMenu: ((NSEvent, NSView) -> Void)?
    public override func rightMouseDown(with event: NSEvent) { onContextMenu?(event, self) }
    public enum Kind: Sendable { case row, select, locked }
    public var kind: Kind { didSet { if kind != oldValue { update() } } }
    public var icons: [IconDefinition] = [] { didSet { if icons != oldValue { rebuildIcons() } } }
    public var text = "" { didSet { label.text = middleTruncates ? "" : text; middle.value = middleTruncates ? text : ""; needsLayout = true } }
    public var middleTruncates = false { didSet { label.isHidden = middleTruncates; middle.isHidden = !middleTruncates; let t = text; text = t } }
    /// A tone for the icons in place of the muted one (a pull request row wears its state's).
    public var iconColor: NSColor? { didSet { restyle() } }
    /// The split group's 32pt secondary cell after a 16pt rule (`THREAD_DETAILS_PANEL_SPLIT_*`): the row is
    /// then the group, which fills on hover, and the primary part fills again under the mouse.
    public var secondary: ControlView? { didSet { oldValue?.removeFromSuperview(); secondary.map(addSubview); update() } }
    /// A view right of the label (`flex-1` label, then this at its natural size).
    public var trailing: NSView? { didSet { oldValue?.removeFromSuperview(); trailing.map(addSubview); needsLayout = true } }
    /// The hover tooltip (attached on first use; T3 shows the workspace path on the run context).
    public var tooltipText: String? {
        didSet {
            if tooltip == nil, let tooltipText { tooltip = TooltipController.attach(to: self, text: tooltipText) }
            tooltip?.text = tooltipText ?? ""
        }
    }

    private var iconViews: [IconView] = []
    private let label = LabelView()
    private let middle = MiddleTruncateView("", font: DSFont.ui(13, weight: .medium))
    private let chevron = IconView(name: .chevronDown, size: 16)
    private let rule = CALayer()
    private let fill = CALayer()
    private let primaryFill = BoxDecorationLayer()
    private var tooltip: TooltipController?

    public init(kind: Kind = .row) {
        self.kind = kind
        super.init(frame: .zero)
        for l in [fill, rule] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        primaryFill.host = self
        layer?.addSublayer(primaryFill)
        layer?.addSublayer(rule)
        label.font = DSFont.ui(13, weight: .medium)
        label.lineHeight = 20
        middle.lineHeight = 20
        middle.showsTitle = false
        middle.isHidden = true
        addSubview(label)
        addSubview(middle)
        addSubview(chevron)
        update()
    }

    private func rebuildIcons() {
        iconViews.forEach { $0.removeFromSuperview() }
        iconViews = icons.map { IconView(definition: $0, size: 16) }
        iconViews.forEach(addSubview)
        restyle()
        needsLayout = true
    }

    private func update() {
        chevron.isHidden = kind != .select
        rule.isHidden = kind != .select && secondary == nil
        scalesWhenPressed = kind == .row && secondary == nil
        setAccessibilityRole(kind == .locked ? .staticText : kind == .select ? .popUpButton : .button)
        restyle()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        fill.frame = bounds
        let midY = bounds.height / 2
        var x: CGFloat = 10
        for (i, v) in iconViews.enumerated() {
            v.frame = NSRect(x: x + CGFloat(i) * 18, y: midY - 8, width: 16, height: 16)
        }
        if !iconViews.isEmpty { x += CGFloat(iconViews.count) * 16 + CGFloat(iconViews.count - 1) * 2 + 10 }
        var right = bounds.width - (kind == .select ? 0 : 10)
        if kind == .select {
            // `pe-0`, the chevron cell `w-8 -me-px` with its rule at -1.
            chevron.frame = NSRect(x: bounds.width + 1 - 32 + 8, y: midY - 8, width: 16, height: 16)
            rule.frame = CGRect(x: bounds.width + 1 - 32 - 1, y: midY - 8, width: 1, height: 16)
            right = bounds.width + 1 - 32 - 10
        }
        if let secondary {
            secondary.frame = NSRect(x: bounds.width - 32, y: 0, width: 32, height: bounds.height)
            rule.frame = CGRect(x: bounds.width - 33, y: midY - 8, width: 1, height: 16)
            right = bounds.width - 33 - 10
            primaryFill.frame = CGRect(x: 0, y: 0, width: bounds.width - 33, height: bounds.height)
            primaryFill.layout(boxSize: primaryFill.frame.size)
        }
        if let trailing {
            let w = trailing.intrinsicContentSize.width
            trailing.frame = NSRect(x: right - w, y: midY - 8, width: w, height: 16)
            right -= w + 10
        }
        let frame = NSRect(x: x, y: midY - 10, width: max(0, right - x), height: 20)
        label.frame = frame
        middle.frame = frame
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    public override func updateLayer() {
        let lit = kind != .locked && state.enabled && state.hoverOrPressed
        fill.backgroundColor = lit ? detailsHoverFill().cgColor(in: self) : nil
        var part = BoxStyle()
        part.radius = 10
        part.corners = .leading
        part.fill = lit && secondary.map { !$0.state.hoverOrPressed } == true ? detailsHoverFill() : nil
        primaryFill.boxStyle = part
        rule.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self)
    }

    private func restyle() {
        label.color = Themed.color(\.contrastForeground, 0.8)
        middle.color = Themed.color(\.contrastForeground, 0.8)
        iconViews.forEach { $0.strokeColor = iconColor ?? Themed.color(\.contrastMutedForeground) }
        chevron.strokeColor = Themed.color(\.contrastMutedForeground)
        needsDisplay = true
    }

    public override func resetCursorRects() {
        if kind != .locked { super.resetCursorRects() }
    }

    public override func performAction() {
        guard kind != .locked else { return }
        super.performAction()
    }
}

/// The git actions split button in the panel (`THREAD_DETAILS_PANEL_SPLIT_*`): a group that fills on hover
/// or while its menu is open, the primary (icon and label, `flex-1`), a 16pt rule and a 32pt chevron that
/// opens the menu. While an action runs the primary shows a spinner, the status and its last output line,
/// and the elapsed time takes the chevron's place; after it succeeds it shows a check and the result for 10 s.
public final class DetailsSplitControl: DSView {
    public let primary = DetailsSplitPart()
    public let secondary = DetailsSplitPart()
    private let rule = CALayer()
    private let fill = CALayer()
    private let elapsed = LabelView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [fill, rule] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = 10
        layer?.addSublayer(fill)
        layer?.addSublayer(rule)
        primary.corners = .leading
        secondary.corners = .trailing
        secondary.isChevron = true
        secondary.opensPopupOnPress = true // the chevron is a MenuTrigger
        elapsed.font = DSFont.ui(11)
        elapsed.lineHeight = 16
        elapsed.isHidden = true
        addSubview(primary)
        addSubview(secondary)
        addSubview(elapsed)
        primary.onStateChange = { [weak self] in self?.needsDisplay = true }
        secondary.onStateChange = { [weak self] in self?.needsDisplay = true }
        secondary.setAccessibilityLabel("Git action options")
    }

    /// `role="group"` height: 32, or taller while the progress or success row shows its second line.
    public var preferredHeight: CGFloat { primary.preferredHeight }

    /// The elapsed time in the chevron's slot while an action runs; nil shows the chevron.
    public var elapsedText: String? {
        didSet {
            elapsed.text = elapsedText ?? ""
            elapsed.isHidden = elapsedText == nil
            secondary.isHidden = elapsedText != nil
            rule.isHidden = elapsedText != nil
            needsLayout = true
            needsDisplay = true
        }
    }

    public override func layout() {
        super.layout()
        fill.frame = bounds
        let w = bounds.width
        secondary.frame = NSRect(x: w - 32, y: 0, width: 32, height: 32)
        rule.frame = CGRect(x: w - 33, y: 8, width: 1, height: 16)
        if elapsedText != nil {
            // `pe-2.5`, in the 32pt title row.
            let ew = ceil(elapsed.textWidth)
            elapsed.frame = NSRect(x: w - 10 - ew, y: 8, width: ew, height: 16)
            primary.frame = NSRect(x: 0, y: 0, width: w - 10 - ew, height: bounds.height)
        } else {
            primary.frame = NSRect(x: 0, y: 0, width: w - 33, height: bounds.height)
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { hovered = true }
    public override func mouseExited(with event: NSEvent) { hovered = false }

    public override func updateLayer() {
        // The group fills on hover and while its menu is open (`has-[[data-popup-open]]`); a running action
        // keeps a resting fill (`bg-black/[0.035] dark:bg-white/[0.055]`).
        let running = elapsedText != nil
        let lit = hovered || secondary.isPopupOpen
        fill.backgroundColor = running ? Themed.pick(light: Themed.black(0.035), dark: Themed.white(0.055)).cgColor(in: self)
            : lit ? detailsHoverFill().cgColor(in: self) : nil
        rule.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self)
        elapsed.color = Themed.color(\.contrastMutedForeground)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One half of the split button.
public final class DetailsSplitPart: ControlView {
    public enum Mode: Equatable, Sendable {
        case idle
        /// Spinner, status and the hook's last output line.
        case running(status: String, output: String?)
        /// Success check, title and description.
        case success(title: String, description: String?)
    }

    var corners: BoxStyle.Corners = .all
    var isChevron = false { didSet { rebuild() } }
    var onStateChange: (@MainActor () -> Void)?
    public var icon: IconDefinition? { didSet { if icon != oldValue { rebuild() } } }
    public var text = "" { didSet { label.text = text; needsLayout = true } }
    public var mode = Mode.idle { didSet { if mode != oldValue { rebuild() } } }
    /// `aria-disabled`: drawn at 64% but still hoverable for its reason.
    public var looksDisabled = false { didSet { applyAlpha() } }

    /// Disabled parts draw at 64%, but the progress and success rows stay opaque (`multiline`: `disabled:opacity-100`).
    private func applyAlpha() { alphaValue = looksDisabled || (!state.enabled && mode == .idle) ? 0.64 : 1 }

    private let fill = BoxDecorationLayer()
    private var iconView: IconView?
    private let label = LabelView()
    private let detail = LabelView()
    private var spinner: SpinnerView?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.host = self
        layer?.addSublayer(fill)
        label.font = DSFont.ui(13, weight: .medium)
        label.lineHeight = 20
        detail.font = DSFont.ui(11)
        detail.lineHeight = 16
        addSubview(label)
        addSubview(detail)
        rebuild()
    }

    var preferredHeight: CGFloat {
        switch mode {
        case .running(_, let output?), .success(_, let output?): _ = output; return 28 + 16 + 2 + 6
        default: return 32
        }
    }

    private func rebuild() {
        iconView?.removeFromSuperview(); iconView = nil
        spinner?.removeFromSuperview(); spinner = nil
        label.isHidden = isChevron
        detail.isHidden = true
        if isChevron {
            let v = IconView(name: .chevronDown, size: 16)
            addSubview(v); iconView = v
        } else {
            switch mode {
            case .idle:
                if let icon { let v = IconView(definition: icon, size: 16); addSubview(v); iconView = v }
                label.text = text
            case .running(let status, let output):
                let s = SpinnerView(size: .md)
                addSubview(s); spinner = s
                label.text = status
                detail.text = output ?? ""
                detail.isHidden = output == nil
            case .success(let title, let description):
                let v = IconView(name: .check, size: 14)
                addSubview(v); iconView = v
                label.text = title
                detail.text = description ?? ""
                detail.isHidden = description == nil
            }
        }
        scalesWhenPressed = mode == .idle
        restyle()
        needsLayout = true
        applyAlpha()
        onStateChange?()
    }

    public override func layout() {
        super.layout()
        fill.layout(boxSize: bounds.size)
        if isChevron {
            iconView?.frame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
            return
        }
        // Idle: the 32pt row. Running and success: a 28pt title row (`grid-rows-[1.75rem]`, `py-0.75`) with
        // the output line under it (`pt-0.5`) and a 12pt column gap.
        let multi = mode != .idle
        let titleY: CGFloat = multi ? 3 : 0, titleH: CGFloat = multi ? 28 : bounds.height
        var x: CGFloat = 10
        if let spinner {
            spinner.frame = NSRect(x: x - 2, y: titleY + (titleH - 16) / 2, width: 16, height: 16)
            x += 12 + 12
        } else if let iconView {
            let s: CGFloat = mode == .idle ? 16 : 14
            iconView.frame = NSRect(x: x, y: titleY + (titleH - s) / 2, width: s, height: s)
            x += s + (multi ? 12 : 10)
        }
        label.frame = NSRect(x: x, y: titleY + (titleH - 20) / 2, width: max(0, bounds.width - x - 10), height: 20)
        detail.frame = NSRect(x: x, y: titleY + titleH + 2, width: max(0, bounds.width - x - 10), height: 16)
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        applyAlpha()
        restyle()
        onStateChange?()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        var box = BoxStyle()
        box.radius = 10
        box.corners = corners
        let lit = mode == .idle && state.enabled && (state.hoverOrPressed)
        box.fill = lit ? detailsHoverFill() : nil
        fill.boxStyle = box
        label.color = Themed.color(\.contrastForeground, 0.8)
        detail.color = Themed.color(\.contrastMutedForeground)
        if case .success = mode { iconView?.strokeColor = Themed.color(\.success) } else { iconView?.strokeColor = Themed.color(\.contrastMutedForeground) }
        spinner?.color = Themed.color(\.contrastForeground, 0.8)
        needsDisplay = true
    }
}

/// The Changes row's totals (`font-mono text-2xs tabular-nums`, `gap-1`): `+N` in success, `-N` in destructive.
public final class DiffTotalsView: DSView {
    private let plus = LabelView()
    private let minus = LabelView()
    public var insertions = 0 { didSet { update() } }
    public var deletions = 0 { didSet { update() } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [plus, minus] { l.font = DSFont.mono(11); l.lineHeight = 16; addSubview(l) }
        update()
    }

    private func update() {
        plus.text = "+\(insertions)"
        minus.text = "-\(deletions)"
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: ceil(plus.textWidth) + 4 + ceil(minus.textWidth), height: 16) }

    public override func layout() {
        super.layout()
        plus.frame = NSRect(x: 0, y: 0, width: ceil(plus.textWidth), height: 16)
        minus.frame = NSRect(x: ceil(plus.textWidth) + 4, y: 0, width: ceil(minus.textWidth), height: 16)
    }

    public override func updateLayer() {
        plus.color = Themed.color(\.success)
        minus.color = Themed.color(\.destructive)
    }
}

/// `ThreadDetailsCard` with `ThreadDetailsPanel`'s Workspace and Version Control sections (ThreadDetailsCard.tsx,
/// ThreadDetailsPanel.tsx, ThreadDetailsSection.tsx): a `dropdown-glass` card, radius 22, 264 wide, each section
/// `px-2 pt-2 pb-2.5` and the second one under a `border/65` rule. Workspace holds the run context; Version Control
/// holds the branch, the git actions and Changes, or "Initialize Git" outside a repository.
public final class ThreadDetailsCardView: DSView {
    public static let width: CGFloat = 264

    public let runContext = DetailsRowControl(kind: .select).menuTrigger()
    /// `OpenInPicker` with `displayMode="panel"` (ThreadDetailsPanel.tsx:121-128): open the workspace in the
    /// preferred editor, the chevron picks another.
    public let openIn = DetailsSplitControl()
    public var showsOpenIn = false { didSet { if showsOpenIn != oldValue { updateRows() } } }
    /// `ProjectScriptsControl displayMode="panel"` (ProjectScriptsControl.tsx:283-470): "Run" the primary
    /// action with the chevron listing every action, "Actions" when none is a one-click action, or
    /// "Add project script" without actions. Nil hides the row (no project).
    public enum ScriptsRow: Equatable, Sendable {
        case run(name: String, icon: IconName)
        case actions
        case add
    }
    public let scripts = DetailsSplitControl()
    public let addScript = DetailsRowControl(kind: .row)
    public var scriptsRow: ScriptsRow? { didSet { if scriptsRow != oldValue { updateScripts() } } }
    public let branch = DetailsRowControl(kind: .select)
    public let gitActions = DetailsSplitControl()
    public let changes = DetailsRowControl(kind: .row)
    public let initGit = DetailsRowControl(kind: .row)
    public let totals = DiffTotalsView()
    /// The thread's pull request rows under the branch (ThreadDetailsPrRows.tsx): the current one,
    /// then the rest of its links while expanded, then "Show N more" or "Show less". A row the host
    /// answered for is a `ThreadDetailsPrRowView` (two lines), the rest are `DetailsRowControl`s.
    public var pullRequestRows: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; pullRequestRows.forEach(addSubview); relayout() }
    }

    /// Shows the Version Control section's rows for a repository; false shows "Initialize Git".
    public var isRepo = true { didSet { if isRepo != oldValue { updateRows() } } }
    /// Hides the Version Control section (`gitCwd` is null).
    public var showsVersionControl = true { didSet { if showsVersionControl != oldValue { updateRows() } } }
    /// The git actions need a project (`activeProjectName`).
    public var showsGitActions = true { didSet { if showsGitActions != oldValue { updateRows() } } }

    /// How much the card shows (ThreadDetailsPanel.tsx:100-185): `full` shows everything; `compact`
    /// drops the run context row, the Version Control rule, the idle git actions, automations and
    /// lineage; `essential` also drops Open in. The panel picks it from the height it has
    /// (`resolveDensity`).
    public enum Density: Sendable { case full, compact, essential }
    public var density = Density.full { didSet { if density != oldValue { updateRows() } } }

    /// `resolveThreadDetailsCardDensity` (threadDetailsCardLayout.ts:7-14): the richest density whose
    /// content fits `height`. T3 measures each density's content once it renders; the card knows its
    /// heights up front, so it asks for them directly.
    public static func resolveDensity(height: CGFloat, full: CGFloat, compact: CGFloat) -> Density {
        if full == 0 || full <= height { return .full }
        if compact == 0 || compact <= height { return .compact }
        return .essential
    }

    /// The density for the height the card can take. Lineage scrolls as it grows, so it does not count
    /// toward the fit (ThreadDetailsCard.tsx:93-97).
    public func density(fitting height: CGFloat) -> Density {
        Self.resolveDensity(height: height, full: preferredHeight(.full) - lineage.preferredHeight, compact: preferredHeight(.compact))
    }

    private let decoration = BoxDecorationLayer()
    private let divider = CALayer()
    /// Tasks bound to the thread (`ThreadAutomationsPanel`), separated by `border-t border-border/65`.
    public let automations = ThreadAutomationsView()
    private let automationsDivider = CALayer()
    /// Related threads and subagents (`ThreadRelationshipsPanel`), the last section; it draws its own rule.
    public let lineage = ThreadLineageSectionView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        divider.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(divider)
        automationsDivider.actions = divider.actions
        layer?.addSublayer(automationsDivider)
        addSubview(automations)
        addSubview(lineage)
        lineage.onResize = { [weak self] in self?.relayout() }
        runContext.setAccessibilityLabel("Run context")
        branch.icons = [IconName.gitBranch.definition]
        branch.middleTruncates = true
        branch.setAccessibilityLabel("Branch")
        changes.icons = [IconName.fileDiff.definition]
        changes.text = "Changes"
        changes.trailing = totals
        initGit.icons = [IconName.gitBranchPlus.definition]
        initGit.text = "Initialize Git"
        openIn.isHidden = true
        openIn.secondary.setAccessibilityLabel("Choose editor")
        scripts.isHidden = true
        scripts.secondary.setAccessibilityLabel("Script actions")
        addScript.isHidden = true
        addScript.icons = [IconName.plus.definition]
        addScript.text = "Add project script"
        for v in [runContext, openIn, scripts, addScript, branch, gitActions, changes, initGit] as [NSView] { addSubview(v) }
        // Compact shows the git actions only while one runs or reports success (GitActionsControl.tsx:1824).
        gitActions.primary.onStateChange = { [weak self] in self?.updateRows() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Thread details")
        updateRows()
    }

    private func relayout() { invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true }

    private func updateScripts() {
        switch scriptsRow {
        case .run(let name, let icon):
            scripts.primary.icon = icon.definition
            scripts.primary.text = name
            scripts.primary.setAccessibilityLabel("Run \(name)")
            scripts.primary.toolTip = "Run \(name)"
            scripts.secondary.setAccessibilityLabel("Script actions")
        case .actions:
            scripts.primary.icon = IconName.wrench.definition
            scripts.primary.text = "Actions"
            scripts.primary.setAccessibilityLabel("Project actions")
            scripts.primary.toolTip = nil
            scripts.secondary.setAccessibilityLabel("Choose project action")
        case .add, nil:
            break
        }
        scripts.isHidden = scriptsRow == nil || scriptsRow == .add
        addScript.isHidden = scriptsRow != .add
        relayout()
    }

    /// The scripts row's view while it shows.
    private var scriptsView: NSView? { !scripts.isHidden ? scripts : !addScript.isHidden ? addScript : nil }

    private func updateRows() {
        runContext.isHidden = density != .full
        openIn.isHidden = !showsOpenIn || density == .essential
        branch.isHidden = !showsVersionControl || !isRepo
        gitActions.isHidden = !showsVersionControl || !isRepo || !showsGitActions || (density != .full && gitActions.primary.mode == .idle)
        changes.isHidden = !showsVersionControl || !isRepo
        initGit.isHidden = !showsVersionControl || isRepo || !showsGitActions
        relayout()
    }

    private func versionRows(_ density: Density) -> [NSView] {
        guard showsVersionControl else { return [] }
        guard isRepo else { return showsGitActions ? [initGit] : [] }
        let actions: [NSView] = showsGitActions && (density == .full || gitActions.primary.mode != .idle) ? [gitActions] : []
        return [branch] + pullRequestRows + actions + [changes]
    }

    private var versionRows: [NSView] { versionRows(density) }

    private func rowHeight(_ row: NSView) -> CGFloat {
        row === gitActions ? gitActions.preferredHeight : row is ThreadDetailsPrRowView ? ThreadDetailsPrRowView.height : 32
    }

    public var preferredHeight: CGFloat { preferredHeight(density) }

    /// The card's height at a density, with every section it shows there.
    public func preferredHeight(_ density: Density) -> CGFloat {
        var h: CGFloat = 2 + 8 + (density == .full ? 32 : 0) + (showsOpenIn && density != .essential ? 32 : 0) + (scriptsView != nil ? 32 : 0) + 10
        let rows = versionRows(density)
        if showsVersionControl, !rows.isEmpty {
            h += (density == .full ? 1 : 0) + 8 + 10 + rows.reduce(0) { $0 + rowHeight($1) }
        }
        guard density == .full else { return h }
        if !automations.isEmpty { h += 1 + automations.preferredHeight }
        h += lineage.preferredHeight
        return h
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: preferredHeight) }

    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        let inner = bounds.width - 2 - 16
        var y: CGFloat = 1 + 8
        if density == .full {
            runContext.frame = NSRect(x: 9, y: y, width: inner, height: 32)
            y += 32
        }
        if !openIn.isHidden {
            openIn.frame = NSRect(x: 9, y: y, width: inner, height: 32)
            y += 32
        }
        if let row = scriptsView {
            row.frame = NSRect(x: 9, y: y, width: inner, height: 32)
            y += 32
        }
        y += 10
        let rows = versionRows
        let separated = density == .full
        divider.isHidden = rows.isEmpty || !showsVersionControl || !separated
        divider.frame = CGRect(x: 1, y: y, width: bounds.width - 2, height: 1)
        y += (separated ? 1 : 0) + 8
        for row in rows {
            let h = rowHeight(row)
            row.frame = NSRect(x: 9, y: y, width: inner, height: h)
            y += h
        }
        let full = density == .full
        let lineageHeight = full ? lineage.preferredHeight : 0
        lineage.isHidden = lineage.isEmpty || !full
        lineage.frame = NSRect(x: 1, y: preferredHeight - lineageHeight, width: bounds.width - 2, height: lineageHeight)
        y = automations.isEmpty || !full ? y : preferredHeight - lineageHeight - 1 - automations.preferredHeight
        automations.isHidden = automations.isEmpty || !full
        automationsDivider.isHidden = automations.isHidden
        automationsDivider.frame = CGRect(x: 1, y: y, width: bounds.width - 2, height: 1)
        automations.frame = NSRect(x: 1, y: y + 1, width: bounds.width - 2, height: automations.preferredHeight)
    }

    /// The card grows when the automations change.
    public func automationsChanged() { relayout() }

    public override func updateLayer() {
        var box = BoxStyle()
        box.radius = 22
        box.fill = PopupSurface.glassFill
        box.border = Themed.color(\.contrastForeground, 0.1)
        decoration.boxStyle = box
        divider.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self)
        automationsDivider.backgroundColor = Themed.color(\.border, 0.65).cgColor(in: self)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        needsDisplay = true
    }
}
