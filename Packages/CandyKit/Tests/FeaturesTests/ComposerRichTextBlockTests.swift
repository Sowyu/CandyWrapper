import AppKit
import Testing
@testable import Features

// Ports of T3's apps/web/src/composer-list-split.test.ts, with the typed block rules, Return,
// Backspace, Delete, Tab and paste of ComposerPromptEditorTiptap.tsx:566-720, 1309-1340 and
// 1374-1460. Each case checks the stored draft, and that a rebuild from it shows the same blocks.

@MainActor private func makeEditor() -> ComposerEditor {
    let editor = ComposerEditor()
    editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
    editor.chipLook = ComposerChipLook.basic
    editor.richTextEnabled = true
    return editor
}

@MainActor private func type(_ editor: ComposerEditor, _ text: String) {
    for c in text { editor.insertText(String(c), replacementRange: editor.selectedRange()) }
}

@MainActor private func press(_ editor: ComposerEditor, keyCode: UInt16, characters: String) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    editor.keyDown(with: event)
}

/// Return that does not send (Shift+Enter in T3's default send mode).
@MainActor private func pressReturn(_ editor: ComposerEditor) throws {
    editor.onSubmitKey = { _ in false }
    try press(editor, keyCode: 36, characters: "\r")
}

/// Puts the caret `offset` characters into the first place `text` shows in the editor.
@MainActor private func placeCaret(_ editor: ComposerEditor, _ text: String, _ offset: Int = 0) {
    let at = (editor.string as NSString).range(of: text).location
    editor.setSelectedRange(NSRange(location: at + offset, length: 0))
}

/// One entry per display line: T3's node type names.
@MainActor private func lineKinds(_ editor: ComposerEditor) -> [String] {
    editor.blockLines().atoms.map { atom in
        switch atom?.kind {
        case .bullet?: "bulletList"
        case .ordered?: "orderedList"
        case .task?: "taskList"
        case .quote?: "blockquote"
        case .heading?: "heading"
        default: "paragraph"
        }
    }
}

/// Marker sources without the space after them, which T3 keeps as an attribute that prints nowhere.
@MainActor private func blockSources(_ editor: ComposerEditor) -> [String] {
    editor.blockLines().atoms.map { String(($0?.source ?? "").reversed().drop { $0 == " " }.reversed()) }
}

/// The stored draft, after checking a rebuild from it shows the same blocks and writes it again.
@MainActor private func storedDraft(_ editor: ComposerEditor) -> String {
    let stored = editor.expandedText
    let rebuilt = makeEditor()
    rebuilt.setText(stored)
    #expect(rebuilt.expandedText == stored)
    #expect(lineKinds(rebuilt) == lineKinds(editor), "\(stored)")
    #expect(blockSources(rebuilt) == blockSources(editor), "\(stored)")
    return stored
}

@MainActor struct ComposerRichTextListSplitTests {
    /// Splitting the last item keeps the source marker, indent and spacing.
    @Test(arguments: [("* a", "* a\n* b"), ("+ a", "+ a\n+ b"), ("- p\n  - a", "- p\n  - a\n  - b"), ("3) a", "3) a\n4) b"),
                      ("- [ ] p\n  - [ ] a", "- [ ] p\n  - [ ] a\n  - [ ] b")])
    func keepsTheSourceMarkerAndIndent(_ value: String, _ expected: String) throws {
        let editor = makeEditor()
        editor.setText(value)
        try pressReturn(editor)
        type(editor, "b")
        #expect(storedDraft(editor) == expected)
    }

