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
                    // Rows draw in the header row away from the breadcrumb: right of the patch, below the edge fade.
                    let patch = shade.convert(shade.patchFrame, to: panel)
                    let header = NSRect(x: patch.maxX, y: shade.frame.minY + ThreadHeaderShadeView.edgeFade,
                                        width: panel.readingLane.maxX - patch.maxX, height: DitherChrome.band - ThreadHeaderShadeView.edgeFade)
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

    @Test func thePatchCoversTheBreadcrumbsTextOnly() throws {
        try Self.withRedesign(.picture, dark: true) {
            let panel = try Self.thread(width: 1240, dark: true)
            _ = RedesignBaselineTests.image(panel, size: NSSize(width: 1240, height: 780), dark: true)
            let shade = panel.headerShade
            let text = shade.textRect, patch = shade.patchFrame
            #expect(!text.isEmpty)
            #expect(patch.contains(text))
            #expect(patch.width <= text.width + 2 * (ThreadHeaderShadeView.patchPad.width + ThreadHeaderShadeView.patchFeather) + 2)
            #expect(patch.width < shade.bounds.width / 2)
            // The patch follows the title's width.
            let before = patch.width
            panel.header.threadTitle = "A"
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
            #expect(shade.patchFrame.width < before)
            // The shade sits between the rows and the title and takes no clicks.
            let order = [panel.timeline, shade].compactMap { v in panel.subviews.firstIndex { $0 === v } }
            #expect(order.count == 2 && order[0] < order[1])
            #expect(shade.hitTest(NSPoint(x: 10, y: 10)) == nil)
            #expect(shade.frame.height == DitherChrome.band)
        }
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
