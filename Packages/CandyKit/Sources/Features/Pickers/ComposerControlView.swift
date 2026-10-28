import AppKit
import DesignSystem

/// T3's `ComposerControl` at size `sm` (chat/ComposerControl.tsx:17-26): the composer footer's
/// trigger look. Height 28, 1px transparent border, padding 10, gap 6, radius 8, 14px medium
/// `secondary-label` text, 16px leading icon in `muted-foreground`, 14px chevron in `icon-muted`
/// drawn with -2 margins. Hover and an open popup fill `accent`; hover turns the text `foreground`.
/// Spec: docs/research/J-composer-visuals.md 3.1.
public final class ComposerControlView: ControlView {
    public var title: String { didSet { label.text = title; invalidateIntrinsicContentSize(); needsLayout = true } }
    /// The leading 16px glyph. Its color stays as set when `tintsIcon` is false (brand glyphs).
    public var icon: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let icon { addSubview(icon) }; restyle(); invalidateIntrinsicContentSize() }
    }
    public var compactIcon: NSView? { didSet { oldValue?.removeFromSuperview(); if let compactIcon { addSubview(compactIcon) }; invalidateIntrinsicContentSize(); needsLayout = true } }
    public var adornment: NSView? { didSet { oldValue?.removeFromSuperview(); if let adornment { addSubview(adornment) }; invalidateIntrinsicContentSize(); needsLayout = true } }
    private var visibleIcon: NSView? { showsLabel ? icon : compactIcon ?? icon }
    public var tintsIcon = true { didSet { restyle() } }
    /// A plain lucide icon in `ComposerControl` keeps `[&_svg]:-mx-0.5`: it takes 2 less on each side
    /// in the flow. `ComposerControlIcon` glyphs (`data-composer-control-icon`) reset it to 0.
    public var iconOverhang: CGFloat = 0 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    /// `min-w-13` on the model trigger: the label shrinks first, down to this width.
    public var minimumWidth: CGFloat = 0
    /// False for an icon-only block at narrow widths: the label leaves the flow (ChatComposer.tsx:5604).
    public var showsLabel = true { didSet { if showsLabel != oldValue { label.isHidden = !showsLabel; invalidateIntrinsicContentSize(); needsLayout = true } } }
    /// False for the overflow trigger, which is just the ellipsis (CompactComposerControlsMenu.tsx:41-54).
    public var showsChevron = true { didSet { chevron.isHidden = !showsChevron; invalidateIntrinsicContentSize(); needsLayout = true } }
    /// The composer footer's chips take Capy's look under Dither (measured in Capy 2026-10-22): 13pt text, 8pt
    /// padding, a small quiet chevron and a faint fill on hover. Other uses of this control keep T3's.
    public var followsCapy = false { didSet { if followsCapy != oldValue { restyle() } } }
    var capy: Bool { followsCapy && ThemeRuntime.isDither(dark: effectiveAppearance.isDark) }
    public var emphasized = false { didSet { restyle() } }
    public var iconFollowsLabel = false { didSet { restyle() } }
    public var textOnly = false { didSet { restyle() } }
    public var paddingOverride: (CGFloat, CGFloat)? { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    public var mutedLabel = false { didSet { restyle() } }
    private var leadingPadding: CGFloat { paddingOverride?.0 ?? padding }
    private var trailingPadding: CGFloat { paddingOverride?.1 ?? padding }
    private var padding: CGFloat { capy || modern ? 8 : Self.padding }
    private var modern: Bool { ComposerDesign.uses3814(dark: effectiveAppearance.isDark) }
    private var glyphWidth: CGFloat { if let compactIcon, visibleIcon === compactIcon { return 14 }; return (visibleIcon as? ComposerEffortGlyphView)?.intrinsicContentSize.width ?? 16 }
    private var visibleIconOverhang: CGFloat { compactIcon != nil && visibleIcon === compactIcon ? 2 : iconOverhang }
    private var chevronSize: CGFloat { capy ? 11 : 14 }

    private let label = LabelView()
    private let chevron = IconView(definition: ComposerControlView.chevronDefinition, size: 14)
    private let fill = CALayer()
    private let ring = CALayer()

    /// lucide `chevron-down` at stroke width 2.25 (`ComposerControlChevron`).
    static let chevronDefinition: IconDefinition = {
        var d = IconName.chevronDown.definition
        d.elements = d.elements.map { var e = $0; e.paint.strokeWidth = 2.25; return e }
        return d
    }()

    public init(title: String = "", icon: NSView? = nil) {
        self.title = title
        super.init(frame: .zero)
        scalesWhenPressed = false // every footer picker trigger has `aria-haspopup`
        for l in [fill, ring] { l.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "hidden": NSNull()] }
        fill.cornerRadius = 8
        ring.cornerRadius = 11
        ring.borderWidth = 2
        layer?.addSublayer(fill)
        layer?.addSublayer(ring)
        layer?.masksToBounds = false
        label.font = DSFont.ui(14, weight: .medium)
        label.lineHeight = 20
        label.smoothsFont = false // the composer is a backdrop-filter layer
        label.text = title
        addSubview(label)
        addSubview(chevron)
        self.icon = icon
        if let icon { addSubview(icon) }
        setAccessibilityRole(.popUpButton)
        restyle()
    }

    static let padding: CGFloat = 10, gap: CGFloat = 6

    /// Border, padding, then icon, label and chevron (14 - 4) with `gap-1.5` between those shown, padding, border.
    public var naturalWidth: CGFloat { width(showingLabel: showsLabel) }

    /// The width with or without the label, for the footer's fit decision.
    public func width(showingLabel: Bool) -> CGFloat {
        let measuredIcon = showingLabel ? icon : compactIcon ?? icon
        let measuredWidth: CGFloat = !showingLabel && compactIcon != nil ? 14 : (measuredIcon as? ComposerEffortGlyphView)?.intrinsicContentSize.width ?? 16
        let overhang: CGFloat = !showingLabel && compactIcon != nil ? 2 : iconOverhang
        let adornmentWidth = (adornment as? ComposerTraitsAdornmentView)?.width(showingLabel: showingLabel) ?? adornment?.intrinsicContentSize.width
        let parts = [measuredIcon == nil ? nil : measuredWidth - 2 * overhang, showingLabel && (!title.isEmpty || !modern) ? label.textWidth : nil, adornmentWidth.flatMap { $0 > 0 ? $0 : nil }, (showsChevron && !modern) ? CGFloat(10) : nil].compactMap { $0 }
        return 2 + leadingPadding + trailingPadding + parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * Self.gap
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: (naturalWidth * 2).rounded(.up) / 2, height: 28) }

    public override func layout() {
        super.layout()
        fill.frame = bounds
        ring.frame = bounds.insetBy(dx: -3, dy: -3)
        var x = 1 + leadingPadding
        icon?.isHidden = visibleIcon !== icon
        compactIcon?.isHidden = visibleIcon !== compactIcon
        if let icon = visibleIcon {
            let height: CGFloat = icon is ComposerEffortGlyphView || (compactIcon != nil && icon === compactIcon) ? 14 : 16
            icon.frame = NSRect(x: x - visibleIconOverhang, y: (bounds.height - height) / 2, width: glyphWidth, height: height)
            x += glyphWidth - 2 * visibleIconOverhang + Self.gap
        }
        if let adornment {
            (adornment as? ComposerTraitsAdornmentView)?.showsLabels = showsLabel
            let size = adornment.intrinsicContentSize
            adornment.frame = NSRect(x: bounds.width - 1 - trailingPadding - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        }
        guard showsLabel else {
            chevron.frame = NSRect(x: x + 5 - chevronSize / 2, y: (bounds.height - chevronSize) / 2, width: chevronSize, height: chevronSize)
            return
        }
        // The chevron box is 10 wide in flow; the 14px glyph overhangs it by 2 on each side.
        let chevronBox = bounds.width - 1 - trailingPadding - 10
        chevron.frame = NSRect(x: chevronBox + 5 - chevronSize / 2, y: (bounds.height - chevronSize) / 2, width: chevronSize, height: chevronSize)
        // Frames snap to device pixels; a label that misses by less than that still fits, as in CSS.
        let room = showsChevron && !modern ? chevronBox - Self.gap - x : bounds.width - 1 - trailingPadding - x
        let adornmentRoom = adornment.map { $0.intrinsicContentSize.width + Self.gap } ?? 0
        label.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: max(0, label.textWidth <= room - adornmentRoom + 0.5 ? label.textWidth : room - adornmentRoom), height: 20)
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
        fill.backgroundColor = (state.hoverOrPressed || emphasized) && !(modern && textOnly) ? (capy ? Themed.color(\.foreground, 0.07) : Themed.color(\.accent)).cgColor(in: self) : nil
        // `focus-visible:ring-2 ring-ring ring-offset-1`: a 1px offset gap, then a 2px ring.
        ring.isHidden = !state.focusVisible
        ring.borderColor = Themed.color(\.ring).cgColor(in: self)
    }

    private func restyle() {
        let font = capy ? DSFont.ui(13, weight: .medium) : DSFont.ui(14, weight: .medium)
        if label.font != font { label.font = font; invalidateIntrinsicContentSize(); needsLayout = true }
        chevron.isHidden = !showsChevron || modern
        chevron.alphaValue = capy ? 0.75 : 1
        label.color = state.hoverOrPressed || emphasized ? Themed.color(\.contrastForeground) : (modern ? (mutedLabel ? Themed.color(\.contrastMutedForeground) : Themed.color(\.contrastForeground, 0.8)) : Themed.color(\.contrastSecondaryLabel))
        chevron.strokeColor = Themed.color(\.contrastIconMuted)
        if tintsIcon, let icon = icon as? IconView { icon.strokeColor = iconFollowsLabel ? label.color : Themed.color(\.contrastMutedForeground) }
        (icon as? ComposerEffortGlyphView)?.color = label.color
        (adornment as? ComposerTraitsAdornmentView)?.color = label.color
        (compactIcon as? IconView)?.strokeColor = label.color
        needsDisplay = true
    }
}

