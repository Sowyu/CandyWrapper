import AppKit

/// Redesign's generated avatars (the user, 2026-11-21: "i like c4", avatar-mockups-2026-11-21/round2/gen-C4.png): a
/// hand-drawn 8 x 8 sprite in the light ink, centered on a quiet two-ink ordered dither of the same hue, with a clear
/// one-cell halo around the sprite. A stable seed picks the sprite, the hue and the ground's gradient, so a project or
/// an account looks the same on every machine. Each image is drawn once per seed, size, scale and appearance and kept
/// in an `NSCache`.
public enum PixelSprites {
    /// The sprites, rows top first, the top row in the high byte and each row's left cell in its high bit. Original
    /// designs in a classic 8-bit spirit, ported from the mockup's `handSprites`.
    public nonisolated static let masks: [UInt64] = [
        0x81427EDBFF5A8100, // antenna bug
        0x3C7EDBFF245AA500, // jelly
        0x81BDDBFF7E428100, // crab
        0x3C7E9999FFFFA500, // ghost
        0x187E5A7E427E2466, // robot
        0x81C3FFBDFFE77E00, // cat
        0x7EFF9999E77E5A00, // skull
        0x183C243C7EFFA524, // rocket
        0x3C183C7EDFFBFF7E, // potion
        0x3C66FFBD003C243C, // mushroom
        0x66FFFFFF7E3C1800, // heart
        0x609F956000000000, // key
        0x033D7EFF7EBCC000, // planet
        0x18585A7A1E18187E, // cactus
        0xFF81A581BDFF0000, // cassette
        0xFEB9B981BDBDFF00, // floppy
        0x183C7EDBFF245AA5, // squid
        0x24187EDBFF244281, // tall bug
        0x66A5FFBDFF7EA500, // frog
        0xC3FF9999E77E6624, // owl
        0x183C7E3C7EFF183C, // tree
        0x42247EDBFFBD2442, // beetle
        0x99BDFFDBFF000000, // crown
        0x7E81A581A5997E00, // smiley
        0x3C5AFF7E3C180000, // gem
        0x183C7E7E7EFF1800, // bell
        0x0C18307E0C183000, // bolt
        0x3C70E0E0E0703C00, // moon
        0x183C7EFF66667E00, // house
        0x1EBFFBBF1E000000, // fish
        0x3C7EFF99DB7E3C18, // alien
        0x247E667E24185838, // flower
        0x3C7EFF1010140800, // umbrella
        0x183CFFA5FF428100, // ufo
        0x385CFE7E7C280000, // chick
        0x7EBD1ABD66000000, // controller
    ]

    /// Ten OKLCH hues 30 degrees apart, skipping 75 to 115, which turns mustard at these lightnesses.
    public nonisolated static let hues: [Double] = [25, 55, 140, 165, 195, 225, 255, 285, 315, 345]

    /// What a seed draws: indexes into `masks` and `hues`.
    public struct Pick: Hashable, Sendable {
        public let sprite: Int
        public let hue: Int
    }

    /// The seed's sprite and hue. Anti-twin rule: a sprite only takes hues of its own parity, so two seeds that land
    /// on the same sprite get the same hue or one at least two steps away, never a neighbour that reads as a twin.
    /// The ten hues wrap evenly, so 345 and 25 are neighbours of opposite parity too.
    public nonisolated static func pick(_ seed: String) -> Pick {
        let sprite = Int(mix(fnv1a("sprite:" + seed)) % UInt32(masks.count))
        let hue = 2 * Int(mix(fnv1a(seed)) % UInt32(hues.count / 2)) + (sprite & 1)
        return Pick(sprite: sprite, hue: hue)
    }

    /// The seed for a project title: the same normalization `ProjectMonogramView.identity` uses, lowercased.
    public nonisolated static func seed(title: String) -> String {
        let s = title.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty ? "project" : s
    }

    /// Whether the cell at column `x`, row `y` of `mask` is on. Cells outside the 8 x 8 grid are off.
    public nonisolated static func cell(_ mask: UInt64, _ x: Int, _ y: Int) -> Bool {
        guard (0..<8).contains(x), (0..<8).contains(y) else { return false }
        return mask >> UInt64(63 - (y * 8 + x)) & 1 == 1
    }

    // MARK: Hash

