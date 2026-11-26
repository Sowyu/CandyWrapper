import AppKit
import T3Store
import DesignSystem

/// Fill under a hovered or open panel control (threadDetailsPanelStyles.ts:9-10): black 3.5% in light,
/// white 8% in dark.
@MainActor
func detailsHoverFill() -> NSColor { Themed.pick(light: Themed.black(0.035), dark: Themed.white(0.08)) }

/// A row's corner: T3's 10, or Redesign's control corner, concentric 9 inside the card's 16.
@MainActor
func detailsRowRadius(_ view: NSView) -> CGFloat { ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark) ? DitherChrome.controlRadius : ThreadDesign.uses3814(dark: view.effectiveAppearance.isDark) ? 8 : 10 }

/// `ThreadDetailsControl` in the panel (ThreadDetailsControl.tsx, threadDetailsPanelStyles.ts): a 32pt row,
/// radius 10, `px-2.5 gap-2.5`, a 16pt muted icon (or two, 2 apart), 13pt medium text in `foreground/80`.
/// `.select` ends in a 32pt chevron cell behind a 16pt `border/65` rule; `.locked` is the static row; `.row`
/// may carry a trailing view (the Changes totals). Hover and open fill with `detailsHoverFill`.
public final class DetailsRowControl: ControlView {
    public var onContextMenu: ((NSEvent, NSView) -> Void)?
    public override func rightMouseDown(with event: NSEvent) {
        // Rows without their own menu leave it to the card's items menu.
        guard let onContextMenu else { return super.rightMouseDown(with: event) }
        onContextMenu(event, self)
    }
    public enum Kind: Sendable { case row, select, locked }
    public var kind: Kind { didSet { if kind != oldValue { update() } } }
    public var icons: [IconDefinition] = [] { didSet { if icons != oldValue { rebuildIcons() } } }
    public var text = "" { didSet { wrappedLabel.text = text; label.text = middleTruncates ? "" : text; middle.value = middleTruncates ? text : ""; needsLayout = true } }
    public var wrapsText = false { didSet { needsLayout = true } }
    public func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        guard wrapsText, ThreadDesign.uses3814(dark: effectiveAppearance.isDark) else { return 32 }
        return max(32, wrappedLabel.height(forWidth: max(1, width - 20 - 16 - 10)) + 6)
    }
    public var middleTruncates = false { didSet { label.isHidden = middleTruncates; middle.isHidden = !middleTruncates; let t = text; text = t } }
    /// A tone for the icons in place of the muted one (a pull request row wears its state's).
    public var iconColor: NSColor? { didSet { restyle() } }
    /// The split group's 32pt secondary cell after a 16pt rule (`THREAD_DETAILS_PANEL_SPLIT_*`): the row is
    /// then the group, which fills on hover, and the primary part fills again under the mouse.
    public var secondary: ControlView? { didSet { oldValue?.removeFromSuperview(); secondary.map(addSubview); update() } }
    /// A view right of the label (`flex-1` label, then this at its natural size).
    public var trailing: NSView? { didSet { oldValue?.removeFromSuperview(); trailing.map(addSubview); needsLayout = true } }
    /// Muted text after the label, `gap-1.5`, truncating before `trailing`: the Changes row's
    /// comparison base, "Uncommitted" or "vs main" (GitActionsControl.tsx:1143-1147, 1805-1818, #30085).
    public var detail: String? {
        didSet {
            guard detail != oldValue else { return }
            detailLabel.text = detail ?? ""
            detailLabel.isHidden = detail == nil
            detailLabel.tooltipWhenTruncated()
            needsLayout = true
        }
    }
    private let detailLabel = LabelView()
    /// The hover tooltip (attached on first use; T3 shows the workspace path on the run context).
    public var tooltipText: String? {
        didSet {
            if tooltip == nil, let tooltipText { tooltip = TooltipController.attach(to: self, text: tooltipText) }
            tooltip?.text = tooltipText ?? ""
        }
    }

    private var iconViews: [IconView] = []
    private let label = LabelView()
    private let wrappedLabel = TextBlockView("", font: DSFont.ui(13, weight: .medium), lineHeight: 18)
    private let middle = MiddleTruncateView("", font: DSFont.ui(13, weight: .medium))
    private let chevron = IconView(name: .chevronDown, size: 16)
    private let rule = CALayer()
    private let fill = CALayer()
    private let primaryFill = BoxDecorationLayer()
    /// `.select`: the chevron half's own hover fill (`THREAD_DETAILS_PANEL_SELECT_ICON_CLASS`).
    private let chevronFill = BoxDecorationLayer()
    private var chevronArea: NSTrackingArea?
    private var chevronHovered = false { didSet { if chevronHovered != oldValue { needsDisplay = true } } }
    private var tooltip: TooltipController?

    public init(kind: Kind = .row) {
        self.kind = kind
        super.init(frame: .zero)
        for l in [fill, rule] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
        layer?.addSublayer(fill)
        primaryFill.host = self
        layer?.addSublayer(primaryFill)
        chevronFill.host = self
        layer?.addSublayer(chevronFill)
        layer?.addSublayer(rule)
        label.font = DSFont.ui(13, weight: .medium)
        label.lineHeight = 20
        middle.lineHeight = 20
        middle.showsTitle = false
        middle.isHidden = true
        addSubview(label)
        wrappedLabel.maxLines = 2
        addSubview(wrappedLabel)
        addSubview(middle)
        addSubview(chevron)
        detailLabel.font = DSFont.ui(13)
        detailLabel.lineHeight = 20
        detailLabel.color = Themed.color(\.mutedForeground)
        detailLabel.isHidden = true
        addSubview(detailLabel)
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
        updateTrackingAreas()
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
            primaryFill.frame = CGRect(x: 0, y: 0, width: bounds.width + 1 - 32, height: bounds.height)
            primaryFill.layout(boxSize: primaryFill.frame.size)
            chevronFill.frame = CGRect(x: bounds.width + 1 - 32, y: 0, width: 32, height: bounds.height)
            chevronFill.layout(boxSize: chevronFill.frame.size)
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
        var frame = NSRect(x: x, y: midY - 10, width: max(0, right - x), height: 20)
        if detail != nil {
            frame.size.width = min(frame.width, ceil(label.textWidth))
            let dx = frame.maxX + 6
            detailLabel.frame = NSRect(x: dx, y: frame.minY, width: max(0, right - dx), height: 20)
        }
        label.frame = frame
        let wraps = wrapsText && ThreadDesign.uses3814(dark: effectiveAppearance.isDark)
        wrappedLabel.isHidden = !wraps
        label.isHidden = middleTruncates || wraps
        wrappedLabel.frame = NSRect(x: x, y: 3, width: max(0, right - x), height: max(0, bounds.height - 6))
        if wraps { iconViews.forEach { $0.frame.origin.y = 5 } }
        middle.frame = frame
    }

    public override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if !state.hovered { chevronHovered = false }
        restyle()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let chevronArea { removeTrackingArea(chevronArea) }
        chevronArea = nil
        guard kind == .select else { return }
        let area = NSTrackingArea(rect: NSRect(x: bounds.width + 1 - 32, y: 0, width: 32, height: bounds.height),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        chevronArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if let chevronArea, event.trackingArea === chevronArea { chevronHovered = state.enabled } else { super.mouseEntered(with: event) }
    }

    public override func mouseExited(with event: NSEvent) {
        if let chevronArea, event.trackingArea === chevronArea { chevronHovered = false } else { super.mouseExited(with: event) }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    public override func updateLayer() {
        let lit = kind != .locked && state.enabled && state.hoverOrPressed
        fill.backgroundColor = lit ? detailsHoverFill().cgColor(in: self) : nil
        fill.cornerRadius = detailsRowRadius(self)
        var part = BoxStyle()
        part.radius = detailsRowRadius(self)
        part.corners = .leading
        part.fill = lit && secondary.map { !$0.state.hoverOrPressed } == true ? detailsHoverFill() : nil
        // `.select` stacks a second fill on the hovered half, the label or the chevron
        // (threadDetailsPanelStyles.ts:23-27, commit 2fc244a438).
        let selectHover = kind == .select && state.enabled && state.hovered
        if kind == .select { part.fill = selectHover && !chevronHovered ? detailsHoverFill() : nil }
        primaryFill.boxStyle = part
        var icon = BoxStyle()
        icon.radius = detailsRowRadius(self)
        icon.corners = .trailing
        icon.fill = selectHover && chevronHovered ? detailsHoverFill() : nil
        chevronFill.boxStyle = icon
        rule.backgroundColor = !ThreadDesign.uses3814(dark: effectiveAppearance.isDark) || lit ? Themed.color(\.contrastBorder, 0.65).cgColor(in: self) : nil
    }

    private func restyle() {
        label.color = Themed.color(\.contrastForeground, 0.8)
        middle.color = Themed.color(\.contrastForeground, 0.8)
        wrappedLabel.color = Themed.color(\.contrastForeground, 0.8)
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
    /// The pointer came onto the group (`onPointerEnter`, GitActionsControl.tsx:1652 at 4928).
    public var onPointerEnter: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [fill, rule] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()] }
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

    public override func mouseEntered(with event: NSEvent) { hovered = true; onPointerEnter?() }
    public override func mouseExited(with event: NSEvent) { hovered = false }

    public override func updateLayer() {
        // The group fills on hover and while its menu is open (`has-[[data-popup-open]]`); a running action
        // keeps a resting fill (`bg-black/[0.035] dark:bg-white/[0.055]`).
        let running = elapsedText != nil
        let lit = hovered || secondary.isPopupOpen
        fill.cornerRadius = detailsRowRadius(self)
        fill.backgroundColor = running ? Themed.pick(light: Themed.black(0.035), dark: Themed.white(0.055)).cgColor(in: self)
            : lit ? detailsHoverFill().cgColor(in: self) : nil
        rule.backgroundColor = !ThreadDesign.uses3814(dark: effectiveAppearance.isDark) || lit ? Themed.color(\.contrastBorder, 0.65).cgColor(in: self) : nil
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
    /// A full-color mark drawn instead of `icon` (the Open in editor's brand logos).
    public var image: NSImage? { didSet { if image !== oldValue { rebuild() } } }
    /// The idle icon's color; nil is `muted-foreground` (`THREAD_DETAILS_PANEL_ICON_CLASS`).
    public var iconColor: NSColor? { didSet { restyle() } }
    public var text = "" { didSet { label.text = text; needsLayout = true } }
    public var mode = Mode.idle { didSet { if mode != oldValue { rebuild() } } }
    /// `aria-disabled`: drawn at 64% but still hoverable for its reason.
    public var looksDisabled = false { didSet { applyAlpha() } }

    /// Disabled parts draw at 64%, but the progress and success rows stay opaque (`multiline`: `disabled:opacity-100`).
    private func applyAlpha() { alphaValue = looksDisabled || (!state.enabled && mode == .idle) ? 0.64 : 1 }

    private let fill = BoxDecorationLayer()
    private var iconView: IconView?
    private var imageView: ImageGlyphView?
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
        // `py-1.5` around an 18pt title row (`grid-rows-[1.125rem]`), the output's `pt-0.5` and its 16pt line
        // (ThreadDetailsControl.tsx:58 and GitActionsControl.tsx:343-375 at 4928, #33724 and #34727).
        case .running(_, let output?), .success(_, let output?): _ = output; return 6 + 18 + 2 + 16 + 6
        default: return 32
        }
    }

    private func rebuild() {
        iconView?.removeFromSuperview(); iconView = nil
        imageView?.removeFromSuperview(); imageView = nil
        spinner?.removeFromSuperview(); spinner = nil
        label.isHidden = isChevron
        detail.isHidden = true
        if isChevron {
            let v = IconView(name: .chevronDown, size: 16)
            addSubview(v); iconView = v
        } else {
            switch mode {
            case .idle:
                if let image { let v = ImageGlyphView(image: image); addSubview(v); imageView = v }
                else if let icon { let v = IconView(definition: icon, size: 16); addSubview(v); iconView = v }
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
        // Idle, and running or success without output: the title centered in the 32pt row, so a loading row keeps the
        // idle height (#34727). With output: an 18pt title row under `py-1.5`, the output line under it (`pt-0.5`).
        // Running and success keep a 12pt column gap.
        let multi = mode != .idle
        let outputShown = preferredHeight > 32
        let titleY: CGFloat = outputShown ? 6 : 0, titleH: CGFloat = outputShown ? 18 : bounds.height
        var x: CGFloat = 10
        if let spinner {
            spinner.frame = NSRect(x: x - 2, y: titleY + (titleH - 16) / 2, width: 16, height: 16)
            x += 12 + 12
        } else if let iconView = iconView ?? imageView {
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
        box.radius = detailsRowRadius(self)
        box.corners = corners
        let lit = mode == .idle && state.enabled && (state.hoverOrPressed)
        box.fill = lit ? detailsHoverFill() : nil
        fill.boxStyle = box
        label.color = Themed.color(\.contrastForeground, 0.8)
        detail.color = Themed.color(\.contrastMutedForeground)
        if case .success = mode { iconView?.strokeColor = Themed.color(\.success) } else { iconView?.strokeColor = iconColor ?? Themed.color(\.contrastMutedForeground) }
        spinner?.color = Themed.color(\.contrastForeground, 0.8)
        needsDisplay = true
    }
}

/// The Changes row totals use `font-mono tabular-nums gap-2` at the row's 13px (#31858) and foreground diff roles.
/// Redesign retains its previous type, spacing and colors.
public final class DiffTotalsView: DSView {
    private let plus = LabelView()
    private let minus = LabelView()
    public var insertions = 0 { didSet { update() } }
    public var deletions = 0 { didSet { update() } }
    /// Moves the digits down by this much: mono digits ride high in their line, so Redesign's band nudges them onto the
    /// tab titles' midline.
    public var glyphOffset: CGFloat = 0 { didSet { needsLayout = true } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for l in [plus, minus] { l.font = DSFont.mono(DesignGeometry.usesClassic(self) ? 11 : 13); l.lineHeight = 16; addSubview(l) }
        update()
    }

    private var gap: CGFloat { DesignGeometry.usesClassic(self) ? 4 : 8 }

    private func updateMetrics() {
        let font = DSFont.mono(DesignGeometry.usesClassic(self) ? 11 : 13)
        guard plus.font != font else { return }
        plus.font = font; minus.font = font
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    private func update() {
        updateMetrics()
        plus.text = "+\(insertions)"
        minus.text = "-\(deletions)"
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: ceil(plus.textWidth) + gap + ceil(minus.textWidth), height: 16) }

    public override func layout() {
        super.layout()
        updateMetrics()
        let y = isFlipped ? glyphOffset : -glyphOffset
        plus.frame = NSRect(x: 0, y: y, width: ceil(plus.textWidth), height: 16)
        minus.frame = NSRect(x: ceil(plus.textWidth) + gap, y: y, width: ceil(minus.textWidth), height: 16)
    }

    public override func updateLayer() {
        updateMetrics()
        let classic = DesignGeometry.usesClassic(self)
        plus.color = Themed.color(classic ? \.diffAddition : insertions == 0 ? \.mutedForeground : \.diffAdditionForeground)
        minus.color = Themed.color(classic ? \.diffDeletion : deletions == 0 ? \.mutedForeground : \.diffDeletionForeground)
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
    /// The Changes row's comparison base, `GitActionsLogic.changesBaseLabel` (#30085).
    public var changesBase: String? { get { changes.detail } set { changes.detail = newValue } }
    /// The thread's pull request rows under the branch (ThreadDetailsPrRows.tsx): the current one,
    /// then the rest of its links while expanded, then "Show N more" or "Show less". A row the host
    /// answered for is a `ThreadDetailsPrRowView` (two lines), the rest are `DetailsRowControl`s.
    public var pullRequestRows: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; pullRequestRows.forEach(content.addSubview); relayout() }
    }

    /// Shows the Version Control section's rows for a repository; false shows "Initialize Git".
    public var isRepo = true { didSet { if isRepo != oldValue { updateRows() } } }

    // MARK: Repositories (5258 ThreadRepositorySections.tsx, ThreadDetailsPanel.tsx:185-305, #42919)

    /// One repository section's collapsed row.
    public struct RepositoryRow: Equatable, Sendable {
        public var key: String
        public var name: String
        /// Nil until its first `vcs` status.
        public var summary: ThreadRepositories.Summary?
        public init(key: String, name: String, summary: ThreadRepositories.Summary?) { self.key = key; self.name = name; self.summary = summary }
    }
    public struct Repositories: Equatable, Sendable {
        public var visible: [RepositoryRow] = []
        public var hidden = 0
        public var showAll = false
        /// "Repositories appear here once this thread changes them." when none shows (`explainsEmpty`).
        public var explainsEmpty = false
        public init(visible: [RepositoryRow] = [], hidden: Int = 0, showAll: Bool = false, explainsEmpty: Bool = false) {
            self.visible = visible; self.hidden = hidden; self.showAll = showAll; self.explainsEmpty = explainsEmpty
        }
    }
    /// The project tracks folders: its own plain folder is not offered Initialize Git (ThreadDetailsPanel.tsx:195-199).
    public var tracksFolders = false { didSet { if tracksFolders != oldValue { updateRows() } } }
    /// Nil hides the sections: a project that tracks nothing and changed no repository.
    public var repositories: Repositories? { didSet { if repositories != oldValue { rebuildRepositoryRows() } } }
    public var onRepositoriesShowAll: (() -> Void)?
    private var repositoryRows: [NSView] = []

    private func rebuildRepositoryRows() {
        repositoryRows.forEach { $0.removeFromSuperview() }
        repositoryRows = []
        if let repositories {
            if repositories.visible.isEmpty, repositories.explainsEmpty {
                // `px-2.5 py-1.5 text-xs text-muted-foreground`.
                let note = RepositoryNoteView("Repositories appear here once this thread changes them.")
                repositoryRows.append(note)
            }
            for row in repositories.visible { repositoryRows.append(Self.repositoryRow(row)) }
            if repositories.hidden > 0 || (repositories.showAll && repositories.visible.count > ThreadRepositories.visibleCount) {
                // `tone="muted"` with the label at `ms-6.5`: a clear 16pt icon holds the indent, the muted detail the words.
                let more = DetailsRowControl(kind: .row)
                more.icons = [IconName.chevronRight.definition]
                more.iconColor = .clear
                more.detail = repositories.showAll ? "Show fewer" : "Show \(repositories.hidden) more"
                more.setAccessibilityLabel(more.detail)
                more.setAccessibilityExpanded(repositories.showAll)
                more.action = { [weak self] in self?.onRepositoriesShowAll?() }
                repositoryRows.append(more)
            }
        }
        repositoryRows.forEach { content.addSubview($0) }
        updateRows()
    }

    /// The collapsed section's row (ThreadRepositorySections.tsx:104-142): a chevron, the name, then the branch or
    /// "Not a Git repository" / "Detached HEAD" muted, and the pull request number and working tree counts after.
    /// Read only in this slice, so it is a locked row (the git control per repository is not ported yet).
    static func repositoryRow(_ row: RepositoryRow) -> DetailsRowControl {
        let v = DetailsRowControl(kind: .locked)
        v.icons = [IconName.chevronRight.definition]
        v.text = row.name
        if let s = row.summary {
            v.detail = !s.isRepository ? "Not a Git repository" : (s.branch ?? "Detached HEAD")
            if s.isRepository, s.pullRequestNumber != nil || s.changedFiles > 0 {
                v.trailing = RepositoryCountsView(pullRequest: s.pullRequestNumber, insertions: s.changedFiles > 0 ? s.insertions : nil,
                                                  deletions: s.changedFiles > 0 ? s.deletions : nil)
            }
        }
        v.setAccessibilityLabel("Repository \(row.name)")
        return v
    }

    private var showsRepositories: Bool {
        repositories != nil && showsVersionControl && offersGit && density != .essential && on("gitActions") && !relationsOnly
    }
    /// Hides the Version Control section (`gitCwd` is null).
    public var showsVersionControl = true { didSet { if showsVersionControl != oldValue { updateRows() } } }
    /// False for a No project thread, whose folder sits in the shared scratch root and must never
    /// get git: no branch, git actions or Initialize Git, while its linked pull requests still show
    /// (4928 ThreadDetailsPanel.tsx:104-112, 169-176, #34788).
    public var offersGit = true { didSet { if offersGit != oldValue { updateRows() } } }
    /// The git actions need a project (`activeProjectName`).
    public var showsGitActions = true { didSet { if showsGitActions != oldValue { updateRows() } } }

    /// How much the card shows (ThreadDetailsPanel.tsx:100-185): `full` shows everything; `compact`
    /// drops the run context row, the Version Control rule, the idle git actions, automations and
    /// lineage; `essential` also drops Open in. The panel picks it from the height it has
    /// (`resolveDensity`).
    public enum Density: Sendable { case full, compact, essential }
    /// Redesign keeps only the thread's links: its pull requests, automations and lineage, in a dropdown under the
    /// header band's Lineage button. The workspace and git rows live in that band and under the composer instead.
    public var relationsOnly = false { didSet { if relationsOnly != oldValue { updateRows() } } }
    /// Whether `relationsOnly` has anything to show.
    public var hasRelations: Bool { !pullRequestRows.isEmpty || !automations.isEmpty || !lineage.isEmpty || !servers.isEmpty }
    /// `hasRelations` changed.
    public var onRelationsChange: (@MainActor () -> Void)?
    private var hadRelations = false
    public var density = Density.full { didSet { if density != oldValue { updateRows() } } }
    /// The items chosen in Settings or the card's context menu (`resolveThreadDetailsVisibility`, #26904).
    /// A missing id takes its default.
    public var items: [String: Bool] = [:] { didSet { if items != oldValue { updateRows() } } }
    private func on(_ id: String) -> Bool { items[id] ?? ThreadDetailsItems.all.first { $0.id == id }?.defaultVisible ?? true }

    /// `resolveThreadDetailsCardDensity` (threadDetailsCardLayout.ts:7-14): the richest density whose
    /// content fits `height`. T3 measures each density's content once it renders; the card knows its
    /// heights up front, so it asks for them directly.
    public static func resolveDensity(height: CGFloat, full: CGFloat, compact: CGFloat) -> Density {
        if full == 0 || full <= height { return .full }
        if compact == 0 || compact <= height { return .compact }
        return .essential
    }

    /// The density for the height the card can take. Lineage, automations and the servers past the first
    /// page scroll as they grow, so they do not count toward the fit (4928 ThreadDetailsCard.tsx, #28585, #28684).
    public func density(fitting height: CGFloat) -> Density {
        let growing = (showsLineage ? lineage.preferredHeight : 0) + (showsAutomations ? 1 + automations.preferredHeight : 0)
            + (on("servers") ? servers.overflowHeight : 0)
        return Self.resolveDensity(height: height, full: preferredHeight(.full) - growing, compact: preferredHeight(.compact))
    }

    private let decoration = BoxDecorationLayer()
    private let divider = CALayer()
    /// Tasks bound to the thread (`ThreadAutomationsPanel`), separated by `border-t border-border/65`.
    public let servers = ThreadServersView()
    public let automations = ThreadAutomationsView()
    private let automationsDivider = CALayer()
    /// Related threads and subagents (`ThreadRelationshipsPanel`), the last section; it draws its own rule.
    public let lineage = ThreadLineageSectionView()
    /// Usage limits and Context window, after the relationships at every density (ThreadDetailsPanel.tsx:285-288).
    public let usage = ThreadDetailsUsageSectionView()
    public let context = ThreadDetailsUsageSectionView()
    /// "Choose what to show", only while no item has content (ThreadDetailsPanel.tsx:289-305).
    public let chooseItems = DetailsRowControl(kind: .row)
    /// The card's rows, inside the 1pt border. A card taller than the space it gets scrolls them under T3's
    /// overlay bar with the edge fades (`ScrollArea scrollFade` in a `max-h` card, ThreadDetailsCard.tsx:122-135).
    private let content = DSView()
    public let scrollArea: ScrollAreaView

    public override init(frame frameRect: NSRect) {
        scrollArea = ScrollAreaView(documentView: content, scrollFade: true)
        super.init(frame: frameRect)
        decoration.host = self
        layer?.addSublayer(decoration)
        // `overflow-hidden rounded-3xl`: scrolled rows stay inside the border's rounded corners.
        scrollArea.wantsLayer = true
        scrollArea.layer?.cornerRadius = Self.innerRadius
        scrollArea.layer?.masksToBounds = true
        addSubview(scrollArea)
        content.wantsLayer = true
        divider.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        content.layer?.addSublayer(divider)
        automationsDivider.actions = divider.actions
        content.layer?.addSublayer(automationsDivider)
        content.addSubview(servers)
        servers.onHeightChange = { [weak self] in self?.relayout() }
        content.addSubview(automations)
        content.addSubview(lineage)
        content.addSubview(usage)
        content.addSubview(context)
        chooseItems.icons = [IconName.slidersHorizontal.definition]
        chooseItems.text = "Choose what to show"
        chooseItems.action = { [weak self] in
            guard let self else { return }
            MenuPopupView.show(ThreadDetailsItems.menuItems(), from: self.chooseItems, placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 0))
        }
        content.addSubview(chooseItems)
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
        for v in [runContext, openIn, scripts, addScript, branch, gitActions, changes, initGit] as [NSView] { content.addSubview(v) }
        // Compact shows the git actions only while one runs or reports success (GitActionsControl.tsx:1824).
        gitActions.primary.onStateChange = { [weak self] in self?.updateRows() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Thread details")
        items = ThreadDetailsItems.visibility(ClientSettingsStore.shared.current)
        settingsObserver = ClientSettingsStore.shared.observe { [weak self] keys in
            guard keys.contains("threadDetailsItems") || keys.contains("threadDetailsUsageEnabled") else { return }
            self?.items = ThreadDetailsItems.visibility(ClientSettingsStore.shared.current)
        }
        updateRows()
    }

    private var settingsObserver = 0
    isolated deinit { ClientSettingsStore.shared.removeObserver(settingsObserver) }

    /// Right-click shows and hides the card's items (ThreadDetailsPanel.tsx:146-164); fields keep their own menu.
    public override func rightMouseDown(with event: NSEvent) {
        MenuPopupView.showContextMenu(ThreadDetailsItems.menuItems(), in: self, at: convert(event.locationInWindow, from: nil))
    }

    private func relayout() {
        invalidateIntrinsicContentSize(); needsLayout = true; superview?.needsLayout = true
        if hasRelations != hadRelations { hadRelations = hasRelations; onRelationsChange?() }
    }

    private func updateScripts() {
        switch scriptsRow {
        case .run(let name, let icon):
            scripts.primary.icon = icon.definition
            scripts.primary.text = name
            scripts.primary.setAccessibilityLabel("Run \(name)")
            scripts.primary.setTooltip("Run \(name)")
            scripts.secondary.setAccessibilityLabel("Script actions")
        case .actions:
            scripts.primary.icon = IconName.wrench.definition
            scripts.primary.text = "Actions"
            scripts.primary.setAccessibilityLabel("Project actions")
            scripts.primary.setTooltip(nil)
            scripts.secondary.setAccessibilityLabel("Choose project action")
        case .add, nil:
            break
        }
        scripts.isHidden = scriptsRow == nil || scriptsRow == .add || relationsOnly
        addScript.isHidden = scriptsRow != .add || relationsOnly
        relayout()
    }

    /// The scripts row's view while it shows.
    private var scriptsView: NSView? { !scripts.isHidden ? scripts : !addScript.isHidden ? addScript : nil }

    private func updateRows() {
        lineage.showsLineagePart = on("lineage")
        lineage.showsSideChats = on("sideChats")
        runContext.isHidden = density != .full || relationsOnly || !on("environment")
        openIn.isHidden = !showsOpenIn || density == .essential || relationsOnly || !on("openIn")
        let repo = showsVersionControl && offersGit && isRepo
        branch.isHidden = !repo || relationsOnly || !on("branch")
        gitActions.isHidden = !repo || !showsGitActions || (density != .full && gitActions.primary.mode == .idle)
            || relationsOnly || !on("gitActions")
        changes.isHidden = !repo || relationsOnly || !on("changes")
        initGit.isHidden = !showsVersionControl || !offersGit || isRepo || tracksFolders || !showsGitActions || relationsOnly || !on("gitActions")
        let repositoriesShown = showsRepositories
        repositoryRows.forEach { $0.isHidden = !repositoriesShown }
        scripts.isHidden = scriptsRow == nil || scriptsRow == .add || relationsOnly || !on("scripts")
        addScript.isHidden = scriptsRow != .add || relationsOnly || !on("scripts")
        pullRequestRows.forEach { $0.isHidden = !on("branch") }
        relayout()
    }

    /// The Workspace section's rows at a density: environment, Open in and scripts (ThreadDetailsPanel.tsx:170-226).
    private func workspaceRows(_ density: Density) -> Int {
        (density == .full && on("environment") ? 1 : 0) + (showsOpenIn && density != .essential && on("openIn") ? 1 : 0) + (scriptsView != nil ? 1 : 0)
    }

    private func versionRows(_ density: Density) -> [NSView] {
        let prs = on("branch") ? pullRequestRows : []
        if relationsOnly { return prs }
        // Without a branch selector the linked pull requests still need somewhere to show, then Initialize Git.
        let repositories = showsRepositories && density != .essential ? repositoryRows : []
        guard showsVersionControl, offersGit, isRepo else {
            return prs + (showsVersionControl && offersGit && !isRepo && !tracksFolders && showsGitActions && on("gitActions") ? [initGit] : []) + repositories
        }
        let actions: [NSView] = showsGitActions && on("gitActions") && (density == .full || gitActions.primary.mode != .idle) ? [gitActions] : []
        return (on("branch") ? [branch] : []) + prs + actions + (on("changes") ? [changes] : []) + repositories
    }

    private var versionRows: [NSView] { versionRows(density) }

    private func rowHeight(_ row: NSView) -> CGFloat {
        if row === gitActions { return gitActions.preferredHeight }
        if row is RepositoryNoteView { return 28 }
        let width = max(1, bounds.width - 18)
        return (row as? ThreadDetailsPrRowView)?.preferredHeight(forWidth: width)
            ?? (row as? ThreadDetailsIssueRowView)?.preferredHeight(forWidth: width) ?? 32
    }

    public var preferredHeight: CGFloat { preferredHeight(density) }

    /// The card's height at a density, with every section it shows there.
    public func preferredHeight(_ density: Density) -> CGFloat {
        let base = baseHeight(density)
        return relationsOnly ? base : base + tailHeight(base)
    }

    /// The height without the usage, context and "Choose what to show" tail.
    private func baseHeight(_ density: Density) -> CGFloat {
        if relationsOnly {
            let rows = versionRows(density).reduce(0) { $0 + rowHeight($1) }
            return 2 + (rows > 0 ? 8 + rows + 8 : 0) + (showsAutomations ? 1 + automations.preferredHeight : 0)
                + (showsLineage ? lineage.preferredHeight : 0) + (on("servers") ? servers.preferredHeight : 0)
        }
        let workspace = workspaceRows(density)
        var h: CGFloat = 2 + (workspace > 0 ? 8 + CGFloat(workspace) * 32 + 10 : 0)
        let rows = versionRows(density)
        if !rows.isEmpty {
            h += (density == .full && workspace > 0 ? 1 : 0) + 8 + 10 + rows.reduce(0) { $0 + rowHeight($1) }
        }
        guard density == .full else { return h }
        if showsAutomations { h += 1 + automations.preferredHeight }
        h += (showsLineage ? lineage.preferredHeight : 0) + (on("servers") ? servers.preferredHeight : 0)
        return h
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: preferredHeight) }

    private var showsAutomations: Bool { !automations.isEmpty && on("automations") }
    private var showsUsage: Bool { !usage.isEmpty && on("usage") }
    private var showsContext: Bool { !context.isEmpty && on("context") }
    /// The usage and context sections, or "Choose what to show" when the card would be empty (`h` is the 2pt border).
    private func tailHeight(_ above: CGFloat) -> CGFloat {
        let sections = (showsUsage ? usage.preferredHeight : 0) + (showsContext ? context.preferredHeight : 0)
        return sections == 0 && above <= 2 ? 8 + 32 + 8 : sections
    }
    private var showsLineage: Bool { !lineage.isEmpty }

    /// The box's 22pt radius less its 1pt border.
    static let innerRadius: CGFloat = 21

    /// Rows sit in card coordinates less the 1pt border, which `scrollArea` sits inside.
    public override func layout() {
        super.layout()
        decoration.layout(boxSize: bounds.size)
        scrollArea.frame = bounds.insetBy(dx: 1, dy: 1)
        let width = bounds.width - 2, height = preferredHeight - 2
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let inner = width - 16
        var y: CGFloat = 8
        servers.isHidden = servers.isEmpty || (!relationsOnly && density != .full) || !on("servers")
        if relationsOnly {
            for row in versionRows(density) {
                row.frame = NSRect(x: 8, y: y, width: inner, height: rowHeight(row))
                y += rowHeight(row)
            }
            divider.isHidden = true
            let lineageHeight = showsLineage ? lineage.preferredHeight : 0
            lineage.isHidden = !showsLineage
            lineage.frame = NSRect(x: 0, y: height + 1 - lineageHeight, width: width, height: lineageHeight)
            automations.isHidden = !showsAutomations
            let ay = height + 1 - lineageHeight - 1 - automations.preferredHeight
            // The first section draws no rule over it.
            automationsDivider.isHidden = automations.isHidden || versionRows(density).isEmpty
            automationsDivider.frame = CGRect(x: 0, y: ay, width: width, height: 1)
            automations.frame = NSRect(x: 0, y: ay + 1, width: width, height: automations.preferredHeight)
            servers.frame = NSRect(x: 0, y: ay - servers.preferredHeight, width: width, height: servers.preferredHeight)
            for v in [usage, context, chooseItems] as [NSView] { v.isHidden = true }
            return
        }
        if !runContext.isHidden {
            runContext.frame = NSRect(x: 8, y: y, width: inner, height: 32)
            y += 32
        }
        if !openIn.isHidden {
            openIn.frame = NSRect(x: 8, y: y, width: inner, height: 32)
            y += 32
        }
        if let row = scriptsView {
            row.frame = NSRect(x: 8, y: y, width: inner, height: 32)
            y += 32
        }
        let workspace = workspaceRows(density) > 0
        y = workspace ? y + 10 : 0
        let rows = versionRows
        // No empty section steals the rule (ThreadDetailsPanel.tsx:166-169).
        let separated = density == .full && workspace
        divider.isHidden = rows.isEmpty || !separated
        divider.frame = CGRect(x: 0, y: y, width: width, height: 1)
        y += (separated ? 1 : 0) + 8
        for row in rows {
            let h = rowHeight(row)
            row.frame = NSRect(x: 8, y: y, width: inner, height: h)
            y += h
        }
        let full = density == .full
        let tail = tailHeight(baseHeight(density))
        let bottom = height + 1 - tail
        let lineageHeight = full && showsLineage ? lineage.preferredHeight : 0
        lineage.isHidden = !showsLineage || !full
        // The section's own bottom padding runs into the border's last point, as before the scroll area.
        lineage.frame = NSRect(x: 0, y: bottom - lineageHeight, width: width, height: lineageHeight)
        y = !showsAutomations || !full ? y : bottom - lineageHeight - 1 - automations.preferredHeight
        automations.isHidden = !showsAutomations || !full
        automationsDivider.isHidden = automations.isHidden
        automationsDivider.frame = CGRect(x: 0, y: y, width: width, height: 1)
        automations.frame = NSRect(x: 0, y: y + 1, width: width, height: automations.preferredHeight)
        let serverBottom = bottom - lineageHeight - (automations.isHidden ? 0 : 1 + automations.preferredHeight)
        servers.frame = NSRect(x: 0, y: serverBottom - servers.preferredHeight, width: width, height: servers.preferredHeight)
        layoutTail(width: width, height: height)
    }

    /// Usage, then context, from the tail's top; "Choose what to show" when nothing else shows.
    private func layoutTail(width: CGFloat, height: CGFloat) {
        let base = baseHeight(density)
        let tail = tailHeight(base)
        var y = height + 1 - tail
        let placeholder = !showsUsage && !showsContext && tail > 0
        chooseItems.isHidden = !placeholder
        if placeholder { chooseItems.frame = NSRect(x: 8, y: y + 8, width: width - 16, height: 32) }
        usage.isHidden = !showsUsage
        usage.separated = y > 1
        if showsUsage { usage.frame = NSRect(x: 0, y: y, width: width, height: usage.preferredHeight); y += usage.preferredHeight }
        context.isHidden = !showsContext
        context.separated = y > 1
        if showsContext { context.frame = NSRect(x: 0, y: y, width: width, height: context.preferredHeight) }
    }

    /// The card grows when the usage rows change.
    public func usageChanged() { relayout() }

    /// The card grows when the automations change.
    public func automationsChanged() { relayout() }

    public override func updateLayer() {
        var box = BoxStyle()
        box.radius = ThreadDesign.uses3814(dark: effectiveAppearance.isDark) ? 16 : 22
        let dark = effectiveAppearance.isDark
        let frost = ThemeRuntime.isDither(dark: dark)
        box.fill = frost ? Themed.color(dark ? \.surfaceRaised : \.card) : PopupSurface.glassFill
        // Redesign: the composer's solid surface, its rim on the card's own layer over the rows.
        box.border = frost ? nil : Themed.color(\.contrastForeground, 0.1)
        decoration.boxStyle = box
        layer?.cornerRadius = frost ? DitherChrome.radius(box.radius) : 0
        layer?.borderWidth = frost ? 1 : 0
        layer?.borderColor = frost ? DitherChrome.rim(dark: dark).cgColor : nil
        // The rows clip inside the border's curve: 22 less 1, or Redesign's 16 less 1.
        scrollArea.layer?.cornerRadius = frost ? DitherChrome.nested(in: DitherChrome.radius(box.radius), inset: 1) : ThreadDesign.uses3814(dark: dark) ? 15 : Self.innerRadius
        divider.backgroundColor = Themed.color(\.contrastBorder, 0.65).cgColor(in: self)
        automationsDivider.backgroundColor = Themed.color(\.border, 0.65).cgColor(in: self)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        decoration.setNeedsDisplay()
        needsDisplay = true
    }
}


