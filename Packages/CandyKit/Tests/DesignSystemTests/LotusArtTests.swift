import CoreGraphics
import Testing

@testable import DesignSystem

/// The Flower background's renderer (stage 1): geometry, the bloom's silhouettes, deterministic masks, the seamless
/// idle loop and the byte budget.
struct LotusArtTests {
    private func box(_ shot: LotusArt.Shot) -> (x0: Int, x1: Int, y0: Int, y1: Int, cells: Int) {
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min, cells = 0
        for y in 0..<shot.height {
            for x in 0..<shot.width where shot.cover[y * shot.width + x] > 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y); cells += 1
            }
        }
        return (x0, x1, y0, y1, cells)
    }

    /// The opening's bloom view, the camera every frame used before the flower became a background.
    private let place = LotusArt.Placement(width: 120, height: 90, centreX: 60, centreY: 46, radius: 44, view: LotusArt.bloomView)

    @Test func geometryIsDeterministic() {
        let a = LotusArt.mesh(bloom: 0.6, breath: 0.3), b = LotusArt.mesh(bloom: 0.6, breath: 0.3)
        #expect(a.positions == b.positions)
        #expect(a.normals == b.normals)
        #expect(a.indices == b.indices)
        // The petals, the seed pod and the receptacle under them.
        let petals = LotusArt.rings.reduce(0) { $0 + $1.count } + 2
        #expect(a.triangles == petals * LotusArt.trianglesPerPetal)
        #expect(a.layer.count == petals)
        // Every ring repeats each quarter, which the seamless idle turn relies on.
        #expect(LotusArt.rings.allSatisfy { $0.count % 8 == 0 })
    }

    @Test func bloomOpensAroundAFixedCentre() {
        let bud = box(LotusArt.render(LotusArt.Pose(bloom: 0), placement: place, samples: 1))
        let open = box(LotusArt.render(LotusArt.Pose(bloom: 1), placement: place, samples: 1))
        // The open flower covers the bud's box and far more cells.
        #expect(open.x0 <= bud.x0 && open.x1 >= bud.x1 && open.y0 <= bud.y0 && open.y1 >= bud.y1)
        #expect(open.cells > 3 * bud.cells)
        #expect(open.x1 - open.x0 > 2 * (bud.x1 - bud.x0))
        // Both stay centred across.
        #expect(abs(Double(bud.x0 + bud.x1) / 2 - place.centreX) <= 2)
        #expect(abs(Double(open.x0 + open.x1) / 2 - place.centreX) <= 2)
    }

    @Test func petalsDoNotCutThroughEachOther() {
        // Slivers: a petal showing in pieces under 20 samples. On a 960 x 540 render the open and half-open flower show
        // about 60 to 70 (tips peeking between neighbours); petals that cut through each other showed 250 to 500.
        for bloom in [1.0, 0.6] {
            let r = LotusArt.scene(LotusArt.Pose(bloom: bloom, turn: 0.3),
                                   placement: LotusArt.Placement(width: 960, height: 540, centreX: 480, centreY: 286, radius: 380), samples: 1)
            let covered = r.id.filter { $0 >= 0 }.count
            #expect(LotusArt.slivers(r, limit: 20) < covered / 1500)
        }
    }

    @Test func masksAreDeterministicAndTheIdleLoopCloses() {
        let idle = LotusArt.idlePoses()
        func mask(_ pose: LotusArt.Pose) -> [UInt8] {
            LotusArt.mask(LotusArt.render(pose, placement: place, samples: 1), placement: place, dark: true, inks: 2)
        }
        let first = mask(idle[0])
        #expect(first == mask(idle[0]))
        // The pose after the last is the first: a quarter turn on, breath back at rest.
        var after = idle[0]
        after.turn = LotusArt.symmetry
        #expect(mask(after) == first)
        // The last frame steps into the first no further than one frame steps to the next.
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).filter { $0 != $1 }.count }
        let step = diff(first, mask(idle[1]))
        #expect(diff(mask(idle[idle.count - 1]), first) <= step * 2 + 10)
    }

    @Test func oneInkIsBinaryAndTwoInksHaveThreeLevels() {
        let shot = LotusArt.render(LotusArt.Pose(bloom: 1), placement: place, samples: 1)
        #expect(Set(LotusArt.mask(shot, placement: place, dark: true, inks: 1)) == [0, 255])
        #expect(Set(LotusArt.mask(shot, placement: place, dark: true, inks: 2)) == [0, LotusArt.deepAlpha, 255])
        #expect(Set(LotusArt.mask(shot, placement: place, dark: false, inks: 2)) == [0, LotusArt.deepAlpha, 255])
    }

    @Test func framesHoldTheBloomAndTheLoop() {
        let tiny = LotusArt.Placement(width: 40, height: 30, centreX: 20, centreY: 15, radius: 14)
        let f = LotusArt.frames(placement: tiny, dark: true, inks: 2, samples: 1)
        #expect(f.bloom.count == Int(LotusArt.bloomDuration * LotusArt.bloomFPS))
        #expect(f.idle.count == Int(LotusArt.idlePeriod * LotusArt.idleFPS))
        #expect(f.bloom.allSatisfy { $0.width == 40 && $0.height == 30 && $0.bitsPerPixel == 8 })
        #expect(f.bytes == (f.bloom.count + f.idle.count) * 40 * 30)
    }

    /// The new-thread page's flower at 1400 x 900pt (300pt radius on 3pt cells) and a full-width one stay under
    /// 20 MB of masks.
    @Test func frameSetStaysInTheByteBudget() {
        let frames = LotusArt.bloomPoses().count + LotusArt.idlePoses().count
        for radius in [100.0, 140.0] {
            let p = LotusArt.placement(panelWidth: 467, panelHeight: 300, centreX: 233, centreY: 85, radius: radius)
            #expect(p.width > 0 && p.height > 0)
            #expect(frames * p.width * p.height < 20 * 1_048_576)
        }
        // The canvas holds the whole open flower.
        let p = LotusArt.placement(panelWidth: 467, panelHeight: 300, centreX: 233, centreY: 120, radius: 60)
        let shot = LotusArt.render(LotusArt.Pose(bloom: 1), placement: p, samples: 1)
        let b = box(shot)
        #expect(b.x0 > 0 && b.y0 > 0 && b.x1 < p.width - 1 && b.y1 < p.height - 1)
    }
}

