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

    /// The new-thread reveal starts empty, grows in Bayer order and ends on the resting art, byte for byte.
    @Test func revealFramesGrowFromTheBackgroundToTheRestingArt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dither-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = 10.0 / 255
        let art = try #require(DitherArt.render(.init(url: try picture(gray: 0.9, in: dir), width: 80, height: 60, background: [bg, bg, bg], scale: 2)))
        let frames = DitherArt.revealFrames(art, background: [bg, bg, bg], reveals: [0, 0.5, 1])
        try #require(frames.count == 3)
        func lit(_ image: CGImage) -> Int { bytes(image).enumerated().filter { $0.offset % 4 == 0 && $0.element != 10 }.count }
        #expect(lit(frames[0]) == 0)
        #expect(lit(frames[1]) > 0 && lit(frames[1]) < lit(art))
        #expect(bytes(frames[2]) == bytes(art))
    }
}

/// A thread's text column keeps AA over the brightest art: the scrim there is the least that holds 4.5:1 for every
/// muted text color that holds it on the plain background, and a dark picture needs none.
struct DitherArtColumnScrimTests {
    func hex(_ v: Int) -> [Double] { [Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255] }

    @Test func columnScrimHoldsAAOverTheWorstArt() {
        for (bg, texts) in [(hex(0x131314), [hex(0xaaaaab), hex(0x848485)]), (hex(0xf9f9f9), [hex(0x6c6c6c), hex(0x898989)])] {
            let worst = DitherArt.farthest(from: bg)
            let a = Double(DitherArt.columnScrim(worst: worst, background: bg, texts: texts))
            let mixed = (0..<3).map { bg[$0] * a + worst[$0] * (1 - a) }
            for text in texts where DitherArt.contrast(text, bg) >= 4.6 { #expect(DitherArt.contrast(text, mixed) >= 4.5) }
            #expect(a > DitherArt.threadScrim && a < 1)
            #expect(DitherArt.columnScrim(worst: bg, background: bg, texts: texts) == 0)
        }
    }
}

/// The art yields to the system display options: Reduce Transparency covers it with the solid background, and
/// Increase Contrast keeps every page's scrim heavy enough that text sits on about the background.
struct DitherArtDisplayOptionTests {
    typealias Display = (reduceTransparency: Bool, increaseContrast: Bool)
    let standard: Display = (false, false)

    @Test func standardScrimsMatchTheDesign() {
        #expect(DitherArt.scrim(.hero, standard) == 0)
        #expect(DitherArt.scrim(.thread, standard) == DitherArt.threadScrim)
        #expect(DitherArt.scrim(.page, standard) == DitherArt.pageScrim)
    }

    @Test func reduceTransparencyHidesTheArt() {
        for page in [DitherArt.Page.hero, .thread, .page] {
            #expect(DitherArt.scrim(page, (true, false)) == 1)
            #expect(DitherArt.scrim(page, (true, true)) == 1)
        }
    }

    @Test func increaseContrastThickensEveryScrim() {
        for page in [DitherArt.Page.hero, .thread, .page] {
            #expect(DitherArt.scrim(page, (false, true)) > DitherArt.scrim(page, standard) || DitherArt.scrim(page, standard) == 1)
            #expect(DitherArt.scrim(page, (false, true)) >= 0.6)
        }
    }
}

@MainActor
struct DitherTabStripAccessibilityTests {
    @Test func tabsAreATabGroupWithACloseAction() throws {
        let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        var closed: [String] = []
        strip.onClose = { closed.append($0) }
        strip.tabs = [.init(id: "a", title: "First", icon: .messageSquare), .init(id: "b", title: "Second", icon: .messageSquare)]
        strip.selected = "a"
        #expect(strip.accessibilityRole() == .tabGroup)
        let tabs = try #require(strip.accessibilityTabs() as? [NSView])
        #expect(tabs.map { $0.accessibilityLabel() } == ["First", "Second"])
        #expect(tabs.map { $0.accessibilityRole() } == [.radioButton, .radioButton])
        let close = try #require(tabs[1].accessibilityCustomActions()?.first)
        #expect(close.name == "Close tab")
        #expect(close.handler?() == true)
        #expect(closed == ["b"])
    }

    @Test func restingTabsStayReadable() {
        let normal = DitherTabStripView.TabView.restingAlpha(increaseContrast: false)
        let high = DitherTabStripView.TabView.restingAlpha(increaseContrast: true)
        #expect(normal.label >= 0.7)
        #expect(high.label > normal.label && high.icon > normal.icon)
    }
}
