import AppKit
import Testing
@testable import DesignSystem

/// Flower, Redesign's fourth background: the bloom plays once per opening, the motion stops whenever the flower can't
/// be seen or isn't wanted and holds the open flower, a resize scales the shown frame and renders once it settles, and
/// other pages show none.
@MainActor
struct FlowerArtTests {
    private func setUp() throws -> (art: DitherArtView, page: NSView, window: NSWindow, input: ThemeRuntimeInput) {
        var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                      dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
        input.ditherLight = true; input.ditherDark = true; input.ditherFlower = true
        ThemeRuntime.apply(input)
        let shell = SidebarLayoutView(defaults: UserDefaults(suiteName: "cw.dither-flower.\(UUID().uuidString)")!)
        // Small, with a tall composer, so the flower renders at a small radius and the test stays quick.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled], backing: .buffered, defer: true)
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

    /// The page's stage: the whole page, and the top of the composer group (page coordinates, y up) when the opening
    /// should play its two beats.
    private func stage(_ page: NSView, kind: LotusArt.Kind = .hero, width: CGFloat? = nil, floorTop: CGFloat? = nil) {
        let b = page.bounds
        let content = NSRect(x: 0, y: 0, width: width ?? b.width, height: b.height)
        DitherArtView.setFlowerStage(kind: kind, content: content, floorTop: floorTop, from: page)
    }

    /// A composer top so high on the small test window that the bloom above it would be too small: the new thread
    /// blooms in place.
    static let noOpening: CGFloat = 260

    @Test func bloomsOncePerOpeningAndHoldsTheOpenFlowerWhenStopped() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try bloomsOncePerOpening() }
    }

    private func bloomsOncePerOpening() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = false
        let (art, page, window, start) = try setUp()
        var input = start
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }

        // No page yet: nothing renders.
        #expect(art.flowerSet == nil)
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page, floorTop: Self.noOpening)
        let set = try #require(art.flowerSet)
        #expect(set.bloom.count == LotusArt.bloomPoses().count && set.idle.count == LotusArt.idlePoses().count)
        // The first show is an opening: the bloom plays, the idle loop queued after it, and the art lays no scrim.
        #expect(art.flowerBloomingForTesting && art.flowerIdlingForTesting)
        #expect(art.scrimAlphaForTesting == 0)
        let firstBloom = art.bloomEnds

        // Re-renders, the same stage again and a stream update's layout are not openings.
        art.refresh()
        stage(page, floorTop: Self.noOpening)
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
        // The bloom and the packed loop are gone; only the open still stays.
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
        #expect(art.flowerSet == nil && art.flowerHost.isHidden)
        #expect(!art.flowerIdlingForTesting)
        // Back on the page: the flower returns without a bloom; only openings bloom.
        DitherArtView.setEmphasis(.hero, from: page)
        #expect(!art.flowerHost.isHidden && art.flowerIdlingForTesting && !art.flowerBloomingForTesting)

        // Another Background takes it out.
        input.ditherFlower = false
        ThemeRuntime.apply(input)
        #expect(art.flowerSet == nil && art.flowerHost.isHidden)
    }

    /// The flower fills the content area: one cell per mask pixel inside the area, nothing outside it. A drag scales
    /// the shown frame and renders once, after it settles. A thread masks it behind the column; the new thread doesn't.
    /// A surface floating over it shows the ground and the blurred flower.
    @Test func fillsTheAreaAndRendersOnceAfterADrag() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try followsTheStage() }
    }

    private func followsTheStage() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = true
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page)
        let key = try #require(art.flowerSet?.key)
        let frame = try #require(art.flowerFrame())
        // The layer is the content area's whole canvas, one cell per mask pixel: the field and the flower share it.
        let p = key.full
        #expect(abs(frame.width - CGFloat(p.width) * 3) < 0.01 && abs(frame.height - CGFloat(p.height) * 3) < 0.01)
        let pageFrame = art.convert(frame, to: page)
        #expect(pageFrame.minX >= -0.01 && pageFrame.maxX <= page.bounds.width + 3 && pageFrame.minY >= -3)
        #expect(pageFrame.maxY >= page.bounds.height - 0.01)
        // Reduce Motion: the open flower at once, no bloom, no turn, and no bloom or loop frames held.
        #expect(!art.flowerBloomingForTesting && !art.flowerIdlingForTesting && art.flowerContentsForTesting === art.flowerSet?.open)
        #expect(art.flowerSet?.bloom.isEmpty == true && art.flowerSet?.idle.isEmpty == true)
        #expect(art.flowerHost.mask == nil)
        // The surfaces over the flower get its blurred copy.
        let glass = FlowerGlassView(frame: NSRect(x: 100, y: 30, width: 200, height: 80))
        page.addSubview(glass)
        glass.layout()
        #expect(glass.glowShownForTesting)

        // The same stage again: nothing renders.
        let renders = art.rendersForTesting
        stage(page)
        #expect(art.rendersForTesting == renders)

        // A drag: the first change renders, the next ones within the gap scale the shown frame instead.
        stage(page, width: page.bounds.width - 30)
        let afterFirst = art.rendersForTesting
        // A debug render outlasts the drag gap, so the test says the last change was just now.
        art.flowerMovedAt = CACurrentMediaTime()
        stage(page, width: page.bounds.width - 60)
        #expect(art.rendersForTesting == afterFirst && art.flowerResizing)
        // The shown set is the earlier area's, placed for the new one.
        #expect(art.flowerSet?.key != art.flowerTarget && art.flowerFrame() != nil)
        art.settleFlower()
        #expect(art.rendersForTesting == afterFirst + 1 && !art.flowerResizing)
        #expect(art.flowerSet?.key.placement == LotusArt.canvas(content: CGRect(x: 0, y: 0, width: page.bounds.width - 60, height: page.bounds.height)))

        // A thread: the still column mask, built from the column, and the same frames.
        let before = art.rendersForTesting
        DitherArtView.setEmphasis(.thread, from: page)
        DitherArtView.setColumn(NSRect(x: 150, y: 0, width: 300, height: page.bounds.height), from: page)
        stage(page, kind: .thread, width: page.bounds.width - 60)
        #expect(art.flowerHost.mask === art.columnLayer && art.columnLayer.contents != nil)
        // Moving the column rebuilds only the mask.
        let renderedThread = art.rendersForTesting
        DitherArtView.setColumn(NSRect(x: 120, y: 0, width: 300, height: page.bounds.height), from: page)
        #expect(art.rendersForTesting == renderedThread)
        #expect(renderedThread - before <= 1)
    }

    /// Behind the reading column the worst cell (the ink at the cap, under light's faintness) keeps body text at 12:1
    /// and muted at 6:1 in dark, muted at 4.5:1 in light, with Redesign's own palettes and every accent.
    @Test func columnKeepsTheTextFloorsInBothAppearances() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        for accent in DitherAccent.all.map(\.id) {
            var input = ThemeRuntimeInput(light: ThemeDefinition.dither.colors(for: .light).map { ThemeRuntimeHalf(colors: $0) },
                                          dark: ThemeDefinition.dither.colors(for: .dark).map { ThemeRuntimeHalf(colors: $0) })
            input.ditherLight = true; input.ditherDark = true; input.ditherFlower = true; input.ditherAccent = accent
            ThemeRuntime.apply(input)
            for dark in [true, false] {
                let p = ThemeRuntime.palettes.palette(dark: dark, sidebar: false)
                let g = p.background.srgb, t = p.foreground.srgb, m = p.mutedForeground.srgb
                let ground = SIMD3(g.x, g.y, g.z), ink = DitherArtView.flowerInkRGB(p, dark: dark)
                let opacity = Double(DitherArtView.flowerOpacity(dark: dark))
                let cap = LotusArt.columnCap(ground: ground, ink: ink, text: SIMD3(t.x, t.y, t.z), muted: SIMD3(m.x, m.y, m.z),
                                             opacity: opacity, dark: dark)
                let worst = PictureInk.luminance(ground + (ink - ground) * Double(cap) * opacity)
                let body = PictureInk.contrast(worst, PictureInk.luminance(SIMD3(t.x, t.y, t.z)))
                let muted = PictureInk.contrast(worst, PictureInk.luminance(SIMD3(m.x, m.y, m.z)))
                print("flower column \(accent) \(dark ? "dark" : "light"): cap \(Int(cap * 255))/255, body \(String(format: "%.2f", body)):1, muted \(String(format: "%.2f", muted)):1")
                let floors = LotusArt.textFloors(dark: dark)
                #expect(body >= floors.body && muted >= floors.muted, "\(accent) \(dark)")
                // Some of the flower still shows behind the column.
                #expect(cap > 0.05, "\(accent) \(dark)")
            }
        }
    }

    /// The new thread opens in two beats: the bloom above the composer, then the move down, rendered ahead on the full
    /// canvas and freed on landing, which shows the resting frame and starts the turn. A quick return shows it at rest.
    @Test func newThreadOpensInTwoBeats() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try twoBeats() }
    }

    private func twoBeats() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = false
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page, floorTop: 100)
        let set = try #require(art.flowerSet)
        let o = try #require(set.opening)
        #expect(art.openingPlaying && art.flowerBloomingForTesting && !art.flowerIdlingForTesting)
        #expect(set.openingBloom.count == LotusArt.openingBloomPoses().count && set.flight.count == LotusArt.flightFrames(o).count)
        #expect(art.flowerFrame()?.width == CGFloat(o.canvas.width) * 3)
        // The hold is over: the move plays and the bloom's frames go.
        art.openingFly?.cancel(); art.openingFly = nil
        art.bloomEnds = -1000
        art.fly()
        #expect(art.flowerMask.animation(forKey: "flight") != nil && art.flowerSet?.openingBloom.isEmpty == true)
        // Landed: the resting frame on the resting canvas, the opening's frames gone, the turn going.
        art.openingLand?.cancel()
        art.land()
        #expect(!art.openingPlaying && art.flowerContentsForTesting === art.flowerSet?.open)
        #expect(art.flowerSet?.flight.isEmpty == true && art.flowerSet?.opening == nil && art.flowerIdlingForTesting)
        #expect(art.flowerFrame()?.width == CGFloat(try #require(art.flowerSet).key.placement.width) * 3)
        #expect(try #require(art.flowerSet).bytes < 10 * 1_048_576)

        // Away and straight back: at rest, no opening.
        DitherArtView.setEmphasis(.page, from: page)
        DitherArtView.setEmphasis(.hero, from: page)
        DitherArtView.flowerOpened(from: page)
        #expect(!art.openingPlaying && !art.flowerBloomingForTesting)
        // Reduce Motion: at rest, no opening.
        art.heroLeftAt = nil
        Motion.reducedOverride = true
        DitherArtView.flowerOpened(from: page)
        #expect(!art.openingPlaying && !art.flowerBloomingForTesting && art.flowerContentsForTesting === art.flowerSet?.open)
    }

    /// The frames render once a window: a return to the new thread, a replayed opening and a thread's second bloom
    /// compose the kept codes and render nothing; a thread shows the new thread's resting frame.
    @Test func returnsAndThreadsRenderNoFrames() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try rendersOnce() }
    }

    private func rendersOnce() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = false
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        func land() {
            art.openingFly?.cancel(); art.openingFly = nil
            art.bloomEnds = -1000
            art.fly()
            art.openingLand?.cancel()
            art.land()
        }
        DitherArtView.setEmphasis(.hero, from: page)
        // The stage before the composer's top: the field alone, no bloom in place, so the opening isn't used up.
        stage(page)
        #expect(!art.flowerBloomingForTesting && !art.openingPlaying && art.flowerSet?.bloom.isEmpty == true)
        stage(page, floorTop: 100)
        #expect(art.openingPlaying)
        land()
        let rendered = art.flowerFramesRendered
        let o = try #require(art.flowerOpening)
        #expect(rendered == 1 + LotusArt.openingBloomPoses().count + LotusArt.flightFrames(o).count + LotusArt.idlePoses().count)
        // What stays between visits, with the resting set, within the budget.
        let held = try #require(art.flowerSet).bytes + art.flowerCodeSets.reduce(0) { $0 + $1.bytes }
        #expect(held < 10 * 1_048_576)

        // Away and back within the interval: the flower at rest and turning, nothing rendered.
        DitherArtView.setEmphasis(.page, from: page)
        #expect(art.flowerSet == nil)
        DitherArtView.setEmphasis(.hero, from: page)
        DitherArtView.flowerOpened(from: page)
        #expect(!art.openingPlaying && art.flowerIdlingForTesting && art.flowerFramesRendered == rendered)

        // Away for longer: the opening plays again from the kept codes.
        DitherArtView.setEmphasis(.page, from: page)
        art.heroLeftAt = CACurrentMediaTime() - LotusArt.replayInterval - 1
        DitherArtView.setEmphasis(.hero, from: page)
        DitherArtView.flowerOpened(from: page)
        #expect(art.openingPlaying && art.flowerFramesRendered == rendered)
        land()

        // A thread on the same area: the new thread's resting frame, no new still; its bloom renders once.
        let open = try #require(art.flowerSet?.open)
        DitherArtView.setEmphasis(.thread, from: page)
        stage(page, kind: .thread)
        DitherArtView.flowerOpened(from: page)
        #expect(art.flowerSet?.open === open && art.flowerBloomingForTesting)
        #expect(art.flowerFramesRendered == rendered + LotusArt.bloomPoses().count)
        art.endBloom()
        #expect(art.flowerContentsForTesting === open)
        // The next thread blooms from the kept codes.
        DitherArtView.flowerOpened(from: page)
        #expect(art.flowerBloomingForTesting && art.flowerFramesRendered == rendered + LotusArt.bloomPoses().count)

        // Animate off keeps no motion frames; the window going keeps none at all.
        var input = ThemeRuntime.input
        input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        #expect(art.flowerCodeSets.allSatisfy { $0[.idle] == nil && $0[.bloom] == nil })
        input.ditherFlower = false
        ThemeRuntime.apply(input)
        #expect(art.flowerCodeSets.isEmpty)
    }

    /// The turn runs only while the art can be seen and the window is active: hiding the art or an ancestor, or the
    /// window losing key, stops it and holds the frame; showing it again resumes.
    @Test func turnStopsWhenHiddenOrInactive() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try stopsWhenHidden() }
    }

    private func stopsWhenHidden() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = false
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page, floorTop: Self.noOpening)
        art.endBloom()
        art.syncMotion()
        #expect(art.flowerIdlingForTesting)
        art.isHidden = true
        #expect(!art.flowerIdlingForTesting)
        art.isHidden = false
        #expect(art.flowerIdlingForTesting)
        let parent = try #require(art.superview)
        parent.isHidden = true
        #expect(!art.flowerIdlingForTesting)
        parent.isHidden = false
        #expect(art.flowerIdlingForTesting)
        art.windowIsActiveOverride = false; art.syncMotion()
        #expect(!art.flowerIdlingForTesting)
    }

    /// Render jobs, and frames rendered from the model, for a fixed run of stage reports while each job is still
    /// running when the next report comes (as a slow render is), so a job restarted or a part rendered for nothing shows
    /// in the counts. The CPU the Flower costs is these frames; the counts hold it, not a timing.
    @Test func eachStageRendersItsFramesOnce() throws {
        try DitherArtView.$flowerSamples.withValue(1) { try countsJobs() }
    }

    private func countsJobs() throws {
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, patience = DitherArtView.bloomPatience
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; DitherArtView.bloomPatience = patience }
        DitherArtView.bloomPatience = 600
        Motion.reducedOverride = false
        let (art, page, window, _) = try setUp()
        defer { window.contentView = nil; DitherArtView.setEmphasis(nil, from: page); DitherArtView.clearFlowerStage(from: page) }
        art.holdsFlowerJobsForTesting = true
        func drain() { while !art.heldFlowerJobsForTesting.isEmpty { art.heldFlowerJobsForTesting.removeFirst()() } }
        func land() {
            art.openingFly?.cancel(); art.openingFly = nil
            art.bloomEnds = -1000
            art.fly()
            art.openingLand?.cancel()
            art.land()
        }
        func quiet(width: CGFloat? = nil) {
            // Left alone: layout passes, the same stage again, the motion re-synced.
            for _ in 0..<5 { art.needsLayout = true; art.layoutSubtreeIfNeeded(); art.refresh(); art.syncMotion() }
            stage(page, width: width, floorTop: 100)
        }

        // The new-thread page: its stage before the composer's top, then a top too high for the opening, then the real
        // one, all while the first job runs.
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page)
        stage(page, floorTop: Self.noOpening)
        stage(page, floorTop: 100)
        DitherArtView.flowerOpened(from: page)
        drain()
        #expect(art.openingPlaying)
        land()
        quiet()
        drain()
        let o = try #require(art.flowerOpening)
        let heroFrames = 1 + LotusArt.openingBloomPoses().count + LotusArt.flightFrames(o).count + LotusArt.idlePoses().count
        #expect(art.flowerFramesRendered == heroFrames)
        #expect(art.flowerJobsForTesting == 3)
        #expect(art.flowerIdlingForTesting)

        // A thread opens on the same area: one job, its bloom.
        var jobs = art.flowerJobsForTesting
        DitherArtView.setEmphasis(.thread, from: page)
        stage(page, kind: .thread)
        DitherArtView.flowerOpened(from: page)
        drain()
        art.endBloom()
        #expect(art.flowerJobsForTesting == jobs + 1)
        #expect(art.flowerFramesRendered == heroFrames + LotusArt.bloomPoses().count)

        // Switching threads and back to the new thread: frames from the kept codes, one job a switch, none rendered.
        jobs = art.flowerJobsForTesting
        DitherArtView.flowerOpened(from: page); drain(); art.endBloom()
        DitherArtView.flowerOpened(from: page); drain(); art.endBloom()
        DitherArtView.setEmphasis(.hero, from: page)
        stage(page, floorTop: 100)
        DitherArtView.flowerOpened(from: page)
        drain()
        quiet()
        drain()
        #expect(art.flowerJobsForTesting == jobs + 3)
        #expect(art.flowerFramesRendered == heroFrames + LotusArt.bloomPoses().count)
        #expect(art.flowerCancelsForTesting == 2)

        // A drag: its first step starts a render, which the second stops; the shown frame scales through the rest and
        // one set renders when it ends.
        jobs = art.flowerJobsForTesting
        let cancels = art.flowerCancelsForTesting, end = page.bounds.width - 60
        stage(page, width: page.bounds.width - 10, floorTop: 100)
        #expect(art.flowerJobsForTesting == jobs + 1)
        stage(page, width: page.bounds.width - 20, floorTop: 100)
        #expect(art.flowerCancelsForTesting == cancels + 1 && art.flowerJob == nil)
        for w in stride(from: page.bounds.width - 30, through: end, by: -10) { stage(page, width: w, floorTop: 100) }
        #expect(art.flowerJobsForTesting == jobs + 1)
        art.settleFlower()
        drain()
        quiet(width: end)
        drain()
        #expect(art.flowerJobsForTesting == jobs + 2)
        #expect(art.flowerCancelsForTesting == cancels + 1)
        #expect(art.flowerSet?.key == art.flowerTarget && art.flowerSet?.idle.isEmpty == false)
        print("flower-jobs: \(art.flowerJobsForTesting) jobs, \(art.flowerCancelsForTesting) cancelled, \(art.flowerFramesRendered) frames kept")
    }
}
