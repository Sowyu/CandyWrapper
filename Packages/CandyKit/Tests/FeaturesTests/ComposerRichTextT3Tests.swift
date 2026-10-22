import AppKit
import Testing
@testable import Features

// Ports of T3's apps/web/src/composer-rich-text.test.ts and composer-rich-text-doc.test.ts,
// one Swift test per T3 case, with T3's inputs and expected values. T3 builds a ProseMirror
// document; we hold an attributed string with atomic block prefixes and chips. Where a case
// asserts ProseMirror positions, the port asserts what a user sees and what the server gets:
// the Markdown (`expandedText`), the visible text and our display-to-Markdown caret offsets.

private typealias Span = ComposerRichText.Span

@MainActor private func makeEditor(rich: Bool = true, chips: Bool = true) -> ComposerEditor {
    let editor = ComposerEditor()
    editor.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
    if chips { editor.chipLook = ComposerChipLook.basic }
    editor.richTextEnabled = rich
    return editor
}

/// `roundTrip`: the stored draft read back into the editor and written out again.
@MainActor private func roundTrip(_ value: String) -> String {
    let editor = makeEditor()
    editor.setText(value)
    return editor.expandedText
}

/// `roundTripPlain`: the same with rich text off in Settings.
@MainActor private func roundTripPlain(_ value: String) -> String {
    let editor = makeEditor(rich: false)
    editor.setText(value)
    return editor.expandedText
}

@MainActor private func mapping(_ editor: ComposerEditor) -> ComposerRichText.Mapping {
    ComposerRichTextStyler.mapping(editor.textStorage!)
}

/// The display caret a Markdown offset lands on: offsets inside markers clamp onto the text.
private func display(_ map: ComposerRichText.Mapping, markdown: Int) -> Int {
    map.offsets.firstIndex { $0 >= markdown } ?? map.offsets.count - 1
}

/// Every display caret maps into the Markdown, in order, ending at its end.
@MainActor private func expectMonotonicMapping(_ editor: ComposerEditor, _ value: String) {
    let map = mapping(editor)
    #expect(map.offsets.count == (editor.string as NSString).length + 1, "\(value)")
    #expect(zip(map.offsets, map.offsets.dropFirst()).allSatisfy { $0 <= $1 }, "\(value)")
    #expect(map.offsets.last == (map.value as NSString).length, "\(value)")
    for i in map.offsets.indices {
        #expect(map.offsets[display(map, markdown: map.offsets[i])] == map.offsets[i], "\(value) at \(i)")
    }
}

/// One entry per display line: the block it is, as T3's node type names.
@MainActor private func lineKinds(_ editor: ComposerEditor) -> [String] {
    let storage = editor.textStorage!
    let text = storage.string as NSString
    var kinds: [String] = []
    var start = 0
    while true {
        let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
        let end = newline.location == NSNotFound ? text.length : newline.location
        var kind = "paragraph"
        if end > start, let block = storage.attribute(.attachment, at: start, effectiveRange: nil) as? ComposerBlockAttachment {
            switch block.kind {
            case .bullet: kind = "bulletList"
            case .ordered: kind = "orderedList"
            case .task: kind = "taskList"
            case .quote: kind = "blockquote"
            case .heading: kind = "heading"
            case .rule: kind = "horizontalRule"
            case .codeHeader: kind = "codeBlock"
            case .codeEnd: kind = "codeEnd"
            }
        } else if end > start, storage.attribute(.composerCodeBlock, at: start, effectiveRange: nil) != nil {
            kind = "code"
        }
        kinds.append(kind)
        if newline.location == NSNotFound { break }
        start = end + 1
    }
    return kinds
}

/// The block attachment sources, in order.
@MainActor private func blockSources(_ editor: ComposerEditor) -> [String] {
    var sources: [String] = []
    let storage = editor.textStorage!
    storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        if let block = value as? ComposerBlockAttachment { sources.append(block.source) }
    }
    return sources
}

/// Marks of each display character, as sets (T3 keeps them in schema order).
@MainActor private func markSets(_ editor: ComposerEditor) -> [Set<String>] {
    let storage = editor.textStorage!
    return (0..<storage.length).map { i in
        Set(ComposerRichTextStyler.marks(storage.attribute(.composerMarks, at: i, effectiveRange: nil)).map(\.rawValue))
    }
}

@MainActor private func type(_ editor: ComposerEditor, _ text: String) {
    editor.insertText(text, replacementRange: editor.selectedRange())
}

@MainActor private func press(_ editor: ComposerEditor, keyCode: UInt16, characters: String) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    editor.keyDown(with: event)
}

@MainActor private func pressReturn(_ editor: ComposerEditor) throws {
    editor.onSubmitKey = { _ in false }
    try press(editor, keyCode: 36, characters: "\r")
}

// MARK: - composer-rich-text.test.ts

