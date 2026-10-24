import Foundation
import Testing
import DesignSystem
@testable import Features

/// Settings > Experimental > Redesign: on remembers the theme in use, off brings it back.
@MainActor
struct RedesignSwitchTests {
    private func library() -> ThemeLibrary {
        ThemeLibrary(defaults: UserDefaults(suiteName: "cw.redesign.tests.\(UUID().uuidString)")!, pinned: nil)
    }

    @Test func offRestoresThePreviousThemeAndItsMix() {
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
        let lib = library()
        lib.setThemeHalf(.dark, ThemeDefinition.dither.id)
        #expect(lib.isRedesignOn)
        lib.setRedesign(false)
        #expect(!lib.isRedesignOn)
    }
}
