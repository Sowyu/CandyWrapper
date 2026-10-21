import AppKit

/// CandyWrapper's Glass theme (not in T3): the stock palette over a frosted window. Under the whole layout sits the
/// desktop picture, blurred once (`WallpaperBackdropView`), or the window server's live blur where that can't be
/// used, so nothing here redraws when the desktop behind changes. The base surfaces (main panel and sidebar)
/// paint their stock color at `frostBaseAlpha`, and views that repeat the main background over them go clear, so one
/// tint covers the blur everywhere. Popovers, menus and dialogs keep their own fills.
public enum WindowGlass {
    nonisolated static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    nonisolated static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    /// WCAG relative luminance.
    nonisolated static func luminance(_ c: TokenColor) -> Double {
        0.2126 * linear(c.srgb.x) + 0.7152 * linear(c.srgb.y) + 0.0722 * linear(c.srgb.z)
    }

    // MARK: Frost, classic Glass's panes (docs/design.md "Glass")

    /// The base tint over classic Glass's clear frost: the sidebar's and main panel's own color at this alpha. Text
    /// sits on it, so it never thins below the floor where body text still reads at 4.5:1 over a bright (dark) or dark
    /// (light) desktop. The slider spends the rest on a curve that keeps the default clearly frosted and 100% nearly
    /// solid: 61% at 10%, 69% at 40%, 86% at the default 80%, 97% at 100%.
    public nonisolated static func frostBaseAlpha(opacity: Double) -> Double { 0.6 + 0.37 * pow(min(max(opacity, 0.1), 1), 1.5) }

    /// The worst background text on the base tint can get, as sRGB gray: the tint over a blurred desktop at 10% gray
    /// in light and 85% in dark, darker or brighter than a blurred busy desktop gets. Panes only add density, so text
    /// on them reads at least this well.
    nonisolated static func frostWorstBackground(_ base: TokenColor, dark: Bool, opacity: Double) -> Double {
        let a = frostBaseAlpha(opacity: opacity)
        let b = (base.srgb.x + base.srgb.y + base.srgb.z) / 3
        return a * b + (1 - a) * (dark ? 0.85 : 0.1)
    }

    /// Text roles and the ratio each keeps against `frostWorstBackground`: 4.5:1 for text and 3:1 for icons, each with
    /// a margin for hover tints and desktops brighter or darker than the model.
    nonisolated static let frostTextTargets: [String: Double] = {
        var t: [String: Double] = [:]
        for m in ["--foreground", "--contrast-foreground", "--card-foreground", "--contrast-card-foreground", "--popover-foreground",
                  "--contrast-popover-foreground", "--message-foreground", "--contrast-message-foreground", "--accent-foreground",
                  "--contrast-accent-foreground", "--secondary-foreground", "--contrast-secondary-foreground",
                  "--sidebar-foreground", "--contrast-sidebar-foreground", "--toolbar-foreground", "--contrast-toolbar-foreground",
                  "--toolbar-control-foreground", "--contrast-toolbar-control-foreground", "--muted-foreground",
                  "--contrast-muted-foreground", "--sidebar-muted-foreground", "--contrast-sidebar-muted-foreground",
                  "--secondary-label", "--contrast-secondary-label", "--message-action-foreground", "--destructive", "--error",
                  "--success", "--warning", "--info", "--update", "--diff-addition-foreground", "--diff-deletion-foreground",
                  "--placeholder", "--contrast-placeholder"] { t[m] = 5 }
        for m in ["--icon-muted", "--contrast-icon-muted", "--sidebar-icon-color", "--tool-error-icon"] { t[m] = 3.3 }
        return t
    }()

    /// Muted text roles that T3 also paints faded (`/70`, `/60`, the composer's placeholder at 75%); classic Glass
    /// paints them at full strength.
    nonisolated(unsafe) static let frostFullStrength: Set<KeyPath<Palette, TokenColor>> = [
        \.mutedForeground, \.contrastMutedForeground, \.sidebarMutedForeground, \.contrastSidebarMutedForeground,
        \.secondaryLabel, \.contrastSecondaryLabel, \.placeholder, \.contrastPlaceholder,
    ]

    /// `palette` with every text color moved, if it must, until it keeps its ratio over the frost's worst background.
    /// Light text darkens and dark text lightens in linear light, so colored text keeps its hue.
    nonisolated static func frostReadable(_ palette: Palette, dark: Bool, sidebar: Bool, opacity: Double) -> Palette {
        let members = palette.members
        let worst = frostWorstBackground(sidebar ? palette.sidebar : palette.background, dark: dark, opacity: opacity)
        let lb = linear(worst)
        return Palette(members: { i in
            let c = members[i]
            guard let ratio = frostTextTargets[Palette.memberNames[i]], c.srgb.w >= 1 else { return c }
            return readable(c, over: lb, ratio: ratio, dark: dark)
        })
    }