    /// The second Return lifts the new empty item one level, written at its new depth.
    @Test(arguments: [
        ("- a\n  - x", "- a\n  - x\n- b"),
        ("* a\n  * x", "* a\n  * x\n* b"),
        ("1. a\n   1. x", "1. a\n   1. x\n2. b"),
        ("- a\n  - x\n- c", "- a\n  - x\n- b\n- c"),
        ("- a\n  - x\n  - y", "- a\n  - x\n- b\n  - y"),
        ("- [ ] a\n  - [ ] x", "- [ ] a\n  - [ ] x\n- [ ] b"),
        ("- [x] a\n  - [ ] x\n- [ ] c", "- [x] a\n  - [ ] x\n- [ ] b\n- [ ] c"),
    ])
    func returnTwiceOnAnItem(_ value: String, _ expected: String) throws {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "x", 1)
        try pressReturn(editor)
        try pressReturn(editor)
        type(editor, "b")
        #expect(storedDraft(editor) == expected)
    }

    @Test(arguments: [
        ("1. a\n2. x\n3. c\n4. d", "1. a\n2. x\n3. b\n4. c\n5. d"),
        ("1) a\n2) x\n3) c", "1) a\n2) x\n3) b\n4) c"),
        ("1. a\n   1. x\n   2. c\n2. d", "1. a\n   1. x\n   2. b\n   3. c\n2. d"),
    ])
    func returnInTheMiddleOfAnOrderedListRenumbers(_ value: String, _ expected: String) throws {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "x", 1)
        try pressReturn(editor)
        type(editor, "b")
        #expect(storedDraft(editor) == expected)
    }

    /// Return on an empty top-level item leaves the list; mid-text it splits the item.
    @Test func returnOnAnEmptyItemLeavesTheList() throws {
        let editor = makeEditor()
        editor.setText("1. a")
        try pressReturn(editor)
        try pressReturn(editor)
        type(editor, "b")
        #expect(storedDraft(editor) == "1. a\nb")
        let split = makeEditor()
        split.setText("1. foobar")
        placeCaret(split, "bar")
        try pressReturn(split)
        #expect(storedDraft(split) == "1. foo\n2. bar")
    }

    /// No task list one level up under a bullet, and an item holds one line: the draft stays
    /// what the editor shows.
    @Test(arguments: ["- a\n  - [ ] x", "- [ ] a\n  - x"])
    func returnOnAnEmptyTaskUnderABulletKeepsTheDraftHonest(_ value: String) throws {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "x", 1)
        try pressReturn(editor)
        try pressReturn(editor)
        _ = storedDraft(editor)
    }

    @Test(arguments: [
        ("- a\n  - x", "x", "- a\n- x"),
        ("- a\n  - x\n  - y", "x", "- a\n- x\n  - y"),
        ("- [ ] a\n  - [ ] x", "x", "- [ ] a\n- [ ] x"),
        ("- a\n- b\n- c", "b", "- a\nb\n- c"),
        ("- a\n  - [ ] x", "x", "- ax"),
        ("- a\n  - x\nb", "b", "- a\n  - xb"),
        ("1. a\nb", "b", "1. ab"),
        ("1. a\n   1. x\n2. c", "x", "1. a\n2. x\n3. c"),
    ])
    func backspaceAtTheStartOfALine(_ value: String, _ at: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, at)
        editor.deleteBackward(nil)
        #expect(storedDraft(editor) == expected)
    }

    @Test(arguments: [("- a\n```\nl1\nl2\n```", "- a\nl1\nl2"), ("p\n```ts\nl1\n```", "p\nl1")])
    func backspaceRemovesAFenceRatherThanJoiningItsCodeUp(_ value: String, _ expected: String) throws {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "l1")
        try press(editor, keyCode: 51, characters: "\u{7F}")
        #expect(storedDraft(editor) == expected)
    }

    @Test(arguments: [("- a\n- b", "- ab"), ("- a\n  - x\n- c", "- ax\n- c"), ("- a\n\nb", "- a\nb")])
    func deleteAtTheEndOfALine(_ value: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "a", 1)
        editor.deleteForward(nil)
        #expect(storedDraft(editor) == expected)
    }

    /// The review's crash: a quote line whose break is the draft's last character read one past the end.
    @Test func deleteAtTheEndOfAQuoteBeforeTheLastBreak() {
        let editor = makeEditor()
        editor.setText("> a\n")
        placeCaret(editor, "a", 1)
        editor.deleteForward(nil)
        #expect(storedDraft(editor) == "> a")
    }

    @Test(arguments: ["- a\n```\nl1\n```", "a\n```\nl1\n```"])
    func deleteLeavesAFenceAlone(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "a", 1)
        editor.deleteForward(nil)
        #expect(storedDraft(editor) == value)
    }

    /// `[ ] ` typed at the start of a bullet item makes it a task where it stands.
    @Test(arguments: [
        ("* x", "- [ ] x"),
        ("* a\n* x\n* c", "* a\n- [ ] x\n* c"),
        ("- a\n  * x", "- a\n  - [ ] x"),
        ("- a\n  - x\n  - y", "- a\n  - [ ] x\n  - y"),
        ("- x\n  - y", "- [ ] x\n  - y"),
        ("-   x", "-   [ ] x"),
    ])
    func typedBoxMakesABulletATask(_ value: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(value)
        placeCaret(editor, "x")
        type(editor, "[ ] ")
        #expect(storedDraft(editor) == expected)
        // The caret is at the start of the item's text.
        #expect((editor.string as NSString).substring(from: editor.selectedRange().location).hasPrefix("x"))
    }

    /// T3 inserts content that is not one plain line as whole blocks: lines pasted at the end
    /// of an item go after the list.
    @Test func putsLinesPastedAtTheEndOfAnItemAfterTheList() {
        let editor = makeEditor()
        editor.setText("- a")
        #expect(editor.pasteBlocks("one\ntwo"))
        #expect(storedDraft(editor) == "- a\none\ntwo")
    }
}

