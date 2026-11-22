import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Redesign: a thread's rows run on under the header, where a blur and a wash of the band's color cover them.
@MainActor @Suite struct RedesignHeaderShadeTests {
    private func withRedesign(dark: Bool, flower: Bool, blur: Bool = false, _ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        input.ditherFlower = flower; input.ditherBlur = blur; input.ditherGradientAnimates = false
        ThemeRuntime.apply(input)
        try body()
    }

    private func thread(width: CGFloat = 1240, dark: Bool = true) throws -> ThreadPanelView {
        let panel = ComposerFidelityTests.panel(width: width, dark: dark)
        panel.setProjection(try ThreadPreview.projection(titled: ThreadPreview.markdownThread), projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    /// The timeline mask's alpha at `y` in the panel, from its gradient's stops.
    private func maskAlpha(_ panel: ThreadPanelView, at y: CGFloat) throws -> CGFloat {
        let mask = try #require(panel.timeline.layer?.mask as? CAGradientLayer)
        let locations = try #require(mask.locations).map { CGFloat($0.doubleValue) }
        let alphas = try #require(mask.colors as? [CGColor]).map(\.alpha)
        let t = (y - panel.timeline.frame.minY) / panel.timeline.bounds.height
        guard let next = locations.firstIndex(where: { $0 >= t }) else { return alphas.last ?? 1 }
        guard next > 0 else { return alphas[0] }
        let a = locations[next - 1], b = locations[next]
        return b == a ? alphas[next] : alphas[next - 1] + (alphas[next] - alphas[next - 1]) * (t - a) / (b - a)
    }

    @Test func rowsRunUnderTheHeaderUnderTheShade() throws {
        for (flower, blur) in [(false, false), (false, true), (true, false)] {
            for dark in [false, true] {
                try withRedesign(dark: dark, flower: flower, blur: blur) {
                    let panel = try thread(dark: dark)
                    panel.timeline.scroll(toFraction: 0.5)
                    panel.layoutSubtreeIfNeeded()
                    // A row scrolled under the header is drawn there, up to the window's top edge.
                    for y in stride(from: panel.timeline.frame.minY, through: panel.timeline.frame.minY + DitherChrome.band + 24, by: 2) {
                        #expect(try maskAlpha(panel, at: y) == 1, "y \(y)")
                    }
                    // The shade covers the breadcrumb's row, from the window's top, between the rows and the title.
                    let shade = panel.headerShade
                    #expect(!shade.isHidden)
                    #expect(shade.frame.minY == panel.timeline.frame.minY)
                    #expect(shade.frame.width == panel.timeline.frame.width)
                    #expect(shade.frame.maxY >= DitherChrome.band + panel.timeline.frame.minY + 16)
                    let subviews = panel.subviews
                    let order = [panel.timeline, shade].compactMap { v in subviews.firstIndex { $0 === v } }
                    #expect(order.count == 2 && order[0] < order[1])
                    #expect(shade.hitTest(NSPoint(x: 10, y: 10)) == nil)
                }
            }
        }
    }

    @Test func theShadeEndsSoftly() {
        for solid in [false, true] {
            #expect(ThreadHeaderShadeView.wash(1, solid: solid) == 0)
            #expect(ThreadHeaderShadeView.wash(0, solid: solid) >= 0.9 && ThreadHeaderShadeView.wash(0.3, solid: solid) >= 0.9)
            // Falling all the way, never rising.
            let samples = (0...50).map { ThreadHeaderShadeView.wash(Double($0) / 50, solid: solid) }
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
        }
        // Without the blur the breadcrumb's row stays covered.
        #expect(ThreadHeaderShadeView.wash(0.35, solid: true) == 1)
        #expect(ThreadHeaderShadeView.blurStrength(0) == 1 && ThreadHeaderShadeView.blurStrength(0.85) == 0 && ThreadHeaderShadeView.blurStrength(0.35) == 1)
        #expect(ThreadHeaderShadeView.height(reducesTransparency: true) > ThreadHeaderShadeView.height(reducesTransparency: false))
    }
}