/// Where the flower sits: composition 2, "Low and cropped", for a table of windows, and what the canvas holds.
struct LotusPlacementTests {
    /// A Redesign window's content area as the thread panel reports it: from the window's top, left of the right panel.
    struct Window: CustomStringConvertible {
        var name: String
        var width: CGFloat, height: CGFloat
        var sidebar: CGFloat = 240
        var rightPanel: CGFloat = 0
        var description: String { name }
        var content: CGRect {
            CGRect(x: 0, y: 0, width: width - sidebar - (rightPanel > 0 ? rightPanel + 8 : 0), height: height)
        }
    }

    static let windows: [Window] = [
        Window(name: "default", width: 1440, height: 900),
        Window(name: "sidebar collapsed", width: 1400, height: 900, sidebar: 0),
        Window(name: "right panel", width: 1600, height: 900, rightPanel: 420),
        Window(name: "small", width: 1000, height: 700),
        Window(name: "cramped", width: 820, height: 560),
        Window(name: "wide", width: 2200, height: 1000),
        Window(name: "tall", width: 1100, height: 1300),
        Window(name: "short", width: 1400, height: 520),
        Window(name: "tiny", width: 560, height: 420),
    ]

    /// Centred across, its centre just under the bottom edge, wider than the area, at every size: it never hides.
    @Test(arguments: windows) func flowerRisesFromTheBottomEdge(_ w: Window) throws {
        let c = w.content
        let spot = try #require(LotusArt.spot(in: c))
        #expect(abs(spot.centre.x - c.midX) < 0.01)
        #expect(abs(spot.centre.y - (c.minY + 1.02 * c.height)) < 0.01)
        // It scales like a picture filling the area: by the width, or by the height on a narrow area.
        #expect(abs(spot.radius - 0.66 * max(c.width, c.height * LotusArt.referenceAspect)) < 0.01)
        // The open flower spans more than the area's width.
        let reach = (LotusArt.reach.left + LotusArt.reach.right) * Double(spot.radius)
        #expect(reach > Double(c.width), "\(w)")
    }

