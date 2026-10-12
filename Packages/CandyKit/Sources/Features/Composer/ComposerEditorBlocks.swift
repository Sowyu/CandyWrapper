import AppKit

/// T3's block editing in the rich composer, applied to the draft's lines: Return splits or
/// leaves a list item, continues or leaves a quote and splits a heading; Backspace at the start
/// of a block's text outdents, unwraps or joins it; Delete at a line's end pulls the next line
/// up; a paste that parses to blocks goes in as whole lines. Sources: composer-rich-text-doc.ts
/// (`splitOrLiftListItem`, `alignListItemWithSiblings`, `renumberFollowingItems`,
/// `backspaceAcrossList`, `deleteAcrossList`) and ComposerPromptEditorTiptap.tsx:1309-1340, 1374-1460.
/// Each edit rewrites block markers as Markdown source and lets the styler read them back, so the
/// draft T3 would store is what the editor shows.
extension ComposerEditor {
    struct BlockLines {
        var starts: [Int]
        var atoms: [ComposerBlockAttachment?]
        var lists: ComposerBlockLayout.Lists
        func line(of location: Int) -> Int { (starts.lastIndex { $0 <= location }) ?? 0 }
    }

    /// Display lines, the marker atom that starts each, and T3's list structure over them.
    func blockLines() -> BlockLines {
        let text = string as NSString
        var starts = [0], search = 0
        while true {
            let newline = text.range(of: "\n", range: NSRange(location: search, length: text.length - search))
            if newline.location == NSNotFound { break }
            starts.append(newline.location + 1)
            search = newline.location + 1
        }
        let atoms = starts.map { start in block(at: start).flatMap { $0.isLineMarker ? $0 : nil } }
        return BlockLines(starts: starts, atoms: atoms, lists: ComposerBlockLayout.lists(atoms.map(ComposerRichTextStyler.layoutLine)))
    }

    /// Replaces display `range` with Markdown whose lines are read as blocks.
    func replaceBlocks(_ range: NSRange, with text: String) {
        parseRange = NSRange(location: range.location, length: (text as NSString).length)
        replace(range, with: text)
        parseRange = nil
    }

    func markdownOffset(_ display: Int) -> Int {
        guard let storage = textStorage else { return 0 }
        let offsets = ComposerRichTextStyler.mapping(storage).offsets
        return offsets[max(0, min(display, offsets.count - 1))]
    }

    func setCaret(markdown: Int) {
        guard let storage = textStorage else { return }
        let offsets = ComposerRichTextStyler.mapping(storage).offsets
        setSelectedRange(NSRange(location: offsets.firstIndex { $0 >= markdown } ?? offsets.count - 1, length: 0))
    }

    private static func isOrdered(_ marker: String) -> Bool { marker.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil }

    private static func isTask(_ atom: ComposerBlockAttachment) -> Bool { if case .task = atom.kind { true } else { false } }

    /// `renumberFollowingItems`: the items after `item` count on from `marker`.
    private func renumber(after item: Int, from marker: String, in lines: BlockLines) {
        var previous = marker
        var edits: [(Int, String)] = []
        for sibling in lines.lists.followingSiblings(of: item) {
            guard let atom = lines.atoms[sibling], let parts = atom.listParts else { continue }
            previous = ComposerListContinuation.nextOrderedMarker(previous)
            if parts.marker != previous { edits.append((lines.starts[sibling], parts.indent + previous + parts.space)) }
        }
        for (start, source) in edits.reversed() { replaceBlocks(NSRange(location: start, length: 1), with: source) }
    }

    /// The marker an item gets where it now follows `sibling` (`alignListItemWithSiblings`): the
    /// sibling's indent, its next number or its bullet, and for a task its spacing.
    private static func alignedSource(_ atom: ComposerBlockAttachment, after sibling: ComposerBlockAttachment,
                                      checked: Bool, space: String) -> String? {
        guard let own = atom.listParts, let other = sibling.listParts else { return nil }
        if isTask(atom) { return other.indent + "-" + other.space + (checked ? "[x]" : "[ ]") + own.contentSpace }
        return other.indent + (isOrdered(other.marker) ? ComposerListContinuation.nextOrderedMarker(other.marker) : other.marker) + space
    }

    // MARK: Return

