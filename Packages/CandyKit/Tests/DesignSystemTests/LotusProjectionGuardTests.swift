import Foundation
import Testing
@testable import DesignSystem

/// The flower's projection survives any camera and any canvas: a vertex in or behind the camera plane is dropped
/// with its triangles instead of trapping in `Int(Float)`, and a canvas too big to render is refused before anything
/// is allocated.
struct LotusProjectionGuardTests {
    func finite(_ s: LotusArt.Shot) -> Bool {
        s.light.allSatisfy { $0.isFinite && (0...1).contains($0) } && s.cover.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func place(_ w: Int, _ h: Int, camera: LotusArt.Camera? = nil) -> LotusArt.Placement {
        LotusArt.Placement(width: w, height: h, centreX: Double(w) / 2, centreY: Double(h) / 2, radius: Double(min(w, h)) / 2, camera: camera)
    }

    @Test func aVertexExactlyInTheCameraPlaneRenders() {
        // With no turn and scale 1 a vertex sits at its mesh position, so an eye there puts it at depth 0.
        let pose = LotusArt.openPose
        let vertex = LotusArt.mesh(bloom: pose.bloom).positions[0]
        for lookAt in [SIMD3<Float>(0, 0, 0), vertex + SIMD3(0, -1, 0), vertex + SIMD3(1, 0, 0)] {
            let camera = LotusArt.Camera(eye: vertex, lookAt: lookAt, focal: 60, centreX: 40, centreY: 30)
            let shot = LotusArt.render(pose, placement: place(80, 60, camera: camera), samples: 2)
            #expect(shot.width == 80 && shot.light.count == 80 * 60 && finite(shot))
        }
        // An eye in the middle of the flower: most petals are behind it, some cross the plane.
        let inside = LotusArt.Camera(eye: SIMD3(0, 0.2, 0), lookAt: SIMD3(0, 0.2, 1), focal: 60, centreX: 40, centreY: 30)
        #expect(finite(LotusArt.render(pose, placement: place(80, 60, camera: inside))))
        // A camera that looks away from the flower draws nothing at all.
        let away = LotusArt.Camera(eye: SIMD3(0, 0.5, 6), lookAt: SIMD3(0, 0.5, 12), focal: 60, centreX: 40, centreY: 30)
        #expect(LotusArt.render(pose, placement: place(80, 60, camera: away)).cover.allSatisfy { $0 == 0 })
    }

    @Test func zeroAndOnePixelCanvasesRender() throws {
        let zero = LotusArt.render(LotusArt.openPose, placement: place(0, 0))
        #expect(zero.light.isEmpty && zero.cover.isEmpty)
        #expect(LotusArt.render(LotusArt.openPose, placement: place(0, 40)).light.isEmpty)
        let one = LotusArt.render(LotusArt.openPose, placement: place(1, 1))
        #expect(one.light.count == 1 && finite(one))
        let packed = try #require(LotusArt.packedMasks([LotusArt.openPose], placement: place(1, 1), dark: true))
        #expect(packed.count == 1)
        #expect(LotusArt.canvas(content: .zero) == nil && LotusArt.fullCanvas(content: CGRect(x: 0, y: 0, width: 0.5, height: 900)) == nil)
    }

    @Test func anEnormousCanvasIsRefusedNotAllocated() {
        let start = Date()
        let huge = place(1_000_000, 1_000_000)
        #expect(!LotusArt.renderable(huge))
        let shot = LotusArt.render(LotusArt.openPose, placement: huge)
        #expect(shot.width == 0 && shot.light.isEmpty)
        #expect(LotusArt.packedMasks([LotusArt.openPose], placement: huge, dark: false) == nil)
        #expect(LotusArt.packedFrames([(LotusArt.openPose, huge)], dark: false, density: { _ in nil }) == nil)
        #expect(LotusArt.render(LotusArt.openPose, placement: place(LotusArt.maxSide + 1, 2)).light.isEmpty)
        var nan = place(80, 60); nan.radius = .nan
        #expect(LotusArt.render(LotusArt.openPose, placement: nan).light.isEmpty)
        // A window's content area of any size: far too big, infinite or NaN gives no canvas.
        for content in [CGRect(x: 0, y: 0, width: 1e9, height: 1e9), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 900),
                        CGRect(x: CGFloat.nan, y: 0, width: 900, height: 900), CGRect(x: 0, y: 0, width: 40_000, height: 900)] {
            #expect(LotusArt.fullCanvas(content: content) == nil && LotusArt.canvas(content: content) == nil)
            #expect(LotusArt.opening(content: content, floorTop: 800) == nil)
        }
        #expect(LotusArt.fullCanvas(content: CGRect(x: 0, y: 0, width: 1440, height: 900)) != nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