struct ComposerRichTextT3InlineTests {
    @Test func parsesBoldMarkersIntoStyledSpans() {
        #expect(ComposerRichText.parse("hello **bold** world") == [
            Span(text: "hello ", marks: []), Span(text: "bold", marks: [.bold]), Span(text: " world", marks: []),
        ])
    }

    @Test(arguments: ["plain text", "snake_case", "unmatched **", "** spaced **", #"\*literal\*"#])
    func preservesUnmatchedMarkersEscapedMarkersAndIdentifiers(_ text: String) {
        #expect(ComposerRichText.parse(text) == [Span(text: text, marks: [])])
    }

    @Test func rendersTripleMarkersAndNestedStyles() {
        #expect(ComposerRichText.parse("***both***") == [Span(text: "both", marks: [.bold, .italic])])
        #expect(ComposerRichText.parse("*a **b** c*") == [
            Span(text: "a ", marks: [.italic]), Span(text: "b", marks: [.italic, .bold]), Span(text: " c", marks: [.italic]),
        ])
        #expect(ComposerRichText.parse("**a `code` c**") == [
            Span(text: "a ", marks: [.bold]), Span(text: "code", marks: [.bold, .code]), Span(text: " c", marks: [.bold]),
        ])
    }

    @Test func preservesCrossingItalicAndBoldSpans() {
        #expect(ComposerRichText.parse("*a**b*****c**") == [
            Span(text: "a", marks: [.italic]), Span(text: "b", marks: [.italic, .bold]), Span(text: "c", marks: [.bold]),
        ])
    }

    @Test func keepsRepeatedAndAlternateDelimitersLiteralInsideAnActiveMark() {
        let repeated = String(repeating: "*", count: 10_000)
        #expect(ComposerRichText.parse(repeated + "text" + repeated) == [
            Span(text: String(repeated.dropFirst(2)) + "text", marks: [.bold]), Span(text: String(repeated.dropFirst(2)), marks: []),
        ])
        let alternate = String(repeating: "__", count: 5_000)
        #expect(ComposerRichText.parse("**~~" + alternate + "text" + alternate + "~~**") == [
            Span(text: alternate + "text" + alternate, marks: [.bold, .strike]),
        ])
    }

    @Test func keepsCodeSpanContentsLiteral() {
        #expect(ComposerRichText.parse("`**not bold**`") == [Span(text: "**not bold**", marks: [.code])])
    }
}

// MARK: - composer-rich-text-doc.test.ts: literal editor answers

/// T3's `literalText` editor holds answers verbatim. Ours is the editor with rich text and chips off.
@MainActor struct ComposerRichTextT3LiteralTests {
    @Test(arguments: [
        "", "\n\n", "  - [X] done\n\n**keep** €my-skill @README.md  \n", "line one\r\nline two\r\n",
        "- [X] done\n" + String(repeating: "  detail €my-skill @README.md\n", count: 100),
    ])
    func preservesTheCompleteAnswerThroughSelectionAndSerialization(_ value: String) {
        let editor = makeEditor(rich: false, chips: false)
        editor.setText(value)
        #expect(editor.expandedText == value)
        #expect(editor.string == value)
        #expect(editor.expanded(NSRange(location: 0, length: (editor.string as NSString).length)) == value)
        #expect(mapping(editor).offsets == Array(0...(value as NSString).length))
    }

    @Test func editsLiteralMarkdownInsertsANewlineAndPreservesAnExplicitlyClearedAnswer() {
        let value = "  - [X] done €my-skill @README.md  "
        let editor = makeEditor(rich: false, chips: false)
        editor.setText(value)
        type(editor, " edited")
        type(editor, "\n")
        type(editor, "second line  ")
        #expect(editor.expandedText == "\(value) edited\nsecond line  ")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        type(editor, "")
        #expect(editor.expandedText == "")
    }
}

// MARK: - composer-rich-text-doc.test.ts: document model

@MainActor struct ComposerRichTextT3DocTests {
    @Test(arguments: ["€", "£", "¥", "₹", "₩", "₿", "𑿝"])
    func canonicalizesSkillAliasesWhilePreservingAmounts(_ prefix: String) {
        let value = "Use \(prefix)my-skill for \(prefix)20 please"
        let expected = "Use $my-skill for \(prefix)20 please"
        #expect(roundTrip(value) == expected)
        #expect(roundTripPlain(value) == expected)
    }

