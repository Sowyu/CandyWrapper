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

    private let place = LotusArt.Placement(width: 120, height: 90, centreX: 60, centreY: 46, radius: 44)

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

/// Stage 2: where the flower sits, measured from real page geometry, for a table of windows.
struct LotusPlacementTests {
    /// A Redesign window as the thread panel reports it to the art, in the art's top-left space: the band at the top,
    /// the content area left of the right panel card, the 736pt lane centred in it, the composer and its pills.
    struct Window: CustomStringConvertible {
        var name: String
        var width: CGFloat, height: CGFloat
        var sidebar: CGFloat = 240
        var rightPanel: CGFloat = 0
        var description: String { name }

        var main: CGSize { CGSize(width: width - sidebar, height: height) }
        var content: CGRect {
            CGRect(x: 0, y: 52, width: main.width - (rightPanel > 0 ? rightPanel + 8 : 0), height: height - 52)
        }
        var lane: CGRect {
            let pad: CGFloat = width < 640 ? 12 : 48
            let w = min(736, content.width - 2 * pad)
            return CGRect(x: ((content.width - w) / 2).rounded(), y: content.minY, width: w, height: content.height)
        }
        /// The header pill, in the band at the right.
        var pill: CGRect { CGRect(x: main.width - 12 - 150, y: 12, width: 150, height: 28) }
        /// The new thread: the composer centred down the content area, the project chips 8pt above it.
        var heroKeepOut: [CGRect] {
            let composer = CGRect(x: lane.minX, y: (content.minY + (content.height - 132 - 20) / 2).rounded(), width: lane.width, height: 132)
            let chips = CGRect(x: lane.minX + 6, y: composer.minY - 8 - 26, width: 220, height: 26)
            return [composer, chips, pill]
        }
        /// A thread: the reading column down the whole content area, the composer docked at its foot.
        var threadKeepOut: [CGRect] {
            [lane, CGRect(x: lane.minX, y: content.maxY - 20 - 34 - 110, width: lane.width, height: 110), pill]
        }
    }

    static let windows: [Window] = [
        Window(name: "default", width: 1400, height: 900),
        Window(name: "sidebar collapsed", width: 1400, height: 900, sidebar: 0),
        Window(name: "sidebar wide", width: 1400, height: 900, sidebar: 380),
        Window(name: "right panel", width: 1600, height: 900, rightPanel: 420),
        Window(name: "small", width: 900, height: 640),
        Window(name: "cramped", width: 820, height: 560),
        Window(name: "wide", width: 2200, height: 1000),
        Window(name: "tall", width: 1100, height: 1300),
        Window(name: "short", width: 1400, height: 520),
        Window(name: "tiny", width: 560, height: 420),
    ]

    private func clear(_ spot: LotusArt.Spot, of keepOut: [CGRect], in content: CGRect) -> Bool {
        let box = spot.box
        let gap = LotusArt.clearance - 0.01
        return content.insetBy(dx: gap, dy: gap).contains(box) && keepOut.allSatisfy { !$0.insetBy(dx: -gap, dy: -gap).intersects(box) }
    }

    @Test(arguments: windows) func newThreadFlowerIsCentredAndClear(_ w: Window) {
        let stage = LotusArt.Stage(kind: .hero, content: w.content, keepOut: w.heroKeepOut)
        guard let spot = LotusArt.spot(for: stage) else {
            // Only a window too small for a flower at the minimum radius hides it.
            #expect(["tiny", "short", "cramped"].contains(w.name), "\(w)")
            return
        }
        #expect(clear(spot, of: w.heroKeepOut, in: w.content), "\(w): \(spot.box)")
        // Centred across the content area, not the window.
        #expect(abs(spot.box.midX - w.content.midX) < 0.5, "\(w)")
        // Centred down the free space between the band and the pills above the composer.
        let above = w.heroKeepOut[1].minY - LotusArt.clearance, below = w.content.minY + LotusArt.clearance
        #expect(abs(spot.box.midY - (above + below) / 2) < 1 || spot.radius == LotusArt.heroMaxRadius, "\(w)")
        #expect(spot.radius >= LotusArt.minRadius && spot.radius <= LotusArt.heroMaxRadius)
    }