    /// `color` moved toward white (dark) or black (light) until it keeps `ratio` against a background of luminance `lb`.
    nonisolated static func readable(_ color: TokenColor, over lb: Double, ratio: Double, dark: Bool) -> TokenColor {
        let l = luminance(color)
        let lin = SIMD3(linear(color.srgb.x), linear(color.srgb.y), linear(color.srgb.z))
        let out: SIMD3<Double>
        if dark {
            let target = min(1, ratio * (lb + 0.05) - 0.05)
            guard l < target else { return color }
            let t = (target - l) / max(1 - l, 1e-6)
            out = lin + (SIMD3(repeating: 1) - lin) * t
        } else {
            let target = max(0, (lb + 0.05) / ratio - 0.05)
            guard l > target else { return color }
            out = lin * (target / max(l, 1e-6))
        }
        return ThemeCSSColor(srgb: gamma(out.x), gamma(out.y), gamma(out.z)).token
    }

    /// How dense a frosted pane is. Depth comes from density, not shadows: the window's base tint, then panes
    /// (cards, bubbles, pills, selected rows), dense panes for code, and floating panes over their own blur.
    public enum Level: Sendable { case pane, dense, floating }

    /// A pane's alpha at a "Glass opacity" (0.1...1). The slider thins every pane, but never below a floor that
    /// keeps text on it readable over a busy desktop (measured, docs/design.md "Glass").
    public nonisolated static func paneAlpha(_ level: Level, dark: Bool, opacity: Double) -> Double {
        let o = min(max(opacity, 0.1), 1)
        switch level {
        case .pane: return dark ? 0.35 + 0.4 * o : 0.4 + 0.35 * o
        case .dense: return dark ? 0.6 + 0.35 * o : 0.65 + 0.3 * o
        case .floating: return 0.7 + 0.25 * o
        }
    }

    /// Opaque surface tokens that become panes, by level.
    nonisolated static let paneMembers: [String: Level] = [
        "--card": .pane, "--surface-raised": .pane, "--toolbar-control": .pane,
        "--sidebar-row-selected": .pane, "--sidebar-row-active": .pane,
        "--code-background": .dense, "--terminal-background": .dense,
        "--popover": .floating,
    ]
    /// Light fills and lines that T3 paints opaque, a step off the background. Frosted, each becomes the black or
    /// white overlay that paints the same color over the stock background, so it tints whatever pane it sits on.
    /// Dark already paints these as white overlays.
    nonisolated static let tintMembers: Set<String> = [
        "--accent", "--muted", "--secondary", "--message-surface", "--sidebar-control-surface", "--toolbar-control-hover",
        "--sidebar-row-hover", "--border", "--contrast-border", "--sidebar-border", "--contrast-sidebar-border",
        "--input", "--contrast-input", "--toolbar-border", "--contrast-toolbar-border",
    ]

    /// `palette` with its surfaces turned into frosted panes and its light fills into overlays.
    nonisolated static func frosted(_ palette: Palette, dark: Bool, sidebar: Bool, opacity: Double) -> Palette {
        let members = palette.members
        let base = sidebar ? palette.sidebar : palette.background
        return Palette(members: { i in
            let c = members[i], name = Palette.memberNames[i]
            guard c.srgb.w >= 1 else { return c }
            if let level = paneMembers[name] { return c.withAlpha(paneAlpha(level, dark: dark, opacity: opacity)) }
            if !dark, tintMembers.contains(name) { return overlay(c, over: base) }
            return c
        })
    }

    /// The black or white overlay that paints `color` over `base`.
    nonisolated static func overlay(_ color: TokenColor, over base: TokenColor) -> TokenColor {
        let c = (color.srgb.x + color.srgb.y + color.srgb.z) / 3, b = (base.srgb.x + base.srgb.y + base.srgb.z) / 3
        if c <= b {
            let a = b > 0 ? min(1, 1 - c / b) : 1
            return TokenColor(srgb: SIMD4(0, 0, 0, a), displayP3: SIMD4(0, 0, 0, a))
        }
        let a = b < 1 ? min(1, (c - b) / (1 - b)) : 1
        return TokenColor(srgb: SIMD4(1, 1, 1, a), displayP3: SIMD4(1, 1, 1, a))
    }

