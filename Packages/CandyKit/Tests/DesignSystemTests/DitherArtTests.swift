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

    /// "Use desktop" never leaves the panel blank: a nil desktop URL or a file that won't decode still renders art,
    /// and a `.madesktop`, which macOS's own wallpapers are, renders its still thumbnail.
    @Test func unreadableOrMissingPicturesStillRenderArt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dither-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = 10.0 / 255
        func request(_ url: URL?, fallbacks: [URL] = []) -> DitherArt.Request {
            .init(url: url, width: 80, height: 60, background: [bg, bg, bg], scale: 2, fallbacks: fallbacks)
        }
        func lit(_ image: CGImage?) -> Int { image.map { bytes($0).enumerated().filter { $0.offset % 4 == 0 && $0.element != 10 }.count } ?? 0 }
        let broken = dir.appending(path: "broken.jpg")
        try Data("not a picture".utf8).write(to: broken)
        #expect(lit(DitherArt.render(request(nil))) > 0)
        #expect(lit(DitherArt.render(request(broken))) > 0)
        #expect(lit(DitherArt.render(request(dir.appending(path: "missing.png")))) > 0)
        // A fallback that reads wins over the built-in picture.
        let bright = try picture(gray: 0.9, in: dir)
        #expect(DitherArt.render(request(broken, fallbacks: [bright])).map(bytes) == DitherArt.render(request(bright)).map(bytes))

        let madesktop = dir.appending(path: "Wallpaper.madesktop")
        try PropertyListSerialization.data(fromPropertyList: ["thumbnailPath": bright.path, "isDynamic": false] as [String: Any], format: .xml, options: 0)
            .write(to: madesktop)
        #expect(DitherArt.resolved(madesktop) == bright)
        #expect(DitherArt.render(request(madesktop)).map(bytes) == DitherArt.render(request(bright)).map(bytes))
    }

    /// The pictures a MacBook really has: each renders as its own art, never the built-in fallback.
    enum Kind: String, CaseIterable, Sendable { case iPhoneHEIC, jpeg6K, screenshotPNG, displayP3PNG, hdrEXR, sixteenBitPNG }

    func write(_ kind: Kind, in dir: URL) throws -> URL {
        let (w, h, type, ext): (Int, Int, String, String) = switch kind {
        case .iPhoneHEIC: (4032, 3024, "public.heic", "HEIC")
        case .jpeg6K: (6016, 3384, "public.jpeg", "jpg")
        case .screenshotPNG: (3024, 1964, "public.png", "png")
        case .displayP3PNG: (1200, 800, "public.png", "png")
        case .hdrEXR: (1600, 1000, "com.ilm.openexr-image", "exr")
        case .sixteenBitPNG: (1200, 800, "public.png", "png")
        }
        let name: CFString = switch kind {
        case .iPhoneHEIC, .displayP3PNG: CGColorSpace.displayP3
        case .hdrEXR: CGColorSpace.extendedLinearDisplayP3
        default: CGColorSpace.sRGB
        }
        let space = CGColorSpace(name: name)!
        let ctx: CGContext = switch kind {
        case .hdrEXR:
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        case .sixteenBitPNG:
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        case .screenshotPNG:
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        default:
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        }
        // Brighter than SDR white in the HDR picture, so its values run past 1.
        let peak: CGFloat = kind == .hdrEXR ? 3 : 1
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.9 * peak, 0.45 * peak, 0.2 * peak, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = dir.appending(path: "\(kind.rawValue).\(ext)")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        // iPhone photos are stored sideways with an orientation tag.
        let properties: [CFString: Any] = kind == .iPhoneHEIC ? [kCGImagePropertyOrientation: 6] : [:]
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), properties as CFDictionary)
        try #require(CGImageDestinationFinalize(dest))
        return url
    }

    @Test(arguments: Kind.allCases) func everyKindOfPictureRendersAsItself(_ kind: Kind) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dither-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bg = 10.0 / 255
        // A 1512 x 945 pt panel at 2pt dots: a 14" MacBook Pro's window at 2x.
        func request(_ url: URL?) -> DitherArt.Request { .init(url: url, width: 756, height: 473, background: [bg, bg, bg], scale: 2) }
        let art = try #require(DitherArt.render(request(try write(kind, in: dir))))
        let builtIn = try #require(DitherArt.render(request(nil)))
        #expect(bytes(art) != bytes(builtIn))
        // The top row is the picture's own warm color: red over blue, never the built-in's violet and teal.
        let b = bytes(art)
        let red = (0..<756).map { Int(b[$0 * 4]) }.reduce(0, +), blue = (0..<756).map { Int(b[$0 * 4 + 2]) }.reduce(0, +)
        #expect(red > blue + 756 * 20)
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

    /// Reduce Transparency once covered the art with the solid background, so Redesign showed a plain panel with any
    /// picture. It takes a heavier scrim now, never full cover.
    @Test func reduceTransparencyThickensTheScrimWithoutCoveringTheArt() {
        for page in [DitherArt.Page.hero, .thread, .settings, .page] {
            for contrast in [false, true] {
                for light in [false, true] {
                    let reduced = DitherArt.scrim(page, (true, contrast), light: light)
                    #expect(reduced < 1)
                    #expect(reduced >= min(DitherArt.scrim(page, (false, contrast), light: light), DitherArt.pageScrim))
                }
            }
        }
        #expect(DitherArt.scrim(.hero, (true, false)) > DitherArt.scrim(.hero, (false, false)))
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

    /// Over the brightest (dark) or darkest (light) dot behind the chat column, Redesign's muted text keeps 4.5:1 in
    /// its own colors and in another theme's, at any "Background dim" where any text could.
    @Test func mutedTextKeepsContrastOverTheArt() {
        for theme in [ThemeDefinition.dither] + ThemeDefinition.builtIns.prefix(3) {
            for dim in [0, 35, 90] {
                var input = ThemeRuntimeInput(light: theme.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                              dark: theme.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
                input.ditherLight = true; input.ditherDark = true; input.ditherDim = dim
                let palettes = ThemeRuntime.resolve(input)
                for dark in [false, true] {
                    let p = palettes.palette(dark: dark, sidebar: false)
                    let worst = WindowGlass.linear(DitherArt.worstBackground(p.background, dark: dark, dim: Double(dim) / 100))
                    for c in [p.mutedForeground, p.secondaryLabel] {
                        let l = WindowGlass.luminance(c)
                        let ratio = (max(l, worst) + 0.05) / (min(l, worst) + 0.05)
                        // At no dim a lighter dark background can leave even white short; then the text is white.
                        #expect(ratio >= 4.5 || (dark && l > 0.999), "\(theme.id) dim \(dim) dark \(dark): \(ratio)")
                    }
                }
            }
        }
    }

    /// The veil covers the chat column, eases out beside it, and is gone off a thread or under Reduce Transparency.
    @Test func veilFadesBesideTheColumn() {
        let lane: ClosedRange<CGFloat> = 300...1100
        #expect(DitherArt.veilShare(700, lane: lane) == 1)
        #expect(DitherArt.veilShare(300, lane: lane) == 1)
        #expect(DitherArt.veilShare(300 - DitherArt.veilFeather, lane: lane) == 0)
        let mid = DitherArt.veilShare(1100 + DitherArt.veilFeather / 2, lane: lane)
        #expect(mid > 0.4 && mid < 0.6)
        #expect(DitherArt.veil(.thread, reduceTransparency: false) == DitherArt.veilAlpha)
        #expect(DitherArt.veil(.thread, reduceTransparency: true) == 0)
        #expect(DitherArt.veil(.hero, reduceTransparency: false) == 0)
    }
}