    @Test(arguments: [
        "", "\n\n", "plain text", "hello **bold** world", "a *italic* word and `code` here", "struck ~~out~~ now",
        "**`x`**", "*`x`*", "~~`x`~~", "**a `code` c**", "***bold italic*** keeps nesting", "line one\nline two",
        "trailing newline\n", "1. foo\n2. asdf\n", "- [ ] buy milk", "-   [ ]  buy milk", "\t-\t[x]\t\titem", "- [ ]  ",
        "- [ ]\n  - [ ] child", "  - [ ] first\n - [ ] second\n  - [ ] child", "**before @README.md after**",
        "*a **b** c*", "*a**b***", "**a*b***", "**a *b* c**", "literal \u{FFFC} **before @README.md after**",
        "- [x] done\n- [ ] next", "- [ ] parent\n  - [ ] child\n  - [ ] sibling\n- [ ] uncle",
        "- [ ] empty task follows\n- [ ]", "- [ ] **bold** task with @README.md", "para\n- [ ] task\npara",
        "- [ ]No space stays literal", "-[ ] also literal", "@README.md explain this",
        "@\"docs/My File.md\" and $my-skill please", "snake_case stays literal", "unmatched ** stays literal",
        "**bold** then @README.md then *italic*",
    ])
    func roundTripsThroughARealDocument(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    @Test(arguments: ["", "\n", "text\n\n", "- [ ]\n- [ ] next\n", "- [ ] parent\n  - [ ] child\n- [ ]", "para\n- [ ] task\npara", "**before @README.md after**"])
    func mapsEditablePositions(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        expectMonotonicMapping(editor, value)
    }

    /// T3 keeps the caret inside the paragraph after a trailing hard break. Ours has no hard
    /// break: Shift+Return writes a newline, and the caret sits on the line after it.
    @Test func keepsTheCaretAfterATrailingHardBreakInsideTheSameParagraph() {
        let editor = makeEditor()
        editor.setText("a")
        type(editor, "\n")
        #expect(editor.expandedText == "a\n")
        #expect(mapping(editor).offsets[editor.selectedRange().location] == 2)
    }

    /// Ours keeps every task line flat with its own indent; T3 nests them. The Markdown and the
    /// markers each line draws are the same.
    @Test func rendersALeadingTaskDedentAsSiblingsAndNestsUnderTheNewIndent() {
        let editor = makeEditor()
        editor.setText("  - [ ] first\n - [ ] second\n  - [ ] child")
        #expect(lineKinds(editor) == ["taskList", "taskList", "taskList"])
        #expect(blockSources(editor) == ["  - [ ] ", " - [ ] ", "  - [ ] "])
        #expect(editor.string.replacingOccurrences(of: "\u{FFFC}", with: "") == "first\nsecond\nchild")
    }

    @Test func appliesASharedMarkToTextOnBothSidesOfAChip() {
        let editor = makeEditor()
        editor.setText("**before @README.md after**")
        let storage = editor.textStorage!
        #expect(storage.containsAttachments)
        #expect(markSets(editor).allSatisfy { $0 == ["bold"] })
        #expect(editor.expandedText == "**before @README.md after**")
    }

    @Test(arguments: [
        [["bold"], ["bold", "italic"], ["italic"]],
        [["italic"], ["bold", "italic"], ["bold"]],
        [["bold"], ["bold", "strike"], ["strike"]],
        [["strike"], ["bold", "strike"], ["bold"]],
    ])
    func preservesCrossingMarkRangesThroughControlledRebuilds(_ marks: [[String]]) {
        let spans = marks.enumerated().map { index, names in
            Span(text: String(UnicodeScalar(97 + index)!), marks: names.compactMap(ComposerRichText.Mark.init(rawValue:)))
        }
        let serialized = ComposerRichText.serialize(spans)
        let editor = makeEditor()
        editor.setText(serialized)
        #expect(editor.string == "abc")
        #expect(markSets(editor) == marks.map(Set.init))
        #expect(editor.expandedText == serialized)
    }

    struct BoundaryCase: Sendable, CustomTestStringConvertible {
        var parts: [(String, [String])]
        var expected: String
        var testDescription: String { expected }
    }

    @Test(arguments: [
        BoundaryCase(parts: [("hello ", ["bold"])], expected: "**hello** "),
        BoundaryCase(parts: [("  ", ["bold"])], expected: "  "),
        BoundaryCase(parts: [(" left ", ["bold", "italic"])], expected: " ***left*** "),
        BoundaryCase(parts: [("one ", ["bold"]), (" two ", ["bold", "italic"]), (" three", ["bold"])], expected: "**one  *two*  three**"),
        BoundaryCase(parts: [("hello ", ["bold"]), ("world ", ["bold", "italic"])], expected: "**hello *world*** "),
        BoundaryCase(parts: [(" hello ", ["code"])], expected: "` hello `"),
        BoundaryCase(parts: [(" hello ", ["bold", "code"])], expected: "**` hello `**"),
        BoundaryCase(parts: [(" ", ["bold", "code"])], expected: "**` `**"),
    ])
    func keepsBoundaryWhitespaceOutsideEmphasis(_ c: BoundaryCase) {
        let spans = c.parts.map { Span(text: $0.0, marks: $0.1.compactMap(ComposerRichText.Mark.init(rawValue:))) }
        #expect(ComposerRichText.serialize(spans) == c.expected)
        let text = c.parts.map(\.0).joined()
        let editor = makeEditor()
        editor.setText(c.expected)
        #expect(editor.string == text)
        #expect(editor.expandedText == c.expected)
        let wanted = c.parts.flatMap { part in part.0.map { _ in Set(part.1) } }
        let got = markSets(editor)
        for (i, ch) in text.enumerated() where !ch.isWhitespace {
            #expect(got[i] == wanted[i], "\(c.expected) at \(i)")
        }
        expectMonotonicMapping(editor, c.expected)
    }

    @Test func keepsChipSourcesCanonicalThroughTheDocument() {
        let editor = makeEditor()
        editor.setText("explain @README.md with **care**\nsecond line *here*")
        #expect(editor.expandedText == "explain @README.md with **care**\nsecond line *here*")
        var mention = false
        editor.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
            if let chip = value as? ComposerChipAttachment, case .mention = chip.look.kind { mention = true }
        }
        #expect(mention)
    }

    @Test func normalizesUppercaseCheckboxesToLowercase() {
        #expect(roundTrip("- [X] done") == "- [x] done")
    }

    @Test(arguments: [
        "plain text", "hello **bold** stays literal", "a *italic* stays literal", "some `code` stays literal",
        "struck ~~out~~ stays literal", "- [ ] stays a paragraph", "- [x] stays a paragraph", "line one\nline two",
        "@README.md explain this", "**bold** then @README.md then *italic*",
    ])
    func roundTripsByteIdenticallyInPlainMode(_ value: String) {
        #expect(roundTripPlain(value) == value)
    }

