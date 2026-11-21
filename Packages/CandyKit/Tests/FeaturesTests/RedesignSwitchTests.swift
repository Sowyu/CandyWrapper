import Foundation
import Testing
import DesignSystem
@testable import Features

/// Settings > Experimental > Redesign: on remembers the theme in use, off brings it back.
/// Every change a library makes applies to the global theme runtime, so each test puts it back: left on ocean with an
/// ember dark half, it tinted fidelity renders running alongside brown (491 failures on 2026-10-25).
@MainActor
struct RedesignSwitchTests {
    private let previous = ThemeRuntime.input

    private func library() -> ThemeLibrary {
        let lib = ThemeLibrary(defaults: UserDefaults(suiteName: "cw.redesign.tests.\(UUID().uuidString)")!, pinned: nil)
        lib.controlsAppearance = false
        return lib
    }

    @Test func offRestoresThePreviousThemeAndItsMix() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setTheme("ocean")
        lib.setThemeHalf(.dark, "ember")
        #expect(!lib.isRedesignOn)
        lib.setRedesign(true)
        #expect(lib.isRedesignOn && lib.preference == ThemeDefinition.dither.id && lib.halves == .init())
        lib.setRedesign(false)
        #expect(!lib.isRedesignOn && lib.preference == "ocean" && lib.halves == .init(dark: "ember"))
    }

    @Test func alreadyOnRedesignShowsOnAndFallsBackToTheStandardLook() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setAppearanceMode("dark")
        lib.setTheme(ThemeDefinition.dither.id)
        #expect(lib.isRedesignOn)
        lib.setRedesign(true)
        #expect(lib.preference == ThemeDefinition.dither.id)
        lib.setRedesign(false)
        #expect(!lib.isRedesignOn && lib.preference == "dark")
    }

    @Test func aRedesignHalfCountsAsOn() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setThemeHalf(.dark, ThemeDefinition.dither.id)
        #expect(lib.isRedesignOn)
        lib.setRedesign(false)
        #expect(!lib.isRedesignOn)
    }

    // MARK: The Redesign card left the Themes grid (2026-11-21)

    /// "Use in" turns Redesign on for one appearance, with the theme from Settings > Appearance in the other.
    @Test func useInPicksOneAppearance() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setTheme("ocean")
        lib.setRedesignUseIn([.dark])
        #expect(!lib.isRedesignOn, "choosing where it shows does not turn it on")
        lib.setRedesign(true)
        #expect(lib.redesignAppearances == [.dark] && lib.owner(of: .light) == "ocean")
        // Changed while on, it applies at once.
        lib.setRedesignUseIn([.light, .dark])
        #expect(lib.redesignAppearances == [.light, .dark] && lib.preference == ThemeDefinition.dither.id)
        lib.setRedesignUseIn([.light])
        #expect(lib.redesignAppearances == [.light] && lib.owner(of: .dark) == "ocean")
        lib.setRedesign(false)
        #expect(!lib.isRedesignOn && lib.preference == "ocean" && lib.halves == .init())
        #expect(lib.redesignUseIn == [.light])
    }

    /// Someone who picked Redesign's card in 1.15.2 keeps it after updating, both cards and the dark half alone.
    @Test func redesignPickedFromTheOldCardStaysOn() throws {
        defer { ThemeRuntime.apply(previous) }
        let suite = "cw.redesign.card.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ThemeDefinition.dither.id, forKey: ThemeLibrary.preferenceKey)
        var lib = ThemeLibrary(defaults: defaults, pinned: nil)
        lib.controlsAppearance = false
        #expect(lib.redesignAppearances == [.light, .dark])
        #expect(lib.underlying.preference == lib.appearanceMode)
        // The old card's dark circle: a dark half over Ocean.
        defaults.removePersistentDomain(forName: suite)
        defaults.set("ocean", forKey: ThemeLibrary.preferenceKey)
        defaults.set(try JSONSerialization.data(withJSONObject: ["dark": ThemeDefinition.dither.id]), forKey: ThemeLibrary.halvesKey)
        lib = ThemeLibrary(defaults: defaults, pinned: nil)
        lib.controlsAppearance = false
        #expect(lib.redesignAppearances == [.dark] && lib.underlying == .init(preference: "ocean"))
        lib.setRedesign(false)
        #expect(lib.preference == "ocean" && lib.halves == .init())
        // CANDY_THEME still pins Redesign over everything.
        #expect(ThemeLibrary(defaults: defaults, pinned: ThemeDefinition.dither.id).redesignAppearances == [.light, .dark])
    }

    /// While Redesign is on, the grid picks the theme under it: Redesign stays, and off brings the new pick.
    @Test func gridPicksTheThemeUnderRedesign() {
        defer { ThemeRuntime.apply(previous) }
        let lib = library()
        lib.setTheme("ocean")
        lib.setRedesign(true)
        lib.keepingRedesign { lib.setTheme("ember") }
        #expect(lib.redesignAppearances == [.light, .dark] && lib.underlying.preference == "ember")
        #expect(lib.pickedModes("ember") == [.light, .dark] && lib.pickedModes(ThemeDefinition.dither.id).isEmpty)
        lib.setRedesignUseIn([.dark])
        lib.keepingRedesign { lib.assignHalf(.light, "ocean") }
        #expect(lib.redesignAppearances == [.dark] && lib.owner(of: .light) == "ocean")
        lib.setRedesign(false)
        #expect(lib.preference == "ember" && lib.halves == .init(light: "ocean"))
    }

    @Test func themesGridHasNoRedesignCard() {
        #expect(!AppearanceSettingsView.gridBuiltIns.contains { $0.isDither })
        #expect(AppearanceSettingsView.gridBuiltIns.count == ThemeDefinition.pickerBuiltIns.count - 1)
        #expect(AppearanceSettingsView.redesignNotice([]) == nil)
        #expect(AppearanceSettingsView.redesignNotice([.dark])
                == "Redesign is on in dark mode, so the theme you pick here shows in light mode and when Redesign is off.")
    }
}
