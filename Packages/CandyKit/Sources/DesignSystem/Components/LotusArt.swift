import CoreGraphics
import Foundation

/// A lotus drawn in code for the Flower background (the user, 2026-11-21: "a 3d dithered flower that blooms on opening
/// a thread and moves smoothly"). The petals are parametric sheets in six rings, rasterised on the CPU into a small
/// luminance buffer at the dot grid's resolution, then thresholded with the Gradient background's 8 x 8 Bayer matrix
/// on the panel's fixed 3pt grid, so the flower moves under the dots and the dots never move.
///
/// Motion is precomputed: `frames` renders the bloom (bud to open) and a seamless idle loop (a slow turn and a breath)
/// once into one-byte alpha masks, the way `DitherArt.gradientFrames` does, for a discrete keyframe animation to flip.
/// One mask carries both inks: 255 is the ink, `deepAlpha` the ink over the ground at that share.
public enum LotusArt {
    // MARK: Geometry

    /// One ring of petals, outermost first. Angles in degrees; lengths in units of the outer petal.
    struct Ring {
        var count: Int
        var length: Float, halfWidth: Float
        var openElevation: Float, budElevation: Float
        var openCurl: Float, budCurl: Float
        var openCup: Float, budCup: Float
        var baseRadius: Float, baseHeight: Float
        /// Where the ring's first petal sits, in petal slots.
        var offset: Float
    }

    /// The rings, after the reference (lotus-reference.jpg): the outer rings wide and nearly flat, the inner ones
    /// shorter, narrower and more upright, each ring's base higher and further in than the one outside it so it
    /// sits on top, and its petals over the gaps of the ring outside. Within a ring the odd petals sit a little lower
    /// (`alternate`), so neighbours overlap instead of cutting through each other. Eight petals a ring, and jitter
    /// that repeats every two petals, make the flower look the same after `symmetry` radians, so the idle turn loops
    /// without a seam.
    static let rings: [Ring] = [
        Ring(count: 8, length: 1.00, halfWidth: 0.3, openElevation: -10, budElevation: 74, openCurl: 24, budCurl: 40,
             openCup: 0.2, budCup: 0.7, baseRadius: 0.17, baseHeight: 0.00, offset: 0),
        Ring(count: 8, length: 0.90, halfWidth: 0.3, openElevation: 9, budElevation: 77, openCurl: 26, budCurl: 38,
             openCup: 0.24, budCup: 0.7, baseRadius: 0.15, baseHeight: 0.06, offset: 0.5),
        Ring(count: 8, length: 0.78, halfWidth: 0.3, openElevation: 27, budElevation: 80, openCurl: 28, budCurl: 36,
             openCup: 0.3, budCup: 0.7, baseRadius: 0.13, baseHeight: 0.12, offset: 0.25),
        Ring(count: 8, length: 0.65, halfWidth: 0.30, openElevation: 44, budElevation: 83, openCurl: 28, budCurl: 34,
             openCup: 0.38, budCup: 0.7, baseRadius: 0.11, baseHeight: 0.18, offset: 0.75),
        Ring(count: 8, length: 0.53, halfWidth: 0.31, openElevation: 59, budElevation: 86, openCurl: 28, budCurl: 32,
             openCup: 0.44, budCup: 0.7, baseRadius: 0.09, baseHeight: 0.24, offset: 0.125),
        Ring(count: 8, length: 0.42, halfWidth: 0.32, openElevation: 72, budElevation: 88, openCurl: 26, budCurl: 30,
             openCup: 0.5, budCup: 0.7, baseRadius: 0.07, baseHeight: 0.30, offset: 0.625),
    ]

    /// Each petal rolls about its own midrib by this much (degrees, open and bud), its leading edge up, so a bud wraps
    /// like a pinwheel.
    static let openRoll: Float = 4, budRoll: Float = 10

    /// How much lower an odd petal sits than its even neighbours: base height (flower units) and elevation (degrees).
    static let alternate = (height: Float(0.02), elevation: Float(4))

    /// A petal's layer: inner rings over outer ones, even petals over odd ones. Nearer layers win depth ties by
    /// `layerBias` per layer, so where two petals touch the upper one shows whole rather than in slivers.
    static func layer(ring k: Int, index i: Int) -> Int { 2 * k + (i % 2 == 0 ? 1 : 0) }

    /// The angle after which the flower repeats: a quarter turn.
    public static let symmetry = Double.pi / 2

    /// Grid points along a petal and across it.
    static let along = 20, across = 11
    static var trianglesPerPetal: Int { (along - 1) * (across - 1) * 2 }

    /// How long a bud petal is, as a share of its open length.
    static let budLength: Float = 0.86

    /// Ring `k` opens over its own window of `bloom`: the outer ring leads and each ring inside starts `stagger` later.
    static let stagger: Float = 0.08

