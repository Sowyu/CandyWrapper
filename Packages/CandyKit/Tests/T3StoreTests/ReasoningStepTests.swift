import Testing
import T3Protocol
@testable import T3Store

/// `getComposerReasoningStep` (composerProviderState.test.tsx, 2993dfc069): one keyboard effort step.
struct ReasoningStepTests {
    static let levels: [ProviderOptionChoice] = [.init(id: "low", label: "Low"), .init(id: "medium", label: "Medium", isDefault: true),
                                                 .init(id: "high", label: "High")]
    static let claude = ServerProviderModel(slug: "opus", name: "Opus", optionDescriptors: [
        ProviderOptionDescriptor(id: "effort", label: "Effort", type: .select,
                                 options: [.init(id: "medium", label: "Medium"), .init(id: "high", label: "High", isDefault: true),
                                           .init(id: "ultrathink", label: "Ultrathink")],
                                 promptInjectedValues: ["ultrathink"]),
    ])

    static func model(_ descriptors: [ProviderOptionDescriptor]) -> ServerProviderModel {
        ServerProviderModel(slug: "m", name: "M", optionDescriptors: descriptors)
    }

    static func select(_ id: String, _ options: [ProviderOptionChoice]) -> ProviderOptionDescriptor {
        ProviderOptionDescriptor(id: id, label: id, type: .select, options: options)
    }

    static func sel(_ pairs: (String, String)...) -> [ProviderOptionSelection] {
        pairs.map { ProviderOptionSelection(id: $0.0, value: .string($0.1)) }
    }

    static func step(_ model: ServerProviderModel, _ options: [ProviderOptionSelection]?, prompt: String = "Fix the bug",
                     cursor: Int = 0, direction: Int = 1) -> ModelTraits.ReasoningStep? {
        ModelTraits.reasoningStep(model: model, options: options, prompt: prompt, cursor: cursor, direction: direction)
    }

    @Test func wrapsAtBothEndsAndKeepsOtherTraits() {
        let m = Self.model([Self.select("contextWindow", [.init(id: "200k", label: "200k", isDefault: true), .init(id: "1m", label: "1M")]),
                            Self.select("reasoningEffort", Self.levels)])
        for (from, direction, to) in [("low", -1, "high"), ("low", 1, "medium"), ("high", 1, "low"), ("high", -1, "medium")] {
            let result = Self.step(m, Self.sel(("contextWindow", "1m"), ("reasoningEffort", from)), direction: direction)
            #expect(result == .init(prompt: "Fix the bug", cursor: 0, options: Self.sel(("contextWindow", "1m"), ("reasoningEffort", to))),
                    "\(from) by \(direction)")
        }
        // No explicit choice starts from the catalog default.
        #expect(Self.step(Self.model([Self.select("variant", Self.levels)]), nil)?.options == Self.sel(("variant", "high")))
    }

    @Test func ultrathinkPrefixKeepsTheCaret() {
        let on = "  Fix the bug \n"
        let added = Self.step(Self.claude, Self.sel(("effort", "high")), prompt: on, cursor: 10)
        #expect(added == .init(prompt: "Ultrathink:\nFix the bug", cursor: 20, options: nil))
        // The prefix, not the draft's Medium, is the current level.
        let off = "Ultrathink:\n  Fix the bug"
        let stripped = Self.step(Self.claude, Self.sel(("effort", "medium")), prompt: off, cursor: 22, direction: -1)
        #expect(stripped == .init(prompt: "Fix the bug", cursor: 8, options: Self.sel(("effort", "high"))))
        // A caret in leading whitespace does not land inside the new prefix.
        #expect(Self.step(Self.claude, Self.sel(("effort", "high")), prompt: "   Fix")?.cursor == "Ultrathink:\n".utf16.count)
        // An empty prompt gets just the prefix.
        #expect(Self.step(Self.claude, Self.sel(("effort", "high")), prompt: "")?.prompt == "Ultrathink:\n")
    }

    @Test func slashCommandSkipsUltrathinkAndBodyLocks() {
        #expect(Self.step(Self.claude, Self.sel(("effort", "high")), prompt: "/review")
                == .init(prompt: "/review", cursor: 0, options: Self.sel(("effort", "medium"))))
        #expect(Self.step(Self.claude, Self.sel(("effort", "high")), prompt: "Please ultrathink harder") == nil)
        #expect(Self.step(Self.claude, Self.sel(("effort", "high")), prompt: "Ultrathink:\nPlease ultrathink harder", direction: -1) == nil)
    }

    @Test func noOps() {
        #expect(Self.step(Self.model([Self.select("reasoningEffort", [.init(id: "high", label: "High")])]), nil) == nil)
        #expect(Self.step(Self.model([Self.select("contextWindow", Self.levels)]), nil) == nil)
        #expect(ModelTraits.reasoningStep(model: nil, options: nil, prompt: "", cursor: 0, direction: 1) == nil)
    }

    @Test func providerDefaultFastModeStaysOff() {
        let m = Self.model([Self.select("reasoning", Self.levels),
                            ProviderOptionDescriptor(id: "fastMode", label: "Fast", type: .boolean, currentValue: .bool(true))])
        #expect(Self.step(m, nil)?.options == Self.sel(("reasoning", "high")) + [.init(id: "fastMode", value: .bool(false))])
        #expect(Self.step(m, [.init(id: "fastMode", value: .bool(true))])?.options
                == Self.sel(("reasoning", "high")) + [.init(id: "fastMode", value: .bool(true))])
    }
}