    @Test(arguments: [
        "- one\n- two", "* star\n* star two", "+ plus", "* star\n+ plus", "1. first\n2. second", "1) paren\n2) paren",
        "3. starts at three\n4. four", "01. zero padded\n02. two", "- parent\n  - child\n  - sibling\n- uncle",
        "1. ordered\n   - bullet child\n2. next", "- outer\n  1. inner ordered\n  2. more\n- outer again",
        "-   wide space item", "-", "1.", "- \n- second", "- **bold** item with @README.md", "- [ ] task\n- bullet after",
        "- bullet\n- [x] task after", "para\n- item\npara", "\t- tab indented\n\t- again", "  - leading indent only",
        "- item\n\n- after a blank", "- item one\n```ts\ncode\n```\n- item two", "-no space stays literal",
        "1.no space stays literal", "10. ten\n11. eleven",
    ])
    func roundTripsTheList(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    @Test(arguments: ["- one\n- two", "1. first\n2. second", "- parent\n  - child", "* star\n+ plus", "-no space stays literal"])
    func keepsTheListLiteralInPlainMode(_ value: String) {
        #expect(roundTripPlain(value) == value)
    }

    @Test(arguments: ["- one\n- two", "1. a\n   - b\n2. c", "- **bold** @README.md tail", "-"])
    func mapsEveryDocumentOffsetOfTheList(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        expectMonotonicMapping(editor, value)
    }

    /// T3's marker owns no document position. Ours is one atom with a caret stop before it
    /// (the start of the line); every offset inside the marker lands after it.
    @Test func clampsOffsetsInsideAListMarkerToTheStartOfTheItemText() {
        let editor = makeEditor()
        editor.setText("- item")
        let map = mapping(editor)
        for markdown in 1...2 { #expect(display(map, markdown: markdown) == 1) }
        #expect(display(map, markdown: "- it".count) == 3)
        #expect(map.offsets[1] == "- ".count)
    }

    @Test(arguments: [
        "> quoted", "> line one\n> line two", ">no space", ">  two spaces", "> a\n>b", ">", "> **bold** and @README.md inside",
        "> - looks like a list but stays quote text", "> > nested stays literal inside the quote", "before\n> quoted",
        "> quote\n\n> another", "- item\n> quote after list", "> quoted\n\ncomment", "> line one\n> line two\n\ncomment",
    ])
    func roundTripsTheQuote(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    /// A paragraph after a quote is written after a blank line, or Markdown folds it into the
    /// quote (02e9d2417a, composer-rich-text-doc.test.ts:484-541).
    @Test func writesABlankLineBeforeAParagraphAfterAQuote() {
        #expect(roundTrip("before\n> quoted\nafter") == "before\n> quoted\n\nafter")
        #expect(roundTrip("> a\n> b\ncomment") == "> a\n> b\n\ncomment")
        // The empty line the user left is that blank line already.
        #expect(roundTrip("> quoted\n\nComment to it") == "> quoted\n\nComment to it")
        for next in ["# Heading", "- item", "3. item", "---", "```\ncode\n```"] {
            #expect(roundTrip("> quoted\n\(next)") == "> quoted\n\(next)")
        }
        let editor = makeEditor()
        editor.setText("> quoted\nComment")
        expectMonotonicMapping(editor, editor.expandedText)
        let map = mapping(editor)
        // The caret at the end of the quote stays on it; the blank line clamps to the comment.
        #expect(map.offsets[1 + "quoted".count] == "> quoted".count)
        #expect(map.offsets[2 + "quoted".count] == "> quoted\n\n".count)
        #expect(display(map, markdown: "> quoted\n".count) == 2 + "quoted".count)
    }

    @Test(arguments: ["---", "***", "___", "- - -", "* * *", "-----", "---   ", "text\n---\nmore", "- item\n---\n- item two", "```\n---\n```", "--", "-- -", "---text"])
    func roundTripsTheRule(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    /// T3 has this case twice (composer-rich-text-doc.test.ts:503 and :573); ported once.
    @Test func parsesRulesAheadOfListsAndEmphasis() {
        let editor = makeEditor()
        editor.setText("- - -\n***\n___\ntext\n---\n- item")
        #expect(lineKinds(editor) == ["horizontalRule", "horizontalRule", "horizontalRule", "paragraph", "horizontalRule", "bulletList"])
    }

    /// T3 has this list twice (:518 and :588); ported once.
    @Test(arguments: [
        "# Heading", "## Two", "###### Six", "####### seven hashes stays a paragraph", "#  two spaces", "#\tTab",
        "# Trailing hashes stay literal #", "#1234", "#1234 is a pull request, not a heading", "# Heading with **bold** and @README.md",
        "#", "# ", "text\n# Heading\ntext", "# Heading\n- item\n> quote\n---",
    ])
    func roundTripsTheHeading(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    /// T3 has this list twice (:537 and :607); ported once.
    @Test(arguments: ["> quoted", "> a\n>b", "---", "- - -", "# Heading", "#1234"])
    func keepsTheBlockLiteralInPlainMode(_ value: String) {
        #expect(roundTripPlain(value) == value)
    }

    @Test func parsesTheBlocksItRendersAsTheRightNodeTypes() {
        let editor = makeEditor()
        editor.setText("# Title\n> quote\n---\n#1234 ref\n- - -")
        // The empty line a final rule keeps for the caret.
        #expect(lineKinds(editor) == ["heading", "blockquote", "horizontalRule", "paragraph", "horizontalRule", "paragraph"])
    }

    @Test(arguments: [("---", "---"), ("a\n---", "a\n---"), ("---\n", "---")])
    func givesTheCaretALineAfterTheFinalRule(_ value: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == expected)
        // The caret rests on its own line after the rule, so typing writes a new line.
        type(editor, "x")
        #expect(editor.expandedText == expected + "\nx")
    }

    @Test func parsesAQuoteAsABlockquoteOfOneParagraphPerLine() {
        let editor = makeEditor()
        editor.setText("> a\n> b\n>c")
        #expect(lineKinds(editor) == ["blockquote", "blockquote", "blockquote"])
        #expect(blockSources(editor) == ["> ", "> ", ">"])
    }

    @Test(arguments: ["> a\n> b", "> **q** @README.md", "text\n---\nmore", "---\ntext", "# Heading text", "## **b** @README.md"])
    func mapsEveryDocumentOffsetOfTheBlock(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        expectMonotonicMapping(editor, value)
    }

    @Test func clampsOffsetsInsideAQuoteOrHeadingMarkerToTheStartOfTheText() {
        for (value, prefix) in [("> quoted", "> "), ("# Heading", "# ")] {
            let editor = makeEditor()
            editor.setText(value)
            let map = mapping(editor)
            for markdown in 1...prefix.count { #expect(display(map, markdown: markdown) == 1) }
            #expect(map.offsets[1] == prefix.count)
        }
    }

    @Test(arguments: [
        "```\ncode\n```", "```ts\nconst a = 1;\n```", "```ts\nconst a = 1;\n```\n", "before\n```ts\nconst a = 1;\n```\nafter",
        "```\n```", "```ts\nline one\nline two\nline three\n```", "```ts\n  indented\n    deeper\n```", "```js title=example\ncode\n```",
        "~~~py\ncode\n~~~", "````\n```\n````", "```ts\ncode without a closing fence", "```",
        "```ts\n**not bold** and @README.md stay literal\n```", "```ts\ncode\n````", "- [ ] task\n```ts\ncode\n```\n- [ ] after",
        "  ```ts\nindented fence stays a paragraph\n  ```",
    ])
    func roundTripsTheFencedBlock(_ value: String) {
        #expect(roundTrip(value) == value)
    }

    @Test(arguments: ["```ts\nconst a = 1;\n```", "```\n```", "before\n```ts\ncode\n```\nafter"])
    func mapsEveryDocumentOffsetOfTheFence(_ value: String) {
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        expectMonotonicMapping(editor, value)
    }

    @Test func readsBlocksWrittenWithCRLFLineEndings() {
        let value = "# Title\r\n> quote\r\n---\r\n```ts\r\nconst a = 1;\r\n```\r\nafter"
        let editor = makeEditor()
        editor.setText(value)
        #expect(lineKinds(editor).filter { $0 != "code" && $0 != "codeEnd" } == ["heading", "blockquote", "horizontalRule", "codeBlock", "paragraph"])
        #expect(editor.expandedText == value)
    }

    @Test func keepsTheEndOfTheCodeInsideTheFenceRatherThanAfterIt() {
        let editor = makeEditor()
        editor.setText("```ts\nfunc();\n```")
        let map = mapping(editor)
        let endOfCode = 2 + "func();".count
        #expect(map.offsets[endOfCode] == "```ts\nfunc();".count)
        #expect(display(map, markdown: map.offsets[endOfCode]) == endOfCode)
    }

    @Test func keepsTheCaretInsideAnEmptyFence() {
        let editor = makeEditor()
        editor.setText("before\n```\n```")
        #expect(editor.expandedText == "before\n```\n```")
        #expect(lineKinds(editor) == ["paragraph", "codeBlock", "paragraph", "codeEnd"])
        // The empty line between the fences holds the caret; typing there writes code.
        let map = mapping(editor)
        let inside = "before\n".count + 2
        #expect(map.offsets[inside] == "before\n```".count)
        editor.setSelectedRange(NSRange(location: inside, length: 0))
        type(editor, "x")
        #expect(editor.expandedText == "before\n```\nx\n```")
    }

    @Test func stillPlacesTheEndOfAnInlineMarkAfterItsMarkers() {
        let editor = makeEditor()
        editor.setText("a **bold** c")
        #expect(mapping(editor).offsets[6] == 10)
    }

    /// Our fences are atoms on lines of their own, so the fence lines keep a caret stop each.
    /// Offsets inside the code clamp to its edges as in T3.
    @Test func clampsOffsetsInsideAFenceToTheEdgeOfTheCode() {
        let value = "```ts\nab\n```"
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        let map = mapping(editor)
        #expect(display(map, markdown: "```ts\n".count) == 2)
        #expect(display(map, markdown: "```ts\na".count) == 3)
        #expect(display(map, markdown: "```ts\nab".count) == 4)
    }

    @Test(arguments: [("```\n\n```", "```\n```"), ("```\n", "```")])
    func canonicalizesTheEmptyFence(_ value: String, _ expected: String) {
        #expect(roundTrip(value) == expected)
    }

    @Test func keepsAChipInAFenceInfoStringAsSourceAndKeepsLaterChipsAligned() {
        let value = "```@README.md\ncode\n```\n$my-skill after"
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        let storage = editor.textStorage!
        let lastLine = (editor.string as NSString).range(of: "\n", options: .backwards).location + 1
        let chip = storage.attribute(.attachment, at: lastLine, effectiveRange: nil) as? ComposerChipAttachment
        #expect(chip?.source == "$my-skill")
        #expect(chip?.look.kind == .skill)
    }

    @Test func keepsChipsInAFenceInfoStringAndBodyEachInTheirOwnPlace() {
        let value = "``` @a.md\nsee @b.md\n```"
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        let header = editor.textStorage!.attribute(.attachment, at: 0, effectiveRange: nil) as? ComposerBlockAttachment
        if case .codeHeader(_, let info) = header?.kind { #expect(info == " @a.md") } else { Issue.record("no fence header") }
        #expect(editor.string.contains("see @b.md"))
    }

    @Test(arguments: [("-", "- text"), ("1.", "1. text")])
    func givesABareListItemASpaceOnceItHasText(_ marker: String, _ expected: String) {
        let editor = makeEditor()
        editor.setText(marker)
        type(editor, "text")
        #expect(editor.expandedText == expected)
        #expect(roundTrip("-") == "-")
    }

    @Test func writesCodeHoldingAClosingFenceInsideALongerFence() {
        let editor = makeEditor()
        editor.setText("```\ninitial\n```")
        editor.setSelectedRange(NSRange(location: 2 + "initial".count, length: 0))
        type(editor, "\n```\nsecret")
        let stored = editor.expandedText
        #expect(stored == "````\ninitial\n```\nsecret\n````")
        let rebuilt = makeEditor()
        rebuilt.setText(stored)
        #expect(lineKinds(rebuilt) == ["codeBlock", "code", "code", "code", "codeEnd"])
        #expect(rebuilt.expandedText == stored)
    }

    /// T3 builds an unclosed fence followed by a paragraph by hand. Ours gets there by leaving
    /// an unclosed fence with two blank lines, which writes the closing fence.
    @Test func closesAnUnclosedFenceThatHasABlockAfterIt() throws {
        let editor = makeEditor()
        editor.setText("```\ncode")
        for _ in 0..<3 { try pressReturn(editor) }
        type(editor, "after")
        #expect(editor.expandedText == "```\ncode\n```\nafter")
        #expect(roundTrip("```\ncode") == "```\ncode")
    }

    @Test func countsAChipSourceInAFenceAsLiteralCode() {
        let value = "```\nsee @b.md now\n```\nafter"
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        #expect(editor.string.contains("see @b.md now"))
        expectMonotonicMapping(editor, value)
    }

    @Test func keepsFencesLiteralInPlainMode() {
        #expect(roundTripPlain("```ts\nconst a = 1;\n```") == "```ts\nconst a = 1;\n```")
    }

    @Test func mapsEveryDocumentOffsetThroughCollapsedCoordinatesAndBack() {
        let value = "hi **bold** @README.md bye"
        let editor = makeEditor()
        editor.setText(value)
        #expect(editor.expandedText == value)
        expectMonotonicMapping(editor, value)
    }

    @Test(arguments: ["plain prose with no styling at all", "a chip @README.md counts one character in both modes", "$my-skill leads the line", "trailing newline\n"])
    func resolvesACursorIdenticallyInBothModes(_ value: String) {
        let rich = makeEditor()
        rich.setText(value)
        let plain = makeEditor(rich: false)
        plain.setText(value)
        #expect(rich.expandedText == value)
        #expect(plain.expandedText == value)
        let richMap = mapping(rich), plainMap = mapping(plain)
        for markdown in 0...(value as NSString).length {
            #expect(richMap.offsets[display(richMap, markdown: markdown)] == plainMap.offsets[display(plainMap, markdown: markdown)])
        }
    }

    @Test func clampsACursorThatWasSittingInsideAMarkerOntoTheStyledText() {
        let plain = makeEditor(rich: false)
        plain.setText("a **bold** c")
        let rich = makeEditor()
        rich.setText("a **bold** c")
        let plainMap = mapping(plain), richMap = mapping(rich)
        #expect(plainMap.offsets[display(plainMap, markdown: 3)] == 3)
        #expect(richMap.offsets[display(richMap, markdown: 3)] == 4)
    }

    @Test func mapsMarkdownOffsetsAtStyledEdgesOntoDocumentText() {
        let editor = makeEditor()
        editor.setText("a **bold** c")
        #expect(editor.string == "a bold c")
        let map = mapping(editor)
        #expect(map.offsets[2] == 4)
        #expect(map.offsets[6] == 10)
        #expect(display(map, markdown: 3) == 2)
        #expect(display(map, markdown: 9) == 6)
    }
}

// MARK: - composer-rich-text-doc.test.ts: serializeSelection

@MainActor struct ComposerRichTextT3CopyTests {
    /// The Markdown copy writes for the selection from the start of `first` to the end of `last`.
    private func copy(_ value: String, _ first: String, _ last: String) -> String {
        let editor = makeEditor()
        editor.setText(value)
        let text = editor.string as NSString
        let from = text.range(of: first).location
        let to = NSMaxRange(text.range(of: last, options: .backwards))
        return editor.clipboardText(NSRange(location: from, length: to - from))
    }

    @Test func keepsTheMarkersOfTheListItemsItSpans() {
        #expect(copy("- one\n- two\n- three", "one", "two") == "- one\n- two")
        #expect(copy("3) one\n4) two", "one", "two") == "3) one\n4) two")
        #expect(copy("- [ ] one\n- [x] two", "one", "two") == "- [ ] one\n- [x] two")
    }

    @Test func keepsTheNestingOfAnItemAndItsChildren() {
        #expect(copy("- p\n  - a\n  - b", "p", "a") == "- p\n  - a")
    }

    @Test func keepsThePrefixOfTheQuoteLinesItSpans() {
        #expect(copy("> one\n> two", "one", "two") == "> one\n> two")
    }

    @Test func copiesTextWithinOneBlockWithoutItsMarker() {
        #expect(copy("- one two", "one", "one") == "one")
    }

    @Test func copiesAcrossBlocksAsTheyAreWritten() {
        #expect(copy("intro\n- one", "intro", "one") == "intro\n- one")
    }
}

// MARK: - composer-rich-text-doc.test.ts: pasting into a list item or quote

@MainActor struct ComposerRichTextT3PasteTests {
    /// T3 builds paragraphs, not nested blocks, inside an item (`blocks: false`). Text inserted in
    /// place keeps its lines literal and applies the inline marks; a real paste puts the lines
    /// after the item (ComposerRichTextListSplitTests.putsLinesPastedAtTheEndOfAnItemAfterTheList).
    @Test func keepsInlineMarksButBuildsNoBlocks() {
        let editor = makeEditor()
        editor.setText("- x")
        type(editor, "**bold** text\n- item\n> quote")
        #expect(editor.expandedText == "- x**bold** text\n- item\n> quote")
        #expect(editor.string.contains("xbold text"))
    }
}

// MARK: - composer-rich-text-doc.test.ts: caret stops at styled edges

@MainActor struct ComposerRichTextT3CaretTests {
    private func editor(_ value: String, caret: Int) -> ComposerEditor {
        let editor = makeEditor()
        editor.setText(value)
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        return editor
    }

    private func typed(_ editor: ComposerEditor, _ text: String) -> String {
        let saved = editor.expandedText, selection = editor.selectedRange(), attributes = editor.typingAttributes
        type(editor, text)
        let result = editor.expandedText
        editor.setText(saved)
        editor.setSelectedRange(selection)
        editor.typingAttributes = attributes
        return result
    }

    @Test func letsTheCaretStepOutInFrontOfBoldThatStartsTheLine() {
        let inside = editor("**bold** tail", caret: 0)
        #expect(!inside.caretTakesMarksBefore)
        #expect(typed(inside, "x") == "**xbold** tail")
        #expect(inside.stepCaretAcrossStyledEdge(-1))
        #expect(inside.caretTakesMarksBefore)
        #expect(typed(inside, "x") == "x**bold** tail")
        // Already outside: the next ArrowLeft moves the caret as usual.
        #expect(!inside.stepCaretAcrossStyledEdge(-1))
        #expect(inside.stepCaretAcrossStyledEdge(1))
        #expect(typed(inside, "x") == "**xbold** tail")
    }

    @Test func letsTheCaretStepOutAfterBoldThatEndsTheLine() {
        let inside = editor("head **bold**", caret: 9)
        #expect(inside.caretTakesMarksBefore)
        #expect(typed(inside, "x") == "head **boldx**")
        #expect(!inside.stepCaretAcrossStyledEdge(-1))
        #expect(inside.stepCaretAcrossStyledEdge(1))
        #expect(!inside.caretTakesMarksBefore)
        #expect(typed(inside, "x") == "head **bold**x")
    }

    @Test func offersBothStopsWhereStyledTextMeetsPlainTextMidLine() {
        let plain = editor("a **b** c", caret: 2)
        #expect(plain.caretTakesMarksBefore)
        #expect(typed(plain, "x") == "a x**b** c")
        #expect(plain.stepCaretAcrossStyledEdge(1))
        #expect(typed(plain, "x") == "a **xb** c")
    }

    @Test func offersThePlainStopBetweenBoldTextAndAChipRightAfterIt() {
        // Markdown needs a space before a mention, but deleting it leaves them adjacent.
        let inside = makeEditor()
        inside.setText("**bold** @README.md ")
        inside.setSelectedRange(NSRange(location: 4, length: 1))
        type(inside, "")
        inside.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(inside.textStorage!.attribute(.attachment, at: 4, effectiveRange: nil) is ComposerChipAttachment)
        #expect(inside.caretTakesMarksBefore)
        #expect(inside.stepCaretAcrossStyledEdge(1))
        #expect(!inside.caretTakesMarksBefore)
        #expect(typed(inside, "x") == "**bold**x@README.md ")
    }

    @Test func stepsOutOfInlineCodeAtTheEndOfALineWithoutInsertingASpace() {
        let inside = editor("`code`", caret: 4)
        #expect(inside.stepCaretAcrossStyledEdge(1))
        #expect(typed(inside, "x") == "`code`x")
        #expect(!inside.stepCaretAcrossStyledEdge(1))
    }

    @Test func keepsMarksTheUserToggledAtAnEdgeAndLetsTheArrowMove() {
        let inside = editor("a **b** c", caret: 2)
        inside.typingAttributes = ComposerRichTextStyler.attributes([.bold, .italic], base: inside.typingAttributes)
        #expect(!inside.stepCaretAcrossStyledEdge(1))
        #expect(!inside.stepCaretAcrossStyledEdge(-1))
    }

    @Test func leavesArrowKeysAloneAwayFromStyledEdges() {
        #expect(!editor("**bold** tail", caret: 2).stepCaretAcrossStyledEdge(-1))
        #expect(!editor("plain text", caret: 1).stepCaretAcrossStyledEdge(-1))
        #expect(!editor("plain text", caret: 1).caretTakesMarksBefore)
    }
}

// MARK: - What reaches the server

/// Plain prompts typed without formatting must reach the server as typed, except where T3
/// itself rewrites them (`__x__` and `_x_` become `**x**` and `*x*`, `[X]` becomes `[x]`,
/// a skill's currency sigil becomes `$`). With rich text off, every prompt goes out as typed.
@MainActor struct ComposerRichTextWireTests {
    nonisolated static let literal = [
        "2 * 3 * 4 = 24", "a*b", "**", "*", "_", "my_var_name", "snake_case_name", "a_b_c", "x = y * z;",
        "price: $20 or $5.99", "`", "``", "```", "use `", "a ` b", "C:\\Users\\me\\file.txt", "\\*not italic\\*", "\\\\",
        "# not a heading?", "#", "#hashtag", "##", "> quoted reply", ">", ">>", "- item", "-", "--", "- ", "1. one", "1.",
        "1)", "2.5 is a number", "- [ ] todo", "- [x] done", "[ ]", "[link](https://example.com)", "~", "~~", "~/path",
        "~~~", "emoji 👩🏽‍💻 🇯🇵 ❤️", "👍*👍*", "日本語 **太字**", "**unclosed", "tail **", "* bullet", "+ plus",
        "* * *", "line\n\nline", "  indented", "\ttab", "trailing space ", "\n", "a\r\nb",
    ]

    @Test(arguments: literal)
    func plainPromptsSurviveRichTextUnchanged(_ value: String) {
        #expect(roundTrip(value) == value)
        // Typed one character at a time, as a user would.
        let editor = makeEditor()
        for character in value { type(editor, String(character)) }
        #expect(editor.expandedText == value, "typed")
    }

    @Test(arguments: literal + ["__bold__", "_italic_", "- [X] done", "Use €my-skill now", "```\n\n```", "---\n"])
    func plainModeSendsTextExactlyAsTyped(_ value: String) {
        let editor = makeEditor(rich: false)
        for character in value { type(editor, String(character)) }
        let expected = value.replacingOccurrences(of: "€my-skill", with: "$my-skill")
        #expect(editor.expandedText == expected)
        #expect(roundTripPlain(value) == expected)
    }

    @Test(arguments: [("__bold__", "**bold**"), ("_italic_", "*italic*"), ("- [X] done", "- [x] done"), ("Use €my-skill now", "Use $my-skill now")])
    func richTextRewritesWhatT3Rewrites(_ value: String, _ expected: String) {
        #expect(roundTrip(value) == expected)
    }

    @Test func turningRichTextOffKeepsThePrompt() {
        let editor = makeEditor()
        editor.setText("**bold** `code`\n- [ ] task\n```ts\nx\n```")
        editor.richTextEnabled = false
        #expect(editor.string == "**bold** `code`\n- [ ] task\n```ts\nx\n```")
        #expect(editor.expandedText == editor.string)
        editor.richTextEnabled = true
        #expect(editor.expandedText == "**bold** `code`\n- [ ] task\n```ts\nx\n```")
    }

    /// `convertCodeFenceOnEnter`: a fence line and Return open a closed, empty block.
    @Test func returnOnAFenceLineOpensAClosedBlock() throws {
        let editor = makeEditor()
        for character in "```ts" { type(editor, String(character)) }
        try pressReturn(editor)
        #expect(editor.expandedText == "```ts\n```")
        type(editor, "let x = 1")
        #expect(editor.expandedText == "```ts\nlet x = 1\n```")
        // Two blank lines at the end leave the block (`exitCodeBlockOnTrailingBlankLines`).
        for _ in 0..<3 { try pressReturn(editor) }
        type(editor, "after")
        #expect(editor.expandedText == "```ts\nlet x = 1\n```\nafter")
    }

    /// `exitCodeBlockOnClosingFence`: Return after a typed closing fence ends the block there.
    @Test func returnAfterATypedClosingFenceEndsTheBlock() throws {
        let editor = makeEditor()
        for character in "```" { type(editor, String(character)) }
        try pressReturn(editor)
        type(editor, "x\n```")
        #expect(editor.expandedText == "````\nx\n```\n````")
        try pressReturn(editor)
        type(editor, "after")
        #expect(editor.expandedText == "```\nx\n```\nafter")
    }

    /// `horizontalRuleInputRule`: the third dash makes a rule and the caret moves past it.
    @Test func typedRuleMovesTheCaretToTheNextLine() {
        let editor = makeEditor()
        for character in "---" { type(editor, String(character)) }
        #expect(editor.expandedText == "---")
        type(editor, "x")
        #expect(editor.expandedText == "---\nx")
    }
}

/// `inline code entry` (composer-rich-text-doc.test.ts:1160-1277, 7259e4f594): text typed between a typed pair of
/// backticks stays literal until the caret leaves through the closing one, then becomes inline code.
@MainActor struct ComposerCodePairTests {
    private func type(_ editor: ComposerEditor, _ text: String) {
        for c in text { editor.insertText(String(c), replacementRange: editor.selectedRange()) }
    }
    private func codeText(_ editor: ComposerEditor) -> String {
        var out = ""
        editor.textStorage!.enumerateAttribute(.composerMarks, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, range, _ in
            if ComposerRichTextStyler.marks(value).contains(.code) { out += (editor.string as NSString).substring(with: range) }
        }
        return out
    }

    @Test(arguments: ["", "prefix "])
    func formatsAFilledPairAndLeavesTheFollowingTextPlain(_ prefix: String) {
        let editor = makeEditor()
        type(editor, prefix)
        let offset = editor.selectedRange().location
        type(editor, "``")
        editor.setSelectedRange(NSRange(location: offset + 1, length: 0))
        type(editor, "hello world")
        // Still literal while the caret is inside.
        #expect(editor.string == prefix + "`hello world`")
        #expect(codeText(editor).isEmpty)
        editor.setSelectedRange(NSRange(location: offset + 13, length: 0))
        #expect(editor.string == prefix + "hello world")
        #expect(codeText(editor) == "hello world")
        #expect(editor.expandedText == prefix + "`hello world`")
        type(editor, " next `typed`")
        #expect(editor.expandedText == prefix + "`hello world` next `typed`")
    }

    @Test(arguments: [("````", 2), ("```", 1)])
    func leavesDoubledDelimitersUnchanged(_ delimiters: String, _ caret: Int) {
        let editor = makeEditor()
        type(editor, delimiters)
        editor.setSelectedRange(NSRange(location: caret, length: 0))
        type(editor, "literal")
        let before = editor.expandedText
        editor.setSelectedRange(NSRange(location: caret + "literal".count + 1, length: 0))
        #expect(editor.expandedText == before)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(editor.expandedText == before)
        #expect(codeText(editor).isEmpty)
    }

    @Test func leavesABoldPairUnchanged() {
        let editor = makeEditor()
        editor.toggleMark(.bold)
        type(editor, "``")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        type(editor, "literal")
        let before = editor.expandedText
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(editor.expandedText == before)
        #expect(codeText(editor).isEmpty)
    }
}
