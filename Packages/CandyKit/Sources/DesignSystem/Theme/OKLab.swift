import AppKit

/// CSS `oklch()` colors and `color-mix(in oklab, ...)`, for colors T3 builds at runtime from a per-kind
/// accent (ContextChip.tsx) that the token extraction never sees.
public enum OKLab {
    /// `oklch(l c h / alpha)` as an extended sRGB color.
    public static func oklch(_ l: CGFloat, _ c: CGFloat, _ h: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let rad = h * .pi / 180
        return color(fromLab: (l, c * cos(rad), c * sin(rad)), alpha: alpha)
    }

    /// `color-mix(in oklab, a p, b)` with premultiplied alpha, resolved per appearance.
    public static func mix(_ a: NSColor, _ p: CGFloat, _ b: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                let (la, aa) = lab(a), (lb, ab) = lab(b)
                let alpha = aa * p + ab * (1 - p)
                guard alpha > 0 else { return }
                func channel(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x * aa * p + y * ab * (1 - p)) / alpha }
                result = color(fromLab: (channel(la.0, lb.0), channel(la.1, lb.1), channel(la.2, lb.2)), alpha: alpha)
            }
            return result
        }
    }

    static func lab(_ color: NSColor) -> ((CGFloat, CGFloat, CGFloat), CGFloat) {
        let c = color.usingColorSpace(.extendedSRGB) ?? color
        func linear(_ v: CGFloat) -> CGFloat {
            let s: CGFloat = v < 0 ? -1 : 1, x = abs(v)
            return s * (x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
        }
        let r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return ((0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s), c.alphaComponent)
    }

    static func color(fromLab lab: (CGFloat, CGFloat, CGFloat), alpha: CGFloat) -> NSColor {
        let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
        let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
        let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
        func gamma(_ v: CGFloat) -> CGFloat {
            let sign: CGFloat = v < 0 ? -1 : 1, x = abs(v)
            return sign * (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        return NSColor(colorSpace: .extendedSRGB, components: [
            gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha], count: 4)
    }
}
