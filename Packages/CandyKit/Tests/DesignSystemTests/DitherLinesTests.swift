import Testing
@testable import DesignSystem

/// Redesign's dark lines sit on frosted panes over the art, so each is a white overlay, never a dark or black one.
@MainActor
struct DitherLinesTests {
    @Test(arguments: [80, 100, 130]) func darkLinesAreWhiteOverlays(contrast: Int) {
        var input = ThemeRuntimeInput(contrast: contrast)
        input.ditherDark = true
        input.dark = ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark) ?? ThemeDefinition.dither.colors)
        let palette = ThemeRuntime.resolve(input).palette(dark: true, sidebar: false)
        for (i, name) in Palette.memberNames.enumerated() where WindowGlass.lineMembers.contains(name) {
            let c = palette.members[i].srgb
            #expect(c.x == 1 && c.y == 1 && c.z == 1 && c.w > 0.02 && c.w < 0.2, "\(name) \(c)")
        }
    }
}
