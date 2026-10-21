import Foundation

/// Ports of T3's theme library (apps/web/src/themePalette.ts and packages/shared/src/themePalettes.ts):
/// definitions, the theme file format, color canonicalization, the guided editor's vivid palette engine and
/// the advanced editor's color families. Line numbers below refer to themePalette.ts.

public enum ThemeAppearance: String, CaseIterable, Sendable, Codable {
    case light, dark
    public var other: ThemeAppearance { self == .light ? .dark : .light }
}

extension ThemeColorRole {
    /// The CSS variable T3 sets for the role (`APP_THEME_VARIABLES`, 1448-1510).
    public var cssVariable: String {
        if self == .terminalSelection { return "--app-theme-terminal-selection-background" }
        return "--app-theme-" + rawValue.replacing(#/[A-Z]/#) { "-" + $0.output.lowercased() }
    }
}

/// `ThemeDefinition` (themePalettes.ts:113-125).
public struct ThemeDefinition: Equatable, Sendable {
    public struct Collection: Equatable, Sendable { public var id: String; public var label: String }
    public var id: String
    public var label: String
    public var appearance: ThemeAppearance
    public var colors: [ThemeColorRole: String]
    public var variants: [ThemeAppearance: [ThemeColorRole: String]]
    public var collection: Collection?
    public var sidebarArtwork: Bool
    public var managed: Bool

    public init(id: String, label: String, appearance: ThemeAppearance, colors: [ThemeColorRole: String],
                variants: [ThemeAppearance: [ThemeColorRole: String]] = [:], collection: Collection? = nil,
                sidebarArtwork: Bool = false, managed: Bool = false) {
        self.id = id; self.label = label; self.appearance = appearance; self.colors = colors; self.variants = variants
        self.collection = collection; self.sidebarArtwork = sidebarArtwork; self.managed = managed
    }

    /// `getThemeColorsForMode` (1124-1130).
    public func colors(for mode: ThemeAppearance) -> [ThemeColorRole: String]? {
        mode == appearance ? colors : variants[mode]
    }

    /// `getThemeModes` (1132-1134).
    public var modes: [ThemeAppearance] { ThemeAppearance.allCases.filter { colors(for: $0) != nil } }

    /// `singleAppearanceOf` (1119-1122).
    public var singleAppearance: ThemeAppearance? { modes.count == 1 ? modes[0] : nil }

    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    /// CandyWrapper's own theme, not in T3: T3 Code's stock colors over a window the system frosts with a
    /// behind-window blur (`WindowGlass`). Its id can't clash with a theme saved in T3, whose ids never
    /// carry this prefix by convention, and the runtime paints it with the stock tokens, not these colors.
    public static let glass = ThemeDefinition(id: "candywrapper-glass", label: "Glass", appearance: .light,
                                              colors: standardLightColors, variants: [.dark: standardDarkColors])

    /// CandyWrapper's own theme, not in T3: the stock look with a dithered picture the user chose (the desktop picture
    /// until they do) in the main panel (`DitherArtView`). Every other surface stays solid.
    public static let dither = ThemeDefinition(id: "candywrapper-dither", label: "Dither", appearance: .light,
                                               colors: capyLightColors, variants: [.dark: capyDarkColors])

