import AppKit
import Testing
@testable import DesignSystem

@MainActor
struct FieldLigatureTests {
    /// #42352: `font-variant-ligatures: none` turns off ligatures and contextual forms in the typed text.
    @Test func ligaturesOffReachesTheTypedText() throws {
        let field = TextareaView(placeholder: "bun test", text: "a -- b")
        #expect(field.editor.typingAttributes[.ligature] == nil)
        field.ligatures = false
        #expect(field.editor.typingAttributes[.ligature] as? Int == 0)
        let font = try #require(field.editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let settings = font.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]] ?? []
        #expect(settings.contains { $0[.typeIdentifier] == kContextualAlternatesType && $0[.selectorIdentifier] == kContextualAlternatesOffSelector })
    }
}
