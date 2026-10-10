import AppKit

/// T3's `surface-grain`: an SVG `feTurbulence` tile (fractalNoise, baseFrequency 0.9, 4 octaves,
/// stitchTiles, seed 0) under a rect at opacity 0.035, repeated every 256px (index.css:1677-1680).
/// We run the SVG spec's reference turbulence once, at 2x, into a static tile. No animation.
/// Spec: docs/research/E-design-tokens.md 1.15.
@MainActor
public enum SurfaceGrain {
    public static let tilePoints: CGFloat = 256
    public static let opacity: Double = 0.035

    /// Unpremultiplied noise RGBA as sRGB bytes, 512x512 for a 256pt tile at 2x.
    // ponytail: computed at 2x only; 1x screens downsample it, render a 256px tile if 1x displays matter
    public static let tile: CGImage = makeTile(pixels: 512, scale: 2)

    /// The pattern color for `draw(_:)`: the tile at 256pt with its 2x pixels.
    public static let pattern: NSColor = {
        let image = NSImage(size: NSSize(width: tilePoints, height: tilePoints))
        let rep = NSBitmapImageRep(cgImage: tile)
        rep.size = image.size
        image.addRepresentation(rep)
        return NSColor(patternImage: image)
    }()

    static func makeTile(pixels: Int, scale: Double) -> CGImage {
        let noise = Turbulence(seed: 0)
        // The filter region is the default -10%/120% box around the 256-unit rect, and stitching uses it.
        let tile = (x: -25.6, y: -25.6, w: 307.2, h: 307.2)
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        for py in 0..<pixels {
            for px in 0..<pixels {
                let p = ((Double(px) + 0.5) / scale, (Double(py) + 0.5) / scale)
                var c = [Double](repeating: 0, count: 4)
                for ch in 0..<4 {
                    let v = noise.turbulence(channel: ch, point: p, baseFrequency: 0.9, octaves: 4, tile: tile)
                    c[ch] = min(1, max(0, (v + 1) / 2))
                }
                // color-interpolation-filters is linearRGB: the noise is linear light, shown as sRGB.
                let a = c[3] * opacity
                let i = (py * pixels + px) * 4
                for ch in 0..<3 { bytes[i + ch] = UInt8((linearToSRGB(c[ch]) * a * 255).rounded()) }
                bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func linearToSRGB(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// The SVG 1.1 reference implementation of feTurbulence (section 15.21), fractal noise with stitching.
struct Turbulence {
    private static let bSize = 0x100, bm = 0xff, perlinN = 0x1000
    private var lattice = [Int](repeating: 0, count: 0x100 + 0x100 + 2)
    private var gradient = [[(Double, Double)]](repeating: [(Double, Double)](repeating: (0, 0), count: 0x100 + 0x100 + 2), count: 4)

    init(seed: Int) {
        let m = 2147483647, a = 16807, q = 127773, r = 2836
        var s = seed
        if s <= 0 { s = -(s % (m - 1)) + 1 }
        if s > m - 1 { s = m - 1 }
        func random(_ x: Int) -> Int { var v = a * (x % q) - r * (x / q); if v <= 0 { v += m }; return v }
        let b = Self.bSize
        for k in 0..<4 {
            for i in 0..<b {
                lattice[i] = i
                s = random(s); let gx = Double((s % (b + b)) - b) / Double(b)
                s = random(s); let gy = Double((s % (b + b)) - b) / Double(b)
                let len = (gx * gx + gy * gy).squareRoot()
                gradient[k][i] = (gx / len, gy / len)
            }
        }
        var i = b - 1
        while i > 0 {
            let k = lattice[i]
            s = random(s)
            let j = s % b
            lattice[i] = lattice[j]
            lattice[j] = k
            i -= 1
        }
        for i in 0..<(b + 2) {
            lattice[b + i] = lattice[i]
            for k in 0..<4 { gradient[k][b + i] = gradient[k][i] }
        }
    }

    private struct Stitch { var width: Int, height: Int, wrapX: Int, wrapY: Int }

    private func noise2(_ ch: Int, _ vx: Double, _ vy: Double, _ stitch: Stitch?) -> Double {
        let n = Double(Self.perlinN), bm = Self.bm
        var t = vx + n
        var bx0 = Int(t) & bm, bx1 = (bx0 + 1) & bm
        let rx0 = t - Double(Int(t)), rx1 = rx0 - 1
        t = vy + n
        var by0 = Int(t) & bm, by1 = (by0 + 1) & bm
        let ry0 = t - Double(Int(t)), ry1 = ry0 - 1
        if let st = stitch {
            if bx0 >= st.wrapX { bx0 -= st.width }
            if bx1 >= st.wrapX { bx1 -= st.width }
            if by0 >= st.wrapY { by0 -= st.height }
            if by1 >= st.wrapY { by1 -= st.height }
        }
        bx0 &= bm; bx1 &= bm; by0 &= bm; by1 &= bm
        let i = lattice[bx0], j = lattice[bx1]
        let b00 = lattice[i + by0], b10 = lattice[j + by0], b01 = lattice[i + by1], b11 = lattice[j + by1]
        func curve(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double { a + t * (b - a) }
        let sx = curve(rx0), sy = curve(ry0)
        let g = gradient[ch]
        var q = g[b00]; var u = rx0 * q.0 + ry0 * q.1
        q = g[b10]; var v = rx1 * q.0 + ry0 * q.1
        let a = lerp(sx, u, v)
        q = g[b01]; u = rx0 * q.0 + ry1 * q.1
        q = g[b11]; v = rx1 * q.0 + ry1 * q.1
        let b = lerp(sx, u, v)
        return lerp(sy, a, b)
    }

    func turbulence(channel: Int, point: (Double, Double), baseFrequency: Double, octaves: Int,
                    tile: (x: Double, y: Double, w: Double, h: Double)) -> Double {
        func adjust(_ f: Double, _ size: Double) -> Double {
            let lo = (size * f).rounded(.down) / size, hi = (size * f).rounded(.up) / size
            return f / lo < hi / f ? lo : hi
        }
        let fx = adjust(baseFrequency, tile.w), fy = adjust(baseFrequency, tile.h)
        let n = Self.perlinN
        var w = Int(tile.w * fx + 0.5), h = Int(tile.h * fy + 0.5)
        var stitch = Stitch(width: w, height: h, wrapX: Int(tile.x * fx + Double(n) + Double(w)),
                            wrapY: Int(tile.y * fy + Double(n) + Double(h)))
        var sum = 0.0, vx = point.0 * fx, vy = point.1 * fy, ratio = 1.0
        for _ in 0..<octaves {
            sum += noise2(channel, vx, vy, stitch) / ratio
            vx *= 2; vy *= 2; ratio *= 2
            w += w; h += h
            stitch = Stitch(width: w, height: h, wrapX: 2 * stitch.wrapX - n, wrapY: 2 * stitch.wrapY - n)
        }
        return sum
    }
}

/// A flat fill plus the grain tile on top: `bg-sidebar surface-grain`, or `bg-background surface-grain`.
/// Layer properties only: the fill is the layer's background and replicator layers repeat one
/// 256pt tile, so the GPU composites the grain and no surface-sized bitmap exists. Drawing it
/// cost a 27 MB backing store per surface at 2x, plus as much again in scratch for the pattern.
public final class GrainSurfaceView: DSView {
    public var fill: NSColor { didSet { needsDisplay = true } }
    public var showsGrain = true { didSet { columns.isHidden = !showsGrain } }
    /// Repeats `rows` across; `rows` repeats `tile` down.
    private let columns = CAReplicatorLayer(), rows = CAReplicatorLayer(), tile = CALayer()

    public init(fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        let size = SurfaceGrain.tilePoints
        tile.contents = SurfaceGrain.tile
        tile.frame = CGRect(x: 0, y: 0, width: size, height: size)
        rows.instanceTransform = CATransform3DMakeTranslation(0, size, 0)
        columns.instanceTransform = CATransform3DMakeTranslation(size, 0, 0)
        rows.addSublayer(tile)
        columns.addSublayer(rows)
        layer?.addSublayer(columns)
    }

    public override func updateLayer() {
        layer?.backgroundColor = resolving { fill.cgColor }
    }

    // ponytail: tiles start at the layer origin, not T3's top left; invisible at 3.5% opacity
    public override func layout() {
        super.layout()
        let size = SurfaceGrain.tilePoints
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        columns.frame = bounds
        rows.frame = CGRect(x: 0, y: 0, width: size, height: bounds.height)
        rows.instanceCount = max(1, Int((bounds.height / size).rounded(.up)))
        columns.instanceCount = max(1, Int((bounds.width / size).rounded(.up)))
        CATransaction.commit()
    }
}
