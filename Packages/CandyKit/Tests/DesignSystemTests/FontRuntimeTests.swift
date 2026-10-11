import Testing
import AppKit
@testable import DesignSystem

@MainActor @Suite(.serialized) struct FontRuntimeTests {
    @Test func defaultsKeepOriginalMetrics() {
        FontRuntime.apply(.init())
        #expect(DSFont.ui(14) == NSFont.systemFont(ofSize: 14))
        let reference = CTFontCreateUIFontForLanguage(.userFixedPitch, 13, nil)! as NSFont
        #expect(DSFont.mono(13).fontName == reference.fontName)
        #expect(DSFont.mono(13).pointSize == reference.pointSize)
        #expect(FontRuntime.font(.terminal, size: 12).pointSize == 12)
    }
    @Test func rolesDoNotDoubleScale() {
        defer { FontRuntime.apply(.init()) }
        var input = FontRuntimeInput()
        input.interfaceSize = 20; input.promptSize = 18; input.codeSize = 16
        FontRuntime.apply(input)
        #expect(DSFont.ui(14).pointSize == 17.5)
        #expect(FontRuntime.font(.prompt, size: 14).pointSize == 18)
        #expect(DSFont.mono(13).pointSize == 16)
        #expect(FontRuntime.font(.terminal, size: 12).pointSize == 16)
        input.advanced = true; input.terminalSize = 10
        FontRuntime.apply(input)
        #expect(FontRuntime.font(.terminal, size: 12).pointSize == 10)
    }
    @Test func detachedLabelCatchesUpAndDoesNotCompoundSize() {
        defer { FontRuntime.apply(.init()) }
        FontRuntime.apply(.init())
        let label = LabelView("Settings", font: DSFont.ui(14))
        var input = FontRuntimeInput(); input.interfaceSize = 20
        FontRuntime.apply(input); label.fontRuntimeDidChange()
        #expect(label.font.pointSize == 17.5)
        input.interfaceSize = 12
        FontRuntime.apply(input); label.fontRuntimeDidChange()
        #expect(label.font.pointSize == 10.5)
        FontRuntime.apply(.init()); label.fontRuntimeDidChange()
        #expect(label.font.pointSize == 14)
    }
    @Test func familyFallbackAndNoOp() {
        defer { FontRuntime.apply(.init()) }
        var input = FontRuntimeInput(); input.interfaceFamily = "Missing font, Menlo"
        FontRuntime.apply(input)
        #expect(DSFont.ui(14).familyName == "Menlo")
        #expect(FontRuntime.font(.prompt, size: 14).familyName == "Menlo")
        let generation = FontRuntime.generation
        FontRuntime.apply(input)
        #expect(FontRuntime.generation == generation)
    }
}
