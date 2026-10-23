import CoreGraphics
import Foundation

// The Orchestrator's bots (docs/orchestrator.md, "The bots"): Grok Bot's flat shapes and capsule eyes, redrawn here, and
// omabot's eye logic (github.com/njpatel/omabot, Apache-2.0): the eyes are printed on the face and turn with the head,
// and the head turns less instead of the eyes sliding off the edge.
//
// Each bot is a real 3D solid in one flat colour: the 2D outline inflated into a cushion of slices that shrink toward
// the front and back, turned by the gaze's yaw and pitch, projected straight on, and filled as the union of the slices.
// The eyes sit on the face, a smooth dome as deep as the cushion, so they curve and thin as they turn away. All units
// are fractions of the bot's radius.

public enum BotShape: Int, CaseIterable, Sendable, Codable {
    case circle, cloud, tile, star, clover, heart, flower, drop, bean, triangle, chunk, splat, hexagon, pumpkin

    public var name: String {
        switch self {
        case .circle: "Circle"
        case .cloud: "Cloud"
        case .tile: "Tilted tile"
        case .star: "Four-point star"
        case .clover: "Clover"
        case .heart: "Heart blob"
        case .flower: "Flower"
        case .drop: "Drop"
        case .bean: "Bean"
        case .triangle: "Rounded triangle"
        case .chunk: "Chunk"
        case .splat: "Splat"
        case .hexagon: "Hexagon"
        case .pumpkin: "Pumpkin"
        }
    }

    /// The cushion's half depth: a ball for the circle, flatter for the thin shapes.
    var thickness: Double {
        switch self {
        case .circle: 1.0
        case .cloud: 0.75
        case .tile: 0.65
        case .star: 0.5
        case .clover: 0.6
        case .heart: 0.7
        case .flower: 0.6
        case .drop: 0.8
        case .bean: 0.75
        case .triangle: 0.65
        case .chunk: 0.8
        case .splat: 0.55
        case .hexagon: 0.7
        case .pumpkin: 0.85
        }
    }

    /// Where the eyes sit: their centre's height and half the distance between them.
    var eyeCenterY: Double {
        switch self {
        case .drop: -0.22
        case .triangle: -0.24
        case .heart: 0.06
        case .pumpkin, .bean: -0.04
        default: 0.02
        }
    }

    var eyeSpread: Double {
        switch self {
        case .star: 0.15
        case .triangle, .drop: 0.2
        default: 0.27
        }
    }
}

/// Grok Bot's eleven picker colours.
public enum BotColor: Int, CaseIterable, Sendable, Codable {
    case white, brown, red, orange, amber, green, teal, blue, violet, pink, grey

    /// sRGB, 0...1.
    public var rgb: (r: Double, g: Double, b: Double) {
        func hex(_ v: UInt32) -> (Double, Double, Double) {
            (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        }
        return switch self {
        case .white: hex(0xF1F1EF)
        case .brown: hex(0xA77250)
        case .red: hex(0xF2554B)
        case .orange: hex(0xFF8A3A)
        case .amber: hex(0xFFC53D)
        case .green: hex(0x5BCB6B)
        case .teal: hex(0x37C6B3)
        case .blue: hex(0x4A9BFF)
        case .violet: hex(0x9C7BFF)
        case .pink: hex(0xFF7EB8)
        case .grey: hex(0x9EA3A8)
        }
    }
}

/// Which bot a thread or the Orchestrator wears.
public struct BotIdentity: Hashable, Sendable, Codable {
    public var shape: BotShape
    public var color: BotColor

    public init(shape: BotShape, color: BotColor) {
        self.shape = shape
        // The pumpkin is always orange.
        self.color = shape == .pumpkin ? .orange : color
    }

    /// A stable bot for a thread: the same id always gets the same shape and colour.
    // ponytail: a hash, so two threads can share a bot; hand out the next free pair when bots get profiles (phase 2)
    public static func forThread(_ id: String) -> BotIdentity {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        let shape = BotShape.allCases[Int(h % UInt64(BotShape.allCases.count))]
        let color = BotColor.allCases[Int((h / 97) % UInt64(BotColor.allCases.count))]
        return BotIdentity(shape: shape, color: color)
    }

    public static let orchestrator = BotIdentity(shape: .flower, color: .violet)
}

/// Where a bot looks: yaw turns it right, pitch turns it up, in radians.
public struct BotGaze: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public init(yaw: Double, pitch: Double) { self.yaw = yaw; self.pitch = pitch }
    public static let front = BotGaze(yaw: 0, pitch: 0)
    var magnitude: Double { (yaw * yaw + pitch * pitch).squareRoot() }
}

public enum BotGeometry {
    typealias P = SIMD2<Double>
    typealias P3 = SIMD3<Double>