    /// 32-bit FNV-1a over UTF-8.
    nonisolated static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
        return h
    }

    /// MurmurHash3's finalizer, so nearby FNV values spread over the whole range.
    nonisolated static func mix(_ x: UInt32) -> UInt32 {
        var h = x
        h ^= h >> 16; h = h &* 0x85ebca6b; h ^= h >> 13; h = h &* 0xc2b2ae35; h ^= h >> 16
        return h
    }

    // MARK: Colors

    /// The three inks for hue `h`, gamma-encoded sRGB. The ground is two quiet inks so the sprite keeps its contrast.
    nonisolated static func inks(_ h: Double, dark: Bool, grey: Bool) -> (ground: SIMD3<Double>, dots: SIMD3<Double>, sprite: SIMD3<Double>) {
        let k = grey ? 0.0 : 1.0
        return dark
            ? (OKLCH.srgb(oklch: 0.25, 0.04 * k, h), OKLCH.srgb(oklch: 0.40, 0.09 * k, h), OKLCH.srgb(oklch: 0.88, 0.09 * k, h))
            : (OKLCH.srgb(oklch: 0.94, 0.03 * k, h), OKLCH.srgb(oklch: 0.84, 0.07 * k, h), OKLCH.srgb(oklch: 0.42, 0.13 * k, h))
    }

    /// How much of its gradient the ground's dots may cover at `points`: none below 20pt, where only a ring of part
    /// cells is left around the halo and reads as speckle; less in light, where the dots are darker than the ground.
    nonisolated static func coverage(points: CGFloat, dark: Bool) -> Double {
        points < 20 ? 0 : dark ? 0.85 : 0.6
    }

    // MARK: Drawing

    /// The ground's gradient for a seed: linear in one of eight directions, or radial from a corner, 0...1.
    nonisolated static func field(_ seed: String) -> (Double, Double) -> Double {
        var s = fnv1a("grad:" + seed)
        if s == 0 { s = 1 }
        func next() -> Double { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Double(s) / 4294967296 }
        func int(_ n: Int) -> Int { min(Int(next() * Double(n)), n - 1) }
        let radial = next() < 0.4
        let dir = Double(int(8)) * .pi / 4
        let corner = int(4)
        let (dx, dy) = (cos(dir), sin(dir))
        return { u, v in
            let t: Double
            if radial {
                let cx: Double = corner % 2 == 0 ? 0 : 1, cy: Double = corner < 2 ? 0 : 1
                t = 1 - hypot(u - cx, v - cy) / 1.25
            } else {
                t = ((u - 0.5) * dx + (v - 0.5) * dy) / 0.75 + 0.5
            }
            return min(max(t, 0), 1)
        }
    }

    /// The 4 x 4 Bayer threshold the mockup used, in 0..<1.
    nonisolated static func bayer4(_ x: Int, _ y: Int) -> Double {
        let m = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        return (Double(m[(y & 3) * 4 + (x & 3)]) + 0.5) / 16
    }

    /// The avatar as a `px` square bitmap, row 0 at the top: the rounded tile in the ground ink, the dots outside the
    /// halo, the sprite on whole cells of `floor(px / 10)` pixels, so the 8 cells and a cell of margin each side fit.
    /// `points` is the size on screen, which picks the ground's coverage and the corner.
    public static func render(seed: String, points: CGFloat, px: Int, dark: Bool, grey: Bool = false) -> CGImage? {
        let p = pick(seed), mask = masks[p.sprite]
        let ink = inks(hues[p.hue], dark: dark, grey: grey)
        let S = CGFloat(px)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip so y runs down, like the grid.
        ctx.translateBy(x: 0, y: S)
        ctx.scaleBy(x: 1, y: -1)
        func color(_ c: SIMD3<Double>) -> CGColor { CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }
        var minX = 8, maxX = -1, minY = 8, maxY = -1
        for y in 0..<8 { for x in 0..<8 where cell(mask, x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        let c = max(1, floor(S / 10))
        let ox = ((S - CGFloat(maxX - minX + 1) * c) / 2).rounded(.down) - CGFloat(minX) * c
        let oy = ((S - CGFloat(maxY - minY + 1) * c) / 2).rounded(.down) - CGFloat(minY) * c
        // The nested control corner at 28pt, in proportion at other sizes, on whole pixels.
        let radius = (S * RedesignTokens.Radius.control / 28).rounded()
        ctx.addPath(SmoothCorners.path(CGRect(x: 0, y: 0, width: S, height: S), radius, flipped: true))
        ctx.clip()
        ctx.setFillColor(color(ink.ground))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        let cover = coverage(points: points, dark: dark)
        if cover > 0 {
            let f = field(seed)
            ctx.setFillColor(color(ink.dots))
            let i0 = -Int(ceil(ox / c)) - 1, j0 = -Int(ceil(oy / c)) - 1, n = Int(ceil(S / c)) + 2
            for j in j0..<(j0 + n) { for i in i0..<(i0 + n) {
                var halo = false
                for dj in -1...1 { for di in -1...1 where cell(mask, i + di, j + dj) { halo = true } }
                if halo { continue }
                let x = ox + CGFloat(i) * c, y = oy + CGFloat(j) * c
                if f(Double((x + c / 2) / S), Double((y + c / 2) / S)) * cover > bayer4(i + 64, j + 64) {
                    ctx.fill(CGRect(x: x, y: y, width: c, height: c))
                }
            }}
        }
        ctx.setFillColor(color(ink.sprite))
        for y in 0..<8 { for x in 0..<8 where cell(mask, x, y) {
            ctx.fill(CGRect(x: ox + CGFloat(x) * c, y: oy + CGFloat(y) * c, width: c, height: c))
        }}
        return ctx.makeImage()
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 512
        return cache
    }()

    /// `render`, cached per seed, size, pixel size and appearance.
    public static func image(seed: String, points: CGFloat, px: Int, dark: Bool, grey: Bool = false) -> CGImage? {
        let key = "\(seed)\u{1}\(points)\u{1}\(px)\u{1}\(dark)\u{1}\(grey)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = render(seed: seed, points: points, px: px, dark: dark, grey: grey) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Draws the avatar into `rect` of a flipped context, on whole device pixels at the context's scale. `points` is
    /// the avatar's size on screen when the context scales a fixed-size drawing (the 16-unit favicon at 14pt).
    public static func draw(seed: String, in rect: CGRect, points: CGFloat? = nil, dark: Bool, grey: Bool = false, ctx: CGContext) {
        let t = ctx.userSpaceToDeviceSpaceTransform
        let px = max(1, Int((rect.width * (t.a * t.a + t.b * t.b).squareRoot()).rounded()))
        let size = points ?? rect.width
        guard let image = image(seed: seed, points: size, px: px, dark: dark, grey: grey) else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