    /// Return that does not send, in a rich draft: true when a block took it.
    func blockReturn() -> Bool {
        guard richTextEnabled, selectedRange().length == 0 else { return false }
        let lines = blockLines()
        let caret = selectedRange().location, i = lines.line(of: caret), start = lines.starts[i]
        guard let atom = lines.atoms[i] else { return false }
        let end = lineEnd(start), empty = end == start + 1
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        switch atom.kind {
        case .bullet, .ordered, .task:
            splitOrLift(i, atom, caret: caret, empty: empty, lines)
            return true
        case .quote:
            // An empty quote line leaves the quote; any other splits, both halves quoted.
            if empty { replace(NSRange(location: start, length: 1), with: "") } else { replaceBlocks(NSRange(location: caret, length: 0), with: "\n" + atom.source) }
            return true
        case .heading:
            // `splitBlock`: at the end a plain line follows; at the start of the text the empty
            // line above is plain; in the middle both halves stay headings.
            if caret == end { return false }
            if caret == start + 1 { replace(NSRange(location: start, length: 0), with: "\n") } else { replaceBlocks(NSRange(location: caret, length: 0), with: "\n" + atom.source) }
            return true
        default: return false
        }
    }

    /// `splitOrLiftListItem` (Shift+Enter in a list or task item).
    private func splitOrLift(_ i: Int, _ atom: ComposerBlockAttachment, caret: Int, empty: Bool, _ lines: BlockLines) {
        guard let parts = atom.listParts else { return }
        if !empty {
            // A split item gets the next number or the same bullet, and a task starts unchecked.
            let source: String
            if Self.isTask(atom) { source = parts.indent + "-" + parts.space + "[ ]" + parts.contentSpace }
            else if Self.isOrdered(parts.marker) { source = parts.indent + ComposerListContinuation.nextOrderedMarker(parts.marker) + " " }
            else { source = parts.indent + parts.marker + " " }
            if Self.isOrdered(parts.marker) {
                renumber(after: i, from: ComposerListContinuation.nextOrderedMarker(parts.marker), in: lines)
            }
            replaceBlocks(NSRange(location: caret, length: 0), with: "\n" + source)
            return
        }
        // An empty item leaves one level: out of the list at the top, else under its parent's
        // list, written with the parent's indent and marker.
        guard let parent = lines.lists.parent(of: i) else {
            replace(NSRange(location: lines.starts[i], length: 1), with: "")
            return
        }
        // A task has no task list to move into under a bullet, nor a bullet under a task.
        guard let parentAtom = lines.atoms[parent], Self.isTask(parentAtom) == Self.isTask(atom) else { return }
        // The last item of its list splits the parent (a fresh item: unchecked, one space);
        // any other lifts and keeps its own state.
        let last = lines.lists.followingSiblings(of: i).isEmpty
        let checked = if case .task(let c) = atom.kind { c && !last } else { false }
        guard let source = Self.alignedSource(atom, after: parentAtom, checked: checked, space: last ? " " : parts.space) else { return }
        if !Self.isTask(atom), let p = parentAtom.listParts, Self.isOrdered(p.marker) {
            renumber(after: parent, from: ComposerListContinuation.nextOrderedMarker(p.marker), in: lines)
        }
        replaceBlocks(NSRange(location: lines.starts[i], length: 1), with: source)
    }

    // MARK: Backspace and Delete

