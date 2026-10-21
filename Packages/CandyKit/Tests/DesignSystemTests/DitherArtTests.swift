import AppKit
import Testing
@testable import DesignSystem

/// The Dither theme's art: a picture that matches the background renders as exactly the background, a bright picture
/// is held to the reach that keeps text readable in three clean strengths, and the art thins toward the bottom.
struct DitherArtTests {
    func picture(gray: CGFloat, in dir: URL) throws -> URL {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let url = dir.appending(path: "\(gray).png")
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func bytes(_ image: CGImage) -> [UInt8] { [UInt8](image.dataProvider!.data! as Data) }

    @Test func fadesIntoTheBackgroundWithoutStrayDots() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dither-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = 10.0 / 255
        let flat = try #require(DitherArt.render(.init(url: try picture(gray: bg, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        #expect(Set(bytes(flat).enumerated().filter { $0.offset % 4 != 3 }.map(\.element)) == [10])

        // A bright picture is held to the reach, in three strengths: none, half and full.
        let bright = try #require(DitherArt.render(.init(url: try picture(gray: 0.9, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        let b = bytes(bright), row = bright.bytesPerRow
        let half = 10 + Int((DitherArt.reach / 2).rounded()), full = 10 + Int(DitherArt.reach.rounded())
        #expect(Set((0..<60).flatMap { y in (0..<80).map { Int(b[y * row + $0 * 4]) } }).isSubset(of: [10, half, full]))
        #expect(abs((0..<80).map { Int(b[$0 * 4]) }.reduce(0, +) / 80 - full) <= 4)
        // A mid gray, under the reach, thins toward the bottom.
        let mid = try #require(DitherArt.render(.init(url: try picture(gray: 0.4, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        let m = bytes(mid), mrow = mid.bytesPerRow
        let top = (0..<80).map { Int(m[$0 * 4]) }.reduce(0, +) / 80
        let bottom = (0..<80).map { Int(m[59 * mrow + $0 * 4]) }.reduce(0, +) / 80
        #expect(bottom < top)
        #expect(DitherArt.fade(0.5) == 0.15 && DitherArt.fade(1) < 0.4)
    }

    /// The motion frames: no reveal shows only the background, and a send's ring is brighter on its band than off it.
    @Test func motionFramesRevealAndRing() throws {
        let field = DitherArt.Field(width: 40, height: 40, background: [10, 10, 10],
                                    deviation: [Float](repeating: 40, count: 40 * 40 * 3))
        let hidden = try #require(DitherArt.image(field, .init(reveal: 0)))
        #expect(Set(bytes(hidden).enumerated().filter { $0.offset % 4 != 3 }.map(\.element)) == [10])
        let ring = try #require(DitherArt.image(field, .init(ring: (20, 20, 10, 6, 1.4))))
        let b = bytes(ring), row = ring.bytesPerRow
        func mean(_ cells: [(Int, Int)]) -> Int { cells.map { Int(b[$0.1 * row + $0.0 * 4]) }.reduce(0, +) / cells.count }
        let onBand = mean((16...24).flatMap { x in [(x, 10), (x, 30)] })
        let center = mean((16...24).flatMap { x in [(x, 19), (x, 20)] })
        #expect(onBand > center)
    }
}