/// The 1x16 footer separator with 2px margins (`ComposerControlSeparator`, `mx-0.5 h-4`).
public final class ComposerControlSeparatorView: DSView {
    public override var intrinsicContentSize: NSSize { NSSize(width: 5, height: 16) }
    private let line = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(line)
    }

    public override func layout() {
        super.layout()
        line.frame = CGRect(x: 2, y: (bounds.height - 16) / 2, width: 1, height: 16)
    }

    public override func updateLayer() { line.backgroundColor = Themed.color(\.contrastBorder).cgColor(in: self) }
}

/// A provider's glyph (`ProviderInstanceIcon`): Claude's asterisk in #d97757; other glyphs take
/// `currentColor`, which is `foreground` in the rail and `muted-foreground` in rows and triggers
/// (`[&_svg:not([class*='text-'])]:text-muted-foreground`). Otherwise the instance's initials.
@MainActor
enum ProviderIcon {
    /// `model`: the glyph marks a model (the composer's model chip, a picker row), so Claude keeps its own logo under
    /// Dither; elsewhere it marks the provider and shows Anthropic's.
    /// Claude's spark with its orange fill swapped for the current color.
    static let monoClaude: IconDefinition = {
        var d = IconName.brandClaudeAI.definition
        d.elements = d.elements.map { var e = $0; e.paint.fill = .current; return e }
        return d
    }()