    /// Backspace in a rich draft: true when a block took it.
    func blockBackspace() -> Bool {
        guard richTextEnabled, selectedRange().length == 0, let storage = textStorage else { return false }
        let caret = selectedRange().location
        // Right after an input rule, Backspace puts back what was typed (`undoInputRule`).
        if let undo = inputRuleUndo, undo.stamp == editStamp, undo.caret == caret, NSMaxRange(undo.range) <= storage.length {
            inputRuleUndo = nil
            breakUndoCoalescing()
            replaceAttributed(undo.range, with: undo.literal, caret: undo.range.location + undo.literal.length)
            breakUndoCoalescing()
            return true
        }
        guard caret > 0 else { return false }
        let lines = blockLines()
        let i = lines.line(of: caret), start = lines.starts[i]
        guard caret == start + 1, let atom = lines.atoms[i] else { return false }
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        let previous = i > 0 ? lines.atoms[i - 1] : nil
        switch atom.kind {
        case .bullet, .ordered, .task:
            // `backspaceAcrossList`: out of the list at the top, one level out when nested.
            guard let parent = lines.lists.parent(of: i) else {
                replace(NSRange(location: start, length: 1), with: "")
                return true
            }
            guard let parentAtom = lines.atoms[parent], Self.isTask(parentAtom) == Self.isTask(atom),
                  let parts = atom.listParts else {
                // No list to lift into: the text joins the line above.
                replace(NSRange(location: start - 1, length: 2), with: "")
                return true
            }
            let checked = if case .task(let c) = atom.kind { c } else { false }
            guard let source = Self.alignedSource(atom, after: parentAtom, checked: checked, space: parts.space) else { return false }
            if let p = parentAtom.listParts, !Self.isTask(atom), Self.isOrdered(p.marker) {
                renumber(after: parent, from: ComposerListContinuation.nextOrderedMarker(p.marker), in: lines)
            }
            replaceBlocks(NSRange(location: start, length: 1), with: source)
            return true
        case .quote:
            guard let previous, case .quote = previous.kind else {
                // The first line of a quote leaves it.
                replace(NSRange(location: start, length: 1), with: "")
                return true
            }
            if previous.source == atom.source {
                replace(NSRange(location: start - 1, length: 2), with: "")
            } else {
                // Two quotes meet: they join into the first, every line keeping its own text.
                requote(from: i, as: previous.source, lines)
            }
            return true
        case .heading:
            if i == 0 {
                // At the start of the draft an empty heading turns plain; a full one stays.
                if lineEnd(start) == start + 1 { replace(NSRange(location: start, length: 1), with: "") }
                return true
            }
            if let previous, case .rule = previous.kind { return false }
            if storage.attribute(.composerCodeBlock, at: start - 1, effectiveRange: nil) != nil { return false }
            replace(NSRange(location: start - 1, length: 2), with: "")
            return true
        default: return false
        }
    }

    /// Gives the quote lines from `line` on, while they share its prefix, the prefix `source`.
    private func requote(from line: Int, as source: String, _ lines: BlockLines) {
        guard let first = lines.atoms[line] else { return }
        var group: [Int] = []
        var j = line
        while j < lines.atoms.count, let a = lines.atoms[j], case .quote = a.kind, a.source == first.source { group.append(j); j += 1 }
        let caret = markdownOffset(selectedRange().location) + (source as NSString).length - (first.source as NSString).length
        for k in group.reversed() { replaceBlocks(NSRange(location: lines.starts[k], length: 1), with: source) }
        setCaret(markdown: caret)
    }

    /// Delete at the end of a line in a rich draft: true when a block took it.
    func blockDeleteForward() -> Bool {
        guard richTextEnabled, selectedRange().length == 0, let storage = textStorage else { return false }
        let caret = selectedRange().location
        guard caret == lineEnd(caret), caret < storage.length else { return false }
        let lines = blockLines()
        let i = lines.line(of: caret)
        let current = lines.atoms[i], next = block(at: caret + 1)
        let inCode = codeFenceAtCaret != nil
        // Before a fence nothing happens: pulling the code up would drop the fence.
        if let next, case .codeHeader = next.kind { return !inCode }
        guard !inCode else { return false }
        func isList(_ a: ComposerBlockAttachment?) -> Bool { a?.listParts != nil }
        func isQuote(_ a: ComposerBlockAttachment?) -> Bool { if let a, case .quote = a.kind { true } else { false } }
        let nextMarker = next?.isLineMarker == true ? next : nil
        breakUndoCoalescing()
        defer { breakUndoCoalescing() }
        if isList(current) || isList(nextMarker) || (nextMarker != nil && !isQuote(nextMarker)) {
            // `deleteAcrossList`, and a heading's text joining the line: the next line's text comes up.
            replace(NSRange(location: caret, length: nextMarker == nil ? 1 : 2), with: "")
            setSelectedRange(NSRange(location: caret, length: 0))
            return true
        }
        if isQuote(nextMarker), let nextMarker {
            if let current, isQuote(current) {
                if current.source == nextMarker.source { replace(NSRange(location: caret, length: 2), with: "") }
                else { requote(from: i + 1, as: current.source, lines) }
            } else {
                // A quote after plain text: its first line leaves the quote.
                replace(NSRange(location: caret + 1, length: 1), with: "")
            }
            setSelectedRange(NSRange(location: caret, length: 0))
            return true
        }
        // The line break at the caret can be the draft's last character: then no line follows and the
        // default delete joins nothing but the break.
        if let current, isQuote(current), nextMarker == nil, caret + 1 < storage.length,
           storage.attribute(.composerCodeBlock, at: caret + 1, effectiveRange: nil) == nil {
            // A plain line after a quote moves into it as its next line.
            replaceBlocks(NSRange(location: caret + 1, length: 0), with: current.source)
            setSelectedRange(NSRange(location: caret, length: 0))
            return true
        }
        return false
    }

