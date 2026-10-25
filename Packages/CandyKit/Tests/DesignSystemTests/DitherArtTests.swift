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

/// The art yields to the system display options: Reduce Transparency covers it with the solid background, and
/// Increase Contrast keeps every page's scrim heavy enough that text sits on about the background.
struct DitherArtDisplayOptionTests {
    typealias Display = (reduceTransparency: Bool, increaseContrast: Bool)
    let standard: Display = (false, false)

    @Test func standardScrimsMatchTheDesign() {
        #expect(DitherArt.scrim(.hero, standard) == 0)
        #expect(DitherArt.scrim(.thread, standard) == DitherArt.threadScrim)
        // The user wants the thread's art vivid with a slight dim: never a heavy veil.
        #expect(DitherArt.threadScrim <= 0.4)
        #expect(DitherArt.scrim(.page, standard) == DitherArt.pageScrim)
        // Settings shows the art under its cards, dimmer than a thread and lighter than other pages.
        #expect(DitherArt.scrim(.settings, standard) > DitherArt.threadScrim)
        #expect(DitherArt.scrim(.settings, standard) < DitherArt.pageScrim)
    }

    @Test func reduceTransparencyHidesTheArt() {
        for page in [DitherArt.Page.hero, .thread, .settings, .page] {
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

    /// The working wave runs only while a thread works on a page that shows the art, never under Reduce Motion, and its
    /// band repeats seamlessly with crests that dim a dot alike on any screen.
    @Test func workingWaveRunsOnlyWhileWorkingAndRepeats() throws {
        func runs(_ page: DitherArt.Page = .thread, working: Bool = true, motion: Bool = false, transparency: Bool = false, art: Bool = true) -> Bool {
            DitherArt.waves(working: working, reduceMotion: motion, reduceTransparency: transparency, page: page, hasArt: art)
        }
        #expect(runs() && runs(.hero))
        #expect(!runs(working: false) && !runs(motion: true) && !runs(transparency: true) && !runs(art: false))
        #expect(!runs(.settings) && !runs(.page))
        let profile = DitherArt.waveProfile(cycles: 3, depth: 0.4)
        #expect(profile.first?.alpha == 0 && profile.last?.alpha == 0 && profile.last?.at == 1)
        #expect(abs((profile.map(\.alpha).max() ?? 0) - 0.4) < 1e-9)
        // A crest takes the same share of a dot at 1x, 2x and 3x, under a band that never goes past opaque: the grid
        // covers 3/4 of a dot on each.
        for k in [2, 4, 6] {
            #expect(abs(DitherArt.waveCover(pixelsPerDot: k) - 0.75) < 1e-9)
            #expect(abs(DitherArt.waveDepth(pixelsPerDot: k) * 0.75 - DitherArt.waveStrength) < 1e-9)
            #expect(DitherArt.waveDepth(pixelsPerDot: k) <= 1)
        }
        #expect(zip(profile, profile.dropFirst()).allSatisfy { $0.at < $1.at })

        // At 2x the grid covers exactly each dot's right two columns and bottom two rows of device pixels.
        let grid = try #require(DitherArt.waveGrid(columns: 3, rows: 2, pixelsPerDot: 4))
        #expect(grid.width == 12 && grid.height == 8)
        let alpha = [UInt8](grid.dataProvider!.data! as Data), row = grid.bytesPerRow
        for y in 0..<8 {
            for x in 0..<12 { #expect((alpha[y * row + x] == 255) == (x % 4 >= 2 || y % 4 >= 2)) }
        }
    }
}
