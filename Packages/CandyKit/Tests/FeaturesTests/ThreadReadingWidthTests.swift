import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Redesign keeps the thread column `RedesignTokens.Thread.minReading` wide beside the right panel, and shows the panel
/// as a sheet when the window can't hold both. T3's themes keep T3's rule: a sheet at 980px and a 360px chat floor.
@MainActor @Suite(.serialized) struct ThreadReadingWidthTests {
    @Test func sheetRule() {
        let min = RedesignTokens.Thread.minReading
        // T3: the viewport decides, and its 360px floor never turns the panel into a sheet.
        #expect(RightPanelView.isSheet(viewport: 980, container: 900))
        #expect(!RightPanelView.isSheet(viewport: 981, container: 600))
        // Redesign: a sheet as soon as the container can't hold the reading width beside the panel's narrowest.
        #expect(RightPanelView.isSheet(viewport: 1100, container: min + RightPanelView.minWidth - 1, chatMin: min))
        #expect(!RightPanelView.isSheet(viewport: 1100, container: min + RightPanelView.minWidth, chatMin: min))
        // Dragging the divider wide never takes the column under the floor.
        for container in stride(from: min + RightPanelView.minWidth, through: 1600, by: 37) {
            let panel = RightPanelView.width(viewport: container + 260, container: container, preferred: 5000, chatMin: min)
            #expect(container - panel >= min, "column \(container - panel) in \(container)")
        }
    }

    @Test(arguments: [(CGFloat(800), true), (CGFloat(860), false), (CGFloat(1100), false)])
    func columnKeepsItsWidth(container: CGFloat, sheet: Bool) throws {
        let previous = ThemeRuntime.input, duration = SettingsPanelMotion.durationMs
        defer { ThemeRuntime.apply(previous); SettingsPanelMotion.durationMs = duration }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true; input.insetPanel = true
        ThemeRuntime.apply(input)
        SettingsPanelMotion.durationMs = 0
        let panel = ComposerFidelityTests.panel(width: container, dark: true)
        panel.referenceViewportWidth = container + 260
        panel.mutatePanel { $0.open(.diff); $0.isOpen = true; return [] }
        panel.layoutSubtreeIfNeeded()
        #expect(panel.rightPanel.isSheet == sheet)
        #expect(panel.timeline.frame.width >= RedesignTokens.Thread.minReading)
    }
}