    /// Dither's palette: Capy's default theme, its hover and selected fills translucent overlays like Capy's `--secondary`, from its stylesheet (`--bg`, `--panel`, `--card`, `--popover`, the text
    /// mixes and the teal `--primary`, docs/research in ~/CandyWrapper-research/capy-design.md). Near-black cool grays,
    /// the chrome a step darker than the panel, and teal for the focus ring, selection and send button.
    static let capyDarkColors: [ThemeColorRole: String] = standardDarkColors.merging([
        .canvas: "#131314", .chrome: "#0a0a0b", .toolbar: "#0a0a0b", .toolbarBorder: "#1d1d1e", .toolbarControl: "#181819",
        .toolbarControlHover: "#ffffff14", .surface: "#181819", .surfaceRaised: "#202021", .surfaceOverlay: "#202021",
        .text: "#f5f5f5", .textMuted: "#aaaaab", .border: "#232324", .input: "#2a2a2b", .focus: "#2b948b",
        .accent: "#2b948b", .accentForeground: "#ffffff", .secondary: "#ffffff14", .secondaryForeground: "#f5f5f5",
        .muted: "#1c1c1d", .mutedForeground: "#aaaaab", .placeholder: "#616162", .secondaryLabel: "#848485",
        .iconMuted: "#686869", .accentSurface: "#ffffff14", .accentSurfaceForeground: "#f5f5f5",
        .messageSurface: "#202021", .messageForeground: "#f5f5f5", .messageAction: "#2b948b",
        .messageActionForeground: "#ffffff", .messageActionHover: "#258178", .codeBackground: "#0f0f10",
        .sidebar: "#0a0a0b", .sidebarForeground: "#f5f5f5", .sidebarMutedForeground: "#848485",
        .sidebarControlSurface: "#141415", .sidebarRowHover: "#ffffff0f", .sidebarRowActive: "#ffffff17",
        .sidebarRowSelected: "#ffffff17", .sidebarBorder: "#0a0a0b", .terminalBackground: "#0f0f10",
        .terminalCursor: "#2b948b", .terminalSelection: "#1f3d3a",
    ]) { $1 }
    static let capyLightColors: [ThemeColorRole: String] = standardLightColors.merging([
        .canvas: "#f9f9f9", .chrome: "#ececec", .toolbar: "#ececec", .toolbarBorder: "#dadada", .toolbarControl: "#ffffff",
        .toolbarControlHover: "#0000000d", .surface: "#ffffff", .surfaceRaised: "#ffffff", .surfaceOverlay: "#ffffff",
        .text: "#1e1e1e", .textMuted: "#6c6c6c", .border: "#dadada", .input: "#d4d4d4", .focus: "#0b9f95",
        .accent: "#0b9f95", .accentForeground: "#ffffff", .secondary: "#0000000d", .secondaryForeground: "#1e1e1e",
        .muted: "#e1e1e2", .mutedForeground: "#6c6c6c", .placeholder: "#a2a2a2", .secondaryLabel: "#898989",
        .iconMuted: "#959595", .accentSurface: "#0000000d", .accentSurfaceForeground: "#1e1e1e",
        .messageSurface: "#efefef", .messageForeground: "#1e1e1e", .messageAction: "#0b9f95",
        .messageActionForeground: "#ffffff", .messageActionHover: "#098a81", .codeBackground: "#f4f4f4",
        .sidebar: "#ececec", .sidebarForeground: "#1e1e1e", .sidebarMutedForeground: "#898989",
        .sidebarControlSurface: "#e4e4e4", .sidebarRowHover: "#0000000a", .sidebarRowActive: "#00000012",
        .sidebarRowSelected: "#00000012", .sidebarBorder: "#ececec",
    ]) { $1 }

    /// The theme picker's fixed cards: T3's built-ins, then Glass and Dither.
    public static let pickerBuiltIns = builtIns + [glass, dither]

    public var isWindowGlass: Bool { id == Self.glass.id }
    public var isDither: Bool { id == Self.dither.id }
}

/// The theme library's rules and color math.
public enum ThemePalette {
    public static let fileVersion = 1
    public static let reservedIds: Set<String> = ["system", "light", "dark", "t3-chat", "grove", "ocean", "ember", "iris",
                                                  "t3-chat-dark", "t3-grove", "t3-ocean", "t3-ember", "t3-iris",
                                                  "candywrapper-glass", "candywrapper-glass-native", "candywrapper-dither"]
    static let legacyAliases = ["t3-chat-dark": "t3-chat", "t3-grove": "grove", "t3-ocean": "ocean", "t3-ember": "ember", "t3-iris": "iris",
                               "candywrapper-glass-native": "candywrapper-glass"]

    /// `normalizeThemeId` (308-310), plus CandyWrapper's removed Glass Native, which reads as Glass (decided
    /// 2026-10-14, docs/decisions.md). Its id stays reserved so no custom theme takes it.
    public static func normalizedId(_ id: String) -> String { legacyAliases[id] ?? id }

