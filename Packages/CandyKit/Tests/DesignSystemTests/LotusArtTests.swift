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
        let petals = LotusArt.rings.reduce(0) { $0 + $1.count } + 1
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
