import AppKit
import QuartzCore
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign opens the right panel with `RedesignMotion.panel` when Panel animations are off (T3's default), and the
/// panel's frame is its resting frame from the first frame.
@MainActor
struct RedesignPanelMotionTests {
    @Test func rightPanelSlidesInOnItsRestingFrame() throws {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs
        Motion.reducedOverride = false
        defer { ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration; Motion.reducedOverride = nil }
        var input = ThemeRuntimeInput(light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                                      dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
        panel.referenceViewportWidth = 1400
        window.contentView = panel
        panel.layoutSubtreeIfNeeded()
        panel.mutatePanel { $0.open(.diff); return [] }
        let layer = try #require(panel.rightPanel.layer)
        #expect(!panel.rightPanel.isHidden)
        #expect((layer.animationKeys() ?? []).contains("redesign.panel.x"), "\(layer.animationKeys() ?? [])")
        #expect(CATransform3DIsIdentity(layer.transform) && layer.opacity == 1)
    }
}
