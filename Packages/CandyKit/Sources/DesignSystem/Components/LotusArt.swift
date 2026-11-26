import CoreGraphics
import Foundation

/// A lotus drawn in code for the Flower background (the user, 2026-11-21: "a 3d dithered flower that blooms on opening
/// a thread and moves smoothly"). The petals are parametric sheets in six rings, rasterised on the CPU into a small
/// luminance buffer at the dot grid's resolution, then thresholded with the 8 x 8 Bayer matrix on the panel's fixed 3pt
/// grid, so the flower moves under the dots and the dots never move.
///
/// Motion is precomputed off the main thread: the bloom (bud to open) and the new thread's opening as one-byte masks
/// that play once and are dropped, and the idle loop (a slow turn and a breath) as codes packed two bits a cell. One
/// mask carries both inks and the field behind the flower: 255 is the ink, `deepAlpha` the deep ink, `fieldAlpha` a
/// field dot.
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

    /// A standard view: from `elevation` above, the camera `distance` flower units from `target`, the target on the
    /// placement's centre and the open flower `radius` cells across at the target's depth.
    public struct View: Hashable, Sendable {
        public var elevation: Float, distance: Float
        public init(elevation degrees: Float, distance: Float) { elevation = degrees * .pi / 180; self.distance = distance }
    }
    /// At rest: composition 2, "Low and cropped", which the user picked from the mocks (2026-11-21: "looks awesome"),
    /// seen from closer than the mocks so the settle can fly in to it.
    public static let rest = View(elevation: 26, distance: restDistance)
    static let restDistance: Float = 3.0
    /// Where the new thread's opening blooms: the flower as it looked above the composer in 1.16.0, which the user
    /// wanted kept ("i love this animation when it appears here").
    public static let bloomView = View(elevation: 34, distance: 5.5)
    static let target = SIMD3<Float>(0, 0.18, 0)

    /// A camera anywhere: its eye and look-at point in flower units, its lens (canvas cells per flower unit at one unit
    /// of depth), and where the look-at point lands on the canvas, in cells, so the lens can shift off centre the way
    /// the standard views do. Up is always the flower's up.
    public struct Camera: Hashable, Sendable {
        public var eye: SIMD3<Float>, lookAt: SIMD3<Float>
        public var focal: Float
        public var centreX: Float, centreY: Float
    }

    /// The camera `view` gives `placement`, with the pose's scale.
    static func camera(_ view: View, _ p: Placement, scale: Float) -> Camera {
        let back = SIMD3<Float>(0, sin(view.elevation), cos(view.elevation))
        return Camera(eye: target + back * view.distance, lookAt: target,
                      focal: Float(p.radius) / openRadius * view.distance * scale, centreX: Float(p.centreX), centreY: Float(p.centreY))
    }
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
        /// The standard view it is seen from, or a camera of its own (the settle's frames). With a camera, `centreX`,
        /// `centreY` and `radius` only size the shading.
        public var view: View
        public var camera: Camera?

        public init(width: Int, height: Int, centreX: Double, centreY: Double, radius: Double, originX: Int = 0, originY: Int = 0,
                    view: View = LotusArt.rest, camera: Camera? = nil) {
            self.width = width; self.height = height; self.centreX = centreX; self.centreY = centreY
            self.radius = radius; self.originX = originX; self.originY = originY; self.view = view; self.camera = camera
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
        var depth: Scratch<Float>, attrs: Scratch<Float>, id: Scratch<Int32>
    }

    /// Fills triangles into a `width` x `height` z-buffer, sampling at pixel centres. Strictly nearest wins, no
    /// blending. `x`, `y` in pixels, `z` the depth, `attr` `channels` values per vertex, `bias` subtracted from the
    /// depth of every triangle of petal `p`. Overdraw only writes the depth, the triangle and two barycentrics; the
    /// attributes are interpolated once per sample at the end.
    static func raster(width w: Int, height h: Int, x sx: Scratch<Float>, y sy: Scratch<Float>, z sz: Scratch<Float>, attr: Scratch<Float>, channels nc: Int,
                       indices: [UInt32], bias: [Float]) -> Raster {
        let r = Raster(width: w, height: h, channels: nc, depth: Scratch(w * h, .infinity),
                       attrs: Scratch(w * h * nc, 0), id: Scratch(w * h, -1))
        let tri = Scratch<Int32>(nc > 0 ? w * h : 0, -1)
        let bary = Scratch<SIMD2<Float>>(nc > 0 ? w * h : 0, .zero)
        let per = trianglesPerPetal
        let keep = nc > 0
        withExtendedLifetime((r, tri, bary)) {
            let zb = r.depth.buffer, tb = tri.buffer, bb = bary.buffer
            do {
                do {
                    indices.withUnsafeBufferPointer { ix in
                        do { let sx = sx.buffer
                            do { let sy = sy.buffer
                                do { let sz = sz.buffer
                                    for t in 0..<(ix.count / 3) {
                                        let a = Int(ix[3 * t]), b = Int(ix[3 * t + 1]), c = Int(ix[3 * t + 2])
                                        let ax = sx[a], ay = sy[a], bx = sx[b], by = sy[b], qx = sx[c], qy = sy[c]
                                        let area = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
                                        guard abs(area) > 1e-9 else { continue }
                                        // A vertex the camera can't see (`nearPlane`) is NaN, so its triangle goes.
                                        // The rest clamp to just outside the canvas before turning into integers,
                                        // which leaves every on-canvas bound as it was and can't trap.
                                        let minX = min(ax, bx, qx), maxX = max(ax, bx, qx), minY = min(ay, by, qy), maxY = max(ay, by, qy)
                                        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite else { continue }
                                        let fw = Float(w), fh = Float(h)
                                        let x0 = max(0, Int(min(max((minX - 0.5).rounded(.up), -1), fw)))
                                        let x1 = min(w - 1, Int(min(max((maxX - 0.5).rounded(.down), -1), fw)))
                                        let y0 = max(0, Int(min(max((minY - 0.5).rounded(.up), -1), fh)))
                                        let y1 = min(h - 1, Int(min(max((maxY - 0.5).rounded(.down), -1), fh)))
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
        withExtendedLifetime((r, tri, bary, attr)) {
            let ab = r.attrs.buffer, idb = r.id.buffer
            do {
                do { let va = attr.buffer
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
    static func shadowSize(radius: Float) -> Int { radius.isFinite ? min(384, max(64, Int(min(max(radius * 0.8, 0), 384)))) : 64 }
    /// The shadow map's reach either side of the target, in flower units.
    static var shadowReach: Float { openRadius * 1.25 }

    /// The closest a vertex can sit in front of the camera and still be drawn, in flower units. The standard views and
    /// the opening's flight keep the whole flower several units away.
    static let nearPlane: Float = 1e-3
    /// The largest canvas side in cells, and the most samples a cell: a 6K screen at 1pt cells is 6,016 wide. Anything
    /// bigger is refused before a byte is allocated.
    static let maxSide = 8192, maxSamples = 8

    /// Whether `placement` can render: no side over `maxSide` and a finite centre and radius. A zero-size canvas is
    /// fine and renders nothing.
    static func renderable(_ p: Placement) -> Bool {
        let limit = 1e7
        func ok(_ v: Double) -> Bool { v.isFinite && abs(v) <= limit }
        func ok(_ v: Float) -> Bool { v.isFinite && abs(v) <= Float(limit) }
        guard (0...maxSide).contains(p.width), (0...maxSide).contains(p.height), ok(p.centreX), ok(p.centreY), ok(p.radius) else { return false }
        guard let c = p.camera else { return true }
        return [c.eye.x, c.eye.y, c.eye.z, c.lookAt.x, c.lookAt.y, c.lookAt.z, c.focal, c.centreX, c.centreY].allSatisfy(ok)
    }

    /// The scene at `pose` on a `samples`-per-cell grid: the z-buffer with each sample's tone in channel 0.
    /// Gouraud-shaded triangles; the key light is shadowed per sample from a shadow map (a bilinear lookup blurred
    /// twice on screen, so the shadow of a petal on the one beneath is soft), and a depth-darkening pass (Luft et
    /// al.'s unsharp mask on depth) adds contact shade where a nearer petal overlaps.
    static func scene(_ pose: Pose, placement: Placement, samples: Int) -> Raster {
        let ss = min(max(1, samples), maxSamples)
        let w = placement.width * ss, h = placement.height * ss
        let m = mesh(bloom: pose.bloom, breath: pose.breath)
        // The turn repeats every quarter, so the loop's end renders exactly its start.
        let turn = Float(pose.turn.truncatingRemainder(dividingBy: symmetry))
        let ct = cos(turn), st = sin(turn)
        let cam = placement.camera ?? camera(placement.view, placement, scale: Float(pose.scale))
        let camera = cam.eye
        let forward = normalize(cam.lookAt - cam.eye)
        let right = normalize(cross(forward, SIMD3<Float>(0, 1, 0))), upC = cross(right, forward)
        let focal = cam.focal * Float(ss)
        let cx = cam.centreX * Float(ss), cy = cam.centreY * Float(ss)
        // The light's frame, for the shadow map: an orthographic view along the key light.
        let lz = key, lx = normalize(cross(SIMD3<Float>(0, 1, 0), lz)), ly = cross(lz, lx)
        let shadowSize = shadowSize(radius: Float(placement.radius) * Float(ss))
        let texels = Float(shadowSize) / (2 * shadowReach * Float(pose.scale))
        let bias = m.layer.map { Float($0) * layerBias }

        // Vertices: turn, shade, project to the screen and to the light. Channels: the key light's share (shadowed),
        // the rest (ambient, rim, edge), and the light-space x, y and depth.
        let count = m.positions.count
        let nc = 5
        let sx = Scratch<Float>(count, 0), sy = Scratch<Float>(count, 0), sz = Scratch<Float>(count, 0)
        let mx = Scratch<Float>(count, 0), my = Scratch<Float>(count, 0), mz = Scratch<Float>(count, 0)
        let attr = Scratch<Float>(count * nc, 0)
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
            let d = p - camera
            let z = dot(d, forward)
            // Near-plane rejection: a vertex in or behind the camera plane has no screen position, and `raster` drops
            // every triangle that uses it.
            sx[i] = z > nearPlane ? cx + focal * dot(d, right) / z : .nan
            sy[i] = z > nearPlane ? cy - focal * dot(d, upC) / z : .nan
            sz[i] = z
            let t = p - target
            mx[i] = (dot(t, lx) / (2 * shadowReach * Float(pose.scale)) + 0.5) * Float(shadowSize)
            my[i] = (0.5 - dot(t, ly) / (2 * shadowReach * Float(pose.scale))) * Float(shadowSize)
            mz[i] = -dot(t, lz) * texels
            attr[i * nc] = direct; attr[i * nc + 1] = ambient
            attr[i * nc + 2] = mx[i]; attr[i * nc + 3] = my[i]
            // Slope-scaled bias: a face lit at a grazing angle changes depth fast across a texel.
            let cosL = max(0.15, abs(lambert))
            attr[i * nc + 4] = mz[i] - (1 + 2.5 * (1 - cosL * cosL).squareRoot() / cosL)
        }

        // The shadow map, depth in texel units so the bias reads in texels.
        let map = raster(width: shadowSize, height: shadowSize, x: mx, y: my, z: mz, attr: Scratch(0, 0), channels: 0,
                         indices: m.indices, bias: [])
        let r = raster(width: w, height: h, x: sx, y: sy, z: sz, attr: attr, channels: nc, indices: m.indices, bias: bias)

        // Depth darkening: a sample behind its neighbourhood's mean depth sits under a nearer petal's edge.
        let radius = max(2, Int(Float(placement.radius) * Float(ss) * 0.05))
        let occlusion = darkening(r.depth, width: w, height: h, radius: radius, reach: 0.12)
        // The key light's share per sample: bilinear over the map's four nearest texels, then blurred twice in screen
        // space, so a petal's shadow on the one beneath has a soft edge.
        let sm = shadowSize
        let litBuffer = Scratch<Float>(w * h, 1)
        withExtendedLifetime((litBuffer, r, map)) {
            let lit = litBuffer.buffer, at = r.attrs.buffer, id = r.id.buffer
            do {
                do {
                    do { let md = map.depth.buffer
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
        withExtendedLifetime((litBuffer, r, occlusion)) {
            boxBlur(litBuffer.buffer, width: w, height: h, radius: soft)
            boxBlur(litBuffer.buffer, width: w, height: h, radius: soft)
            let lit = litBuffer.buffer, at = r.attrs.buffer, id = r.id.buffer, occ = occlusion.buffer
            for k in 0..<(w * h) where id[k] >= 0 {
                let a = k * nc
                at[a] = (at[a + 1] + at[a] * (0.35 + 0.65 * lit[k])) * (1 - 0.5 * occ[k])
            }
        }
        return r
    }

    /// Renders `pose` with `samples` x `samples` samples a cell, down to one tone and one coverage value per cell.
    /// A canvas `renderable` refuses gives an empty shot, 0 x 0.
    public static func render(_ pose: Pose, placement: Placement, samples: Int = 2) -> Shot {
        guard renderable(placement) else { return Shot(width: 0, height: 0, light: [], cover: []) }
        let (light, cover) = cells(pose, placement: placement, samples: samples)
        return Shot(width: placement.width, height: placement.height, light: Array(light), cover: Array(cover))
    }

    /// `render`'s tone and coverage in scratch, for the frame renders.
    /// Callers check `renderable` first; a canvas it refuses gives empty scratch.
    static func cells(_ pose: Pose, placement: Placement, samples: Int) -> (light: Scratch<Float>, cover: Scratch<Float>) {
        guard renderable(placement) else { return (Scratch(0, 0), Scratch(0, 0)) }
        let ss = min(max(1, samples), maxSamples)
        let light = Scratch<Float>(placement.width * placement.height, 0), cover = Scratch<Float>(placement.width * placement.height, 0)
        guard placement.width > 0, placement.height > 0 else { return (light, cover) }
        let r = scene(pose, placement: placement, samples: ss)
        withExtendedLifetime((r, light, cover)) {
            let w = r.width, nc = r.channels, id = r.id.buffer, attrs = r.attrs.buffer
            let lb = light.buffer, cb = cover.buffer
            let n = Float(ss * ss)
            for y in 0..<placement.height {
                for x in 0..<placement.width {
                    var sum: Float = 0, hit: Float = 0
                    for dy in 0..<ss {
                        let row = (y * ss + dy) * w + x * ss
                        for dx in 0..<ss where id[row + dx] >= 0 { sum += attrs[(row + dx) * nc]; hit += 1 }
                    }
                    let k = y * placement.width + x
                    cb[k] = hit / n
                    lb[k] = hit > 0 ? min(1, sum / hit) : 0
                }
            }
        }
        return (light, cover)
    }

    /// `body` over `cells`' tone and coverage, or nil for a canvas `renderable` refuses. The pointers are only valid
    /// inside `body`, which keeps their scratch mapped: a pointer taken from a `Scratch` must never outlive the last
    /// use of the `Scratch` itself.
    static func withCells<R>(_ pose: Pose, placement: Placement, samples: Int,
                             _ body: (_ light: UnsafeBufferPointer<Float>, _ cover: UnsafeBufferPointer<Float>) -> R?) -> R? {
        guard renderable(placement) else { return nil }
        let c = cells(pose, placement: placement, samples: samples)
        return withExtendedLifetime(c) { body(UnsafeBufferPointer(c.light.buffer), UnsafeBufferPointer(c.cover.buffer)) }
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
    static func darkening(_ depth: Scratch<Float>, width w: Int, height h: Int, radius r: Int, reach: Float) -> Scratch<Float> {
        let sum = Scratch<Float>(w * h, 0), hits = Scratch<Float>(w * h, 0), out = Scratch<Float>(w * h, 0)
        withExtendedLifetime((depth, sum, hits, out)) {
            let d = depth.buffer, sb = sum.buffer, hb = hits.buffer
            for k in 0..<(w * h) where d[k] < .infinity { sb[k] = d[k]; hb[k] = 1 }
            boxBlur(sb, width: w, height: h, radius: r)
            boxBlur(hb, width: w, height: h, radius: r)
            let ob = out.buffer
            for k in 0..<(w * h) where d[k] < .infinity && hb[k] > 0 {
                ob[k] = min(1, max(0, (d[k] - sb[k] / hb[k]) / reach))
            }
        }
        return out
    }

    /// A box filter of `radius` over `a` in place; the edges average what is there. Rows run over a sliding sum;
    /// columns slide a whole row of sums down the image, so both passes read memory in order.
    static func boxBlur(_ a: UnsafeMutableBufferPointer<Float>, width w: Int, height h: Int, radius r: Int) {
        guard w > 0, h > 0 else { return }
        let lineScratch = Scratch<Float>(w, 0), accScratch = Scratch<Float>(w, 0), outScratch = Scratch<Float>(w * h, 0)
        // The pointers below are into the scratch's pages, so the scratch stays mapped until the function returns.
        defer { withExtendedLifetime((lineScratch, accScratch, outScratch)) {} }
        let line = lineScratch.buffer, acc = accScratch.buffer, out = outScratch.buffer
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
        var count: Float = 0
        for y in 0..<min(r, h) { count += 1; for x in 0..<w { acc[x] += a[y * w + x] } }
        for y in 0..<h {
            if y + r < h { count += 1; let row = (y + r) * w; for x in 0..<w { acc[x] += a[row + x] } }
            if y - r - 1 >= 0 { count -= 1; let row = (y - r - 1) * w; for x in 0..<w { acc[x] -= a[row + x] } }
            let inv = 1 / count, row = y * w
            for x in 0..<w { out[row + x] = acc[x] * inv }
        }
        _ = a.update(fromContentsOf: out)
    }

    static func boxBlur(_ a: inout [Float], width w: Int, height h: Int, radius r: Int) {
        a.withUnsafeMutableBufferPointer { boxBlur($0, width: w, height: h, radius: r) }
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
    static func ink(light l: Float, cover c: Float, dark: Bool) -> Float {
        dark ? c * pow(l, 0.9) : c * (0.42 + 0.58 * pow(1 - l, 0.85))
    }

    /// The mask for `shot`: one byte a cell, row 0 at the top. With one ink a cell is on (255) where its ink beats the
    /// cell's Bayer threshold; with two, ground, deep (`deepAlpha`) and ink, dithered between neighbouring levels.
    /// `density` (0...1 a cell) thins the dots, `top` (0...2 a cell) caps the level and `cap` the mask value, as
    /// PictureInk does behind a reading column: a capped cell shows the ink nearer the ground, so text keeps its floor.
    public static func mask(_ shot: Shot, placement: Placement, dark: Bool, inks: Int,
                            density: [Float]? = nil, top: [Float]? = nil, cap: [UInt8]? = nil) -> [UInt8] {
        shot.light.withUnsafeBufferPointer { light in
            shot.cover.withUnsafeBufferPointer { cover in
                mask(light: light, cover: cover, placement: placement, dark: dark, inks: inks, density: density, top: top, cap: cap)
            }
        }
    }

    static func mask(light: UnsafeBufferPointer<Float>, cover: UnsafeBufferPointer<Float>, placement: Placement, dark: Bool, inks: Int,
                     density: [Float]? = nil, top: [Float]? = nil, cap: [UInt8]? = nil) -> [UInt8] {
        let w = placement.width, h = placement.height
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let b = ((y + placement.originY) & 7) * 8
            for x in 0..<w {
                let k = y * w + x
                let threshold = (Float(DitherArt.bayer[b + ((x + placement.originX) & 7)]) + 0.5) / 64
                let v = ink(light: light[k], cover: cover[k], dark: dark) * (density?[k] ?? 1)
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
    /// Fixed numbers, since measuring takes about 50 renders: `measureReach(rest)` and `measureReach(bloomView)`, which
    /// `LotusPlacementTests.reachCoversEveryFrame` checks against these.
    public static let reach = (left: 1.05, right: 1.05, up: 0.65, down: 0.95)
    /// `reach` for the opening's bloom above the composer.
    static let bloomReach = (left: 1.0333, right: 1.0333, up: 0.7167, down: 0.9167)

    static func measureReach(_ view: View) -> (left: Double, right: Double, up: Double, down: Double) {
        let r = 60.0, side = 320, c = 160.0
        let probe = Placement(width: side, height: side, centreX: c, centreY: c, radius: r, view: view)
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
        return ((c - Double(x0) + margin) / r, (Double(x1) - c + margin) / r, (c - Double(y0) + margin) / r, (Double(y1) - c + margin) / r)
    }

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
                             top: [Float]? = nil, cap: [UInt8]? = nil, samples: Int = 2, parallel: Bool = true,
                             stop: (@Sendable () -> Bool)? = nil) -> [CGImage]? {
        each(poses.count, parallel: parallel, stop: stop) { i in
            withCells(poses[i], placement: placement, samples: samples) { light, cover in
                image(mask(light: light, cover: cover, placement: placement,
                           dark: dark, inks: inks, density: density, top: top, cap: cap), width: placement.width, height: placement.height)
            }
        }
    }

    /// Two-ink masks packed four cells a byte (`pack`), for a loop that shows one frame at a time.
    public static func packedMasks(_ poses: [Pose], placement: Placement, dark: Bool, samples: Int = 2,
                                   parallel: Bool = true, stop: (@Sendable () -> Bool)? = nil) -> [[UInt8]]? {
        each(poses.count, parallel: parallel, stop: stop) { i in
            withCells(poses[i], placement: placement, samples: samples) { light, cover in
                pack(codes(light: light, cover: cover, placement: placement, dark: dark))
            }
        }
    }

    /// `make` for 0..<count, or nil if any returned nil or `stop` said so between frames.
    static func each<T>(_ count: Int, parallel: Bool, stop: (@Sendable () -> Bool)? = nil, _ make: @escaping (Int) -> T?) -> [T]? {
        nonisolated(unsafe) let out = UnsafeMutableBufferPointer<T?>.allocate(capacity: count)
        out.initialize(repeating: nil)
        defer { out.deinitialize(); out.deallocate() }
        // Each worker's freed arrays stay with malloc, so fewer workers keep less: four cost about a third more time
        // than one a core and keep a third of the memory.
        let workers = parallel ? Swift.min(renderWorkers, count) : 1
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: count, by: workers) {
                if stop?() == true { return }
                out[i] = make(i)
            }
        }
        let all = out.compactMap { $0 }
        return all.count == count ? all : nil
    }

    /// How many threads render a sequence at once.
    nonisolated(unsafe) static var renderWorkers = 4

    /// Cell codes (`codes`) at two bits a cell, four cells a byte, low bits first.
    public static func pack(_ codes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (codes.count + 3) / 4)
        for (k, v) in codes.enumerated() where v != 0 { out[k >> 2] |= (v & 3) << UInt8((k & 3) * 2) }
        return out
    }

    /// `pack` undone, for `count` cells.
    public static func unpack(_ packed: [UInt8], count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { o in
            packed.withUnsafeBufferPointer { p in
                for k in 0..<count { o[k] = (p[k >> 2] >> UInt8((k & 3) * 2)) & 3 }
            }
        }
        return out
    }

    // MARK: The field

    /// What a cell of the flower shows: nothing, the flower with no dot (it still hides the field, so the lotus is
    /// solid; the user once called a see-through lotus "dumb"), the deep ink, or the ink.
    public enum Code { public static let empty: UInt8 = 0, covered: UInt8 = 1, deep: UInt8 = 2, ink: UInt8 = 3 }
    /// A code's share of the ink, as the shown mask holds it.
    static let codeAlpha: [UInt8] = [0, 0, deepAlpha, 255]

    /// The two-ink mask as codes.
    static func codes(light: UnsafeBufferPointer<Float>, cover: UnsafeBufferPointer<Float>, placement: Placement, dark: Bool,
                      density: [Float]? = nil) -> [UInt8] {
        var out = mask(light: light, cover: cover, placement: placement, dark: dark, inks: 2, density: density)
        for k in out.indices {
            out[k] = out[k] == 255 ? Code.ink : out[k] != 0 ? Code.deep : cover[k] > 0 ? Code.covered : Code.empty
        }
        return out
    }

    /// The field behind the lotus: the Gradient background's dots (the user, 2026-11-21: "i like the gradient so put it
    /// in flower too and then remove gradient"), its field (`DitherArt.gradientField`) across the content area, at
    /// full strength along the top edge (the user: "it should fully commit even at the top") and thinning toward the
    /// bottom, where the flower is, to `fieldFloor` of it. 1 where a dot shows, one byte a cell of `full`, on the same
    /// Bayer grid as the flower, at loop time `t` (0...1).
    public static func field(_ full: Placement, t: Double, dark: Bool = true) -> [UInt8] {
        let w = full.width, h = full.height
        var out = [UInt8](repeating: 0, count: w * h)
        let row = (0..<w).map { DitherArt.gradientField((Double($0) + 0.5) / Double(w), t) * fieldDensity }
        let least = fieldLeast(dark: dark)
        for y in 0..<h {
            let fall = 1 - (1 - fieldFloor) * (Double(y) + 0.5) / Double(h), b = ((y + full.originY) & 7) * 8
            for x in 0..<w where Swift.max(row[x] * fall, least) > (Double(DitherArt.bayer[b + ((x + full.originX) & 7)]) + 0.5) / 64 {
                out[y * w + x] = 1
            }
        }
        return out
    }

    /// The share of Gradient's density the field keeps, so the lotus stays the brighter, clearer thing.
    public static let fieldDensity = 0.5
    /// The field's strength at the bottom edge, as a share of the top's.
    static let fieldFloor = 0.35
    /// The field's least density. Light's ground shows between the petals: the field thins to about 4% at the bottom
    /// right, and there the bare off-white gaps beside the tinted petals looked cut out (the 1.17.0 walk). Dark's
    /// thin field reads as the black ground, so it keeps none.
    static func fieldLeast(dark: Bool) -> Double { dark ? 0 : 0.14 }
    /// The field's share of the ink: about Gradient's own cell color (36% of the accent over the ground in dark), and in
    /// light about its 32% under the flower's faintness.
    public static func fieldAlpha(dark: Bool) -> UInt8 { dark ? 92 : 150 }

    /// One shown frame over `full`'s cells: the field, then the flower's `codes` on `flower` (a canvas inside `full`, or
    /// `full` itself) over it, a covered cell hiding the field.
    public static func compose(codes: [UInt8]?, flower: Placement, full: Placement, field: [UInt8]?, fieldAlpha: UInt8) -> [UInt8] {
        let w = full.width
        var out = [UInt8](repeating: 0, count: w * full.height)
        if let field { for k in out.indices where field[k] != 0 { out[k] = fieldAlpha } }
        guard let codes else { return out }
        let dx = flower.originX - full.originX, dy = flower.originY - full.originY
        for y in 0..<flower.height {
            let fy = y + dy
            guard fy >= 0, fy < full.height else { continue }
            for x in 0..<flower.width {
                let c = codes[y * flower.width + x], fx = x + dx
                guard c != 0, fx >= 0, fx < w else { continue }
                out[fy * w + fx] = codeAlpha[Int(c)]
            }
        }
        return out
    }

    /// The content area's whole canvas: the field and the flower's every position on it.
    public static func fullCanvas(content: CGRect, cell: CGFloat = 3) -> Placement? {
        guard cell.isFinite, cell >= 0.5, let spot = spot(in: content) else { return nil }
        let x0 = (content.minX / cell).rounded(.down), y0 = (content.minY / cell).rounded(.down)
        let x1 = (content.maxX / cell).rounded(.up), y1 = (content.maxY / cell).rounded(.up)
        guard x1 > x0, y1 > y0, x1 - x0 <= CGFloat(maxSide), y1 - y0 <= CGFloat(maxSide) else { return nil }
        let p = Placement(width: Int(x1 - x0), height: Int(y1 - y0), centreX: Double(spot.centre.x / cell - x0),
                          centreY: Double(spot.centre.y / cell - y0), radius: Double(spot.radius / cell), originX: Int(x0), originY: Int(y0))
        return renderable(p) ? p : nil
    }

    // MARK: Placement

    /// Which page the flower sits on. Both place it the same; the new thread turns it and a thread holds it still.
    public enum Kind: Hashable, Sendable { case hero, thread }

    /// Composition 2, "Low and cropped" (the user, 2026-11-21: "it needs to be a background not a fancy prop"): centred
    /// across the content area, its centre just below the bottom edge, so only its upper half rises from the bottom
    /// like a horizon, and wider than the area. Shares of the content area, and of `fillUnit` for the radius.
    public static let composition = (x: 0.5, y: 1.02, radius: 0.66)
    /// The area shape the composition was drawn for, width over height. A narrower area scales the flower by its height
    /// instead, the way a picture that fills the area would.
    public static let referenceAspect: CGFloat = 1180.0 / 900.0

    /// Where the open flower sits: its centre and radius in points, same space as the content area.
    public struct Spot: Equatable, Sendable {
        public var centre: CGPoint
        public var radius: CGFloat
        public init(centre: CGPoint, radius: CGFloat) { self.centre = centre; self.radius = radius }
    }

    /// The flower for a content area in points (top left origin, y down), or nil when the area is empty.
    public static func spot(in content: CGRect) -> Spot? {
        guard content.width >= 1, content.height >= 1,
              [content.minX, content.minY, content.width, content.height].allSatisfy({ $0.isFinite && abs($0) <= 1e7 }) else { return nil }
        let unit = Swift.max(content.width, content.height * referenceAspect)
        return Spot(centre: CGPoint(x: content.minX + composition.x * content.width, y: content.minY + composition.y * content.height),
                    radius: composition.radius * unit)
    }

    /// The canvas for a content area in points: the area's cells on the art's `cell` lattice that any bloom or idle
    /// frame can cover, so nothing outside the area renders or is stored. Nil when that is nothing.
    public static func canvas(content: CGRect, cell: CGFloat = 3) -> Placement? {
        guard cell.isFinite, cell >= 0.5, let spot = spot(in: content) else { return nil }
        let x0 = Int((content.minX / cell).rounded(.down)), y0 = Int((content.minY / cell).rounded(.down))
        let x1 = Int((content.maxX / cell).rounded(.up)), y1 = Int((content.maxY / cell).rounded(.up))
        var p = placement(panelWidth: x1 - x0, panelHeight: y1 - y0, centreX: Double(spot.centre.x / cell) - Double(x0),
                          centreY: Double(spot.centre.y / cell) - Double(y0), radius: Double(spot.radius / cell))
        guard p.width > 0, p.height > 0, renderable(p) else { return nil }
        p.originX += x0; p.originY += y0
        return p
    }

    // MARK: The new thread's opening

    /// The new thread opens in two beats (the user, 2026-11-21: "what if it bloomed here then liked move to the bottom
    /// position", "in a 3d space not just moving and growing a 2d gif"): the bloom above the composer as 1.16.0 had it,
    /// a short hold, then the camera flies in and down around the flower to the resting view while the flower turns a
    /// little on its own axis. Every frame renders from the model at that frame's camera, so near petals grow faster
    /// than far ones and petals uncover each other. The path's key values, in one place to tune.
    public struct Flight: Sendable {
        /// Seconds between the bloom's end and the move, and the move's length.
        public var hold = 0.15, duration = 0.85
        public var fps = 30.0
        /// The flower's turn about its own axis over the move, radians; it ends at the idle turn's start.
        public var yaw = 30 * Double.pi / 180
        /// How far the eye's path sags below the straight line between its ends at a third and two thirds of the way,
        /// and how far the look-at point lifts mid-way, flower units.
        public var dip: Float = 1.0, lift: Float = 0.25
    }
    public static let flight = Flight()
    /// Coming back to the new-thread page within this many seconds shows the flower at rest, with no opening.
    public static let replayInterval: TimeInterval = 30

    /// The opening's geometry: the content area's full canvas, which the bloom and the move render on, with the flower
    /// at rest on it; the bloom on the same canvas, seen from `bloomView` above the composer; and the bloom box's
    /// bottom row, where 1.16.0 thinned the dots toward the composer.
    public struct Opening: Hashable, Sendable {
        public var canvas: Placement
        public var bloom: Placement
        public var bloomBottom: Double
    }

    /// The opening for a content area and the top of the composer and its pills, points from the top left. Nil when the
    /// bloom would be smaller than 1.16.0's smallest flower; the page then blooms at rest.
    public static func opening(content: CGRect, floorTop: CGFloat, cell: CGFloat = 3) -> Opening? {
        // 1.16.0: centred across, centred down the free run from below the band to 24pt above the composer group, at
        // most 288pt and at least 60pt in radius.
        let gap: CGFloat = 24, top = content.minY + 76
        let e = bloomReach
        let w = CGFloat(e.left + e.right), h = CGFloat(e.up + e.down)
        let r = Swift.min(288, (content.width - 2 * gap) / w, (floorTop - gap - top) / h)
        guard r >= 60 else { return nil }
        let bx = content.midX - CGFloat(e.right - e.left) * r / 2
        let by = top + (floorTop - gap - top - h * r) / 2 + CGFloat(e.up) * r
        guard let canvas = fullCanvas(content: content, cell: cell) else { return nil }
        let x0 = CGFloat(canvas.originX), y0 = CGFloat(canvas.originY)
        var bloom = canvas
        bloom.centreX = Double(bx / cell - x0); bloom.centreY = Double(by / cell - y0); bloom.radius = Double(r / cell)
        bloom.view = bloomView
        return Opening(canvas: canvas, bloom: bloom, bloomBottom: Double((by + CGFloat(e.down) * r) / cell - y0))
    }

    /// The opening's bloom: today's bloom poses turned back by the move's yaw, then the open flower held.
    public static func openingBloomPoses() -> [Pose] {
        (bloomPoses() + [openPose]).map { var p = $0; p.turn -= flight.yaw; return p }
    }

    /// 1.16.0's thinning toward the composer, at `share` of its strength: full at the flower's middle, a third of the
    /// dots at the bloom box's bottom.
    static func openingDensity(_ o: Opening, share: Float) -> [Float]? {
        guard share > 0 else { return nil }
        let p = o.canvas
        var d = [Float](repeating: 1, count: p.width * p.height)
        for y in 0..<p.height {
            let t = smooth(Float(o.bloom.centreY + 0.15 * o.bloom.radius), Float(o.bloomBottom), Float(y) + 0.5)
            let v = 1 - 0.65 * t * share
            for x in 0..<p.width { d[y * p.width + x] = v }
        }
        return d
    }

    /// The move's frames between the bloom's last and the resting frame, both excluded: the pose and a canvas with its
    /// own camera. The eye runs a cubic curve from the bloom's camera to the resting one, sagging below the straight
    /// line; the look-at point lifts and comes back; the lens follows so the flower's size at the look-at point grows
    /// geometrically; the lens shift slides from the bloom's spot to the resting one; the flower turns `yaw` into place.
    public static func flightFrames(_ o: Opening) -> [(pose: Pose, placement: Placement, thinning: Float)] {
        let f = flight
        let n = Swift.max(2, Int((f.duration * f.fps).rounded()))
        let a = camera(o.bloom.view, o.bloom, scale: 1), b = camera(rest, o.canvas, scale: 1)
        let down = SIMD3<Float>(0, -f.dip, 0), up = SIMD3<Float>(0, f.lift, 0)
        let c1 = a.eye + (b.eye - a.eye) / 3 + down, c2 = a.eye + (b.eye - a.eye) * 2 / 3 + down
        func bezier(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            let u = 1 - t
            return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
        }
        let ra = Float(o.bloom.radius), rb = Float(o.canvas.radius)
        return (1..<n).map { k in
            let t = Float(k) / Float(n)
            // Ease in and out (smootherstep), so the camera leaves and lands at rest.
            let s = t * t * t * (t * (t * 6 - 15) + 10)
            let eye = bezier(a.eye, c1, c2, b.eye, s)
            let look = bezier(a.lookAt, a.lookAt + up, b.lookAt + up, b.lookAt, s)
            let radius = ra * pow(rb / ra, s)
            let distance = (eye - look).squareRootLength
            let cam = Camera(eye: eye, lookAt: look, focal: radius / openRadius * distance,
                             centreX: a.centreX + (b.centreX - a.centreX) * s, centreY: a.centreY + (b.centreY - a.centreY) * s)
            var p = o.canvas
            p.radius = Double(radius); p.camera = cam
            return (Pose(bloom: 1, turn: -f.yaw * Double(1 - s)), p, 1 - s)
        }
    }

    /// Frames that each have their own pose and canvas, rendered from the model as packed codes (`pack`), or nil if
    /// `stop` said so.
    public static func packedFrames(_ frames: [(pose: Pose, placement: Placement)], dark: Bool, density: @escaping @Sendable (Int) -> [Float]?,
                                    samples: Int = 2, stop: (@Sendable () -> Bool)? = nil) -> [[UInt8]]? {
        nonisolated(unsafe) let frames = frames
        return each(frames.count, parallel: true, stop: stop) { i in
            let (pose, p) = frames[i]
            return withCells(pose, placement: p, samples: samples) { light, cover in
                pack(codes(light: light, cover: cover, placement: p, dark: dark, density: density(i)))
            }
        }
    }

    /// Packed codes on `flower` (a canvas inside `full`) over the field at `t`, as the images that show, across the cores.
    public static func images(_ packed: [[UInt8]], flower: Placement, full: Placement, t: Double, dark: Bool,
                              stop: (@Sendable () -> Bool)? = nil) -> [CGImage]? {
        each(packed.count, parallel: true, stop: stop) { i in frame(packed: packed[i], flower: flower, full: full, t: t, dark: dark) }
    }

    /// One shown frame from packed codes: `image(compose(codes: unpack(packed), …, field: field(full, t:, dark:)))` in
    /// one pass, written straight into the image's buffer. The turn shows one ten times a second on the main thread.
    public static func frame(packed: [UInt8], flower: Placement, full: Placement, t: Double, dark: Bool) -> CGImage? {
        let w = full.width, h = full.height
        guard w > 0, h > 0, packed.count * 4 >= flower.width * flower.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        let row = (0..<w).map { DitherArt.gradientField((Double($0) + 0.5) / Double(w), t) * fieldDensity }
        let least = fieldLeast(dark: dark), ground = fieldAlpha(dark: dark), fw = flower.width
        let dx = flower.originX - full.originX, dy = flower.originY - full.originY
        let alphas = codeAlpha
        packed.withUnsafeBufferPointer { pk in
            for y in 0..<h {
                let fall = 1 - (1 - fieldFloor) * (Double(y) + 0.5) / Double(h), b = ((y + full.originY) & 7) * 8
                let fy = y - dy, inFlower = fy >= 0 && fy < flower.height
                for x in 0..<w {
                    let k = y * w + x, fx = x - dx
                    if inFlower, fx >= 0, fx < fw {
                        let i = fy * fw + fx, c = (pk[i >> 2] >> UInt8((i & 3) * 2)) & 3
                        if c != 0 { data[k] = alphas[Int(c)]; continue }
                    }
                    let shows = Swift.max(row[x] * fall, least) > (Double(DitherArt.bayer[b + ((x + full.originX) & 7)]) + 0.5) / 64
                    data[k] = shows ? ground : 0
                }
            }
        }
        return ctx.makeImage()
    }

    // MARK: Behind the reading column

    /// How the flower thins and dims behind a thread's reading column (the user, of the same problem on Picture: "more
    /// blacker near the middle subtly so its not super obvious"): the share of dots kept over the column, and how far
    /// beside it the effect eases out, in points. Light eases out over a much wider run, so no cut-out shape reads on
    /// the pale ground.
    public static let columnKeep: Float = 0.3
    public static func columnReach(dark: Bool) -> CGFloat { dark ? 240 : 900 }
    /// How far past the column's sides the full effect holds, points.
    public static let columnPad: CGFloat = 20

    /// Text floors over the worst cell behind the column: body and muted text, dark and light.
    public static func textFloors(dark: Bool) -> (body: Double, muted: Double) { dark ? (12, 6) : (7, 4.5) }

    /// The highest share of the ink (0...1) a cell behind the column may show, with the flower layer at `opacity`, so
    /// `text` and `muted` keep `textFloors` over the ink at that share over `ground`. Colors are gamma-encoded sRGB,
    /// mixed as the layers composite.
    public static func columnCap(ground: SIMD3<Double>, ink: SIMD3<Double>, text: SIMD3<Double>, muted: SIMD3<Double>,
                                 opacity: Double, dark: Bool) -> Float {
        let floors = textFloors(dark: dark)
        var best: Float = 0
        for step in 0...255 {
            let a = Double(step) / 255 * opacity
            let bg = PictureInk.luminance(ground + (ink - ground) * a)
            guard PictureInk.contrast(bg, PictureInk.luminance(text)) >= floors.body,
                  PictureInk.contrast(bg, PictureInk.luminance(muted)) >= floors.muted else { break }
            best = Float(step) / 255
        }
        return best
    }

    /// The still mask over the flower for a column spanning `column` (points, the art's x), one byte a cell over
    /// `placement`: full over the flower far from the column, easing down to `cap` of the ink and `columnKeep` of the
    /// dots over it. Dots drop by a fixed hash per cell, not the Bayer matrix the flower dithers with, so thinning
    /// never lines up with the flower's own pattern. The flower's frames never change for it. `keep` is the share of
    /// dots kept over the column, `columnKeep` unless "Dim behind text" moved it (`TextDim`).
    public static func columnMask(_ p: Placement, column: ClosedRange<CGFloat>, cap: Float, keep columnKeep: Float = columnKeep,
                                  dark: Bool, cell: CGFloat = 3) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: p.width * p.height)
        let reach = Float(columnReach(dark: dark))
        let lo = Float(column.lowerBound - columnPad), hi = Float(column.upperBound + columnPad)
        var level = [Float](repeating: 1, count: p.width), keep = level
        for x in 0..<p.width {
            let px = (Float(p.originX + x) + 0.5) * Float(cell)
            let d = px < lo ? lo - px : px > hi ? px - hi : 0
            let g = smooth(0, 1, 1 - d / reach)
            level[x] = 1 - (1 - cap) * g
            keep[x] = 1 - (1 - columnKeep) * g
        }
        for y in 0..<p.height {
            for x in 0..<p.width {
                var h = UInt32(truncatingIfNeeded: (p.originX + x) &* 73_856_093 ^ (p.originY + y) &* 19_349_663)
                h ^= h >> 16; h = h &* 0x7FEB_352D; h ^= h >> 15
                let noise = Float(h & 0xFFFF) / 65536
                out[y * p.width + x] = noise < keep[x] ? UInt8((level[x] * 255).rounded()) : 0
            }
        }
        return out
    }

    /// Cells a pixel of the glass's glow: a quarter of the dots' resolution, which a wide blur never misses.
    public static let glowScale = 4

    /// A soft copy of `mask` (optionally times `over`, both one byte a cell over `p`) for what shows through a surface
    /// over the flower: averaged over `scale` x `scale` cells, then three box passes of `radius` points, which come
    /// close to a Gaussian. One byte a pixel at `scale` cells a pixel; the layer scales it up smoothly.
    public static func glow(_ mask: [UInt8], over: [UInt8]?, placement p: Placement, radius: CGFloat, scale: Int = 2,
                            cell: CGFloat = 3) -> (pixels: [UInt8], width: Int, height: Int) {
        let w = (p.width + scale - 1) / scale, h = (p.height + scale - 1) / scale
        guard w > 0, h > 0 else { return ([], 0, 0) }
        var a = [Float](repeating: 0, count: w * h)
        for y in 0..<p.height {
            for x in 0..<p.width {
                let k = y * p.width + x
                let v = Float(mask[k]) * (over.map { Float($0[k]) / 255 } ?? 1)
                a[(y / scale) * w + x / scale] += v / Float(scale * scale)
            }
        }
        // Three box passes of radius r come to a Gaussian of sigma about r: `radius` is the sigma.
        let r = Swift.max(1, Int((radius / (cell * CGFloat(scale))).rounded()))
        for _ in 0..<3 { boxBlur(&a, width: w, height: h, radius: r) }
        return (a.map { UInt8(Swift.min(255, Swift.max(0, $0)).rounded()) }, w, h)
    }
}

/// Render scratch on its own pages, which go back to the system the moment it goes. The renders' buffers came from
/// malloc before, which kept them dirty after they were freed: one 1440 x 900 flower set left about 200 MB behind
/// (measured 2026-11-21; `malloc_zone_pressure_relief` returned none of it). Trivial element types only.
final class Scratch<T>: @unchecked Sendable, RandomAccessCollection, MutableCollection {
    let buffer: UnsafeMutableBufferPointer<T>
    private let size: Int

    init(_ count: Int, _ value: T) {
        size = Swift.max(1, count * MemoryLayout<T>.stride)
        guard let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), raw != MAP_FAILED else {
            fatalError("LotusArt scratch: mmap of \(size) bytes failed")
        }
        buffer = UnsafeMutableBufferPointer(start: raw.bindMemory(to: T.self, capacity: count), count: count)
        // Fresh anonymous pages read as zero, so a plain value whose bytes are all zero is already there. Writing it
        // again touched every page twice, about a sixth of a frame's render.
        if !(_isPOD(T.self) && withUnsafeBytes(of: value, { $0.allSatisfy { $0 == 0 } })) { buffer.initialize(repeating: value) }
    }

    deinit { munmap(UnsafeMutableRawPointer(buffer.baseAddress), size) }

    var startIndex: Int { 0 }
    var endIndex: Int { buffer.count }
    subscript(i: Int) -> T {
        get { buffer[i] }
        set { buffer[i] = newValue }
    }
}

extension SIMD3 where Scalar == Float {
    var squareRootLength: Float { (self * self).sum().squareRoot() }
}
