import AppKit
import Testing
@testable import DesignSystem
@testable import Features

@MainActor
struct PixelSpritesTests {
    private func bytes(_ image: CGImage?) -> Data? {
        guard let image, let data = image.dataProvider?.data else { return nil }
        return data as Data
    }

    @Test func theSameSeedDrawsTheSameBytes() {
        for size in [CGFloat(16), 20, 28, 64] {
            for dark in [false, true] {
                let a = PixelSprites.render(seed: "atlas-web", points: size, px: Int(size * 2), dark: dark)
                let b = PixelSprites.render(seed: "atlas-web", points: size, px: Int(size * 2), dark: dark)
                #expect(bytes(a) != nil && bytes(a) == bytes(b))
            }
        }
        // Pinned, so a change to the hash or the tables shows up as a test failure, not a silent reshuffle.
        #expect(PixelSprites.pick("atlas") == PixelSprites.pick(PixelSprites.seed(title: "  Atlas ")))
        #expect(PixelSprites.fnv1a("") == 0x811c9dc5)
        #expect(PixelSprites.fnv1a("a") == 0xe40c292c)
    }

    @Test func everyMaskIsNonEmptyAndFitsTheGrid() {
        #expect(PixelSprites.masks.count == 36)
        #expect(Set(PixelSprites.masks).count == 36)
        for mask in PixelSprites.masks {
            #expect(mask != 0)
            // A UInt64 is the 8 x 8 grid, so nothing falls outside it; each sprite also spans at least 4 cells.
            let rows = (0..<8).filter { y in (0..<8).contains { PixelSprites.cell(mask, $0, y) } }
            let cols = (0..<8).filter { x in (0..<8).contains { PixelSprites.cell(mask, x, $0) } }
            #expect(rows.count >= 4 && cols.count >= 4)
        }
        #expect(!PixelSprites.cell(PixelSprites.masks[0], 8, 0) && !PixelSprites.cell(PixelSprites.masks[0], -1, 0))
    }

    @Test func aSpriteNeverComesWithANeighbouringHue() {
        var hues: [Int: Set<Int>] = [:]
        for i in 0..<5000 {
            let p = PixelSprites.pick("project-\(i)")
            #expect((0..<PixelSprites.masks.count).contains(p.sprite) && (0..<PixelSprites.hues.count).contains(p.hue))
            hues[p.sprite, default: []].insert(p.hue)
        }
        let n = PixelSprites.hues.count
        for (_, set) in hues {
            for a in set { for b in set where a != b {
                let d = min((a - b + n) % n, (b - a + n) % n)
                #expect(d >= 2)
            }}
        }
        // Every sprite and every hue still turns up.
        #expect(hues.count == PixelSprites.masks.count)
        #expect(Set(hues.values.flatMap { $0 }).count == n)
    }

    @Test func spritesKeepAPictureFreeTileClean() throws {
        // At 16pt the ground has no dots: every pixel is the ground ink or the sprite ink.
        let image = try #require(PixelSprites.render(seed: "juniper", points: 16, px: 32, dark: false))
        let rep = NSBitmapImageRep(cgImage: image)
        var colors = Set<UInt32>()
        for y in 8..<24 { for x in 8..<24 {
            var p = [Int](repeating: 0, count: 4)
            rep.getPixel(&p, atX: x, y: y)
            colors.insert(UInt32(p[0] << 16 | p[1] << 8 | p[2]))
        }}
        #expect(colors.count == 2)
    }

    /// Renders a 16pt favicon for `source` into a 2x bitmap under `dither`.
    private func favicon(_ source: ProjectIconSource, dither: Bool, sprites: Bool = true) -> Data {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput()
        input.ditherLight = dither; input.ditherDark = dither
        input.projectSprites = sprites
        ThemeRuntime.apply(input)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let g = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = g
            let ctx = g.cgContext
            ctx.translateBy(x: 0, y: 32); ctx.scaleBy(x: 2, y: -2)
            ProjectMonogramView.draw(source, identity: ProjectMonogramView.identity(source), ctx: ctx)
            NSGraphicsContext.restoreGraphicsState()
        }
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * 32)
    }

    @Test func onlyRedesignSwapsTheGeneratedMonogram() {
        let plain = ProjectIconSource(title: "orbit-api", workspaceRoot: "")
        var chosen = plain
        chosen.override = .monogram(text: "OA", color: "teal")
        // Default themes keep T3's monogram.
        let letters = favicon(plain, dither: false)
        #expect(favicon(plain, dither: true) != letters)
        // Letters in Settings > Redesign brings T3's monogram back.
        #expect(favicon(plain, dither: true, sprites: false) == letters)
        // A monogram the user chose is never replaced.
        #expect(favicon(chosen, dither: true) == favicon(chosen, dither: false))
    }
}