    /// The faint line along a pane's top edge, inside its border: light catching the glass.
    public static let highlight = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 1, alpha: 0.75) }
    /// A pane's hairline edge where T3 draws no border of its own.
    public static let edge = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.07) }

    /// `frost` while classic Glass frosts the appearance, `stock` otherwise.
    public static func pick(stock: NSColor, frost: NSColor) -> NSColor {
        NSColor(name: nil) { resolve(ThemeRuntime.isGlass(dark: $0.isDark) ? frost : stock, in: $0) }
    }

    /// A panel's own ground (the right panel's views, full pages): T3's background, clear under classic Glass, so the
    /// window's frost and base tint show through as they do under the thread.
    public static let ground = pick(stock: Themed.color(\.background), frost: .clear)

    /// A surface T3 paints in the background color over another (an input, a list frame, a card): a pane under
    /// classic Glass.
    public static let paneFill = pick(stock: Themed.color(\.background), frost: Themed.color(\.card))

    /// A dense pane (code blocks, tables, diffs, the terminal): the code background at `Level.dense`.
    public static let denseFill = Themed.color(\.codeBackground)

    /// A floating surface's fill (dialogs, the command palette, toasts): T3's `stock` fill, or the floating pane.
    public static func floating(stock: NSColor) -> NSColor {
        let frost = Themed.color(\.popover)
        return NSColor(name: nil) { resolve(ThemeRuntime.framesPanes(dark: $0.isDark) ? frost : stock, in: $0) }
    }

    /// A message bubble's blur in Dither, where the bubble sits over the art: puts a within-window blur under `view`'s
    /// subviews while Dither shows and takes it out otherwise. Pass the blur it returned last time.
    @MainActor
    public static func syncBubbleBlur(_ blur: BackdropBlurView?, in view: NSView, radius: CGFloat) -> BackdropBlurView? {
        let on = view.window != nil && ThemeRuntime.isDither(dark: view.effectiveAppearance.isDark)
        guard on else { blur?.removeFromSuperview(); return nil }
        let made = blur ?? {
            let b = BackdropBlurView(frame: view.bounds)
            b.autoresizingMask = [.width, .height]
            view.addSubview(b, positioned: .below, relativeTo: nil)
            b.layer?.zPosition = -1
            return b
        }()
        made.cornerRadius = radius
        return made
    }

    /// Puts the hairline edge and top highlight on a layer-painted pane (a selected row, the composer) while classic
    /// Glass frosts `view`, and takes them off otherwise. Pass what it returned last time.
    @MainActor
    public static func syncEdge(_ existing: GlassEdgeLayer?, on parent: CALayer?, in view: NSView, radius: CGFloat,
                                edge: Bool = true, show: Bool = true) -> GlassEdgeLayer? {
        guard let parent, show, isActive(for: view) else {
            existing?.removeFromSuperlayer()
            return nil
        }
        let layer = existing ?? GlassEdgeLayer()
        if layer.superlayer !== parent { parent.addSublayer(layer) }
        layer.update(in: view, radius: radius, edge: edge)
        return layer
    }

    /// A drop shadow on a frosted surface: at most `0 2px 8px`, black at 8% (light) or 25% (dark). Smaller ones stay.
    nonisolated static func frostShadow(_ shadow: BoxShadow) -> BoxShadow {
        guard !shadow.inset, shadow.blur > 8 else { return shadow }
        let color = shadow.color
        let capped = NSColor(name: nil) { appearance in
            let resolved = resolve(color, in: appearance)
            return resolved.withAlphaComponent(min(resolved.alphaComponent, appearance.isDark ? 0.25 : 0.08))
        }
        return BoxShadow(x: 0, y: min(shadow.y, 2), blur: 8, spread: 0, color: capped)
    }

    /// A dynamic color's concrete value in `appearance`, for color providers that pick between dynamic colors.
    nonisolated static func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: color.cgColor) ?? color }
        return resolved
    }

    /// Whether classic Glass frosts every surface in the appearance being drawn now.
    public nonisolated static func frostDrawing() -> Bool {
        ThemeRuntime.isGlass(dark: NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// A floating pane's blur (menus, popovers, dialogs, toasts): puts a within-window blur under `view`'s subviews
    /// while classic Glass frosts it and takes it out otherwise. Floating panes cover sharp text, which a tint alone
    /// leaves legible through the glass. Pass the blur it returned last time; size it in `layout`.
    @MainActor
    public static func syncPaneBlur(_ blur: BackdropBlurView?, in view: NSView, radius: CGFloat) -> BackdropBlurView? {
        let on = view.window != nil && ThemeRuntime.framesPanes(dark: view.effectiveAppearance.isDark)
        if on, blur == nil {
            let made = BackdropBlurView(frame: view.bounds)
            made.autoresizingMask = [.width, .height]
            made.cornerRadius = radius
            view.addSubview(made, positioned: .below, relativeTo: nil)
            // Under the view's own box decoration layer too, so the border and highlight stay sharp.
            made.layer?.zPosition = -1
            return made
        }
        if !on, let blur {
            blur.removeFromSuperview()
            return nil
        }
        blur?.cornerRadius = radius
        return blur
    }

    /// A base surface's fill: the token, at `frostBaseAlpha` while Glass frosts the window in that appearance.
    public static func surface(_ key: KeyPath<Palette, TokenColor>, sidebar: Bool = false) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.isDark
            let color = ThemeRuntime.palettes.palette(dark: dark, sidebar: sidebar)[keyPath: key].nsColor
            guard ThemeRuntime.isGlass(dark: dark) else { return color }
            return color.withAlphaComponent(frostBaseAlpha(opacity: Double(ThemeRuntime.glassOpacity)))
        }
    }

    /// The main background painted again over the main surface (right panel, empty states): clear while frosted,
    /// so the right panel shows the same frost as the thread beside it.
    public static let inset = NSColor(name: nil) { appearance in
        let dark = appearance.isDark
        return ThemeRuntime.isGlass(dark: dark) ? .clear : ThemeRuntime.palettes.palette(dark: dark, sidebar: false).background.nsColor
    }

    public static let mainSurface = surface(\.background)
    public static let sidebarSurface = surface(\.sidebar, sidebar: true)

    /// Whether Glass frosts `view`'s window in the view's appearance.
    @MainActor
    public static func isActive(for view: NSView) -> Bool { ThemeRuntime.isGlass(dark: view.effectiveAppearance.isDark) }

    /// Puts the frost under `view`'s subviews while Glass frosts its window and takes it out otherwise: the
    /// pre-blurred desktop picture, or the real blur where that can't be used (`WallpaperBackdropView`). Pass the
    /// backdrop it returned last time.
    @MainActor
    public static func syncBackdrop(_ backdrop: WallpaperBackdropView?, in view: NSView) -> WallpaperBackdropView? {
        let on = view.window != nil && isActive(for: view)
        if on, backdrop == nil {
            let made = WallpaperBackdropView(frame: view.bounds)
            view.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }
        if !on, let backdrop {
            backdrop.removeFromSuperview()
            return nil
        }
        return backdrop
    }
}