    /// The opening of ring `k` at `bloom`, 0 (bud) to 1 (open), eased so each ring starts and settles gently.
    static func opening(ring k: Int, bloom: Float) -> Float {
        let span = 1 - stagger * Float(rings.count - 1)
        let t = min(max((bloom - stagger * Float(k)) / span, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A deterministic value in -1...1 for petal `i` of ring `k`, channel `c`. It repeats every quarter of the ring
    /// so the flower keeps its quarter-turn symmetry.
    static func jitter(_ k: Int, _ i: Int, _ c: Int) -> Float {
        let slot = i % max(1, rings[k].count / 4)
        var h = UInt32(truncatingIfNeeded: (k &* 73_856_093) ^ (slot &* 19_349_663) ^ (c &* 83_492_791) ^ 0x9E37_79B9)
        h ^= h >> 16; h = h &* 0x7FEB_352D; h ^= h >> 15; h = h &* 0x846C_A68B; h ^= h >> 16
        return Float(h & 0xFFFF) / 32767.5 - 1
    }

    /// The petals as one mesh: positions and normals in flower space (y up, the receptacle at the origin), per-vertex
    /// `shade` (ambient occlusion and the midrib crease, multiplied) and `edge` (light added toward the rim, a cue
    /// for a thick rounded edge), `indices` three per triangle, `trianglesPerPetal` triangles per petal in order.
    struct Mesh {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var shade: [Float] = []
        var edge: [Float] = []
        /// How far in the vertex's ring is, 0 outer to 1 innermost.
        var glow: [Float] = []
        var indices: [UInt32] = []
        /// Each petal's layer, in petal order.
        var layer: [Int] = []
        var triangles: Int { indices.count / 3 }
    }

    /// The flower at `bloom` (0 bud, 1 open), `breath` (0 rest, 1 a few degrees closed). Deterministic.
    static func mesh(bloom: Double, breath: Double = 0) -> Mesh {
        var m = Mesh()
        let perPetal = along * across
        let total = rings.reduce(0) { $0 + $1.count }
        m.positions.reserveCapacity(total * perPetal)
        m.normals.reserveCapacity(total * perPetal)
        m.shade.reserveCapacity(total * perPetal)
        m.edge.reserveCapacity(total * perPetal)
        m.glow.reserveCapacity(total * perPetal)
        m.indices.reserveCapacity(total * trianglesPerPetal * 3)
        let b = Float(min(max(bloom, 0), 1)), br = Float(breath)
        for (k, ring) in rings.enumerated() {
            let o = opening(ring: k, bloom: b)
            for i in 0..<ring.count {
                petal(ring: ring, k: k, index: i, open: o, breath: br, into: &m)
                m.layer.append(layer(ring: k, index: i))
            }
        }
        pod(open: opening(ring: rings.count - 1, bloom: b), into: &m)
        m.layer.append(0)
        receptacle(open: opening(ring: 0, bloom: b), into: &m)
        m.layer.append(-1)
        return m
    }

    static let podRadius: Float = 0.22, podHeight: Float = 0.26
    /// The receptacle: a low, shaded saucer under the petals' bases. Between the inner petals, and between rings
    /// while they open, the eye saw straight through to the ground, a hole near the centre on a light ground.
    static let receptacleRadius: Float = 0.5, receptacleHeight: Float = 0.08

    static func receptacle(open o: Float, into m: inout Mesh) {
        let first = m.positions.count
        let radius = receptacleRadius * (0.4 + 0.6 * o)
        for s in 0..<along {
            let rho = 1 - Float(s) / Float(along - 1)
            for c in 0..<across {
                let phi = 2 * Float.pi * Float(c) / Float(across - 1)
                m.positions.append(SIMD3(cos(phi) * rho * radius, receptacleHeight * (1 - rho * rho), sin(phi) * rho * radius))
                let slope = receptacleHeight * 2 * rho / radius
                m.normals.append(normalize(SIMD3(cos(phi) * slope, 1, sin(phi) * slope)))
                m.shade.append(0.35)
                m.edge.append(0)
                m.glow.append(0.4)
            }
        }
        let f = UInt32(first)
        for s in 0..<(along - 1) {
            for c in 0..<(across - 1) {
                let i0 = f + UInt32(s * across + c), i1 = i0 + 1, i2 = i0 + UInt32(across), i3 = i2 + 1
                m.indices += [i0, i2, i1, i1, i2, i3]
            }
        }
    }

    /// The seed pod: a low dome where the petals meet, on the petals' grid so it counts as one more petal. It fills
    /// the gaps between the inner petals' bases, which show as holes on a light ground.
    static func pod(open o: Float, into m: inout Mesh) {
        let first = m.positions.count
        // Inside a bud the pod is small, so it never shows below the closed petals.
        let radius = podRadius * (0.35 + 0.65 * o), height = podHeight * (0.6 + 0.4 * o)
        for s in 0..<along {
            let rho = 1 - Float(s) / Float(along - 1)
            for c in 0..<across {
                let phi = 2 * Float.pi * Float(c) / Float(across - 1)
                let y = height * (1 - pow(rho, 4))
                m.positions.append(SIMD3(cos(phi) * rho * radius, y, sin(phi) * rho * radius))
                // Normal of y = h (1 - (r / R)^4).
                let slope = height * 4 * pow(rho, 3) / radius
                m.normals.append(normalize(SIMD3(cos(phi) * slope, 1, sin(phi) * slope)))
                m.shade.append(0.55)
                m.edge.append(0)
                m.glow.append(1)
            }
        }
        let f = UInt32(first)
        for s in 0..<(along - 1) {
            for c in 0..<(across - 1) {
                let i0 = f + UInt32(s * across + c), i1 = i0 + 1, i2 = i0 + UInt32(across), i3 = i2 + 1
                m.indices += [i0, i2, i1, i1, i2, i3]
            }
        }
    }

    static func petal(ring r: Ring, k: Int, index i: Int, open o: Float, breath: Float, into m: inout Mesh) {
        let rad = Float.pi / 180
        let j0 = jitter(k, i, 0), j1 = jitter(k, i, 1), j2 = jitter(k, i, 2), j3 = jitter(k, i, 3)
        let psi = 2 * Float.pi * (Float(i) + r.offset + 0.1 * j0) / Float(r.count)
        let er = SIMD3<Float>(cos(psi), 0, sin(psi)), et = SIMD3<Float>(-sin(psi), 0, cos(psi)), up = SIMD3<Float>(0, 1, 0)
        // Inner rings close more on the breath, so the centre seems to breathe while the outer ring rests.
        let inner = Float(k) / Float(rings.count - 1)
        let odd: Float = i % 2 == 0 ? 0 : 1
        let a0 = (r.budElevation + (r.openElevation - r.budElevation) * o + 4 * j1 + breath * (2 + 4 * inner)
            - alternate.elevation * odd) * rad
        let curl = (r.budCurl + (r.openCurl - r.budCurl) * o + 4 * j2) * rad
        let length = r.length * (budLength + (1 - budLength) * o) * (1 + 0.05 * j3)
        let w = r.halfWidth * length * (1 + 0.06 * j2)
        let cup = (r.budCup + (r.openCup - r.budCup) * o) * w
        let roll = (budRoll + (openRoll - budRoll) * o) * rad
        let twist = 0.08 * j0
        // The midrib: a shallow V along the petal, so the two halves catch the light differently.
        let crease = 0.07 * w
        let base = SIMD3<Float>(0, r.baseHeight - alternate.height * odd, 0) + er * r.baseRadius

        // The centreline in the petal's radial plane: elevation grows toward the tip (the curl), integrated in steps.
        var centre = [SIMD2<Float>](repeating: .zero, count: along)
        var angle = [Float](repeating: 0, count: along)
        var p = SIMD2<Float>(0, 0)
        let sub = 4
        for s in 0..<along {
            let u = station(s)
            angle[s] = a0 + curl * pow(u, 1.6)
            centre[s] = p
            guard s < along - 1 else { break }
            let u0 = station(s), u1 = station(s + 1)
            for q in 0..<sub {
                let uu = u0 + (u1 - u0) * (Float(q) + 0.5) / Float(sub)
                let a = a0 + curl * pow(uu, 1.6)
                p += SIMD2(cos(a), sin(a)) * (length * (u1 - u0) / Float(sub))
            }
        }

        let first = m.positions.count
        for s in 0..<along {
            let u = station(s)
            // Widest a little past half way, narrow at the base, a rounded point at the tip, sharper further in.
            let width = w * pow(max(0, sin(Float.pi * pow(u, 1.25))), 0.6 + 0.3 * inner)
            let a = angle[s]
            let n3 = er * -sin(a) + up * cos(a)
            // The roll grows in from the base, where all petals meet at the receptacle.
            let tw = roll * smooth(0, 0.35, u) + twist * u
            let side = et * cos(tw) + n3 * sin(tw)
            let normal = n3 * cos(tw) - et * sin(tw)
            let spine = base + er * centre[s].x + up * centre[s].y
            for c in 0..<across {
                let v = Float(c) / Float(across - 1) * 2 - 1
                let lateral = v * width
                let lift = cup * (lateral * lateral) / (w * w) + crease * abs(v) * sin(Float.pi * u)
                let pos = spine + side * lateral + normal * lift
                m.positions.append(pos)
                // Occlusion: deep at the petal's base, and low in the heart of the flower, where the petals crowd.
                let fromAxis = (pos.x * pos.x + pos.z * pos.z).squareRoot()
                let heart = 1 - 0.35 * (1 - smooth(0.05, 0.35, fromAxis)) * (1 - smooth(0.3, 0.6, pos.y))
                let ao = (0.22 + 0.78 * smooth(0, 0.6, u)) * heart
                // A slightly darker crease along the midrib.
                let rib = 1 - 0.16 * (1 - smooth(0, 0.22, abs(v))) * smooth(0.05, 0.3, u)
                m.shade.append(ao * rib)
                m.edge.append(0.12 * smooth(0.7, 1, abs(v)) * smooth(0.15, 0.5, u))
                m.glow.append(inner)
                m.normals.append(.zero)
            }
        }
        // Normals from the grid: central differences, pointed to the petal's inner face.
        for s in 0..<along {
            for c in 0..<across {
                let du = m.positions[first + min(s + 1, along - 1) * across + c] - m.positions[first + max(s - 1, 0) * across + c]
                let dv = m.positions[first + s * across + min(c + 1, across - 1)] - m.positions[first + s * across + max(c - 1, 0)]
                var n = cross(dv, du)
                let len = (n * n).sum().squareRoot()
                n = len > 1e-8 ? n / len : up
                let a = angle[s]
                if (n * (er * -sin(a) + up * cos(a))).sum() < 0 { n = -n }
                m.normals[first + s * across + c] = n
            }
        }
        let f = UInt32(first)
        for s in 0..<(along - 1) {
            for c in 0..<(across - 1) {
                let i0 = f + UInt32(s * across + c), i1 = i0 + 1, i2 = i0 + UInt32(across), i3 = i2 + 1
                m.indices += [i0, i2, i1, i1, i2, i3]
            }
        }
    }

    /// Where grid row `s` sits along the petal, 0 at the base to 1 at the tip: closer together toward the tip, where
    /// the outline turns fastest.
    static func station(_ s: Int) -> Float {
        let t = Float(s) / Float(along - 1)
        return 0.4 * t + 0.6 * (1 - (1 - t) * (1 - t))
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }

    static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = (v * v).sum().squareRoot()
        return l > 1e-12 ? v / l : v
    }

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The open flower's radius in flower units, measured from the mesh once.
    static let openRadius: Float = {
        mesh(bloom: 1).positions.reduce(0) { max($0, ($1.x * $1.x + $1.z * $1.z).squareRoot()) }
    }()

    // MARK: Camera, light and raster

    /// The view: a three-quarter view from `elevation` above, the camera `distance` units from `target`.
    static let elevation: Float = 34 * .pi / 180
    static let distance: Float = 5.5
    static let target = SIMD3<Float>(0, 0.18, 0)
    /// The key light, from the upper left and a little in front, fixed to the camera so it never turns with the flower.
    static let key = normalize(SIMD3<Float>(-0.45, 1, 0.4))
    /// How far a petal one `layer` up wins a depth tie, in flower units.
    static let layerBias: Float = 0.02

    /// One frame's pose.
    public struct Pose: Hashable, Sendable {
        public var bloom: Double
        /// Radians about the vertical axis.
        public var turn: Double
        public var breath: Double
        /// The flower's size as a share of the open size, a little smaller while it opens.
        public var scale: Double

        public init(bloom: Double, turn: Double = 0, breath: Double = 0, scale: Double = 1) {
            self.bloom = bloom; self.turn = turn; self.breath = breath; self.scale = scale
        }
    }

    /// Where the flower sits: the canvas in cells, the flower's centre on it, its open radius in cells, and the
    /// canvas's top-left cell in the panel's grid, which sets the Bayer phase so every canvas shares the panel's grid.
    public struct Placement: Hashable, Sendable {
        public var width: Int, height: Int
        public var centreX: Double, centreY: Double
        public var radius: Double
        public var originX: Int, originY: Int

        public init(width: Int, height: Int, centreX: Double, centreY: Double, radius: Double, originX: Int = 0, originY: Int = 0) {
            self.width = width; self.height = height; self.centreX = centreX; self.centreY = centreY
            self.radius = radius; self.originX = originX; self.originY = originY
        }
    }

    /// A rendered frame, one value per cell: `light` is the lit tone of what covers the cell (0...1) and `cover` how
    /// much of the cell the flower covers.
    public struct Shot: Sendable {
        public var width: Int, height: Int
        public var light: [Float], cover: [Float]
    }

    /// A z-buffer: depth, `channels` interpolated attributes and the petal id per sample (-1 where empty).
    struct Raster {
        var width: Int, height: Int, channels: Int
        var depth: [Float], attrs: [Float], id: [Int32]
    }

    /// Fills triangles into a `width` x `height` z-buffer, sampling at pixel centres. Strictly nearest wins, no
    /// blending. `x`, `y` in pixels, `z` the depth, `attr` `channels` values per vertex, `bias` subtracted from the
    /// depth of every triangle of petal `p`. Overdraw only writes the depth, the triangle and two barycentrics; the
    /// attributes are interpolated once per sample at the end.
    static func raster(width w: Int, height h: Int, x sx: [Float], y sy: [Float], z sz: [Float], attr: [Float], channels nc: Int,
                       indices: [UInt32], bias: [Float]) -> Raster {
        var r = Raster(width: w, height: h, channels: nc, depth: [Float](repeating: .infinity, count: w * h),
                       attrs: [Float](repeating: 0, count: w * h * nc), id: [Int32](repeating: -1, count: w * h))
        var tri = [Int32](repeating: -1, count: nc > 0 ? w * h : 0)
        var bary = [SIMD2<Float>](repeating: .zero, count: nc > 0 ? w * h : 0)
        let per = trianglesPerPetal
        let keep = nc > 0
        r.depth.withUnsafeMutableBufferPointer { zb in
            tri.withUnsafeMutableBufferPointer { tb in
                bary.withUnsafeMutableBufferPointer { bb in
                    indices.withUnsafeBufferPointer { ix in
                        sx.withUnsafeBufferPointer { sx in
                            sy.withUnsafeBufferPointer { sy in
                                sz.withUnsafeBufferPointer { sz in
                                    for t in 0..<(ix.count / 3) {
                                        let a = Int(ix[3 * t]), b = Int(ix[3 * t + 1]), c = Int(ix[3 * t + 2])
                                        let ax = sx[a], ay = sy[a], bx = sx[b], by = sy[b], qx = sx[c], qy = sy[c]
                                        let area = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
                                        guard abs(area) > 1e-9 else { continue }
                                        let x0 = max(0, Int((min(ax, bx, qx) - 0.5).rounded(.up)))
                                        let x1 = min(w - 1, Int((max(ax, bx, qx) - 0.5).rounded(.down)))
                                        let y0 = max(0, Int((min(ay, by, qy) - 0.5).rounded(.up)))
                                        let y1 = min(h - 1, Int((max(ay, by, qy) - 0.5).rounded(.down)))
                                        guard x0 <= x1, y0 <= y1 else { continue }
                                        let inv = 1 / area
                                        let petal = t / per
                                        let shift = petal < bias.count ? bias[petal] : 0
                                        let za = sz[a] - shift, zb2 = sz[b] - shift, zc = sz[c] - shift
                                        // Edge functions step by a constant per pixel.
                                        let e0x = -(qy - by) * inv, e1x = -(ay - qy) * inv
                                        for py in y0...y1 {
                                            let fy = Float(py) + 0.5, fx0 = Float(x0) + 0.5
                                            var w0 = ((bx - fx0) * (qy - fy) - (by - fy) * (qx - fx0)) * inv
                                            var w1 = ((qx - fx0) * (ay - fy) - (qy - fy) * (ax - fx0)) * inv
                                            var k = py * w + x0
                                            for _ in x0...x1 {
                                                let w2 = 1 - w0 - w1
                                                if w0 >= 0, w1 >= 0, w2 >= 0 {
                                                    let z = w0 * za + w1 * zb2 + w2 * zc
                                                    if z < zb[k] {
                                                        zb[k] = z
                                                        if keep { tb[k] = Int32(t); bb[k] = SIMD2(w0, w1) }
                                                    }
                                                }
                                                w0 += e0x; w1 += e1x; k += 1
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard keep else { return r }
        // Resolve: one interpolation per covered sample.
        r.attrs.withUnsafeMutableBufferPointer { ab in
            r.id.withUnsafeMutableBufferPointer { idb in
                attr.withUnsafeBufferPointer { va in
                    indices.withUnsafeBufferPointer { ix in
                        for k in 0..<(w * h) where tri[k] >= 0 {
                            let t = Int(tri[k])
                            idb[k] = Int32(t / per)
                            let a = Int(ix[3 * t]) * nc, b = Int(ix[3 * t + 1]) * nc, c = Int(ix[3 * t + 2]) * nc
                            let w0 = bary[k].x, w1 = bary[k].y, w2 = 1 - w0 - w1
                            for ch in 0..<nc { ab[k * nc + ch] = w0 * va[a + ch] + w1 * va[b + ch] + w2 * va[c + ch] }
                        }
                    }
                }
            }
        }
        return r
    }

    /// The shadow map's side in texels for a flower `samples` across in radius: about one texel per three samples,
    /// since the shadow is blurred on screen anyway, and the map is a fixed cost every frame.
    static func shadowSize(radius: Float) -> Int { min(384, max(64, Int(radius * 0.8))) }
    /// The shadow map's reach either side of the target, in flower units.
    static var shadowReach: Float { openRadius * 1.25 }

    /// The scene at `pose` on a `samples`-per-cell grid: the z-buffer with each sample's tone in channel 0.
    /// Gouraud-shaded triangles; the key light is shadowed per sample from a shadow map (a bilinear lookup blurred
    /// twice on screen, so the shadow of a petal on the one beneath is soft), and a depth-darkening pass (Luft et
    /// al.'s unsharp mask on depth) adds contact shade where a nearer petal overlaps.
    static func scene(_ pose: Pose, placement: Placement, samples: Int) -> Raster {
        let ss = max(1, samples)
        let w = placement.width * ss, h = placement.height * ss
        let m = mesh(bloom: pose.bloom, breath: pose.breath)
        // The turn repeats every quarter, so the loop's end renders exactly its start.
        let turn = Float(pose.turn.truncatingRemainder(dividingBy: symmetry))
        let ct = cos(turn), st = sin(turn)
        let back = SIMD3<Float>(0, sin(elevation), cos(elevation))
        let right = SIMD3<Float>(1, 0, 0), upC = SIMD3<Float>(0, cos(elevation), -sin(elevation))
        let camera = target + back * distance
        let scale = Float(placement.radius) * Float(ss) / openRadius * Float(pose.scale)
        let cx = Float(placement.centreX) * Float(ss), cy = Float(placement.centreY) * Float(ss)
        // The light's frame, for the shadow map: an orthographic view along the key light.
        let lz = key, lx = normalize(cross(SIMD3<Float>(0, 1, 0), lz)), ly = cross(lz, lx)
        let shadowSize = shadowSize(radius: Float(placement.radius) * Float(ss))
        let texels = Float(shadowSize) / (2 * shadowReach * Float(pose.scale))
        let bias = m.layer.map { Float($0) * layerBias }

        // Vertices: turn, shade, project to the screen and to the light. Channels: the key light's share (shadowed),
        // the rest (ambient, rim, edge), and the light-space x, y and depth.
        let count = m.positions.count
        let nc = 5
        var sx = [Float](repeating: 0, count: count), sy = sx, sz = sx, mx = sx, my = sx, mz = sx
        var attr = [Float](repeating: 0, count: count * nc)
        for i in 0..<count {
            let p0 = m.positions[i] * Float(pose.scale), n0 = m.normals[i]
            let p = SIMD3(ct * p0.x - st * p0.z, p0.y, st * p0.x + ct * p0.z)
            var n = SIMD3(ct * n0.x - st * n0.z, n0.y, st * n0.x + ct * n0.z)
            let view = normalize(camera - p)
            var facing = dot(n, view)
            // The petals are thin sheets: light the face the camera sees.
            var under: Float = 1
            if facing < 0 {
                n = -n; facing = -facing
                // The outer face: darker, and darkest where it faces the ground.
                under = 0.55 + 0.33 * smooth(-0.5, 0.2, n.y)
            }
            let lambert = dot(n, key)
            let half = normalize(key + view)
            let spec = lambert > 0 ? pow(max(0, dot(n, half)), 24) * 0.32 : 0
            // Light through the petal from behind, a little, as the reference's petals glow.
            let through = max(0, -lambert) * 0.12
            let direct = m.shade[i] * under * (0.68 * max(0, lambert) + through) + spec * m.shade[i]
            let sky = 0.05 + 0.07 * (0.5 + 0.5 * n.y)
            let rim = pow(1 - min(1, facing), 3) * 0.2 * m.shade[i]
            // A soft fill from the camera, unshadowed, so the heart is not lost in the outer petals' shadow, and a
            // little glow from the inner rings, as the reference's centre glows.
            let fill = 0.2 * facing
            let ambient = m.shade[i] * (under * (sky + fill) + 0.24 * m.glow[i]) + rim + m.edge[i] * under
            let d = p - target
            let z = distance - dot(d, back)
            let f = distance / z
            sx[i] = cx + scale * f * dot(d, right)
            sy[i] = cy - scale * f * dot(d, upC)
            sz[i] = z
            mx[i] = (dot(d, lx) / (2 * shadowReach * Float(pose.scale)) + 0.5) * Float(shadowSize)
            my[i] = (0.5 - dot(d, ly) / (2 * shadowReach * Float(pose.scale))) * Float(shadowSize)
            mz[i] = -dot(d, lz) * texels
            attr[i * nc] = direct; attr[i * nc + 1] = ambient
            attr[i * nc + 2] = mx[i]; attr[i * nc + 3] = my[i]
            // Slope-scaled bias: a face lit at a grazing angle changes depth fast across a texel.
            let cosL = max(0.15, abs(lambert))
            attr[i * nc + 4] = mz[i] - (1 + 2.5 * (1 - cosL * cosL).squareRoot() / cosL)
        }

        // The shadow map, depth in texel units so the bias reads in texels.
        let map = raster(width: shadowSize, height: shadowSize, x: mx, y: my, z: mz, attr: [], channels: 0,
                         indices: m.indices, bias: [])
        var r = raster(width: w, height: h, x: sx, y: sy, z: sz, attr: attr, channels: nc, indices: m.indices, bias: bias)

        // Depth darkening: a sample behind its neighbourhood's mean depth sits under a nearer petal's edge.
        let radius = max(2, Int(Float(placement.radius) * Float(ss) * 0.05))
        let occlusion = darkening(r.depth, width: w, height: h, radius: radius, reach: 0.12)
        // The key light's share per sample: bilinear over the map's four nearest texels, then blurred twice in screen
        // space, so a petal's shadow on the one beneath has a soft edge.
        let sm = shadowSize
        var lit = [Float](repeating: 1, count: w * h)
        lit.withUnsafeMutableBufferPointer { lit in
            r.attrs.withUnsafeBufferPointer { at in
                r.id.withUnsafeBufferPointer { id in
                    map.depth.withUnsafeBufferPointer { md in
                        for k in 0..<(w * h) where id[k] >= 0 {
                            let a = k * nc
                            let fx = min(max(at[a + 2] - 0.5, 0), Float(sm - 2)), fy = min(max(at[a + 3] - 0.5, 0), Float(sm - 2))
                            let tz = at[a + 4]
                            let x0 = Int(fx), y0 = Int(fy)
                            let ax = fx - Float(x0), ay = fy - Float(y0)
                            let i = y0 * sm + x0
                            let t00: Float = tz <= md[i] ? 1 : 0, t10: Float = tz <= md[i + 1] ? 1 : 0
                            let t01: Float = tz <= md[i + sm] ? 1 : 0, t11: Float = tz <= md[i + sm + 1] ? 1 : 0
                            lit[k] = (t00 * (1 - ax) + t10 * ax) * (1 - ay) + (t01 * (1 - ax) + t11 * ax) * ay
                        }
                    }
                }
            }
        }
        let soft = max(1, Int(Float(placement.radius) * Float(ss) * 0.018))
        boxBlur(&lit, width: w, height: h, radius: soft)
        boxBlur(&lit, width: w, height: h, radius: soft)
        for k in 0..<(w * h) where r.id[k] >= 0 {
            let a = k * nc
            r.attrs[a] = (r.attrs[a + 1] + r.attrs[a] * (0.35 + 0.65 * lit[k])) * (1 - 0.5 * occlusion[k])
        }
        return r
    }

    /// Renders `pose` with `samples` x `samples` samples a cell, down to one tone and one coverage value per cell.
    public static func render(_ pose: Pose, placement: Placement, samples: Int = 2) -> Shot {
        let ss = max(1, samples)
        var shot = Shot(width: placement.width, height: placement.height,
                        light: [Float](repeating: 0, count: placement.width * placement.height),
                        cover: [Float](repeating: 0, count: placement.width * placement.height))
        guard placement.width > 0, placement.height > 0 else { return shot }
        let r = scene(pose, placement: placement, samples: ss)
        let w = r.width, nc = r.channels
        let n = Float(ss * ss)
        for y in 0..<placement.height {
            for x in 0..<placement.width {
                var sum: Float = 0, hit: Float = 0
                for dy in 0..<ss {
                    let row = (y * ss + dy) * w + x * ss
                    for dx in 0..<ss where r.id[row + dx] >= 0 { sum += r.attrs[(row + dx) * nc]; hit += 1 }
                }
                let k = y * placement.width + x
                shot.cover[k] = hit / n
                shot.light[k] = hit > 0 ? min(1, sum / hit) : 0
            }
        }
        return shot
    }

    /// Samples that show a petal in pieces smaller than `limit` samples: slivers where one petal cuts through
    /// another. A petal partly hidden by a nearer one legitimately shows in large pieces, which this ignores.
    static func slivers(_ r: Raster, limit: Int) -> Int {
        var seen = [Bool](repeating: false, count: r.width * r.height)
        var stray = 0
        var stack: [Int] = []
        for start in 0..<(r.width * r.height) where !seen[start] && r.id[start] >= 0 {
            let id = r.id[start]
            var size = 0
            stack.append(start); seen[start] = true
            while let k = stack.popLast() {
                size += 1
                let x = k % r.width, y = k / r.width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < r.width && ny < r.height {
                    let q = ny * r.width + nx
                    if !seen[q] && r.id[q] == id { seen[q] = true; stack.append(q) }
                }
            }
            if size < limit { stray += size }
        }
        return stray
    }

    /// How far each covered sample sits behind the mean depth of the covered samples within `radius`, over `reach`
    /// units, 0...1. Two separable box passes over running sums, so it costs the same at any radius.
    static func darkening(_ depth: [Float], width w: Int, height h: Int, radius r: Int, reach: Float) -> [Float] {
        var sum = [Float](repeating: 0, count: w * h), hits = sum
        for k in 0..<(w * h) where depth[k] < .infinity { sum[k] = depth[k]; hits[k] = 1 }
        boxBlur(&sum, width: w, height: h, radius: r)
        boxBlur(&hits, width: w, height: h, radius: r)
        var out = [Float](repeating: 0, count: w * h)
        for k in 0..<(w * h) where depth[k] < .infinity && hits[k] > 0 {
            out[k] = min(1, max(0, (depth[k] - sum[k] / hits[k]) / reach))
        }
        return out
    }

    /// A box filter of `radius` over `a` in place; the edges average what is there. Rows run over a sliding sum;
    /// columns slide a whole row of sums down the image, so both passes read memory in order.
    static func boxBlur(_ a: inout [Float], width w: Int, height h: Int, radius r: Int) {
        guard w > 0, h > 0 else { return }
        var line = [Float](repeating: 0, count: w)
        var acc = [Float](repeating: 0, count: w)
        var out = [Float](repeating: 0, count: w * h)
        a.withUnsafeMutableBufferPointer { a in
            line.withUnsafeMutableBufferPointer { line in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0, count: Float = 0
                    for i in 0..<min(r, w) { sum += a[row + i]; count += 1 }
                    for i in 0..<w {
                        if i + r < w { sum += a[row + i + r]; count += 1 }
                        if i - r - 1 >= 0 { sum -= a[row + i - r - 1]; count -= 1 }
                        line[i] = sum / count
                    }
                    for i in 0..<w { a[row + i] = line[i] }
                }
            }
            acc.withUnsafeMutableBufferPointer { acc in
                out.withUnsafeMutableBufferPointer { out in
                    var count: Float = 0
                    for y in 0..<min(r, h) { count += 1; for x in 0..<w { acc[x] += a[y * w + x] } }
                    for y in 0..<h {
                        if y + r < h { count += 1; let row = (y + r) * w; for x in 0..<w { acc[x] += a[row + x] } }
                        if y - r - 1 >= 0 { count -= 1; let row = (y - r - 1) * w; for x in 0..<w { acc[x] -= a[row + x] } }
                        let inv = 1 / count, row = y * w
                        for x in 0..<w { out[row + x] = acc[x] * inv }
                    }
                }
            }
        }
        a = out
    }

    // MARK: Dither

    /// The share of the ink a deep cell shows over the ground, so one mask carries two inks: 255 is the ink, this the
    /// ink at that share over the ground (about PictureInk's deep ink at L 0.52 under a light ink at L 0.82).
    public static let deepAlpha: UInt8 = 140
    /// Light's ink: the accent's hue at this OKLCH lightness and at most this chroma, deep enough to read on the
    /// off-white ground.
    public static let lightInk = (l: 0.46, c: 0.14)

    /// How much ink a cell takes, 0...1. In dark the lit parts take ink; in light the shaded parts do, over a floor
    /// that keeps the silhouette where the flower is brightest. Light's floor is high, so the lit petals still show
    /// as the deep ink's dots on the off-white ground instead of washing out (stage 1 floored at 0.16).
    static func ink(_ shot: Shot, _ k: Int, dark: Bool) -> Float {
        let l = shot.light[k], c = shot.cover[k]
        return dark ? c * pow(l, 0.9) : c * (0.42 + 0.58 * pow(1 - l, 0.85))
    }

    /// The mask for `shot`: one byte a cell, row 0 at the top. With one ink a cell is on (255) where its ink beats the
    /// cell's Bayer threshold; with two, ground, deep (`deepAlpha`) and ink, dithered between neighbouring levels.
    /// `density` (0...1 a cell) thins the dots, `top` (0...2 a cell) caps the level and `cap` the mask value, as
    /// PictureInk does behind a reading column: a capped cell shows the ink nearer the ground, so text keeps its floor.
    public static func mask(_ shot: Shot, placement: Placement, dark: Bool, inks: Int,
                            density: [Float]? = nil, top: [Float]? = nil, cap: [UInt8]? = nil) -> [UInt8] {
        let w = shot.width, h = shot.height
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let b = ((y + placement.originY) & 7) * 8
            for x in 0..<w {
                let k = y * w + x
                let threshold = (Float(DitherArt.bayer[b + ((x + placement.originX) & 7)]) + 0.5) / 64
                let v = ink(shot, k, dark: dark) * (density?[k] ?? 1)
                if inks < 2 {
                    out[k] = v > threshold ? 255 : 0
                } else {
                    let s = min(v * 2, top?[k] ?? 2)
                    let lo = Int(s)
                    let level = lo < 2 && s - Float(lo) > threshold ? lo + 1 : lo
                    out[k] = level == 0 ? 0 : level == 1 ? deepAlpha : 255
                }
                if let cap { out[k] = min(out[k], cap[k]) }
            }
        }
        return out
    }

    /// A mask as an alpha-only image for a layer's mask, the format Gradient's frames use.
    public static func image(_ mask: [UInt8], width w: Int, height h: Int) -> CGImage? {
        guard w > 0, h > 0, mask.count == w * h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        // Row 0 of the buffer is the top of the canvas.
        mask.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: w * h) }
        return ctx.makeImage()
    }

    // MARK: Motion

    /// The bloom: bud to open in `bloomDuration` seconds at `bloomFPS`, eased out, turning into the idle turn's speed.
    public static let bloomDuration = 1.4, bloomFPS = 20.0
    /// The idle loop: a quarter turn and one breath in `idlePeriod` seconds at `idleFPS`. The flower repeats every
    /// quarter turn, so the loop is seamless and keeps turning the same way.
    public static let idlePeriod = 16.0, idleFPS = 10.0
    /// How far the bloom turns beyond the idle turn's own sweep, and how much smaller the bud starts.
    static let bloomSweep = 26 * Double.pi / 180, budScale = 0.82
    /// How open the bloom's first frame is.
    static let budOpen = 0.12

    /// The idle turn's speed, radians a second.
    static var spin: Double { symmetry / idlePeriod }

    /// The bloom's poses, the bud first; the idle loop's first pose follows its last.
    public static func bloomPoses() -> [Pose] {
        let n = Int((bloomDuration * bloomFPS).rounded())
        return (0..<n).map { i in
            let t = Double(i) / Double(n)
            // Eased out, with a gentle start so the bud does not pop open in the first frames. It starts a little
            // open, a bud with its tips parted, since a closed bud is a smudge at this size.
            let eased = budOpen + (1 - budOpen) * (1 - pow(1 - pow(t, 1.4), 2.6))
            // Ends at turn 0 with the idle turn's speed, so the hand-over has no kink.
            let turn = spin * bloomDuration * (t - 1) - bloomSweep * pow(1 - t, 3)
            return Pose(bloom: eased, turn: turn, breath: 0, scale: budScale + (1 - budScale) * eased)
        }
    }

    /// The open flower at rest: the idle loop's first pose and the bloom's end.
    public static let openPose = Pose(bloom: 1)
    /// How long the bloom's first frames fade in over the ground, seconds.
    public static let bloomFadeIn = 0.3

    /// The idle loop's poses; the pose after the last is the first.
    public static func idlePoses() -> [Pose] {
        let n = Int((idlePeriod * idleFPS).rounded())
        return (0..<n).map { i in
            let t = Double(i) / Double(n)
            return Pose(bloom: 1, turn: symmetry * t, breath: (1 - cos(2 * .pi * t)) / 2, scale: 1)
        }
    }

    /// How far the flower reaches from its centre over the bloom and the idle loop, in open radii: left, right, up
    /// and down. Measured once from every fourth bloom pose and every tenth idle pose, plus a cell of margin.
    public static let reach: (left: Double, right: Double, up: Double, down: Double) = {
        let r = 60.0, side = 200
        let probe = Placement(width: side, height: side, centreX: 100, centreY: 100, radius: r)
        let poses = stride(from: 0, to: bloomPoses().count, by: 4).map { bloomPoses()[$0] }
            + stride(from: 0, to: idlePoses().count, by: 10).map { idlePoses()[$0] }
        var x0 = side, y0 = side, x1 = 0, y1 = 0
        for pose in poses {
            let shot = render(pose, placement: probe, samples: 1)
            for y in 0..<side { for x in 0..<side where shot.cover[y * side + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
            } }
        }
        let margin = 2.0
        return ((100 - Double(x0) + margin) / r, (Double(x1) - 100 + margin) / r, (100 - Double(y0) + margin) / r, (Double(y1) - 100 + margin) / r)
    }()

    /// The canvas for a flower of `radius` cells centred at `centreX`, `centreY` in a panel `width` x `height` cells:
    /// just the cells it can cover, clipped to the panel, so the masks hold nothing but the flower.
    public static func placement(panelWidth width: Int, panelHeight height: Int, centreX: Double, centreY: Double,
                                 radius: Double) -> Placement {
        let x0 = max(0, Int((centreX - reach.left * radius).rounded(.down)))
        let x1 = min(width, Int((centreX + reach.right * radius).rounded(.up)))
        let y0 = max(0, Int((centreY - reach.up * radius).rounded(.down)))
        let y1 = min(height, Int((centreY + reach.down * radius).rounded(.up)))
        return Placement(width: max(0, x1 - x0), height: max(0, y1 - y0), centreX: centreX - Double(x0),
                         centreY: centreY - Double(y0), radius: radius, originX: x0, originY: y0)
    }

    /// The bloom and the idle loop as masks.
    public struct Frames: @unchecked Sendable {
        public let bloom: [CGImage]
        public let idle: [CGImage]
        public var bytes: Int { (bloom + idle).reduce(0) { $0 + $1.bytesPerRow * $1.height } }
    }

    /// Renders both sequences. Each frame is independent, so `parallel` spreads them over the cores.
    public static func frames(placement: Placement, dark: Bool, inks: Int, density: [Float]? = nil, top: [Float]? = nil,
                              cap: [UInt8]? = nil, samples: Int = 2, parallel: Bool = true) -> Frames {
        let bloom = masks(bloomPoses(), placement: placement, dark: dark, inks: inks, density: density, top: top, cap: cap,
                          samples: samples, parallel: parallel)
        let idle = masks(idlePoses(), placement: placement, dark: dark, inks: inks, density: density, top: top, cap: cap,
                         samples: samples, parallel: parallel)
        guard let bloom, let idle else { return Frames(bloom: [], idle: []) }
        return Frames(bloom: bloom, idle: idle)
    }

    /// One mask per pose, or nil if any failed. `parallel` spreads them over the cores.
    public static func masks(_ poses: [Pose], placement: Placement, dark: Bool, inks: Int, density: [Float]? = nil,
                             top: [Float]? = nil, cap: [UInt8]? = nil, samples: Int = 2, parallel: Bool = true) -> [CGImage]? {
        nonisolated(unsafe) let out = UnsafeMutableBufferPointer<CGImage?>.allocate(capacity: poses.count)
        out.initialize(repeating: nil)
        defer { out.deinitialize(); out.deallocate() }
        let one = { (i: Int) in
            let shot = render(poses[i], placement: placement, samples: samples)
            out[i] = image(mask(shot, placement: placement, dark: dark, inks: inks, density: density, top: top, cap: cap),
                           width: placement.width, height: placement.height)
        }
        if parallel { DispatchQueue.concurrentPerform(iterations: poses.count, execute: one) } else { (0..<poses.count).forEach(one) }
        let all = out.compactMap { $0 }
        return all.count == poses.count ? all : nil
    }

    // MARK: Placement (stage 2)

    /// Which page the flower sits on: centred over the new thread's composer, or small beside a thread's column.
    public enum Kind: Hashable, Sendable { case hero, thread }

    /// What a page reports: its content area (below the band, left of the right panel) and what the flower must keep
    /// `clearance` from: the composer and the pills around it on a new thread, the reading column in a thread, and the
    /// header pill. Points, from the art's top left, y down.
    public struct Stage: Equatable, Sendable {
        public var kind: Kind
        public var content: CGRect
        public var keepOut: [CGRect]
        public init(kind: Kind, content: CGRect, keepOut: [CGRect]) { self.kind = kind; self.content = content; self.keepOut = keepOut }
    }

    /// Where the open flower sits: its centre and radius in points, same space as the stage.
    public struct Spot: Equatable, Sendable {
        public var centre: CGPoint
        public var radius: CGFloat
        public init(centre: CGPoint, radius: CGFloat) { self.centre = centre; self.radius = radius }

        /// The box any bloom or idle frame can cover.
        public var box: CGRect {
            CGRect(x: centre.x - extent.left * radius, y: centre.y - extent.up * radius,
                   width: (extent.left + extent.right) * radius, height: (extent.up + extent.down) * radius)
        }
    }

    /// `reach` in points per point of radius.
    static let extent = (left: CGFloat(reach.left), right: CGFloat(reach.right), up: CGFloat(reach.up), down: CGFloat(reach.down))

    /// How far the flower keeps from the content area's edges and from everything in `keepOut`, in points.
    public static let clearance: CGFloat = 24
    /// Below this radius the dots no longer read as a flower (about 20 cells), so it hides.
    public static let minRadius: CGFloat = 60
    /// The new-thread flower's largest radius: 96 cells, about 5.4 MB of masks for the whole set.
    public static let heroMaxRadius: CGFloat = 288
    /// The thread flower's largest radius, in the margin beside the column.
    public static let threadMaxRadius: CGFloat = 150

    /// Where the flower goes on `stage`, or nil when it would be smaller than `minRadius`. The new thread: centred
    /// across the content area, centred down the free space above whatever `keepOut` holds below its top (the
    /// composer and its pills), as large as fits. A thread: top right of the content area, centred across the free
    /// margin right of the column, as large as fits there. It never comes within `clearance` of a keep-out rectangle
    /// or the content area's edge.
    public static func spot(for stage: Stage) -> Spot? {
        let c = stage.content, gap = clearance
        let blocks = stage.keepOut.map { $0.insetBy(dx: -gap, dy: -gap) }
        guard c.width > 2 * gap, c.height > 2 * gap else { return nil }
        let largest = stage.kind == .hero ? heroMaxRadius : threadMaxRadius
        let w = extent.left + extent.right, h = extent.up + extent.down
        // Radii from the largest down in half points; the first that fits wins.
        var r = Swift.min(largest, (c.width - 2 * gap) / w, (c.height - 2 * gap) / h)
        while r >= minRadius {
            if let spot = fit(stage, radius: r, blocks: blocks), blocks.allSatisfy({ !$0.intersects(spot.box) }) { return spot }
            r -= 0.5
        }
        return nil
    }

    private static func fit(_ stage: Stage, radius r: CGFloat, blocks: [CGRect]) -> Spot? {
        let c = stage.content, gap = clearance
        let w = (extent.left + extent.right) * r, h = (extent.up + extent.down) * r
        switch stage.kind {
        case .hero:
            // Across: centred on the content area. Down: the free run from the top to the first thing below it,
            // wherever it sits across, so the composer, its pills and its cards are one floor.
            let x = c.midX - (extent.right - extent.left) * r / 2
            let below = blocks.sorted { $0.minY < $1.minY }
            // Only the run above the composer group: never below or beside it.
            var top = c.minY + gap
            for b in below + [CGRect(x: c.minX, y: c.maxY - gap, width: c.width, height: 0)] {
                guard b.minY <= top else {
                    guard b.minY - top >= h else { return nil }
                    let y = top + (b.minY - top - h) / 2 + extent.up * r
                    return Spot(centre: CGPoint(x: x, y: y), radius: r)
                }
                top = Swift.max(top, b.maxY)
            }
            return nil
        case .thread:
            // Down: from the top. Across: the free run right of anything beside it, the flower centred in it.
            let y0 = c.minY + gap, y1 = y0 + h
            let left = blocks.filter { $0.minY < y1 && $0.maxY > y0 && $0.midX < c.maxX }.map(\.maxX).max() ?? (c.minX + gap)
            let lo = Swift.max(left, c.minX + gap), hi = c.maxX - gap
            guard hi - lo >= w else { return nil }
            let x = (lo + hi) / 2 - (extent.right - extent.left) * r / 2
            return Spot(centre: CGPoint(x: x, y: y0 + extent.up * r), radius: r)
        }
    }

    /// Radii render in steps of 8%, from `minRadius`, in whole cells: a resize lands on one of about 20 frame sets,
    /// never a new one per point. The flower shows at its bucket's radius, at most 8% under the spot's.
    public static func bucket(_ radius: CGFloat, cell: CGFloat = 3) -> Int {
        let base = Double(minRadius / cell)
        let steps = (log(Double(radius / cell) / base) / log(1.08)).rounded(.down)
        return Int((base * pow(1.08, Swift.max(0, steps))).rounded(.down))
    }

    /// The canvas for a flower of `radius` cells, wherever it sits: the cells any frame can cover, its centre on a
    /// whole cell, so one set serves every position.
    public static func canvas(radius: Int) -> Placement {
        let r = Double(radius)
        let left = (reach.left * r).rounded(.up), up = (reach.up * r).rounded(.up)
        return Placement(width: Int(left + (reach.right * r).rounded(.up)), height: Int(up + (reach.down * r).rounded(.up)),
                         centreX: left, centreY: up, radius: r)
    }

    /// The new thread's thinning: full at the flower's middle, a third of the dots at the canvas's bottom edge, where
    /// the composer sits beneath it.
    public static func heroDensity(_ p: Placement) -> [Float] {
        var d = [Float](repeating: 1, count: p.width * p.height)
        for y in 0..<p.height {
            let t = smooth(Float(p.centreY + 0.15 * p.radius), Float(p.height), Float(y) + 0.5)
            for x in 0..<p.width { d[y * p.width + x] = 1 - 0.65 * t }
        }
        return d
    }
}
