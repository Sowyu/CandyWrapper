import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Redesign: a thread's rows draw at full strength up through the header row and behind the composer (the user,
/// 2026-11-22). Only the breadcrumb's text gets a blur patch, the window's top edge an 8 pt fade, and no layer the
/// size of the timeline carries a mask.
@MainActor @Suite(.serialized) struct RedesignHeaderShadeTests {
    enum Ground: CaseIterable { case picture, blur, flower }

    static func withRedesign(_ ground: Ground, dark: Bool, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); NSApp?.appearance = appearance }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        input.ditherPicture = ComposerAttachmentsFidelityTests.fixture.path
        input.ditherFlower = ground == .flower; input.ditherBlur = ground == .blur; input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try body()
    }

    static func thread(width: CGFloat, dark: Bool, fraction: Double = 0.5) throws -> ThreadPanelView {
        let panel = ComposerFidelityTests.panel(width: width, dark: dark)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: fraction)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    /// RGBA bytes of the panel-point rect `r` of a 2x `rep`.
    static func pixels(_ rep: NSBitmapImageRep, _ r: NSRect) -> [UInt8] {
        let all = SidebarFidelityTests.pixels(rep, rep.pixelsWide, rep.pixelsHigh), row = rep.pixelsWide * 4
        let x0 = max(0, Int(r.minX * 2)), x1 = min(rep.pixelsWide, Int(r.maxX * 2))
        let y0 = max(0, Int(r.minY * 2)), y1 = min(rep.pixelsHigh, Int(r.maxY * 2))
        guard x1 > x0, y1 > y0 else { return [] }
        return (y0..<y1).flatMap { y in all[(y * row + x0 * 4)..<(y * row + x1 * 4)] }
    }

    @Test func rowsDrawUpThroughTheHeaderRowAndBehindTheComposer() throws {
        for ground in Ground.allCases {
            for dark in [false, true] {
                try Self.withRedesign(ground, dark: dark) {
                    let size = NSSize(width: ground == .flower ? 1300 : 844, height: 780)
                    // The same thread at its start and scrolled to its end: wherever rows draw, the two differ.
                    let top = RedesignBaselineTests.image(try Self.thread(width: size.width, dark: dark, fraction: 0), size: size, dark: dark)
                    let panel = try Self.thread(width: size.width, dark: dark, fraction: 1)
                    let end = RedesignBaselineTests.image(panel, size: size, dark: dark)
                    let shade = panel.headerShade
                    #expect(!shade.isHidden)
                    // Rows draw in the header row away from the breadcrumb: right of its pill, below the edge fade.
                    let pill = panel.titlePill.frame
                    let header = NSRect(x: pill.maxX, y: shade.frame.minY + ThreadHeaderShadeView.edgeFade,
                                        width: panel.readingLane.maxX - pill.maxX, height: DitherChrome.band - ThreadHeaderShadeView.edgeFade)
                    let beside = Self.pixels(top, header) != Self.pixels(end, header)
                    #expect(!header.isEmpty && beside, "\(ground) dark \(dark): no rows beside the breadcrumb")
                    // And below the composer's top: behind it and in the strip under it (the user: not a bug).
                    let below = NSRect(x: 0, y: panel.composer.frame.minY, width: size.width, height: size.height - panel.composer.frame.minY)
                    let under = Self.pixels(top, below) != Self.pixels(end, below)
                    #expect(under, "\(ground) dark \(dark): no rows below the composer's top")
                }
            }
        }
    }

    @Test func theBreadcrumbIsAPillAtTheLeftEnd() throws {
        try Self.withRedesign(.picture, dark: true) {
            let panel = try Self.thread(width: 1240, dark: true)
            _ = RedesignBaselineTests.image(panel, size: NSSize(width: 1240, height: 780), dark: true)
            // The render took the panel out of its window, which hides the pill until the panel lays out again.
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            let pill = try #require(panel.titlePill as? DitherThreadTitleView)
            #expect(!pill.isHidden)
            #expect(pill.superview === panel)
            // On its own the panel places it as the strip would: in from the left as far as the header pill is from
            // the right, centred in the band, as tall as the tabs, hugging its text.
            #expect(pill.frame.minX == DitherTabStripView.accessoryRight)
            #expect(pill.frame.height == DitherTabStripView.tabHeight)
            #expect(abs(pill.frame.midY - (panel.headerShade.frame.minY + DitherChrome.band / 2)) <= 0.5)
            #expect(pill.frame.width == pill.intrinsicContentSize.width)
            #expect(!pill.project.isHidden && !pill.name.isTruncated)
            // Takes no clicks: the band under it drags the window.
            #expect(pill.hitTest(NSPoint(x: pill.frame.midX, y: pill.frame.midY)) == nil)
            // Its width follows the title.
            let before = pill.frame.width
            panel.header.threadTitle = "A"
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            #expect(pill.frame.width < before)
        }
    }

    @Test func theStripPairsThePillWithTheHeaderPill() throws {
        try Self.withRedesign(.picture, dark: true) {
            let panel = try Self.thread(width: 1240, dark: true)
            panel.header.threadTitle = String(repeating: "A very long thread title that runs on ", count: 6)
            panel.layoutSubtreeIfNeeded()
            let strip = DitherTabStripView(frame: NSRect(x: 0, y: 0, width: 900, height: DitherChrome.band))
            strip.showsTabs = false
            let right = PillStandIn(); strip.trailingAccessory = right
            strip.leadingAccessory = panel.titlePill
            strip.layoutSubtreeIfNeeded()
            let left = panel.titlePill.frame
            #expect(left.minX == strip.contentStart - DitherTabStripView.accessoryRight)
            #expect(left.minX == strip.bounds.width - right.frame.maxX)
            #expect(left.midY == right.frame.midY && left.height == right.frame.height)
            #expect(right.frame.minX - left.maxX >= DitherTabStripView.leadingGap - 0.5)
            // A long title keeps the project and truncates in its middle.
            let pill = try #require(panel.titlePill as? DitherThreadTitleView)
            #expect(!pill.project.isHidden && pill.name.isTruncated && pill.name.truncation == .middle)
            // Narrow: the project drops first, then the title truncates alone.
            strip.setFrameSize(NSSize(width: 360, height: DitherChrome.band))
            strip.layoutSubtreeIfNeeded()
            #expect(pill.project.isHidden && pill.name.isTruncated)
            #expect(right.frame.minX - panel.titlePill.frame.maxX >= DitherTabStripView.leadingGap - 0.5)
        }
    }

    private final class PillStandIn: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 180, height: DitherTabStripView.tabHeight) }
    }

    @Test func theTopFadeIsOnlyTheEdge() {
        #expect(ThreadHeaderShadeView.edgeFade <= 8)
        #expect(ThreadHeaderShadeView.edge(0) == 1 && ThreadHeaderShadeView.edge(1) == 0)
        let samples = (0...50).map { ThreadHeaderShadeView.edge(Double($0) / 50) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// Layers whose visible part, after their ancestors' clips, is at least `minArea`, and that make the compositor
    /// render them offscreen first. A pill's glass clips its window-sized glow to the pill, so that one stays small.
    static func offscreenLayers(in root: CALayer, minArea: CGFloat) -> [String] {
        var found: [String] = []
        func walk(_ layer: CALayer, _ path: String, _ clip: CGRect) {
            let name = path + "/" + (layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer)))
            let frame = layer.convert(layer.bounds, to: root), visible = frame.intersection(clip)
            if !visible.isNull, visible.width * visible.height >= minArea {
                if layer.mask != nil { found.append(name + " mask") }
                if layer.shouldRasterize { found.append(name + " shouldRasterize") }
                if layer.masksToBounds, layer.cornerRadius > 0 { found.append(name + " rounded clip") }
                if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty || layer.compositingFilter != nil {
                    found.append(name + " filter")
                }
                if layer.opacity < 1, layer.allowsGroupOpacity, !(layer.sublayers ?? []).isEmpty { found.append(name + " group opacity") }
            }
            let inner = layer.masksToBounds ? clip.intersection(frame) : clip
            layer.sublayers?.forEach { walk($0, name, inner) }
        }
        walk(root, "", root.bounds)
        return found
    }

    @Test func noTimelineSizedLayerRendersOffscreen() throws {
        for ground in Ground.allCases {
            try Self.withRedesign(ground, dark: true) {
                let panel = try Self.thread(width: 1240, dark: true)
                _ = RedesignBaselineTests.image(panel, size: NSSize(width: 1240, height: 780), dark: true)
                let layer = try #require(panel.layer)
                let area = panel.timeline.bounds.width * panel.timeline.bounds.height / 4
                #expect(panel.timeline.layer?.mask == nil)
                let found = Self.offscreenLayers(in: layer, minArea: area)
                #expect(found.isEmpty, "\(ground): \(found)")
                // The check catches a mask coming back.
                panel.timeline.layer?.mask = CAGradientLayer()
                #expect(!Self.offscreenLayers(in: layer, minArea: area).isEmpty)
                panel.timeline.layer?.mask = nil
            }
        }
    }
}
