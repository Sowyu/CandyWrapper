import AppKit
import Testing
@testable import DesignSystem

/// Flower, Redesign's fourth background: the bloom plays once per opening, the motion stops whenever the flower can't
/// be seen or isn't wanted and holds the open flower, frame sets follow radius buckets, and other pages show none.
@MainActor
struct FlowerArtTests {
    private func setUp() throws -> (art: DitherArtView, page: NSView, window: NSWindow, input: ThemeRuntimeInput) {
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true; input.ditherFlower = true
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.dither-flower.\(UUID().uuidString)")!)
        // Small, with a tall composer, so the flower renders at a small radius and the test stays quick.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        shell.layoutSubtreeIfNeeded()
        let art = try #require(shell.main.subviews.first { $0 is DitherArtView } as? DitherArtView)
        art.windowIsActiveOverride = true
        art.rendersInlineForTesting = true
        let page = NSView(frame: shell.main.bounds)
        shell.main.addSubview(page)
        return (art, page, window, input)
    }

    /// The page's stage: the whole page below a 52pt band, a composer 320 x 150pt centred near the bottom.
    private func stage(_ page: NSView, kind: LotusArt.Kind = .hero, composerWidth: CGFloat = 320) {
        let b = page.bounds
        let content = NSRect(x: 0, y: 0, width: b.width, height: b.height - 52)
        let composer = NSRect(x: (b.width - composerWidth) / 2, y: 24, width: composerWidth, height: 150)
        DitherArtView.setFlowerStage(kind: kind, content: content, keepOut: [composer], from: page)
    }

    @Test func bloomsOncePerOpeningAndHoldsTheOpenFlowerWhenStopped() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try bloomsOncePerOpening() }
    }

    private func bloomsOncePerOpening() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion }
        Motion.reducedOverride = false
        let (art, page, window, start) = try setUp()
        var input = start
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }

        // No page yet: nothing renders.
        #expect(art.flowerSet == nil)
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page)
        let set = try #require(art.flowerSet)
        #expect(set.bloom.count == LotusArt.bloomPoses().count && set.idle.count == LotusArt.idlePoses().count)
        // The first show is an opening: the bloom plays, the idle loop queued after it, and the art lays no scrim.
        #expect(art.flowerBloomingForTesting && art.flowerIdlingForTesting)
        #expect(art.scrimAlphaForTesting == 0)
        let firstBloom = art.bloomEnds

        // Re-renders, the same stage again and a stream update's layout are not openings.
        art.refresh()
        stage(page)
        art.syncMotion()
        #expect(art.bloomEnds == firstBloom)

        // Switching threads is.
        DitherArtView.flowerOpened(from: page)
        #expect(art.bloomEnds > firstBloom)
        #expect(art.flowerBloomingForTesting)

        // The window losing key mid-bloom stops everything and holds the open flower, not the bud.
        art.windowIsActiveOverride = false; art.syncMotion()
        #expect(!art.flowerBloomingForTesting && !art.flowerIdlingForTesting)
        #expect(art.flowerContentsForTesting === art.flowerSet?.open)
        // Coming back resumes the idle loop with no bloom.
        let held = art.bloomEnds
        art.windowIsActiveOverride = true; art.syncMotion()
        #expect(art.flowerIdlingForTesting && !art.flowerBloomingForTesting && art.bloomEnds == held)

        Motion.reducedOverride = true; art.syncMotion()
        #expect(!art.flowerIdlingForTesting)
        Motion.reducedOverride = false; art.syncMotion()
        #expect(art.flowerIdlingForTesting)

        // Animate off: one still, the open flower, nothing moving.
        input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        #expect(!art.flowerIdlingForTesting && !art.flowerBloomingForTesting)
        #expect(art.flowerSet?.bloom.isEmpty == true && art.flowerSet?.idle.isEmpty == true)
        #expect(art.flowerContentsForTesting === art.flowerSet?.open)
        // An opening with Animate off shows the open flower at once.
        DitherArtView.flowerOpened(from: page)
        #expect(!art.flowerBloomingForTesting && art.flower.opacity == 1)
        input.ditherGradientAnimates = true
        ThemeRuntime.apply(input)
        #expect(art.flowerIdlingForTesting && !art.flowerBloomingForTesting)

        // Another page (Settings, Issues, Usage): the plain ground, the frames dropped.
        DitherArtView.setEmphasis(.page, from: page)
        #expect(art.flowerSet == nil && art.flower.isHidden)
        #expect(!art.flowerIdlingForTesting)
        // Back on the page: the flower returns without a bloom; only openings bloom.
        DitherArtView.setEmphasis(.hero, from: page)
        #expect(!art.flower.isHidden && art.flowerIdlingForTesting && !art.flowerBloomingForTesting)

        // Another Background takes it out.
        input.ditherFlower = false
        ThemeRuntime.apply(input)
        #expect(art.flowerSet == nil && art.flower.isHidden)
    }

    /// A composer that takes the room hides the flower; the flower's frame keeps clear of it; a change within one
    /// radius bucket keeps the set, crossing a bucket renders one more.
    @Test func followsTheStageAndKeepsItsSetWithinABucket() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try followsTheStage() }
    }

    private func followsTheStage() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion }
        Motion.reducedOverride = true
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page)
        let spot = try #require(art.flowerSpot)
        let frame = try #require(art.flowerFrame(settled: true))
        // Settled, every dot is one 3pt cell: the layer is the canvas at one cell a pixel.
        let key = try #require(art.flowerSet?.key)
        let canvas = LotusArt.canvas(radius: key.radius)
        #expect(abs(frame.width - CGFloat(canvas.width) * 3) < 0.01 && abs(frame.height - CGFloat(canvas.height) * 3) < 0.01)
        #expect(CGFloat(key.radius) * 3 <= spot.radius)
        // The flower's frame stays above the composer (unflipped: the composer's top is 174pt up).
        #expect(art.convert(frame, to: page).minY >= 174)

        let renders = art.rendersForTesting
        // Same bucket: no render.
        let content = NSRect(x: 0, y: 0, width: page.bounds.width, height: page.bounds.height - 52)
        DitherArtView.setFlowerStage(kind: .hero, content: content.insetBy(dx: 1, dy: 0),
                                     keepOut: [NSRect(x: (page.bounds.width - 320) / 2, y: 24, width: 320, height: 150)], from: page)
        if LotusArt.bucket(try #require(art.flowerSpot).radius) == key.radius { #expect(art.rendersForTesting == renders) }

        // A composer filling the page: no room, no flower, no frames.
        DitherArtView.setFlowerStage(kind: .hero, content: content,
                                     keepOut: [NSRect(x: 0, y: 24, width: page.bounds.width, height: page.bounds.height - 60)], from: page)
        #expect(art.flower.isHidden && art.flowerSet == nil)
    }
}
