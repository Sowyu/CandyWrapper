import AppKit
import Testing
@testable import DesignSystem

/// Redesign's one background, Gradient (the user, 2026-11-27: "lets just only do the gradient theme"): binary accent
/// cells on a fixed 3pt grid across the top of the new-thread page, after Capy's, and plain ground everywhere else.
@MainActor @Suite(.serialized)
struct GradientArtTests {
    private func cells(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height),
                                         count: image.width * image.height))
    }

    private func redesign() -> ThemeRuntimeInput {
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true; input.ditherGradient = true
        return input
    }

    /// A shell in a window with the art in its main panel, rendering inline and counting as the key window.
    private func shell() throws -> (SidebarLayoutView, NSWindow, DitherArtView) {
        _ = NSApplication.shared
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.gradient.\(UUID().uuidString)")!)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        shell.layoutSubtreeIfNeeded()
        let art = try #require(shell.main.subviews.first { $0 is DitherArtView } as? DitherArtView)
        art.windowIsActiveOverride = true
        art.rendersInlineForTesting = true
        return (shell, window, art)
    }

    /// Binary cells of one color: on at the top left, off at the canvas's foot, and the loop's frames differ, so the
    /// field moves under the fixed grid.
    @Test func framesAreBinaryCellsThatMove() throws {
        let frames = DitherArt.gradientFrames(width: 300, height: 120, frames: 8)
        #expect(frames.count == 8)
        let first = cells(frames[0])
        #expect(Set(first).isSubset(of: [0, 255]))
        // Row 0 is the top: the top left cell is on, the bottom row is all off.
        #expect(first[0] == 255)
        #expect(first[(119 * 300)..<(120 * 300)].allSatisfy { $0 == 0 })
        #expect(cells(frames[4]) != first)
    }

    /// The field reaches half the panel, and never closer than the clearance to the composer group's top, so it has
    /// faded to plain ground well above the composer however short the window is.
    @Test func fieldStopsAboveTheComposer() {
        #expect(DitherArt.gradientHeight(panel: 800, groupTop: nil) == 400)
        #expect(DitherArt.gradientHeight(panel: 800, groupTop: 600) == 400)
        #expect(DitherArt.gradientHeight(panel: 800, groupTop: 300) == 300 - DitherArt.gradientClearance)
        #expect(DitherArt.gradientHeight(panel: 400, groupTop: 10) == 0)
    }

    /// The motion runs only while every condition holds, and each one stopping removes it: the window losing key,
    /// another page, Reduce Motion, Animate background off and Redesign's art going (idle costs nothing).
    @Test func motionStopsWhenItCannotBeSeen() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion }
        Motion.reducedOverride = false
        var input = redesign()
        ThemeRuntime.apply(input)
        let (shell, window, art) = try shell()
        defer { window.contentView = nil }
        // No page registered: no frames are rendered or held, and nothing moves.
        #expect(art.requestForTesting == nil)
        #expect(!art.gradientAnimatingForTesting)
        let page = NSView(frame: shell.main.bounds)
        shell.main.addSubview(page)
        DitherArtView.setEmphasis(.hero, from: page)
        defer { DitherArtView.setEmphasis(nil, from: page) }
        let request = try #require(art.requestForTesting)
        #expect(request.url == nil && request.tint != nil)
        #expect(request.width == Int((art.bounds.width / DitherArt.gradientUnit).rounded(.up)))
        #expect(request.frames == Int(DitherArt.gradientPeriod * DitherArt.gradientFPS))
        #expect(art.gradientFrameCountForTesting == request.frames)
        #expect(art.gradientAnimatingForTesting)
        #expect(art.scrimAlphaForTesting == 0)

        art.windowIsActiveOverride = false; art.syncMotion()
        #expect(!art.gradientAnimatingForTesting)
        art.windowIsActiveOverride = true; art.syncMotion()
        #expect(art.gradientAnimatingForTesting)

        Motion.reducedOverride = true; art.syncMotion()
        #expect(!art.gradientAnimatingForTesting)
        Motion.reducedOverride = false; art.syncMotion()
        #expect(art.gradientAnimatingForTesting)

        // A thread takes the page: the frames go too, and the ground is plain with no scrim.
        for other in [DitherArtView.Emphasis.thread, .settings, .page] {
            DitherArtView.setEmphasis(other, from: page)
            #expect(!art.gradientAnimatingForTesting, "\(other)")
            #expect(art.requestForTesting == nil, "\(other)")
            #expect(art.gradientFrameCountForTesting == 0, "\(other)")
            #expect(art.scrimAlphaForTesting == 0, "\(other)")
        }
        DitherArtView.setEmphasis(.hero, from: page)
        #expect(art.gradientAnimatingForTesting)

        // Off shows frame 0, still.
        input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        #expect(!art.gradientAnimatingForTesting)
        #expect(art.requestForTesting?.frames == 1)
        input.ditherGradientAnimates = true
        ThemeRuntime.apply(input)
        #expect(art.gradientAnimatingForTesting)

        // The page hidden: nothing moves.
        page.isHidden = true; DitherArtView.pagesMoved()
        #expect(!art.gradientAnimatingForTesting)
        page.isHidden = false; DitherArtView.pagesMoved()
        #expect(art.gradientAnimatingForTesting)

        input.ditherLight = false; input.ditherDark = false
        ThemeRuntime.apply(input)
        #expect(!art.gradientAnimatingForTesting)
    }

    /// The new-thread page's composer group bounds the canvas: the field stops `gradientClearance` above its top.
    @Test func canvasEndsAboveTheComposerGroup() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        ThemeRuntime.apply(redesign())
        let (shell, window, art) = try shell()
        defer { window.contentView = nil }
        let page = NSView(frame: shell.main.bounds)
        shell.main.addSubview(page)
        DitherArtView.setEmphasis(.hero, from: page)
        defer { DitherArtView.setEmphasis(nil, from: page); DitherArtView.setComposer(nil, from: page) }
        let full = try #require(art.requestForTesting)
        #expect(full.height == Int((art.bounds.height * DitherArt.gradientReach / DitherArt.gradientUnit).rounded()))
        // A group whose top sits 200pt below the art's top.
        let groupTop = art.convert(NSPoint(x: 0, y: art.bounds.height - 200), to: page).y
        let group = NSRect(x: 100, y: page.isFlipped ? groupTop : groupTop - 120, width: 400, height: 120)
        DitherArtView.setComposer(group, from: page)
        let short = try #require(art.requestForTesting)
        #expect(short.height == Int(((200 - DitherArt.gradientClearance) / DitherArt.gradientUnit).rounded()))
    }

    /// Gradient's cell color is the accent mixed into the ground, a quiet step in both appearances.
    @Test func cellColorIsAQuietStep() {
        let dark = DitherArt.gradientColor(tint: [0.17, 0.58, 0.55], background: [0.03, 0.03, 0.03], dark: true)
        let light = DitherArt.gradientColor(tint: [0.03, 0.51, 0.48], background: [0.97, 0.97, 0.97], dark: false)
        let d = dark.components!, l = light.components!
        #expect(abs(d[0] - (0.03 + 0.14 * 0.36)) < 1e-6 && abs(d[1] - (0.03 + 0.55 * 0.36)) < 1e-6)
        #expect(abs(l[0] - (0.97 - 0.94 * 0.24)) < 1e-6)
    }
}