    // MARK: Tab

    /// Tab on a list item nests it two spaces deeper (`listIndentForTab`).
    func blockIndent() -> Bool {
        guard richTextEnabled, selectedRange().length == 0 else { return false }
        let caret = selectedRange().location, start = lineStart(caret)
        guard let atom = block(at: start), atom.listParts != nil else { return false }
        breakUndoCoalescing()
        replaceBlocks(NSRange(location: start, length: 1), with: "  " + atom.source)
        setSelectedRange(NSRange(location: caret, length: 0))
        breakUndoCoalescing()
        return true
    }

    // MARK: Paste

    /// A rich paste that parses to anything but one plain line goes in as whole lines, the way
    /// Tiptap inserts block content (`insertMarkdownParagraphs`, `insertContentAt`): the caret's
    /// line splits around them, an empty line is replaced, and at the start of a line they go
    /// before it. Inside a quote they become quote lines; inside a list item they stay literal
    /// lines after it (`blocks: false`), and the rest of the item continues as a new item.
    func pasteBlocks(_ pasted: String) -> Bool {
        guard richTextEnabled, codeFenceAtCaret == nil, !pasted.isEmpty else { return false }
        var selection = selectedRange()
        let start = lineStart(selection.location)
        // ponytail: a selection across lines pastes in place; split it like T3 if anyone does it
        guard lineStart(NSMaxRange(selection)) == start, !(selection.location == start && block(at: start)?.isLineMarker == true && selection.length > 0) else { return false }
        let atom = block(at: start).flatMap { $0.isLineMarker ? $0 : nil }
        let inList = atom?.listParts != nil
        let inQuote = atom.map { if case .quote = $0.kind { true } else { false } } ?? false
        let lines = pasted.components(separatedBy: "\n")
        if lines.count == 1 {
            // One line that is a block of its own still goes in as a block, at the top level.
            if inList || inQuote || (ComposerBlockAttachment.prefix(pasted) == nil && ComposerBlockAttachment.openingFence(pasted) == nil) { return false }
        }
        if selection.length > 0 { replace(selection, with: ""); selection.length = 0 }
        let caret = selection.location, end = lineEnd(caret), contentStart = start + (atom == nil ? 0 : 1)
        let empty = end == contentStart
        let length = (pasted as NSString).length
        if inQuote, let atom {
            let quoted = lines.joined(separator: "\n" + atom.source)
            let text: String
            if empty || caret == contentStart { text = quoted + (empty ? "" : "\n" + atom.source) }
            else if caret == end { text = "\n" + atom.source + quoted }
            else { text = "\n" + atom.source + quoted + "\n" + atom.source }
            let md = markdownOffset(caret) + (empty || caret == contentStart ? 0 : 1 + (atom.source as NSString).length)
            replaceBlocks(NSRange(location: caret, length: 0), with: text)
            setCaret(markdown: md + (quoted as NSString).length)
            return true
        }
        if inList, let atom {
            if empty { return false }
            if caret == contentStart {
                let md = markdownOffset(start)
                replace(NSRange(location: start, length: 0), with: pasted + "\n")
                setCaret(markdown: md + length)
                return true
            }
            let md = markdownOffset(caret) + 1
            replace(NSRange(location: caret, length: 0), with: "\n" + pasted)
            if caret != end {
                // The rest of the item continues as an item with the same marker.
                let at = selectedRange().location
                replaceBlocks(NSRange(location: at, length: 0), with: "\n" + atom.source)
            }
            setCaret(markdown: md + length)
            return true
        }
        let text: String, at: NSRange, lead: Int
        if empty { at = NSRange(location: start, length: end - start); text = pasted; lead = 0 }
        else if caret == contentStart { at = NSRange(location: start, length: 0); text = pasted + "\n"; lead = 0 }
        else if caret == end { at = NSRange(location: caret, length: 0); text = "\n" + pasted; lead = 1 }
        else { at = NSRange(location: caret, length: 0); text = "\n" + pasted + "\n" + (atom?.source ?? ""); lead = 1 }
        let md = markdownOffset(at.location) + lead
        replaceBlocks(at, with: text)
        setCaret(markdown: md + length)
        return true
    }
}