/// "Repositories appear here once this thread changes them." (`px-2.5 py-1.5 text-xs text-muted-foreground`).
final class RepositoryNoteView: DSView {
    private let label: LabelView
    init(_ text: String) {
        label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 16
        addSubview(label)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 10, y: 6, width: max(0, bounds.width - 20), height: 16)
    }
}

/// A repository row's trailing counts (`ms-auto flex gap-2 ps-2 font-mono tabular-nums`): "#12" in the muted sans
/// face, then the working tree's "+n" and "-n".
final class RepositoryCountsView: DSView {
    private let number = LabelView()
    private let totals = DiffTotalsView()
    init(pullRequest: Int?, insertions: Int?, deletions: Int?) {
        super.init(frame: .zero)
        number.font = DSFont.ui(13)
        number.lineHeight = 16
        number.color = Themed.color(\.mutedForeground)
        number.text = pullRequest.map { "#\($0)" } ?? ""
        number.isHidden = pullRequest == nil
        totals.insertions = insertions ?? 0
        totals.deletions = deletions ?? 0
        totals.isHidden = insertions == nil
        addSubview(number)
        addSubview(totals)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let n = number.isHidden ? 0 : ceil(number.textWidth)
        let t = totals.isHidden ? 0 : totals.intrinsicContentSize.width
        return NSSize(width: n + t + (n > 0 && t > 0 ? 8 : 0), height: 16)
    }
    override func layout() {
        super.layout()
        let n = number.isHidden ? 0 : ceil(number.textWidth)
        number.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: n, height: 16)
        let t = totals.intrinsicContentSize.width
        totals.frame = NSRect(x: bounds.width - t, y: (bounds.height - 16) / 2, width: t, height: 16)
    }
}
