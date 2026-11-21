import Foundation
import Testing
import DesignSystem
@testable import Features

/// The Glass theme went in 1.17.0. Settings saved by 1.16.0 with Glass chosen load cleanly and fall back to the
/// default T3 Code theme in each appearance Glass painted, and the app's note about it is due exactly once.
@MainActor
struct RemovedGlassMigrationTests {
    /// 1.16.0's defaults with Glass as the theme and Redesign in dark only, Redesign remembering Glass under it.
    static func savedBy1160() throws -> UserDefaults {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/settings/candywrapper-1.16.0-glass.plist")
        let domain = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let suite = "cw.removed-glass.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.setPersistentDomain(domain, forName: suite)
        return defaults
    }

    @Test func settingsFrom1160LoadOnTheDefaultTheme() throws {
        let defaults = try Self.savedBy1160()
        let client = ClientSettingsStore(defaults: defaults)
        #expect(!client.readFailed)
        #expect(client.current.int("glassOpacity") == 40, "T3's own Glass opacity setting stays")
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        #expect(library.migrateRemovedGlass())
        #expect(library.preference == "system")
        #expect(library.owner(of: .light) == nil, "light falls back to the default T3 Code theme")
        #expect(library.owner(of: .dark) == ThemeDefinition.dither.id, "Redesign keeps dark")
        #expect(library.underlying.preference == "system", "turning Redesign off lands on the default theme")
        let (input, _) = library.runtimeInput(client: client.current)
        #expect(input.light == nil && !input.ditherLight)
        #expect(input.ditherDark)
        // The note is due once, and a second launch finds nothing to move.
        #expect(library.takeGlassRemovedNotice())
        #expect(!library.takeGlassRemovedNotice())
        #expect(!library.migrateRemovedGlass())
        #expect(!library.takeGlassRemovedNotice())
    }

    @Test func eachGlassSideFallsBackAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: "cw.removed-glass.sides.\(UUID().uuidString)"))
        defaults.set("dark", forKey: "theme.preference")
        defaults.set(try JSONSerialization.data(withJSONObject: ["light": "candywrapper-glass-native", "dark": "candywrapper-dither"]),
                     forKey: "theme.halves.v1")
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        #expect(library.migrateRemovedGlass())
        #expect(library.rawHalves == ThemeLibrary.Halves(dark: ThemeDefinition.dither.id))
        #expect(library.preference == "dark")
        #expect(!ThemeDefinition.pickerBuiltIns.contains { ThemePalette.removedGlassIds.contains($0.id) })
    }

    @Test func nothingToMoveShowsNoNote() throws {
        let defaults = try #require(UserDefaults(suiteName: "cw.removed-glass.none.\(UUID().uuidString)"))
        defaults.set(ThemeDefinition.dither.id, forKey: "theme.preference")
        let library = ThemeLibrary(defaults: defaults, pinned: nil)
        #expect(!library.migrateRemovedGlass())
        #expect(!library.takeGlassRemovedNotice())
    }
}
