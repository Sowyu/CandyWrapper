import XCTest
@testable import DesignSystem

/// All palette colors recorded on 979c85e5 before the 3814 stylesheet update.
@MainActor
final class CandyThemeBaselineTests: XCTestCase {
    func testCandyThemesKeepTheir3669Colors() throws {
        var actual: [String: [String: [[Double]]]] = [:]
        for theme in [ThemeDefinition.dither, .glass] {
            for contrast in [80, 100, 120] {
                for opacity in [10, 80, 100] {
                    var input = ThemeRuntimeInput(contrast: contrast, glassOpacity: opacity)
                    if theme.isDither {
                        input.light = ThemeRuntimeHalf(colors: theme.colors(for: .light)!)
                        input.dark = ThemeRuntimeHalf(colors: theme.colors(for: .dark)!)
                        input.ditherLight = true; input.ditherDark = true
                    } else {
                        input.glassLight = true; input.glassDark = true
                    }
                    let resolved = ThemeRuntime.resolve(input)
                    for (context, palette) in zip(["light", "dark", "sidebarLight", "sidebarDark"],
                                                  [resolved.light, resolved.dark, resolved.sidebarLight, resolved.sidebarDark]) {
                        actual["\(theme.id)/\(contrast)/\(opacity)/\(context)"] = Dictionary(uniqueKeysWithValues:
                            zip(Palette.memberNames, palette.members).map { name, color in
                                (name, [(0..<4).map { color.srgb[$0] }, (0..<4).map { color.displayP3[$0] }])
                            })
                    }
                }
            }
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/theme/candy-3669-baseline.json")
        let expected = try JSONDecoder().decode([String: [String: [[Double]]]].self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        for (context, roles) in expected {
            for (name, value) in roles {
                XCTAssertEqual(actual[context]?[name], value, "\(context) \(name)")
            }
        }
    }
}