    static let outlinePoints = 64
    static let sliceCount = 14
    static let eyePoints = 16
    /// The rounding stroke's width, which also widens the visible edge by half of it.
    public static let strokeWidth = 0.14
    /// Every projected eye point keeps this far inside the visible edge.
    public static let eyeMargin = 0.09
    /// The capsule eye: a quarter of the radius wide, twice that tall.
    static let eyeWidth = 0.25, eyeHeight = 0.5
    /// How far any bot may turn, and the share of a shape's own limit the gaze uses.
    public static let maxTurn = 0.9
    static let clampShare = 0.94
    static let directions = 32

    // MARK: Outlines

    /// The shape's outline, counterclockwise, scaled so its farthest point sits at radius 1 and centred on its box.
    static func outline(_ shape: BotShape) -> [P] {
        if let cached = outlineCache.withLock({ $0[shape] }) { return cached }
        let n = outlinePoints
        var pts: [P] = (0..<n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi
            return raw(shape, t)
        }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let c = P((minX + maxX) / 2, (minY + maxY) / 2)
        pts = pts.map { $0 - c }
        let r = pts.map { ($0 * $0).sum().squareRoot() }.max()!
        pts = pts.map { $0 / r }
        outlineCache.withLock { $0[shape] = pts }
        return pts
    }

    private static let outlineCache = BotLocked<[BotShape: [P]]>([:])

    /// One outline point at parameter `t` (0..<2π), before centring and scaling.
    static func raw(_ shape: BotShape, _ t: Double) -> P {
        func polar(_ r: Double, _ a: Double = t) -> P { P(cos(a) * r, sin(a) * r) }
        switch shape {
        case .circle:
            return polar(1)
        case .cloud:
            // Five round bumps over a flat base.
            var r = 0.8 + 0.2 * (0.5 + 0.5 * cos(5 * (t - .pi / 2))).squareRoot()
            if sin(t) < -0.45 { r = min(r, 0.72 / -sin(t)) }
            return polar(r)
        case .tile:
            let a = t - 0.21
            let r = pow(pow(abs(cos(a)), 4) + pow(abs(sin(a)), 4), -0.25)
            return polar(r)
        case .star:
            return polar(0.46 + 0.54 * pow(abs(cos(2 * t)), 3))
        case .clover:
            return polar(0.6 + 0.4 * pow(abs(sin(2 * t)), 0.55))
        case .heart:
            // The classic heart curve, softened toward a circle so it reads as a blob.
            let x = 16 * pow(sin(t), 3) / 16
            let y = (13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)) / 16
            let heart = P(x, y)
            let circle = P(sin(t), cos(t)) * 0.95
            return heart * 0.68 + circle * 0.32
        case .flower:
            return polar(0.7 + 0.3 * pow(abs(cos(3 * t)), 0.6))
        case .drop:
            // Point up: the classic drop curve along +x, turned a quarter.
            let x = cos(t), y = sin(t) * pow(sin(t / 2), 1.3)
            let p = P(x, y * 0.95)
            return P(-p.y, p.x)
        case .bean:
            var p = P(cos(t), 0.7 * sin(t))
            p.y -= 0.24 * max(0, sin(t)) * exp(-cos(t) * cos(t) / 0.14)
            let a = -0.26
            return P(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
        case .triangle:
            let sector = 2 * Double.pi / 3
            var a = (t - .pi / 2).truncatingRemainder(dividingBy: sector)
            if a < 0 { a += sector }
            let r = cos(.pi / 3) / cos(a - .pi / 3)
            return polar(pow(r, 0.8))
        case .chunk:
            let radii: [Double] = [1, 0.86, 0.95, 0.79, 0.93, 0.83, 0.97]
            let f = t / (2 * .pi) * Double(radii.count)
            let i = Int(f) % radii.count, j = (i + 1) % radii.count
            let u = f - floor(f), s = (1 - cos(u * .pi)) / 2
            return polar(radii[i] * (1 - s) + radii[j] * s)
        case .splat:
            let lobes = pow(0.5 + 0.5 * cos(9 * t), 2)
            return polar(0.7 + 0.3 * lobes * (0.72 + 0.28 * sin(2 * t + 1)))
        case .hexagon:
            let sector = Double.pi / 3
            var a = t.truncatingRemainder(dividingBy: sector)
            if a < 0 { a += sector }
            return polar(cos(.pi / 6) / cos(a - .pi / 6))
        case .pumpkin:
            let ribs = 0.94 + 0.06 * pow(cos(4 * t), 2)
            return P(cos(t) * ribs, 0.8 * sin(t) * ribs)
        }
    }

