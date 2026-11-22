import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import Features

/// Redesign: a thread's rows fade out above the composer group and draw nothing below its top, in every background.
@MainActor @Suite struct RedesignBottomFadeTests {
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

    @Test func noRowDrawsBelowTheComposersTop() throws {
        for (flower, blur) in [(false, false), (false, true), (true, false)] {
            for dark in [false, true] {
                try withRedesign(dark: dark, flower: flower, blur: blur) {
                    let panel = try thread(dark: dark)
                    panel.timeline.scroll(toFraction: 0.5)
                    // Scroll to end shows 150ms after leaving the end.
                    panel.timeline.wantsScrollToEnd = true
                    panel.layoutSubtreeIfNeeded()
                    let fade = try #require(panel.ditherBottomFade)
                    let top = panel.composer.frame.minY
                    #expect(fade.end == top)
                    for y in stride(from: top, through: panel.bounds.height, by: 4) {
                        #expect(try maskAlpha(panel, at: y) == 0, "y \(y)")
                    }
                    // The Scroll to end row sits on faded rows; the scrolled content's end is still fully drawn.
                    #expect(try maskAlpha(panel, at: top - DitherPill.gap - DitherPill.height / 2) < 0.5)
                    #expect(try maskAlpha(panel, at: fade.start - 1) == 1)
                    // A taller composer moves the cut with it.
                    panel.composer.text = String(repeating: "line\n", count: 6)
                    panel.needsLayout = true
                    panel.layoutSubtreeIfNeeded()
                    #expect(panel.ditherBottomFade?.end == panel.composer.frame.minY)
                    #expect(try maskAlpha(panel, at: panel.composer.frame.minY + 1) == 0)
                }
            }
        }
    }
}
