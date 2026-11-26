import Testing
import T3Protocol
@testable import Features

struct ComposerEffortTests {
    @Test func offAndNamedLevels() {
        let options = ["off", "low", "medium", "high", "max", "ultrathink"].map { ProviderOptionChoice(id: $0, label: $0.capitalized) }
        let descriptor = ProviderOptionDescriptor(id: "effort", label: "Effort", type: .select, options: options, promptInjectedValues: ["ultrathink"])
        #expect(ComposerEffort.resolve(descriptor, current: "off")?.filled == 0)
        #expect(ComposerEffort.resolve(descriptor, current: "medium") == .init(count: 3, filled: 2, label: "Medium", special: false))
        #expect(ComposerEffort.resolve(descriptor, current: "max")?.special == true)
        #expect(ComposerEffort.resolve(descriptor, current: "ultrathink")?.special == true)
        #expect(ComposerEffort.resolve(descriptor, current: "missing") == nil)
        #expect(ComposerEffort.resolve(descriptor, current: nil) == nil)
        #expect(ComposerEffort.heights(count: 4) == [6, 8, 10, 12])
    }

    /// EffortGlyph.test.ts at 5258 (#30810): Codex's Ultra is named above the bars, so Xhigh still fills the scale.
    @Test func codexUltraStaysOffTheScale() {
        let options = ["low", "medium", "high", "xhigh", "max", "ultra"].map { ProviderOptionChoice(id: $0, label: $0.capitalized) }
        let codex = ProviderOptionDescriptor(id: "reasoningEffort", label: "Reasoning", type: .select, options: options)
        #expect(ComposerEffort.resolve(codex, current: "xhigh") == .init(count: 4, filled: 4, label: "Xhigh", special: false))
        #expect(ComposerEffort.resolve(codex, current: "ultra") == .init(count: 4, filled: 4, label: "Ultra", special: true))
    }
}
