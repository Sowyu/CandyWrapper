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
}
