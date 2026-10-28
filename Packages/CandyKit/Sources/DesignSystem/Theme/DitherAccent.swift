import AppKit

/// The Redesign theme's accent choices (the "Accent color" setting, the user 2026-10-23). Teal is Capy's own
/// `--primary`; the others sit at about the same lightness so the theme keeps its weight.
public struct DitherAccent: Equatable, Sendable {
    public let id: String
    public let label: String
    /// The accent in light and dark.
    public let light: String
    public let dark: String

    public static let teal = DitherAccent(id: "teal", label: "Teal", light: "#0b9f95", dark: "#2b948b")
    public static let all: [DitherAccent] = [
        teal,
        DitherAccent(id: "blue", label: "Blue", light: "#2f6fdb", dark: "#3f7ee0"),
        DitherAccent(id: "violet", label: "Violet", light: "#7552e0", dark: "#8466e6"),
        DitherAccent(id: "pink", label: "Pink", light: "#cf3f86", dark: "#d4558f"),
        DitherAccent(id: "red", label: "Red", light: "#d03a35", dark: "#d4504a"),
        DitherAccent(id: "orange", label: "Orange", light: "#d9632a", dark: "#e0763e"),
        DitherAccent(id: "amber", label: "Amber", light: "#d99a0b", dark: "#e0a82e"),
        DitherAccent(id: "green", label: "Green", light: "#2f9a45", dark: "#46a35a"),
    ]

    public static func named(_ id: String) -> DitherAccent { all.first { $0.id == id } ?? teal }

    init(id: String, label: String, light: String, dark: String) {
        self.id = id; self.label = label; self.light = light; self.dark = dark
    }

    /// Light draws the accent darkened to `lightAccent`, so white labels on it and the focus ring keep AA.
    public func accent(dark: Bool) -> String { dark ? self.dark : Self.lightAccent(light) }

    /// Text on the accent: white while it reads at 3:1 or better (WCAG's floor for bold text and controls), else near black.
    public func foreground(dark: Bool) -> String {
        Self.contrast(Self.luminance(accent(dark: dark)), 1) >= 3 ? "#ffffff" : "#111111"
    }

    /// The accent's roles in a Dither palette: primary, ring, send button and its hover, terminal cursor and selection.
    public func colors(dark: Bool) -> [ThemeColorRole: String] {
        let a = accent(dark: dark), fg = foreground(dark: dark)
        return [.accent: a, .focus: a, .accentForeground: fg, .messageAction: a, .messageActionForeground: fg,
                .messageActionHover: Self.mix(a, black: 0.12), .terminalCursor: a,
                .terminalSelection: Self.mix(a, toward: dark ? "#131314" : "#ffffff", 0.7)]
    }

    public var darkColor: NSColor { Self.color(dark) }

    /// Light's accent: `accent` darkened in its own hue until white on it reads at 4.6:1, which also keeps it 3:1
    /// over the darkest art dot light allows (#d7d7d7, `DitherArt.lightScrim`) for the focus ring. Teal gives #07837a.
    static func lightAccent(_ accent: String) -> String {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let c = rgb(accent)
        var scale = 1.0
        while scale > 0, 1.05 / ((lin(c.0) * 0.2126 + lin(c.1) * 0.7152 + lin(c.2) * 0.0722) * scale + 0.05) < 4.6 { scale -= 0.01 }
        return hex((gamma(lin(c.0) * scale), gamma(lin(c.1) * scale), gamma(lin(c.2) * scale)))
    }

    // MARK: Color math, sRGB

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let v = Int(hex.dropFirst().prefix(6), radix: 16) ?? 0
        return (Double(v >> 16 & 0xff) / 255, Double(v >> 8 & 0xff) / 255, Double(v & 0xff) / 255)
    }

    static func hex(_ c: (Double, Double, Double)) -> String {
        func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.0), b(c.1), b(c.2))
    }

    static func mix(_ a: String, toward b: String, _ t: Double) -> String {
        let x = rgb(a), y = rgb(b)
        return hex((x.0 + (y.0 - x.0) * t, x.1 + (y.1 - x.1) * t, x.2 + (y.2 - x.2) * t))
    }

    public static func mix(_ a: String, white t: Double) -> String { mix(a, toward: "#ffffff", t) }
    static func mix(_ a: String, black t: Double) -> String { mix(a, toward: "#000000", t) }

    static func luminance(_ hex: String) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = rgb(hex)
        return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    public static func color(_ hex: String) -> NSColor {
        let c = rgb(hex)
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}
