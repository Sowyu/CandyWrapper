import Testing
import T3Protocol
@testable import Features

struct ComposerSetupTests {
    @Test func customModelDropsInjectedValuesAndPreservesDescriptions() {
        let option: JSONValue = .object([
            "id": .string("effort"), "label": .string("Reasoning"), "type": .string("select"),
            "description": .string("Detail"), "currentValue": .string("high"),
            "promptInjectedValues": .array([.string("ultrathink")]),
            "options": .array([
                .object(["id": .string("high"), "label": .string("High")]),
                .object(["id": .string("ultrathink"), "label": .string("Ultra")]),
            ]),
        ])
        let entry: JSONValue = .object(["slug": .string("custom"), "name": .string("custom"),
            "capabilities": .object(["optionDescriptors": .array([option])])])
        let draft = ComposerCustomModelDraft(entry)
        #expect(draft.name.isEmpty)
        #expect(draft.error == nil)
        let descriptor = draft.definition["capabilities"]?["optionDescriptors"]?.arrayValue?.first
        #expect(descriptor?["options"]?.arrayValue?.count == 1)
        #expect(descriptor?["currentValue"]?.stringValue == "high")
        #expect(descriptor?["description"]?.stringValue == "Detail")
        #expect(descriptor?["promptInjectedValues"] == nil)
    }
    @Test func customModelValidation() {
        var draft = ComposerCustomModelDraft(.string("model"))
        #expect(draft.definition["capabilities"] == .null)
        draft.descriptors = [["type": .string("select"), "id": .string(""), "label": .string("")]]
        #expect(draft.error == "Option 1 needs an id.")
        draft.descriptors[0]["id"] = .string("effort")
        draft.descriptors[0]["label"] = .string("Effort")
        #expect(draft.error == "Option 1 needs at least one choice.")
        draft.descriptors[0]["type"] = .string("boolean")
        #expect(draft.error == nil)
        draft.descriptors.append(draft.descriptors[0])
        #expect(draft.error == "Option 2: id \"effort\" is used twice.")
    }
    @Test func terminalRollingWindow() {
        let first = ComposerProviderAuthOutput.delta(output: "hello", offset: nil, written: 0)
        #expect(!first.reset && first.text == "hello" && first.offset == 5)
        let tail = ComposerProviderAuthOutput.delta(output: "lo world", offset: 11, written: 5)
        #expect(!tail.reset && tail.text == " world")
        let gap = ComposerProviderAuthOutput.delta(output: "new", offset: 100, written: 5)
        #expect(gap.reset && gap.text == "new")
        let repeated = ComposerProviderAuthOutput.delta(output: "new", offset: 100, written: 100)
        #expect(!repeated.reset && repeated.text.isEmpty)
        #expect(ComposerProviderAuthOutput.delta(output: "reset", offset: 5, written: 100).reset)
    }
}
