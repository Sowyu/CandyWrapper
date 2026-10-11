import AppKit
import CoreText
import Testing
@testable import Features
@testable import SwiftTerm

/// The vendored SwiftTerm patch (Packages/SwiftTerm/README.md): Private Use Area symbols the base font lacks
/// resolve to the bundled Symbols Nerd Font, which CoreText's line layout skips under the system UI fonts.
@MainActor
struct TerminalSymbolFallbackTests {
    @Test func nerdFontSymbolsResolveUnderTheSystemMonospacedFont() {
        let font = TerminalFontSettings.font(family: "", size: 13)
        #expect(isPrivateUse("\u{E0A0}") && isPrivateUse("\u{F418}") && !isPrivateUse("a"))
        let fallback = privateUseFallbackFont(for: "\u{E0A0}", base: font)
        #expect(fallback.map { CTFontCopyPostScriptName($0 as CTFont) as String } == "SymbolsNFM")
        #expect(privateUseFallbackFont(for: "\u{E0A0}", base: NSFont(name: "SymbolsNFM", size: 13) ?? font) == nil)
    }
}