    /// The canvas covers only cells of the content area, only what any frame reaches, on the art's lattice, and the
    /// whole upper half of the flower is in it.
    @Test(arguments: windows) func canvasIsClippedToTheContentArea(_ w: Window) throws {
        var c = w.content
        c.origin.x = 31
        let p = try #require(LotusArt.canvas(content: c))
        #expect(p.originX >= Int((c.minX / 3).rounded(.down)) && p.originX + p.width <= Int((c.maxX / 3).rounded(.up)))
        #expect(p.originY >= 0 && p.originY + p.height <= Int((c.maxY / 3).rounded(.up)))
        // It runs off both sides and the bottom, so the canvas is the area's full width and reaches its bottom.
        #expect(p.originX == Int((c.minX / 3).rounded(.down)) && p.width == Int((c.maxX / 3).rounded(.up)) - p.originX)
        #expect(p.originY + p.height == Int((c.maxY / 3).rounded(.up)))
        // The flower's top stays in the area: the empty top of the page holds no cells.
        #expect(p.originY > 0, "\(w)")
        #expect(abs((Double(p.originY) + p.centreY) * 3 - (c.minY + 1.02 * c.height)) < 0.01)
    }

    /// The bottom of the open flower fills the area's bottom edge across most of its width.
    @Test func openFlowerFillsTheBottomEdge() throws {
        let c = CGRect(x: 0, y: 0, width: 600, height: 375)
        let p = try #require(LotusArt.canvas(content: c))
        let shot = LotusArt.render(LotusArt.openPose, placement: p, samples: 1)
        let row = p.height - 1
        let covered = (0..<p.width).filter { shot.cover[row * p.width + $0] > 0 }.count
        #expect(Double(covered) > 0.8 * Double(p.width))
        // And the top fifth of the area is empty.
        let topRows = Int(c.height / 3 / 5) - p.originY
        if topRows > 0 { #expect((0..<(topRows * p.width)).allSatisfy { shot.cover[$0] == 0 }) }
    }

    /// The fixed reach holds every bloom and idle frame, for both views, with at most a few cells to spare.
    @Test func reachCoversEveryFrame() {
        for (view, fixed) in [(LotusArt.rest, LotusArt.reach), (LotusArt.bloomView, LotusArt.bloomReach)] {
            let m = LotusArt.measureReach(view)
            for (a, b) in [(m.left, fixed.left), (m.right, fixed.right), (m.up, fixed.up), (m.down, fixed.down)] {
                #expect(a <= b + 0.001 && b - a < 0.05, "\(view): measured \(m), fixed \(fixed)")
            }
        }
    }

    /// The field: Gradient's dots from the area's top edge down, thinning toward the bottom, moving with the loop; composed under
    /// the flower, a covered cell (a petal with no dot there) hides it, so the lotus is solid.
    @Test func fieldSitsBehindASolidFlower() throws {
        let full = try #require(LotusArt.fullCanvas(content: CGRect(x: 0, y: 0, width: 600, height: 375)))
        let field = LotusArt.field(full, t: 0)
        #expect(Set(field).isSubset(of: [0, 1]))
        func dots(_ rows: Range<Int>) -> Int { field[(full.width * rows.lowerBound)..<(full.width * rows.upperBound)].filter { $0 == 1 }.count }
        // Strongest along the very top edge, with no empty rows there, and thinner at the bottom.
        #expect(dots(0..<1) > 0 && dots(1..<2) > 0)
        #expect(dots(0..<8) > dots((full.height - 8)..<full.height))
        #expect(LotusArt.field(full, t: 0.25) != field)
        // A flower canvas inside it, every cell covered with no dot: no field shows there.
        var flower = full
        flower.width = 20; flower.height = 10; flower.originX = full.originX + 30; flower.originY = full.originY + 2
        let covered = [UInt8](repeating: LotusArt.Code.covered, count: 200)
        let shown = LotusArt.compose(codes: covered, flower: flower, full: full, field: [UInt8](repeating: 1, count: field.count), fieldAlpha: 90)
        for y in 2..<12 { for x in 30..<50 { #expect(shown[y * full.width + x] == 0) } }
        #expect(shown[0] == 90)
    }

    /// The idle loop packs into a quarter of the bytes and unpacks exactly.
    @Test func packingIsLossless() {
        let p = LotusArt.Placement(width: 61, height: 23, centreX: 30, centreY: 22, radius: 20)
        let shot = LotusArt.render(LotusArt.openPose, placement: p, samples: 1)
        let codes = shot.light.withUnsafeBufferPointer { l in shot.cover.withUnsafeBufferPointer { c in
            LotusArt.codes(light: l, cover: c, placement: p, dark: true) } }
        #expect(Set(codes).isSuperset(of: [LotusArt.Code.covered, LotusArt.Code.ink]))
        let packed = LotusArt.pack(codes)
        #expect(packed.count == (61 * 23 + 3) / 4)
        #expect(LotusArt.unpack(packed, count: codes.count) == codes)
    }

    /// A 1440 x 900 window's new-thread flower stays well under 10 MB at rest: the open still, the packed idle loop and
    /// one expanded frame. The bloom (rendered per opening, dropped after) is the only larger part.
    @Test func restingFlowerStaysUnderTheBudget() throws {
        let p = try #require(LotusArt.canvas(content: CGRect(x: 0, y: 0, width: 1182, height: 900)))
        let cells = p.width * p.height
        let resting = cells + LotusArt.idlePoses().count * (cells + 3) / 4 + cells
        #expect(resting < 6 * 1_048_576)
        #expect(LotusArt.bloomPoses().count * cells < 5 * 1_048_576)
    }
}

/// Behind a thread's reading column: the still mask's falloff and the text floors it keeps.
struct LotusColumnTests {
    let ground = SIMD3<Double>(0.04, 0.04, 0.04), ink = SIMD3<Double>(0.545, 0.486, 0.965)
    let text = SIMD3<Double>(0.93, 0.93, 0.93), muted = SIMD3<Double>(0.62, 0.62, 0.62)

    @Test func capKeepsTheDarkTextFloors() {
        let cap = LotusArt.columnCap(ground: ground, ink: ink, text: text, muted: muted, opacity: 1, dark: true)
        #expect(cap > 0.1 && cap < 0.6)
        let worst = PictureInk.luminance(ground + (ink - ground) * Double(cap))
        #expect(PictureInk.contrast(worst, PictureInk.luminance(text)) >= 12)
        #expect(PictureInk.contrast(worst, PictureInk.luminance(muted)) >= 6)
    }

    /// Full far from the column, the cap and a third of the dots over it, and no step anywhere between.
    @Test func maskEasesWithNoEdge() {
        let p = LotusArt.Placement(width: 400, height: 40, centreX: 200, centreY: 60, radius: 200)
        let cap: Float = 0.3
        let m = LotusArt.columnMask(p, column: 450...750, cap: cap, dark: true)
        func row(_ x: Int) -> (kept: Double, level: UInt8) {
            let col = (0..<p.height).map { m[$0 * p.width + x] }
            return (Double(col.filter { $0 > 0 }.count) / Double(p.height), col.max() ?? 0)
        }
        #expect(row(200).level == UInt8((cap * 255).rounded()))
        #expect(row(0).level == 255 && row(0).kept == 1)
        var last = Int(row(0).level)
        for x in 1..<200 {
            let level = Int(row(x).level)
            #expect(abs(level - last) <= 4, "a step at x \(x)")
            last = level
        }
        let middle = (0..<p.height).flatMap { y in (190..<210).map { m[y * p.width + $0] } }
        let kept = Double(middle.filter { $0 > 0 }.count) / Double(middle.count)
        #expect(abs(kept - Double(LotusArt.columnKeep)) < 0.1)
    }

    /// Light's falloff runs far wider than dark's.
    @Test func lightFalloffIsWide() {
        #expect(LotusArt.columnReach(dark: false) >= 2 * LotusArt.columnReach(dark: true))
    }
}