/// The real frost, `WallpaperBackdropView`'s fallback: a behind-window visual effect view that keeps the system's material and blur but paints
/// nothing of its own on top. The window server composites it; it has no backing store in this process.
public final class WindowGlassBackdropView: NSVisualEffectView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        material = .underWindowBackground
        // Inactive windows fall back to the flat material like every Mac sidebar, so a background window
        // costs the compositor nothing extra.
        state = .followsWindowActiveState
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The blur alone, with the material's own tint layers hidden, so the base tint over it
    // (`WindowGlass.frostBaseAlpha`) is the only density and the slider controls all of it.
    // ponytail: hides the effect view's private tint layers like BackdropBlurView; if a macOS update renames
    // the backdrop layer, nothing is hidden and the window falls back to the system material. Revisit per macOS.

    public override func updateLayer() { super.updateLayer(); tune() }
    public override func layout() { super.layout(); tune() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tune() }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // AppKit rebuilds the material layers after this returns.
        DispatchQueue.main.async { [weak self] in self?.tune() }
    }

    private func tune() {
        guard let root = layer else { return }
        var hasBackdrop = false
        func walk(_ l: CALayer) {
            for s in l.sublayers ?? [] {
                if NSStringFromClass(type(of: s)).contains("Backdrop") { hasBackdrop = true; continue }
                if s.sublayers?.isEmpty == false { walk(s) } else if s.isHidden != hasBackdrop { s.isHidden = hasBackdrop }
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        walk(root)
        CATransaction.commit()
    }

    // Clicks belong to the surfaces above.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { false }
}

/// A frosted pane's hairline edge and top highlight for surfaces painted on a plain layer. Sized to its parent;
/// no backing store, just a border and a 1px line.
public final class GlassEdgeLayer: CALayer {
    private let shine = CALayer()
    private var flipped = true

    public override init() {
        super.init()
        masksToBounds = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        addSublayer(shine)
        actions = ["bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "cornerRadius": NSNull()]
        shine.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
    }
    public override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func update(in view: NSView, radius: CGFloat, edge: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flipped = view.isFlipped
        frame = superlayer?.bounds ?? .zero
        cornerRadius = radius
        borderWidth = edge ? 1 : 0
        borderColor = WindowGlass.edge.cgColor(in: view)
        shine.backgroundColor = WindowGlass.highlight.cgColor(in: view)
        layoutSublayers()
        CATransaction.commit()
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        let inset = borderWidth
        shine.frame = CGRect(x: 0, y: flipped ? inset : bounds.height - inset - 1, width: bounds.width, height: 1)
    }
}