@MainActor struct ComposerRichTextBlockTypingTests {
    /// Effort stepping restores the caret by its offset in the draft. A rule before it keeps its newline
    /// there, so the caret stays on the line after the rule.
    @Test func expandedCaretRoundTripsPastARule() {
        let editor = makeEditor()
        editor.setText("---\nabc")
        let target = (editor.expandedText as NSString).range(of: "abc").location
        editor.expandedCaret = target
        #expect(editor.expandedCaret == target)
        type(editor, "X")
        #expect(storedDraft(editor) == "---\nXabc")
    }

    /// Each rule fires on the keystroke that completes it, at the start of a plain line.
    @Test(arguments: [
        ("* item", "bulletList"), ("+ item", "bulletList"), ("- item", "bulletList"), ("1. item", "orderedList"),
        ("3) item", "orderedList"), ("- [ ] todo", "taskList"), ("- [x] done", "taskList"), ("> quote", "blockquote"),
        ("## Title", "heading"), ("#1234", "paragraph"), ("-x", "paragraph"), ("1.5 apples", "paragraph"),
    ])
    func typedMarkersBecomeBlocks(_ typed: String, _ kind: String) {
        let editor = makeEditor()
        type(editor, typed)
        #expect(editor.expandedText == typed)
        #expect(lineKinds(editor) == [kind])
    }

    /// `- ` waits for the next character, so `- [ ] ` can be typed whole; a bare `- ` stays text.
    @Test func aDashWaitsForTheFirstCharacter() {
        let editor = makeEditor()
        type(editor, "- ")
        #expect(lineKinds(editor) == ["paragraph"])
        #expect(editor.expandedText == "- ")
    }

    /// A task typed whole is empty until text follows, written without the space after its box.
    @Test func aTypedTaskWritesItsBoxBareWhileEmpty() {
        let editor = makeEditor()
        type(editor, "- [ ] ")
        #expect(editor.expandedText == "- [ ]")
        type(editor, "x")
        #expect(editor.expandedText == "- [ ] x")
    }

    /// Only the keystroke that completes a rule fires, and only at the start of a plain line.
    @Test func onlyTheKeystrokeThatCompletesARuleFires() {
        let editor = makeEditor()
        editor.setText("a* b")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.deleteBackward(nil)
        #expect(lineKinds(editor) == ["paragraph"])
        #expect(editor.expandedText == "* b")
        let indented = makeEditor()
        type(indented, "  * x")
        #expect(lineKinds(indented) == ["paragraph"])
    }

    /// Backspace right after a rule fired puts back what was typed, which then stays text.
    @Test func backspaceRightAfterARuleUndoesIt() {
        let editor = makeEditor()
        type(editor, "> ")
        #expect(lineKinds(editor) == ["blockquote"])
        editor.deleteBackward(nil)
        #expect(lineKinds(editor) == ["paragraph"])
        #expect(editor.expandedText == "> ")
        type(editor, "x")
        #expect(editor.expandedText == "> x")
        #expect(lineKinds(editor) == ["paragraph"])
        // Later, Backspace at the start of a quote's text unwraps it.
        let quote = makeEditor()
        quote.setText("> q")
        placeCaret(quote, "q")
        quote.deleteBackward(nil)
        #expect(quote.expandedText == "q")
    }

    @Test func returnContinuesAndLeavesAQuote() throws {
        let editor = makeEditor()
        editor.setText("> a")
        try pressReturn(editor)
        type(editor, "b")
        #expect(storedDraft(editor) == "> a\n> b")
        try pressReturn(editor)
        try pressReturn(editor)
        type(editor, "c")
        #expect(storedDraft(editor) == "> a\n> b\nc")
        let middle = makeEditor()
        middle.setText(">  ab")
        placeCaret(middle, "b")
        try pressReturn(middle)
        #expect(storedDraft(middle) == ">  a\n>  b")
    }

    @Test(arguments: [(2, "# Ti\n# tle"), (0, "\n# Title"), (5, "# Title\nb")])
    func returnInAHeading(_ offset: Int, _ expected: String) throws {
        let editor = makeEditor()
        editor.setText("# Title")
        placeCaret(editor, "Title", offset)
        try pressReturn(editor)
        if offset == 5 { type(editor, "b") }
        #expect(storedDraft(editor) == expected)
    }

    @Test func backspaceJoinsQuoteLinesAndHeadings() {
        let editor = makeEditor()
        editor.setText("> a\n> b")
        placeCaret(editor, "b")
        editor.deleteBackward(nil)
        #expect(storedDraft(editor) == "> ab")
        let heading = makeEditor()
        heading.setText("text\n# Head")
        placeCaret(heading, "Head")
        heading.deleteBackward(nil)
        #expect(storedDraft(heading) == "textHead")
        let first = makeEditor()
        first.setText("# Head")
        placeCaret(first, "Head")
        first.deleteBackward(nil)
        #expect(first.expandedText == "# Head")
    }