    static func make(driver: String, displayName: String, size: CGFloat, color: NSColor = Themed.color(\.contrastForeground),
                     model: Bool = false) -> NSView {
        switch driver {
        case "claudeAgent":
            // Dither draws a model's Claude spark in the glyph color, like the chip's other glyphs, not orange.
            if model, ThemeRuntime.isDither(dark: NSApp?.effectiveAppearance.isDark ?? true) {
                return IconView(definition: monoClaude, size: size, color: color)
            }
            return IconView(name: .brandClaudeAI, size: size, strokeColor: color, providerMark: !model)
        case "codex": return IconView(name: .brandOpenAI, size: size, strokeColor: color)
        case "cursor": return IconView(name: .brandCursor, size: size, strokeColor: color)
        case "grok": return IconView(definition: ProviderPackageIcons.grok, size: size, color: ProviderPackageIcons.grokFill)
        case "fx": return IconView(definition: ProviderPackageIcons.fx, size: size, color: ProviderPackageIcons.grokFill)
        case "pi": return IconView(definition: ProviderPackageIcons.pi, size: size, color: ProviderPackageIcons.grokFill)
        case "muse": return IconView(definition: ProviderPackageIcons.muse, size: size)
        case "opencode": return ProviderPackageIcons.openCode(size: size)
        case "antigravity": return ProviderPackageIcons.antigravity(size: size)
        case "acpRegistry": return IconView(name: .brandACPRegistry, size: size, strokeColor: color)
        default:
            // ponytail: initials for drivers without a bundled glyph; per-agent ACP registry icons load from URLs in T3, add them with remote icon loading
            let words = displayName.replacingOccurrences(of: "_", with: " ").split(separator: " ")
            let initials = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(displayName.prefix(2))
            let l = LabelView(initials, font: DSFont.ui(10, weight: .semibold), color: color)
            l.lineHeight = size
            l.alignment = .center
            return l
        }
    }
}
