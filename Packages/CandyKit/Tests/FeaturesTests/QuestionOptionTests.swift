import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

@MainActor struct QuestionOptionTests {
    @Test func selectionKeepsShortcutAndAlignsControlsToFirstLine() {
        let row = OptionRow(frame: .zero)
        let option = UserInputQuestion.Option(label: "Choice", description: String(repeating: "Long description ", count: 20))
        row.configure(option, shortcut: 1, selected: true, disabled: false, multiSelect: false)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: row.height(forWidth: 260))
        row.layoutSubtreeIfNeeded()
        #expect(row.radio.isChecked && !row.radio.isHidden)
        #expect(row.checkbox.isHidden)
        #expect(row.key.keys == "1" && !row.key.isHidden)
        #expect(row.radio.frame.midY == row.key.frame.midY)
        #expect(row.key.frame.maxY < row.bounds.midY)
        #expect(row.hitTest(row.radio.frame.origin) === row)
        row.configure(option, shortcut: 1, selected: true, disabled: true, multiSelect: true)
        #expect(row.radio.isHidden && !row.checkbox.isHidden)
        #expect(row.checkbox.value == .on)
        #expect(!row.key.isHidden && row.alphaValue == 0.5)
        row.configure(option, shortcut: nil, selected: false, disabled: false, multiSelect: true)
        #expect(row.key.isHidden && row.checkbox.value == .off)
    }
}