    /// `isThemeId` (110-112).
    public static func isThemeId(_ id: String) -> Bool { id.wholeMatch(of: #/[a-z0-9](?:[a-z0-9-]{0,47})/#) != nil }

    /// `isThemeLabel` (114-116).
    public static func isThemeLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.count <= 48
    }

    /// `themeIdFromName` (1144-1152).
    public static func themeId(fromName name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacing(#/[^a-z0-9]+/#, with: "-")
        s = s.replacing(#/^-+|-+$/#, with: "")
        s = String(s.prefix(48))
        return s.isEmpty ? "custom-theme" : s
    }

    // MARK: Colors (363-468)

    struct Oklch: Equatable { var L: Double; var C: Double; var h: Double }
    typealias RGB = SIMD3<Double>   // 0...255, unrounded

    /// `parseThemeColor` (363-384): any literal CSS color as clamped OKLCH and alpha.
    static func parse(_ value: String) -> (color: Oklch, alpha: Double)? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = ThemeCSSColor.parse(input) else { return nil }
        let lch = c.lch
        let alpha = input.range(of: #"/\s*none\s*\)$"#, options: [.regularExpression, .caseInsensitive]) != nil ? 0 : c.alpha
        guard [lch.x, lch.y, lch.z, alpha].allSatisfy(\.isFinite) else { return nil }
        return (Oklch(L: min(1, max(0, lch.x)), C: max(0, lch.y), h: c.hueMissing ? 0 : lch.z), min(1, max(0, alpha)))
    }

    /// `formatThemeColorNumber` (386-389): JS `toFixed` without trailing zeros.
    static func format(_ value: Double, _ precision: Int) -> String {
        let rounded = abs(value) < pow(10, Double(-precision)) / 2 ? 0 : value
        // JS `toFixed` switches to exponent notation from 1e21 ("1e+303").
        if abs(rounded) >= 1e21 {
            let parts = String(format: "%.15e", rounded).split(separator: "e")
            var mantissa = String(parts[0])
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            return "\(mantissa)e+\(Int(parts[1])!)"
        }
        var s = String(format: "%.\(precision)f", rounded)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// `formatOklchThemeColor` (391-399).
    static func format(_ c: Oklch, alpha: Double = 1) -> String {
        let hue = c.C < 0.0000005 ? 0 : (c.h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let body = "\(format(c.L, 6)) \(format(c.C, 6)) \(format(hue, 3))"
        return alpha < 1 ? "oklch(\(body) / \(format(alpha, 4)))" : "oklch(\(body))"
    }

    /// `toCanonicalThemeColor` (401-404).
    public static func canonical(_ value: String) -> String? {
        parse(value).map { format($0.color, alpha: $0.alpha) }
    }

    public static func isThemeColor(_ value: String) -> Bool { canonical(value) != nil }

    /// `themeColorToHex` (407-418).
    public static func hex(_ value: String) -> String? {
        guard let p = parse(value) else { return nil }
        let opaque = hex(rgb(p.color))
        if p.alpha >= 1 { return opaque }
        return opaque + String(format: "%02x", Int((p.alpha * 255).rounded()))
    }

    static func parseRGB(_ value: String, fallback: RGB) -> RGB { parse(value).map { rgb($0.color) } ?? fallback }

    static func hex(_ c: RGB) -> String {
        "#" + [c.x, c.y, c.z].map { String(format: "%02x", Int(min(255, max(0, $0)).rounded(.toNearestOrAwayFromZero))) }.joined()
    }

    static func color(_ c: RGB) -> String { format(oklch(c)) }

    static func mix(_ base: RGB, _ overlay: RGB, _ amount: Double) -> RGB { base + (overlay - base) * amount }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { let n = v / 255; return n <= 0.03928 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
    }

    static func oklch(_ c: RGB) -> Oklch {
        let lab = ThemeCSSColor(srgb: c.x / 255, c.y / 255, c.z / 255).lab
        return Oklch(L: lab.x, C: (lab.y * lab.y + lab.z * lab.z).squareRoot(), h: atan2(lab.z, lab.y) * 180 / .pi)
    }

    static func linearUnclamped(_ c: Oklch) -> SIMD3<Double> {
        ThemeCSSColor(oklch: c.L, c.C, c.h).linearSRGB
    }

    /// `mapThemeOklchToSrgbGamut` (532-555).
    static func gamutMapped(_ c: Oklch) -> Oklch {
        func inGamut(_ chroma: Double) -> Bool {
            let v = linearUnclamped(Oklch(L: c.L, C: chroma, h: c.h))
            return [v.x, v.y, v.z].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
        }
        if inGamut(c.C) { return c }
        var low = 0.0, high = c.C
        let resolution = 0.000001
        let steps = max(1, Int(ceil(log2(max(c.C, resolution)) - log2(resolution))))
        for _ in 0..<steps {
            let mid = (low + high) / 2
            if inGamut(mid) { low = mid } else { high = mid }
        }
        return Oklch(L: c.L, C: low, h: c.h)
    }

    /// `themeOklchToRgb` (557-564): gamut mapped, rounded channels.
    static func rgb(_ c: Oklch) -> RGB {
        let v = linearUnclamped(gamutMapped(c))
        func ch(_ x: Double) -> Double { (min(1, max(0, ThemeCSSColor.gamma(x))) * 255).rounded(.toNearestOrAwayFromZero) }
        return RGB(ch(v.x), ch(v.y), ch(v.z))
    }

    static func themeColor(_ c: Oklch) -> String { format(gamutMapped(c)) }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `solveOklchLightness` (571-600).
    static func solveLightness(_ base: Oklch, against: RGB, minContrast: Double, lighter: Bool) -> Oklch {
        var low = lighter ? base.L : 0, high = lighter ? 1 : base.L
        if contrast(rgb(base), against) >= minContrast { return base }
        for _ in 0..<18 {
            let mid = (low + high) / 2
            let ok = contrast(rgb(Oklch(L: mid, C: base.C, h: base.h)), against) >= minContrast
            if ok == lighter { high = mid } else { low = mid }
        }
        return Oklch(L: lighter ? high : low, C: base.C, h: base.h)
    }

    static let lightForeground = RGB(255, 250, 255), darkForeground = RGB(36, 21, 35)
    static let white = RGB(255, 255, 255), black = RGB(0, 0, 0)

    /// `readableThemeForeground` (822-833).
    static func readableForeground(_ background: RGB) -> RGB {
        let l = contrast(background, lightForeground), d = contrast(background, darkForeground)
        if max(l, d) >= 4.5 { return l >= d ? lightForeground : darkForeground }
        return contrast(background, white) >= contrast(background, black) ? white : black
    }

    /// `readableThemeText` (835-865).
    static func readableText(_ background: RGB, _ foreground: RGB, _ amount: Double, _ minimum: Double) -> RGB {
        let softened = mix(foreground, background, amount)
        if contrast(softened, background) >= minimum { return softened }
        var readable = foreground, lower = 0.0, upper = amount
        for _ in 0..<12 {
            let a = (lower + upper) / 2
            let candidate = mix(foreground, background, a)
            if contrast(candidate, background) >= minimum { readable = candidate; lower = a } else { upper = a }
        }
        return readable
    }

    /// `standardMutedThemeText` (870-880).
    static func standardMutedText(_ background: RGB, _ foreground: RGB) -> RGB {
        readableText(background, foreground, 1, luminance(background) < 0.179 ? 5.082 : 4.705)
    }

    // MARK: Palettes

    /// `getStandardThemeColors` (337-344): T3 Code's own look, canonicalized.
    public static func standardColors(_ appearance: ThemeAppearance) -> [ThemeColorRole: String] {
        appearance == .dark ? standardDark : standardLight
    }
    private static let standardLight = ThemeDefinition.standardLightColors.compactMapValues(canonical)
    private static let standardDark = ThemeDefinition.standardDarkColors.compactMapValues(canonical)

    /// `getDefaultThemeColors` (882-884): roles a theme file leaves out come from T3 Chat.
    public static func defaultColors(_ appearance: ThemeAppearance) -> [ThemeColorRole: String] {
        let chat = ThemeDefinition.builtIns[0]
        return appearance == .dark ? chat.variants[.dark]! : chat.colors
    }

    /// `standardStatusColors` (622-667).
    static func standardStatusColors(_ canvas: RGB) -> [ThemeColorRole: String] {
        let dark = luminance(canvas) < 0.179
        let standard: (error: String, errorForeground: String, warning: String, warningForeground: String) = dark
            ? ("#fb414a", "#ff6467", "#fe9a00", "#ffb900") : ("#fb2c36", "#c10007", "#fe9a00", "#bb4d00")
        let surfaceMix = dark ? 0.16 : 0.08
        func surface(_ v: String) -> RGB { mix(canvas, parseRGB(v, fallback: canvas), surfaceMix) }
        func readable(_ fg: String, _ on: RGB) -> String {
            themeColor(solveLightness(oklch(parseRGB(fg, fallback: canvas)), against: on, minContrast: 4.6, lighter: dark))
        }
        let errorSurface = surface(standard.error), warningSurface = surface(standard.warning)
        return [.error: canonical(standard.error)!, .errorForeground: readable(standard.errorForeground, errorSurface),
                .errorSurface: color(errorSurface), .warning: canonical(standard.warning)!,
                .warningForeground: readable(standard.warningForeground, warningSurface), .warningSurface: color(warningSurface)]
    }

    /// `createVividThemeColors` (669-812): a whole palette from a background and an accent.
    public static func vividColors(_ appearance: ThemeAppearance, background: String, accent accentValue: String) -> [ThemeColorRole: String] {
        let canvasRGB = parseRGB(background, fallback: appearance == .dark ? RGB(24, 15, 27) : RGB(250, 245, 250))
        let accentRGB = parseRGB(accentValue, fallback: RGB(168, 67, 112))
        let canvas = oklch(canvasRGB), accent = oklch(accentRGB)
        let dark = luminance(canvasRGB) < 0.179
        let hue = accent.C < 0.02 ? canvas.h : accent.h
        let tintC = min(0.045, max(0.008, accent.C * 0.22))
        let step: Double = dark ? 1 : -1
        func surfaceAt(_ dL: Double, _ chroma: Double? = nil) -> Oklch {
            Oklch(L: min(0.98, max(0.05, canvas.L + step * dL)), C: chroma ?? tintC, h: hue)
        }
        let textBase = Oklch(L: dark ? 0.95 : 0.2, C: min(0.035, accent.C * 0.25), h: hue)
        let text = solveLightness(textBase, against: canvasRGB, minContrast: 7, lighter: dark)
        let textRGB = rgb(text)
        let textMutedRGB = standardMutedText(canvasRGB, textRGB)
        let action = Oklch(L: min(0.85, max(0.35, accent.L + (dark ? 0.06 : -0.02))), C: max(accent.C * 0.9, 0.06),
                           h: (hue + 50).truncatingRemainder(dividingBy: 360))
        let actionRGB = rgb(action)
        let sidebar = surfaceAt(0.045, tintC * 1.4), sidebarRGB = rgb(sidebar)
        let surfaceRaised = surfaceAt(0.05), surfaceRaisedRGB = rgb(surfaceRaised)
        let secondary = surfaceAt(dark ? 0.1 : 0.06, min(0.09, accent.C * 0.5))
        let muted = surfaceAt(dark ? 0.06 : 0.04, min(0.06, accent.C * 0.35))
        let accentSurface = surfaceAt(dark ? 0.13 : 0.08, min(0.11, accent.C * 0.55))
        let messageSurface = surfaceAt(dark ? 0.16 : 0.1, min(0.13, accent.C * 0.6))
        let updateSurface = surfaceAt(dark ? 0.14 : 0.09, min(0.12, accent.C * 0.55))
        func foregroundOn(_ s: RGB) -> String { themeColor(solveLightness(textBase, against: s, minContrast: 4.6, lighter: dark)) }
        let searchMatch = rgb(surfaceAt(0.22, min(0.12, accent.C)))
        let searchMatchActive = rgb(surfaceAt(0.4, min(0.18, accent.C)))
        let actionHover = Oklch(L: action.L + (dark ? 0.06 : -0.06), C: action.C, h: action.h)
        var out = defaultColors(appearance)
        out.merge(standardStatusColors(canvasRGB)) { $1 }
        let mutedText = color(textMutedRGB)
        out.merge([
            .canvas: color(canvasRGB), .chrome: color(canvasRGB), .toolbar: color(canvasRGB),
            .toolbarForeground: color(textRGB),
            .toolbarBorder: themeColor(surfaceAt(dark ? 0.14 : 0.1, min(0.08, accent.C * 0.4))),
            .toolbarControl: themeColor(surfaceAt(dark ? 0.09 : 0.05, tintC * 1.3)),
            .toolbarControlForeground: color(textRGB),
            .toolbarControlHover: themeColor(surfaceAt(dark ? 0.14 : 0.09, tintC * 1.6)),
            .surface: themeColor(surfaceAt(0.015)), .surfaceRaised: themeColor(surfaceRaised), .surfaceOverlay: themeColor(surfaceAt(0.075)),
            .text: color(textRGB), .textMuted: mutedText,
            .border: themeColor(surfaceAt(dark ? 0.16 : 0.12, min(0.07, accent.C * 0.35))),
            .input: themeColor(surfaceAt(dark ? 0.21 : 0.16, min(0.08, accent.C * 0.4))),
            .focus: color(accentRGB), .accent: color(accentRGB), .accentForeground: color(readableForeground(accentRGB)),
            .secondary: themeColor(secondary), .secondaryForeground: foregroundOn(rgb(secondary)),
            .muted: themeColor(muted), .mutedForeground: color(readableText(rgb(muted), textRGB, 1, 4.6)),
            .placeholder: color(readableText(surfaceRaisedRGB, textRGB, 1, 4.6)),
            .secondaryLabel: mutedText, .iconMuted: mutedText,
            .update: color(accentRGB), .updateForeground: foregroundOn(rgb(updateSurface)), .updateSurface: themeColor(updateSurface),
            .accentSurface: themeColor(accentSurface), .accentSurfaceForeground: foregroundOn(rgb(accentSurface)),
            .messageSurface: themeColor(messageSurface), .messageForeground: foregroundOn(rgb(messageSurface)),
            .messageAction: color(actionRGB), .messageActionForeground: color(readableForeground(actionRGB)),
            .messageActionHover: themeColor(actionHover),
            .codeBackground: themeColor(surfaceAt(0.035, tintC * 0.8)), .codeForeground: color(textRGB),
            .searchMatchBackground: color(searchMatch), .searchMatchForeground: color(readableForeground(searchMatch)),
            .searchMatchActiveBackground: color(searchMatchActive),
            .searchMatchActiveForeground: color(readableForeground(searchMatchActive)),
            .sidebar: themeColor(sidebar), .sidebarForeground: foregroundOn(sidebarRGB),
            .sidebarMutedForeground: color(standardMutedText(sidebarRGB, textRGB)),
            .sidebarControlSurface: themeColor(surfaceAt(dark ? 0.1 : 0.07, tintC * 1.5)),
            .sidebarRowHover: themeColor(surfaceAt(dark ? 0.08 : 0.06, min(0.08, accent.C * 0.45))),
            .sidebarRowActive: themeColor(surfaceAt(dark ? 0.12 : 0.09, min(0.1, accent.C * 0.55))),
            .sidebarRowSelected: themeColor(surfaceAt(dark ? 0.14 : 0.1, min(0.11, accent.C * 0.6))),
            .sidebarBorder: themeColor(surfaceAt(dark ? 0.17 : 0.12, min(0.08, accent.C * 0.4))),
            .terminalBackground: color(canvasRGB), .terminalForeground: color(textRGB), .terminalCursor: color(accentRGB),
            .terminalSelection: themeColor(surfaceAt(dark ? 0.18 : 0.12, min(0.12, accent.C * 0.55))),
            .terminalScrollbar: themeColor(surfaceAt(dark ? 0.22 : 0.16, tintC)),
            .terminalScrollbarHover: themeColor(surfaceAt(dark ? 0.3 : 0.22, tintC)),
        ]) { $1 }
        return out
    }

    /// `updateThemeColorFamily` (892-1088): the advanced editor changes one family's representative role
    /// and derives its paired roles.
    public static func updateFamily(_ appearance: ThemeAppearance, _ colors: [ThemeColorRole: String], role: ThemeColorRole,
                                    value: String) -> [ThemeColorRole: String] {
        var out = colors
        guard let selectedParsed = parse(value) else { out[role] = value; return out }
        let normalized = format(selectedParsed.color, alpha: selectedParsed.alpha)
        let canvas = parseRGB(colors[.canvas] ?? "", fallback: appearance == .dark ? RGB(24, 15, 27) : RGB(250, 245, 250))
        let selected = rgb(selectedParsed.color)
        func selectedOn(_ background: RGB) -> RGB { mix(background, selected, selectedParsed.alpha) }
        let onCanvas = selectedOn(canvas)
        let accent = parseRGB(colors[.accent] ?? "", fallback: RGB(168, 67, 112))
        let canvasIsDark = luminance(canvas) < 0.179
        let terminalIsDark = luminance(onCanvas) < 0.179
        func foregroundOn(_ b: RGB) -> String { color(readableForeground(b)) }
        func toneOn(_ b: RGB) -> String {
            themeColor(solveLightness(selectedParsed.color, against: b, minContrast: 4.6, lighter: luminance(b) < 0.179))
        }
        func status() -> (foreground: String, surface: String) {
            let surface = mix(canvas, onCanvas, canvasIsDark ? 0.16 : 0.08)
            return (toneOn(surface), color(surface))
        }
        func set(_ pairs: [ThemeColorRole: String]) { out.merge(pairs) { $1 } }
        switch role {
        case .canvas: set([.canvas: normalized, .chrome: normalized, .toolbar: normalized])
        case .text: set([.text: normalized, .toolbarForeground: normalized, .toolbarControlForeground: normalized])
        case .mutedForeground:
            set([.textMuted: normalized, .mutedForeground: normalized, .placeholder: normalized, .secondaryLabel: normalized,
                 .iconMuted: normalized, .sidebarMutedForeground: normalized])
        case .border: set([.border: normalized, .toolbarBorder: normalized, .sidebarBorder: normalized])
        case .secondary:
            set([.secondary: normalized, .secondaryForeground: foregroundOn(onCanvas), .muted: normalized, .toolbarControl: normalized])
        case .accentSurface:
            set([.accentSurface: normalized, .accentSurfaceForeground: foregroundOn(onCanvas), .toolbarControlHover: normalized])
        case .accent:
            let updateSurface = mix(canvas, onCanvas, canvasIsDark ? 0.32 : 0.16)
            set([.accent: normalized, .accentForeground: foregroundOn(onCanvas), .focus: normalized, .update: normalized,
                 .updateForeground: toneOn(updateSurface), .updateSurface: color(updateSurface), .terminalCursor: normalized])
        case .messageAction:
            let fg = readableForeground(onCanvas)
            let toward = fg == lightForeground || fg == white ? black : white
            let hover = mix(selected, toward, 0.12)
            set([.messageAction: normalized, .messageActionForeground: color(fg),
                 .messageActionHover: format(oklch(hover), alpha: selectedParsed.alpha)])
        case .messageSurface: set([.messageSurface: normalized, .messageForeground: foregroundOn(onCanvas)])
        case .searchMatchBackground: set([.searchMatchBackground: color(onCanvas), .searchMatchForeground: foregroundOn(onCanvas)])
        case .searchMatchActiveBackground:
            set([.searchMatchActiveBackground: color(onCanvas), .searchMatchActiveForeground: foregroundOn(onCanvas)])
        case .codeBackground: set([.codeBackground: normalized, .codeForeground: foregroundOn(onCanvas)])
        case .sidebar: set([.sidebar: normalized, .sidebarForeground: foregroundOn(onCanvas)])
        case .sidebarRowSelected:
            let sidebar = parseRGB(colors[.sidebar] ?? "", fallback: canvas)
            let onSidebar = selectedOn(sidebar)
            set([.sidebarRowHover: color(mix(sidebar, onSidebar, 0.5)), .sidebarRowActive: color(mix(sidebar, onSidebar, 0.8)),
                 .sidebarRowSelected: normalized])
        case .terminalBackground:
            let fg = readableForeground(onCanvas)
            set([.terminalBackground: normalized, .terminalForeground: color(fg),
                 .terminalSelection: color(mix(onCanvas, accent, terminalIsDark ? 0.35 : 0.18)),
                 .terminalScrollbar: color(mix(onCanvas, fg, terminalIsDark ? 0.42 : 0.22)),
                 .terminalScrollbarHover: color(mix(onCanvas, fg, terminalIsDark ? 0.55 : 0.32))])
        case .error:
            let s = status()
            set([.error: normalized, .errorForeground: s.foreground, .errorSurface: s.surface])
        case .warning:
            let s = status()
            set([.warning: normalized, .warningForeground: s.foreground, .warningSurface: s.surface])
        default: set([role: normalized])
        }
        return out
    }

    // MARK: Theme files (1350-1446)

    public struct FileError: Error, Equatable, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static func overrides(_ value: Any?) throws -> [ThemeColorRole: String] {
        guard let record = value as? [String: Any] else { throw FileError(message: "Theme colors must be objects.") }
        var out: [ThemeColorRole: String] = [:]
        for (key, raw) in record {
            guard let role = ThemeColorRole(rawValue: key) else { throw FileError(message: "\"\(key)\" is not a supported theme color role.") }
            guard let s = raw as? String, let c = canonical(s) else {
                throw FileError(message: "The color for \"\(key)\" must be a literal CSS color such as oklch(0.62 0.2 280).")
            }
            out[role] = c
        }
        if out.isEmpty { throw FileError(message: "Add at least one color role to the theme file.") }
        return out
    }

    static func collection(_ value: Any?) -> ThemeDefinition.Collection? {
        guard let r = value as? [String: Any], let id = r["id"] as? String, let label = r["label"] as? String,
              id.wholeMatch(of: #/(?i)[a-z0-9][a-z0-9.:-]{0,127}/#) != nil, isThemeLabel(label) else { return nil }
        return .init(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `parseThemeFile` (1372-1431).
    public static func parseFile(_ value: Any) throws -> ThemeDefinition {
        guard let r = value as? [String: Any] else { throw FileError(message: "Theme files must contain a JSON object.") }
        guard (r["version"] as? NSNumber)?.intValue == fileVersion, (r["version"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            throw FileError(message: "This theme file uses an unsupported version. Expected \(fileVersion).")
        }
        guard let name = r["name"] as? String, isThemeLabel(name) else { throw FileError(message: "Theme files need a name (48 characters or fewer).") }
        guard let appearance = (r["appearance"] as? String).flatMap(ThemeAppearance.init(rawValue:)) else {
            throw FileError(message: "Theme files need an appearance of \"light\" or \"dark\".")
        }
        guard r["colors"] is [String: Any] else { throw FileError(message: "Theme files need a colors object.") }
        let idValue: Any = r["id"] ?? themeId(fromName: name)
        guard let id = idValue as? String, isThemeId(id) else {
            throw FileError(message: "Theme ids may only contain lowercase letters, numbers, and hyphens.")
        }
        if reservedIds.contains(id) { throw FileError(message: "The theme id \"\(id)\" is reserved.") }
        let colors = try overrides(r["colors"])
        let coll = collection(r["collection"])
        if r["collection"] != nil, coll == nil { throw FileError(message: "Theme collections need a valid id and label.") }
        var variants: [ThemeAppearance: [ThemeColorRole: String]] = [:]
        if let raw = r["variants"] {
            guard let v = raw as? [String: Any] else { throw FileError(message: "Theme variants must be an object.") }
            for (key, value) in v {
                guard let a = ThemeAppearance(rawValue: key) else { throw FileError(message: "Theme variants may only be named \"light\" or \"dark\".") }
                if a == appearance { throw FileError(message: "Theme variants must not repeat the base appearance \"\(appearance.rawValue)\".") }
                variants[a] = defaultColors(a).merging(try overrides(value)) { $1 }
            }
        }
        return ThemeDefinition(id: id, label: name.trimmingCharacters(in: .whitespacesAndNewlines), appearance: appearance,
                               colors: defaultColors(appearance).merging(colors) { $1 }, variants: variants, collection: coll,
                               managed: r["managed"] as? Bool == true)
    }

    /// `serializeThemeFile` (1433-1446), keys in T3's order with JSON.stringify's two-space indent.
    public static func serializeFile(_ theme: ThemeDefinition) -> String {
        func colorsJSON(_ c: [ThemeColorRole: String], indent: String) -> String {
            let rows = ThemeColorRole.allCases.compactMap { role in c[role].map { "\(indent)  \"\(role.rawValue)\": \(quoted(canonical($0) ?? $0))" } }
            return "{\n" + rows.joined(separator: ",\n") + "\n\(indent)}"
        }
        var parts = ["  \"version\": \(fileVersion)", "  \"id\": \(quoted(theme.id))", "  \"name\": \(quoted(theme.label))",
                     "  \"appearance\": \"\(theme.appearance.rawValue)\"", "  \"colors\": " + colorsJSON(theme.colors, indent: "  ")]
        if !theme.variants.isEmpty {
            let rows = ThemeAppearance.allCases.compactMap { a in theme.variants[a].map { "    \"\(a.rawValue)\": " + colorsJSON($0, indent: "    ") } }
            parts.append("  \"variants\": {\n" + rows.joined(separator: ",\n") + "\n  }")
        }
        if let c = theme.collection { parts.append("  \"collection\": {\n    \"id\": \(quoted(c.id)),\n    \"label\": \(quoted(c.label))\n  }") }
        if theme.managed { parts.append("  \"managed\": true") }
        return "{\n" + parts.joined(separator: ",\n") + "\n}\n"
    }

    static func quoted(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    /// `parseStoredTheme` (171-190): stored themes tolerate unknown roles and bad values.
    public static func parseStored(_ value: Any) -> ThemeDefinition? {
        guard let r = value as? [String: Any], let id = r["id"] as? String, isThemeId(id), !reservedIds.contains(id),
              let label = r["label"] as? String, isThemeLabel(label),
              let appearance = (r["appearance"] as? String).flatMap(ThemeAppearance.init(rawValue:)),
              let colors = lenient(r["colors"], appearance) else { return nil }
        var variants: [ThemeAppearance: [ThemeColorRole: String]] = [:]
        if let raw = r["variants"] {
            guard let v = raw as? [String: Any] else { return nil }
            for (key, value) in v {
                guard let a = ThemeAppearance(rawValue: key) else { return nil }
                if a == appearance { continue }
                guard let c = lenient(value, a) else { return nil }
                variants[a] = c
            }
        }
        return ThemeDefinition(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines), appearance: appearance,
                               colors: colors, variants: variants, collection: collection(r["collection"]),
                               managed: r["managed"] as? Bool == true)
    }

    static func lenient(_ value: Any?, _ appearance: ThemeAppearance) -> [ThemeColorRole: String]? {
        guard let r = value as? [String: Any] else { return nil }
        var out = defaultColors(appearance)
        for (key, raw) in r {
            if let role = ThemeColorRole(rawValue: key), let s = raw as? String, let c = canonical(s) { out[role] = c }
        }
        return out
    }

    /// The JSON object T3 stores for a theme in `t3code:themes:v1` (the canonical definition).
    public static func storedObject(_ theme: ThemeDefinition) -> [String: Any] {
        func colors(_ c: [ThemeColorRole: String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: c.map { ($0.key.rawValue, canonical($0.value) ?? $0.value) })
        }
        var o: [String: Any] = ["id": theme.id, "label": theme.label, "appearance": theme.appearance.rawValue, "colors": colors(theme.colors)]
        if !theme.variants.isEmpty {
            o["variants"] = Dictionary(uniqueKeysWithValues: theme.variants.map { ($0.key.rawValue, colors($0.value)) })
        }
        if let c = theme.collection { o["collection"] = ["id": c.id, "label": c.label] }
        if theme.managed { o["managed"] = true }
        return o
    }
}