    /// The outline's radius in direction `a`, by casting a ray from the centre.
    static func radius(_ shape: BotShape, at a: Double) -> Double {
        let pts = outline(shape)
        let d = P(cos(a), sin(a))
        var best = 0.0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let e = q - p
            let den = d.x * e.y - d.y * e.x
            guard abs(den) > 1e-12 else { continue }
            let s = (p.x * e.y - p.y * e.x) / den
            let u = (p.x * d.y - p.y * d.x) / den
            if s > 0, u >= -1e-9, u <= 1 + 1e-9 { best = max(best, s) }
        }
        return best
    }

    // MARK: The solid

    /// The slices: depth and scale, front to back. The profile is a half ellipse, so the circle becomes a ball.
    static func slices(_ shape: BotShape) -> [(z: Double, s: Double)] {
        (0..<sliceCount).map { k in
            let phi = Double.pi * (Double(k) + 0.5) / Double(sliceCount)
            return (shape.thickness * cos(phi), sin(phi))
        }
    }

    static func rotate(_ p: P3, _ g: BotGaze) -> P3 {
        let cy = cos(g.yaw), sy = sin(g.yaw), cp = cos(g.pitch), sp = sin(g.pitch)
        let x = p.x * cy + p.z * sy
        let z1 = -p.x * sy + p.z * cy
        let y = p.y * cp + z1 * sp
        let z = -p.y * sp + z1 * cp
        return P3(x, y, z)
    }

    /// The projected slices, each a closed polygon.
    static func projectedSlices(_ shape: BotShape, _ g: BotGaze) -> [[P]] {
        let pts = outline(shape)
        return slices(shape).map { slice in
            pts.map { p in
                let r = rotate(P3(p.x * slice.s, p.y * slice.s, slice.z), g)
                return P(r.x, r.y)
            }
        }
    }

    /// The face: a point of the front plane lifted onto the dome.
    static func lift(_ shape: BotShape, _ p: P) -> P3 {
        let len = (p * p).sum().squareRoot()
        let edge = len < 1e-9 ? 1 : radius(shape, at: atan2(p.y, p.x))
        let rho = min(1, len / max(edge, 1e-9))
        return P3(p.x, p.y, shape.thickness * max(0, 1 - rho * rho).squareRoot())
    }

    /// The two capsule outlines on the front plane, counterclockwise.
    static func eyeOutlines(_ shape: BotShape) -> [[P]] {
        let w = eyeWidth, h = eyeHeight, r = w / 2, half = eyePoints / 2
        return [-1.0, 1.0].map { side in
            let c = P(side * shape.eyeSpread, shape.eyeCenterY)
            var pts: [P] = []
            // The top cap, then the bottom cap; the straight sides join them.
            for i in 0..<half {
                let a = Double.pi * Double(i) / Double(half - 1)
                pts.append(c + P(cos(a) * r, h / 2 - r + sin(a) * r))
            }
            for i in 0..<half {
                let a = Double.pi + Double.pi * Double(i) / Double(half - 1)
                pts.append(c + P(cos(a) * r, -h / 2 + r + sin(a) * r))
            }
            return pts
        }
    }

    /// The eyes lifted onto the face and turned with the body: per eye, each point's projection and whether the face
    /// there still looks toward the viewer.
    static func projectedEyes(_ shape: BotShape, _ g: BotGaze) -> [[(p: P, facing: Bool)]] {
        eyeOutlines(shape).map { eye in
            eye.map { q in
                let a = lift(shape, q)
                // The face's normal from two nearby points on the dome.
                let e = 0.01
                let dx = lift(shape, q + P(e, 0)) - a, dy = lift(shape, q + P(0, e)) - a
                let n = rotate(P3(dx.y * dy.z - dx.z * dy.y, dx.z * dy.x - dx.x * dy.z, dx.x * dy.y - dx.y * dy.x), g)
                let len = (n * n).sum().squareRoot()
                let r = rotate(a, g)
                return (P(r.x, r.y), len > 0 && n.z / len > 0.2)
            }
        }
    }

    // MARK: Keeping the eyes off the edge

    /// How far `p` lies inside the polygon's boundary; negative outside.
    static func insideDistance(_ p: P, _ poly: [P]) -> Double {
        var inside = false
        var best = Double.infinity
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[j], b = poly[i]
            if (b.y > p.y) != (a.y > p.y), p.x < (a.x - b.x) * (p.y - b.y) / (a.y - b.y) + b.x { inside.toggle() }
            let e = a - b, w = p - b
            let u = max(0, min(1, (w * e).sum() / max((e * e).sum(), 1e-12)))
            let d = w - e * u
            best = min(best, (d * d).sum())
            j = i
        }
        return inside ? best.squareRoot() : -best.squareRoot()
    }

    /// Whether every eye point keeps the margin from the visible edge and sits on the part of the face toward you.
    /// The union of slices contains each slice, so the deepest slice gives a safe lower bound on the distance.
    static func eyesClear(_ shape: BotShape, _ g: BotGaze) -> Bool {
        let body = projectedSlices(shape, g)
        let need = eyeMargin - strokeWidth / 2
        // The middle slices are the widest; try them first.
        let order = body.indices.sorted { abs($0 - sliceCount / 2) < abs($1 - sliceCount / 2) }
        for eye in projectedEyes(shape, g) {
            for point in eye {
                guard point.facing else { return false }
                var clear = false
                for k in order where insideDistance(point.p, body[k]) >= need { clear = true; break }
                if !clear { return false }
            }
        }
        return true
    }

    /// How far each shape may turn in each of `directions` directions (direction 0 turns right, counterclockwise),
    /// worked out once per shape by walking out from facing front to the first pose that fails.
    public static func turnLimits(_ shape: BotShape) -> [Double] {
        if let cached = limitCache.withLock({ $0[shape] }) { return cached }
        let limits = (0..<directions).map { j -> Double in
            let phi = 2 * Double.pi * Double(j) / Double(directions)
            let d = (cos(phi), sin(phi))
            func ok(_ m: Double) -> Bool { eyesClear(shape, BotGaze(yaw: d.0 * m, pitch: d.1 * m)) }
            guard ok(0) else { return 0 }
            let step = 0.05
            var pass = 0.0
            var fail: Double?
            var m = step
            while m <= maxTurn + 1e-9 {
                if ok(m) { pass = m } else { fail = m; break }
                m += step
            }
            guard var hi = fail else { return maxTurn }
            var lo = pass
            for _ in 0..<5 {
                let mid = (lo + hi) / 2
                if ok(mid) { lo = mid } else { hi = mid }
            }
            return lo
        }
        limitCache.withLock { $0[shape] = limits }
        return limits
    }

    private static let limitCache = BotLocked<[BotShape: [Double]]>([:])

    /// The gaze the shape can take without its eyes nearing the edge: the asked direction, at most 94% of the
    /// tighter of the two nearest worked-out limits.
    public static func clamp(_ g: BotGaze, for shape: BotShape) -> BotGaze {
        let m = g.magnitude
        guard m > 1e-9 else { return g }
        let limits = turnLimits(shape)
        var phi = atan2(g.pitch, g.yaw)
        if phi < 0 { phi += 2 * .pi }
        let f = phi / (2 * .pi) * Double(directions)
        let i = Int(f) % directions, j = (i + 1) % directions
        let limit = min(limits[i], limits[j]) * clampShare
        guard m > limit else { return g }
        return BotGaze(yaw: g.yaw / m * limit, pitch: g.pitch / m * limit)
    }

    // MARK: Paths

    /// The pumpkin's stem, a short rounded post on top of the head.
    static func stem(_ g: BotGaze) -> [P] {
        let base = P3(0.02, 0.74, 0.1), top = P3(0.1, 1.02, 0.1)
        let w = 0.09
        let pts = [base + P3(-w, 0, 0), top + P3(-w * 0.8, 0, 0), top + P3(w * 0.8, 0, 0), base + P3(w, 0, 0)]
        return pts.map { let r = rotate($0, g); return P(r.x, r.y) }
    }

    /// The body, eye and stem paths for a pose, in a square of side `size` with y up from its bottom left.
    public static func paths(_ identity: BotIdentity, gaze: BotGaze, size: CGFloat) -> (body: CGPath, eyes: CGPath, stem: CGPath?) {
        let g = clamp(gaze, for: identity.shape)
        // The body's radius leaves room for the rounding stroke inside the square.
        let radius = Double(size) / 2 / (1 + strokeWidth / 2 + (identity.shape == .pumpkin ? 0.08 : 0))
        let cx = Double(size) / 2, cy = Double(size) / 2 - (identity.shape == .pumpkin ? radius * 0.08 : 0)
        func pt(_ p: P) -> CGPoint { CGPoint(x: cx + p.x * radius, y: cy + p.y * radius) }
        let body = CGMutablePath()
        for poly in projectedSlices(identity.shape, g) {
            body.addLines(between: poly.map(pt))
            body.closeSubpath()
        }
        let eyes = CGMutablePath()
        for eye in projectedEyes(identity.shape, g) {
            eyes.addLines(between: eye.map { pt($0.p) })
            eyes.closeSubpath()
        }
        var stemPath: CGPath?
        if identity.shape == .pumpkin {
            let s = CGMutablePath()
            s.addLines(between: stem(g).map(pt))
            s.closeSubpath()
            stemPath = s
        }
        return (body, eyes, stemPath)
    }

    /// The rounding stroke's width for a bot drawn at `size`.
    public static func lineWidth(_ identity: BotIdentity, size: CGFloat) -> CGFloat {
        size / 2 / (1 + strokeWidth / 2 + (identity.shape == .pumpkin ? 0.08 : 0)) * strokeWidth
    }
}

/// A small lock around a value, for the shape caches that tests read from several threads.
final class BotLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