    @Test(arguments: windows) func threadFlowerSitsInTheMarginOrHides(_ w: Window) {
        let stage = LotusArt.Stage(kind: .thread, content: w.content, keepOut: w.threadKeepOut)
        let margin = w.content.maxX - w.lane.maxX - 2 * LotusArt.clearance
        let needed = LotusArt.minRadius * (LotusArt.extent.left + LotusArt.extent.right)
        guard let spot = LotusArt.spot(for: stage) else {
            #expect(margin < needed, "\(w) hid with a \(margin)pt margin")
            return
        }
        #expect(margin >= needed - 1, "\(w)")
        #expect(clear(spot, of: w.threadKeepOut, in: w.content), "\(w): \(spot.box)")
        // Never behind the column, and at the top of the content area.
        #expect(spot.box.minX >= w.lane.maxX + LotusArt.clearance - 0.01)
        #expect(abs(spot.box.minY - (w.content.minY + LotusArt.clearance)) < 0.01)
        #expect(spot.radius <= LotusArt.threadMaxRadius)
    }

    @Test func expectedWindowsShowAFlower() {
        let shown = Self.windows.filter { LotusArt.spot(for: .init(kind: .hero, content: $0.content, keepOut: $0.heroKeepOut)) != nil }.map(\.name)
        #expect(Set(shown).isSuperset(of: ["default", "sidebar collapsed", "sidebar wide", "right panel", "small", "wide", "tall"]))
        let thread = Self.windows.filter { LotusArt.spot(for: .init(kind: .thread, content: $0.content, keepOut: $0.threadKeepOut)) != nil }.map(\.name)
        #expect(Set(thread).isSuperset(of: ["sidebar collapsed", "wide"]))
        #expect(!thread.contains("small") && !thread.contains("tiny") && !thread.contains("cramped"))
    }

    /// A drag across every width lands on a couple of dozen radii at most, each at or under the spot's radius and
    /// within 8% of it.
    @Test func radiiAreBucketed() {
        var buckets = Set<Int>()
        for r in stride(from: LotusArt.minRadius, through: LotusArt.heroMaxRadius, by: 0.5) {
            let b = LotusArt.bucket(r)
            buckets.insert(b)
            #expect(CGFloat(b) * 3 <= r + 0.001)
            #expect(CGFloat(b) * 3 >= r / 1.08 - 3)
        }
        #expect(buckets.count <= 24)
        // The largest set stays near the 6 MB ceiling.
        let p = LotusArt.canvas(radius: LotusArt.bucket(LotusArt.heroMaxRadius))
        let frames = LotusArt.bloomPoses().count + LotusArt.idlePoses().count + 1
        #expect(frames * p.width * p.height < 6 * 1_048_576)
    }

    /// One canvas serves any position: the open flower's coverage stays inside it, centred on its centre cell.
    @Test func canvasHoldsTheFlowerAndThinsTowardTheComposer() {
        let p = LotusArt.canvas(radius: 24)
        let shot = LotusArt.render(LotusArt.openPose, placement: p, samples: 1)
        var x0 = Int.max, x1 = 0, y0 = Int.max, y1 = 0
        for y in 0..<p.height { for x in 0..<p.width where shot.cover[y * p.width + x] > 0 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        #expect(x0 > 0 && y0 > 0 && x1 < p.width - 1 && y1 < p.height - 1)
        let d = LotusArt.heroDensity(p)
        #expect(d[Int(p.centreY) * p.width] == 1)
        #expect(d[(p.height - 1) * p.width] < 0.45)
    }
}
