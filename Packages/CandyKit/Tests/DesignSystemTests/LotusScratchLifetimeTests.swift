import Foundation
import Testing
@testable import DesignSystem

/// A pointer into a `Scratch`'s pages stays valid while it is in use. Each case takes the pointers, drops every other
/// reference, churns the page allocator so freed pages get mapped again with other contents, and only then reads: a
/// scratch unmapped early would crash or read the churn's 7s.
struct LotusScratchLifetimeTests {
    let place = LotusArt.Placement(width: 120, height: 90, centreX: 60, centreY: 46, radius: 44, view: LotusArt.bloomView)

    /// Maps and drops scratch of about the cells' size, filled with a value no render produces.
    func churn(_ count: Int) {
        autoreleasepool {
            for _ in 0..<16 { let s = Scratch<Float>(count, 7); #expect(s[count - 1] == 7) }
            let keep = (0..<8).map { _ in Scratch<Float>(count, 7) }
            #expect(keep.count == 8)
        }
    }

    @Test func cellsPointersOutliveEveryOtherReference() {
        let n = place.width * place.height
        for pose in [LotusArt.openPose] + LotusArt.bloomPoses().enumerated().filter { $0.offset % 8 == 0 }.map(\.element) {
            let reference = LotusArt.render(pose, placement: place, samples: 2)
            let (light, cover) = LotusArt.withCells(pose, placement: place, samples: 2) { light, cover -> ([Float], [Float]) in
                churn(n)
                return (Array(light), Array(cover))
            }
            #expect(light == reference.light && cover == reference.cover)
        }
    }

    @Test func frameSetsMatchOneAtATimeRendersUnderChurn() throws {
        let poses = LotusArt.bloomPoses().enumerated().filter { $0.offset % 6 == 0 }.map(\.element) + LotusArt.idlePoses().prefix(4)
        let parallel = try #require(LotusArt.packedMasks(poses, placement: place, dark: false))
        for (i, pose) in poses.enumerated() {
            let shot = LotusArt.render(pose, placement: place, samples: 2)
            churn(place.width * place.height)
            let one = shot.light.withUnsafeBufferPointer { l in
                shot.cover.withUnsafeBufferPointer { c in LotusArt.pack(LotusArt.codes(light: l, cover: c, placement: place, dark: false)) }
            }
            #expect(parallel[i] == one)
        }
    }
}
