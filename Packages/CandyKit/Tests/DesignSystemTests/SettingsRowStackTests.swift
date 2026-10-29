import AppKit
import Testing
@testable import DesignSystem

/// A stacked settings row (under 512pt) keeps a switch at its own width and stretches only `w-full` controls.
@MainActor
struct SettingsRowStackTests {
    @Test func switchesKeepTheirWidthAtEveryRowWidth() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        for redesign in [false, true] {
            var theme = ThemeRuntimeInput(); theme.ditherLight = redesign; theme.ditherDark = redesign
            ThemeRuntime.apply(theme)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                for width: CGFloat in [360, 490, 700] {
                    let toggle = SwitchView(isOn: true)
                    let input = InputView(placeholder: "Path")
                    let rows = [SettingsRowView(title: "In-app notifications", detail: "Show a toast when another thread finishes.", control: toggle),
                                SettingsRowView(title: "Binary path", control: input)]
                    for row in rows {
                        row.appearance = NSAppearance(named: name)
                        row.frame = NSRect(x: 0, y: 0, width: width, height: row.height(forWidth: width))
                        row.layoutSubtreeIfNeeded()
                    }
                    let label = "redesign \(redesign), \(name.rawValue), \(width)pt"
                    #expect(toggle.frame.width == toggle.intrinsicContentSize.width, "\(label): switch \(toggle.frame.width) wide")
                    if width < 512 { #expect(input.frame.width == width - 32, "\(label): input \(input.frame.width) wide") }
                }
            }
        }
    }
}