    @Test func tabNestsAnItemAndKeepsTheCaret() throws {
        let editor = makeEditor()
        editor.setText("- a\n- bc")
        placeCaret(editor, "bc", 1)
        try press(editor, keyCode: 48, characters: "\t")
        #expect(storedDraft(editor) == "- a\n  - bc")
        type(editor, "x")
        #expect(editor.expandedText == "- a\n  - bxc")
    }

    /// A character typed in a list item, quote or heading already looks rendered, so the
    /// keystroke edits one character and never restyles the whole draft (the M8 keystroke budget).
    @Test(arguments: ["- one\n- two", "1. a\n   - b", "> q", "# Head", "text\n## Sub", "plain", "Steps\n- a", "> a\n> b", "- [ ] t", "a\n> q\nb\n- c"])
    func typedTextInABlockRendersToItself(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        final class Edits: @unchecked Sendable { var ranges: [NSRange] = [] }
        let edits = Edits()
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: editor.textStorage, queue: nil) { note in
            edits.ranges.append((note.object as! NSTextStorage).editedRange)
        }
        type(editor, "x")
        NotificationCenter.default.removeObserver(token)
        #expect(editor.expandedText == value + "x")
        #expect(edits.ranges.allSatisfy { $0.length <= 1 }, "\(edits.ranges)")
    }

    @Test func aMarkerHoldsNoCaret() {
        let editor = makeEditor()
        editor.setText("a\n- b")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(editor.selectedRange().location == 3)
    }

    /// Pasted Markdown is read as T3 reads it: blocks at the top level, quote lines in a quote,
    /// literal lines after a list item.
    @Test(arguments: [
        ("", "", 0, "- x\n- y", "- x\n- y"),
        ("ab", "ab", 2, "- x\n- y", "ab\n- x\n- y"),
        ("ab", "ab", 1, "one\ntwo", "a\none\ntwo\nb"),
        ("ab", "ab", 0, "# h", "# h\nab"),
        ("ab", "ab", 1, "plain", "aplainb"),
        ("> ab", "ab", 1, "one\ntwo", "> a\n> one\n> two\n> b"),
        ("- ab", "ab", 1, "one\ntwo", "- a\none\ntwo\n- b"),
        ("- ab", "ab", 1, "- x", "- a- xb"),
    ])
    func pastedBlocks(_ value: String, _ at: String, _ offset: Int, _ pasted: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(value)
        if at.isEmpty { editor.setSelectedRange(NSRange(location: 0, length: 0)) } else { placeCaret(editor, at, offset) }
        editor.clipboardEdit = true
        if !editor.pasteBlocks(pasted) { editor.insertText(pasted, replacementRange: editor.selectedRange()) }
        editor.clipboardEdit = false
        #expect(editor.expandedText == expected)
    }

    /// The editor is as tall as T3's: margins collapse, headings and lists keep their boxes.
    @Test func contentHeightMatchesTheReferenceLayout() throws {
        let repo = SidebarFidelityTests.repo
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-rich.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-rich/manifest.json"))) as! [String: [String: Double]]
        for c in spec["cases"] as! [[String: Any]] where ["list", "nestedlist", "quote", "heading", "task"].contains(c["name"] as! String) {
            let editor = makeEditor()
            editor.setText((c["native"] as! [String: String])["text"]!)
            #expect(abs(editor.contentHeight - manifest[c["name"] as! String]!["height"]!) < 1, "\(c["name"]!)")
        }
    }
}

struct ComposerBlockLayoutTests {
    @Test func groupsListLinesLikeT3() {
        typealias L = ComposerBlockLayout.Line
        let lines: [L] = [.list(.bullet, indent: "", marker: "-"), .list(.bullet, indent: "  ", marker: "-"), .list(.bullet, indent: "  ", marker: "*"),
                          .list(.ordered, indent: "", marker: "1."), .paragraph, .list(.task, indent: "  ", marker: "")]
        let lists = ComposerBlockLayout.lists(lines)
        #expect(lists.parent(of: 1) == 0)
        #expect(lists.parent(of: 2) == 0)
        #expect(lists.listOf[1] != lists.listOf[2])
        #expect(lists.parent(of: 3) == nil)
        #expect(lists.listOf[0] != lists.listOf[3])
        #expect(lists.parent(of: 5) == nil)
        let layout = ComposerBlockLayout.layout(lines)
        #expect(layout.lines[1].textX == 40)
        #expect(layout.lines[1].bullet == .circle)
        #expect(layout.lines[3].marginBefore == ComposerBlockLayout.blockMargin)
        #expect(layout.lines[5].textX == ComposerBlockLayout.taskGutter)
        #expect(layout.top == ComposerBlockLayout.blockMargin)
    }
}
