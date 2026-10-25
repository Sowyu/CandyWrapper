import AppKit
import DesignSystem
import SpaceEngine
import SpaceModel

/// Where page images come from: the local blob cache (docs/space.md section 7, piece 6). Upload is piece 16.
@MainActor
public protocol SpaceBlobSource: AnyObject {
    /// Keeps the bytes in the local blob cache and returns the reference a block stores.
    func store(_ data: Data, name: String, mime: String) async throws -> BlobReference
    /// The cached bytes, or nil while the blob isn't on this device.
    func data(for blob: BlobReference) async -> Data?
}

/// Page view (docs/space.md "Page view"): one TextKit 2 text view holds every block and item row as paragraphs, with
/// the record as a paragraph attribute. Typing coalesces into one change per block, 400 ms after the last key or every
/// 2 s while typing goes on, and every change goes through the replica, so undo writes inverse changes.
@MainActor
public final class SpacePageEditor: NSObject, NSTextViewDelegate {
    public let store: SpaceDocumentStore
    public let page: PageID
    public weak var blobs: SpaceBlobSource?
    public let textView: SpacePageTextView
    public let scrollView: NSScrollView
    public var onOpenPage: (PageID) -> Void = { _ in }
    /// Each window's page keeps its own stack (docs/space.md section 9).
    public let undo = UndoManager()

    private(set) var paragraphs: [SpaceParagraphKey: SpaceParagraph] = [:]
    private(set) var keys: [SpaceParagraphKey] = []
    private var index: [SpaceParagraphKey: Int] = [:]
    /// The text each record holds in the store, to diff against.
    private var committed: [SpaceParagraphKey: RichText] = [:]
    /// The empty last paragraph after a final newline, or of an empty page. It has no characters to carry its key.
    private(set) var tailKey: SpaceParagraphKey?
    private(set) var isTodoList = false

    func isTodoRow(_ key: SpaceParagraphKey) -> Bool { key.isItem && paragraphs[key]?.todo == true }
    private var dirty: Set<SpaceParagraphKey> = []
    private var hints: [SpaceParagraphKey: Int] = [:]
    private var flushTimer: Timer?
    private var firstDirty: Date?
    private var typingGroup: UndoBox?
    private var applying = false
    private var pendingEdit: (location: Int, length: Int, structural: Bool)?
    private var expectedCaret: Int?
    /// Overrides what the next new paragraph becomes, for inserts the editor makes itself.
    private var nextFresh: (item: Bool, paragraph: SpaceParagraph)?
    private var pendingExtra: [RecordChange] = []
    private var numbers: [SpaceParagraphKey: Int]?
    private(set) var activeKey: SpaceParagraphKey?
    private var images: [String: NSImage] = [:]
    /// Base attributes and paragraph styles per look, made once instead of once per paragraph. Fonts are the
    /// font runtime's, so both caches empty when its generation moves on.
    private var baseCache: [BaseLook: [NSAttributedString.Key: Any]] = [:]
    private var styleCache: [SpacePageMetrics.StyleKey: NSParagraphStyle] = [:]
    private var cacheGeneration = FontRuntime.generation
    private var loadingImages: Set<String> = []
    private var token: Int?
    var menus = SpaceEditorMenus()

    public init(store: SpaceDocumentStore, page: PageID, blobs: SpaceBlobSource? = nil) {
        self.store = store
        self.page = page
        self.blobs = blobs
        textView = SpacePageTextView(usingTextLayoutManager: true)
        scrollView = NSScrollView()
        super.init()
        textView.editor = self
        textView.textLayoutManager?.delegate = self
        textView.delegate = self
        textView.isRichText = true
        textView.allowsUndo = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.foregroundColor: SpacePageMetrics.accent, .cursor: NSCursor.pointingHand]
        textView.insertionPointColor = Themed.color(\.foreground)
        textView.selectedTextAttributes = [.backgroundColor: SpacePageMetrics.accent.withAlphaComponent(0.28)]
        textView.setAccessibilityLabel("Page content")
        undo.groupsByEvent = false
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        token = store.observe { [weak self] in self?.storeChanged() }
        load()
    }

    isolated deinit {
        flushTimer?.invalidate()
        if let token { store.removeObserver(token) }
    }

    // MARK: Loading

    /// Rebuilds the text from the store. The caret stays in the same record at the same offset.
    func load(keepSelection: Bool = false) {
        let saved = keepSelection ? savedSelection() : nil
        menus.closeAll()
        guard let record = store.pages[page] else { return }
        isTodoList = record.isTodoList
        paragraphs = [:]; committed = [:]; keys = []; hints = [:]; dirty = []; numbers = nil
        let out = NSMutableAttributedString()
        let content = store.content(of: page)
        var texts: [RichText] = []
        texts.reserveCapacity(content.count)
        for item in content {
            let key: SpaceParagraphKey, para: SpaceParagraph, text: RichText
            switch item {
            case .block(let id, let r): key = .block(id); para = SpaceParagraph(block: r); text = r.text
            case .page(let id, let r): key = .item(id); para = SpaceParagraph(item: r); text = RichText(t: r.title)
            }
            paragraphs[key] = para
            committed[key] = text
            keys.append(key)
            texts.append(text)
        }
        tailKey = nil
        if content.isEmpty {
            let key = SpaceParagraphKey.block(BlockID())
            paragraphs[key] = SpaceParagraph()
            keys = [key]
            tailKey = key
        }
        // Card corners and heading spacing read the index, so it's built before the styles.
        reindex()
        // Styles go on with the text, before the text view sees the string, so TextKit lays it out once.
        out.beginEditing()
        for (i, text) in texts.enumerated() {
            let key = keys[i]
            let para = paragraphs[key]!
            let start = out.length
            hints[key] = start
            out.append(attributed(text, key: key, para))
            if i < texts.count - 1 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes(key, para))) }
            let range = NSRange(location: start, length: out.length - start)
            guard range.length > 0 else { continue }
            out.addAttribute(.paragraphStyle, value: paragraphStyle(key, para), range: range)
            if key.isItem { out.addAttribute(.foregroundColor, value: SpacePageMetrics.color(.p, item: para.done && para.todo), range: range) }
        }
        out.endEditing()
        applying = true
        textView.textStorage?.setAttributedString(out)
        applying = false
        if let saved { restore(saved) } else { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        fixTypingAttributes()
    }

    private func reindex() {
        index = [:]
        for (i, key) in keys.enumerated() { index[key] = i }
        numbers = nil
    }

    private func storeChanged() {
        guard !applying else { return }
        let changed = store.lastChanged
        let mine = Set(keys.map(\.id)).union([page])
        let touches = !changed.isDisjoint(with: mine) || changed.contains { id in
            store.block(id)?.page == page || store.pages[id]?.parent == page
        }
        guard touches else { return }
        // A title typed in the header changes only the page record; the paragraphs stay as they are.
        if changed == [page], store.pages[page]?.isTodoList == isTodoList { return }
        flushTyping()
        load(keepSelection: true)
    }

    // MARK: Attributes

    private struct BaseLook: Hashable { var item: Bool; var type: BlockType; var done: Bool }

    private func checkCacheGeneration() {
        guard cacheGeneration != FontRuntime.generation else { return }
        cacheGeneration = FontRuntime.generation
        baseCache = [:]
        styleCache = [:]
    }

    func baseAttributes(_ key: SpaceParagraphKey, _ p: SpaceParagraph) -> [NSAttributedString.Key: Any] {
        checkCacheGeneration()
        let type = key.isItem ? BlockType.p : p.type
        let look = BaseLook(item: key.isItem, type: type, done: key.isItem && p.done && p.todo)
        var attrs = baseCache[look] ?? {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: key.isItem ? DSFont.ui(14) : SpacePageMetrics.baseFont(type),
                .foregroundColor: key.isItem ? SpacePageMetrics.color(.p, item: p.done && p.todo) : SpacePageMetrics.color(type)]
            baseCache[look] = attrs
            return attrs
        }()
        attrs[.spaceBlock] = key.raw
        return attrs
    }

    func attributed(_ text: RichText, key: SpaceParagraphKey, _ p: SpaceParagraph) -> NSAttributedString {
        let string = !text.t.contains("\n") ? text.t
            : key.isItem ? text.t.replacingOccurrences(of: "\n", with: " ") : text.t.replacingOccurrences(of: "\n", with: "\u{2028}")
        let s = NSMutableAttributedString(string: string, attributes: baseAttributes(key, p))
        let length = s.length
        for mark in text.m where mark.start < mark.end && mark.end <= length {
            let r = NSRange(location: mark.start, length: mark.end - mark.start)
            switch mark.kind {
            case .b: s.addAttribute(.spaceBold, value: true, range: r)
            case .i: s.addAttribute(.spaceItalic, value: true, range: r)
            case .c: s.addAttribute(.spaceCode, value: true, range: r)
            case .u: s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .s: s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .a: if let url = mark.value.flatMap(URL.init(string:)) { s.addAttribute(.link, value: url, range: r) }
            case .p: if let id = mark.value, let url = URL(string: "space-page:" + id) { s.addAttribute(.link, value: url, range: r) }
            default: break
            }
        }
        // Without bold, italic or code marks the base font is already the right one.
        if text.m.contains(where: { $0.kind == .b || $0.kind == .i || $0.kind == .c }) {
            fixFonts(s, NSRange(location: 0, length: length), key.isItem ? .p : p.type)
        }
        return s
    }

    /// Fonts follow the block type plus the bold, italic and code marks.
    func fixFonts(_ s: NSMutableAttributedString, _ range: NSRange, _ type: BlockType) {
        guard range.length > 0 else { return }
        s.enumerateAttributes(in: range) { attrs, r, _ in
            let code = attrs[.spaceCode] != nil
            s.addAttribute(.font, value: SpacePageMetrics.font(type, bold: attrs[.spaceBold] != nil, italic: attrs[.spaceItalic] != nil, code: code), range: r)
            if code { s.addAttribute(.backgroundColor, value: Themed.color(\.codeBackground), range: r) } else { s.removeAttribute(.backgroundColor, range: r) }
        }
    }

    /// The paragraph style and base color for every paragraph overlapping `range`.
    func restyle(_ range: NSRange, in string: NSMutableAttributedString? = nil) {
        guard let storage = string ?? textView.textStorage else { return }
        let ms = storage.mutableString
        let length = ms.length
        storage.beginEditing()
        var loc = min(range.location, length)
        let end = min(length, NSMaxRange(range))
        repeat {
            guard loc < length else { break }
            let pr = ms.paragraphRange(for: NSRange(location: loc, length: 0))
            let key = pr.length > 0 ? (storage.attribute(.spaceBlock, at: pr.location, effectiveRange: nil) as? String).flatMap(SpaceParagraphKey.init(raw:)) : tailKey
            if let key, let p = paragraphs[key] {
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(key, p), range: pr)
                if key.isItem { storage.addAttribute(.foregroundColor, value: SpacePageMetrics.color(.p, item: p.done && p.todo), range: pr) }
            }
            loc = NSMaxRange(pr)
        } while loc < end
        storage.endEditing()
    }

    func paragraphStyle(_ key: SpaceParagraphKey, _ p: SpaceParagraph) -> NSParagraphStyle {
        checkCacheGeneration()
        let style = SpacePageMetrics.StyleKey(p, item: key.isItem, todo: p.todo, card: key.isItem ? cardPlace(key) : nil,
                                              firstInPage: index[key] == 0, image: p.type == .image ? imageSize(p) : nil)
        if let cached = styleCache[style] { return cached }
        let made = SpacePageMetrics.paragraphStyle(style)
        styleCache[style] = made
        return made
    }

    func headIndent(_ key: SpaceParagraphKey, _ p: SpaceParagraph) -> CGFloat { paragraphStyle(key, p).firstLineHeadIndent }

    // MARK: Paragraph lookup

    private func isSeparator(_ c: unichar) -> Bool { c == 0x0A || c == 0x0D || c == 0x2029 }

    func key(atParagraph pr: NSRange) -> SpaceParagraphKey? {
        guard let storage = textView.textStorage, pr.length > 0 else { return tailKey }
        return (storage.attribute(.spaceBlock, at: pr.location, effectiveRange: nil) as? String).flatMap(SpaceParagraphKey.init(raw:))
    }

    /// The paragraph holding `location`, without its separator.
    func paragraph(at location: Int) -> (key: SpaceParagraphKey, range: NSRange)? {
        guard let ms = textView.textStorage?.mutableString else { return nil }
        let length = ms.length
        if location >= length, length == 0 || isSeparator(ms.character(at: length - 1)) {
            return tailKey.map { ($0, NSRange(location: length, length: 0)) }
        }
        let pr = ms.paragraphRange(for: NSRange(location: min(location, length), length: 0))
        guard let key = key(atParagraph: pr) else { return nil }
        return (key, contentRange(pr))
    }

    private func contentRange(_ pr: NSRange) -> NSRange {
        guard let ms = textView.textStorage?.mutableString, pr.length > 0, isSeparator(ms.character(at: NSMaxRange(pr) - 1)) else { return pr }
        return NSRange(location: pr.location, length: pr.length - 1)
    }

    /// The paragraph's text range, without its separator.
    func range(of key: SpaceParagraphKey) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        if key == tailKey, let p = paragraph(at: storage.length), p.key == key { return p.range }
        if let hint = hints[key], hint < storage.length, let p = paragraph(at: hint), p.key == key { return p.range }
        var found: NSRange?
        storage.enumerateAttribute(.spaceBlock, in: NSRange(location: 0, length: storage.length)) { value, r, stop in
            if (value as? String) == key.raw { found = r; stop.pointee = true }
        }
        guard let found else { return nil }
        hints[key] = found.location
        return paragraph(at: found.location)?.range
    }

    func cardPlace(_ key: SpaceParagraphKey) -> SpacePageMetrics.CardPlace {
        guard let i = index[key] else { return .init(first: true, last: true) }
        return .init(first: i == 0 || !isTodoRow(keys[i - 1]), last: i == keys.count - 1 || !isTodoRow(keys[i + 1]))
    }

    func number(of key: SpaceParagraphKey) -> Int {
        if numbers == nil {
            var out: [SpaceParagraphKey: Int] = [:], counters: [Int: Int] = [:]
            for k in keys {
                guard let p = paragraphs[k], !k.isItem else { counters = [:]; continue }
                if p.type == .number {
                    let n = (counters[p.indent] ?? 0) + 1
                    counters = counters.filter { $0.key < p.indent }
                    counters[p.indent] = n
                    out[k] = n
                } else {
                    counters = counters.filter { $0.key < p.indent }
                }
            }
            numbers = out
        }
        return numbers?[key] ?? 1
    }

    // MARK: Reading text back

    /// The rich text in `range`: line separators become newlines and attributes become marks.
    func richText(in range: NSRange) -> RichText {
        guard let storage = textView.textStorage, range.length > 0 else { return RichText() }
        let text = storage.attributedSubstring(from: range)
        let t = text.string.replacingOccurrences(of: "\u{2028}", with: "\n")
        var marks: [TextMark] = []
        let all = NSRange(location: 0, length: text.length)
        func collect(_ key: NSAttributedString.Key, _ kind: @escaping (Any) -> (MarkKind, String?)?) {
            text.enumerateAttribute(key, in: all) { value, r, _ in
                guard let value, let (k, v) = kind(value) else { return }
                if let last = marks.last, last.kind == k, last.value == v, last.end == r.location { marks[marks.count - 1].end = NSMaxRange(r) }
                else { marks.append(TextMark(start: r.location, end: NSMaxRange(r), kind: k, value: v)) }
            }
        }
        collect(.spaceBold) { _ in (.b, nil) }
        collect(.spaceItalic) { _ in (.i, nil) }
        collect(.spaceCode) { _ in (.c, nil) }
        collect(.underlineStyle) { v in (v as? Int ?? 0) != 0 ? (.u, nil) : nil }
        collect(.strikethroughStyle) { v in (v as? Int ?? 0) != 0 ? (.s, nil) : nil }
        collect(.link) { v in
            guard let url = v as? URL ?? (v as? String).flatMap(URL.init(string:)) else { return nil }
            if url.scheme == "space-page" { return (.p, String(url.absoluteString.dropFirst("space-page:".count))) }
            return (.a, url.absoluteString)
        }
        return RichText(t: t, m: marks)
    }

    // MARK: Edits from the text view

    public func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        guard !applying, let ms = tv.textStorage?.mutableString else { return true }
        let old = range.length > 0 ? ms.substring(with: range) : ""
        let new = string ?? ""
        let separators = CharacterSet(charactersIn: "\n\r\u{2029}")
        let structural = old.rangeOfCharacter(from: separators) != nil || new.rangeOfCharacter(from: separators) != nil
        if let p = paragraph(at: range.location), p.key.isItem, new.contains("\u{2028}") { return false }
        // A structural edit starts its own undo group, so the typing before it undoes on its own.
        if structural { flushTyping() }
        pendingEdit = (range.location, (new as NSString).length, structural)
        return true
    }

    public func textDidChange(_ notification: Notification) {
        guard !applying, let edit = pendingEdit else { return }
        pendingEdit = nil
        if edit.structural {
            rescan(edited: NSRange(location: edit.location, length: edit.length))
            flush(discrete: true, name: "Typing")
        } else if let p = paragraph(at: edit.location) {
            normalize(p.key, p.range)
            markDirty(p.key, at: p.range.location)
            if edit.length > 0 { checkShortcut(p.key, p.range) }
        }
        expectedCaret = textView.selectedRange().location
        menus.textChanged(self)
    }

    /// Typed characters can pick up the key of the paragraph before; the paragraph keeps one key.
    private func normalize(_ key: SpaceParagraphKey, _ range: NSRange) {
        guard let storage = textView.textStorage, range.length > 0 else { return }
        var eff = NSRange()
        let v = storage.attribute(.spaceBlock, at: range.location, longestEffectiveRange: &eff, in: range) as? String
        if v != key.raw || eff != range {
            applying = true
            storage.addAttribute(.spaceBlock, value: key.raw, range: range)
            applying = false
        }
    }

    private func markDirty(_ key: SpaceParagraphKey, at location: Int) {
        dirty.insert(key)
        hints[key] = location
        let now = Date()
        if firstDirty == nil { firstDirty = now }
        let fire = min(now.addingTimeInterval(0.4), firstDirty!.addingTimeInterval(2))
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: max(0, fire.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush(discrete: false) }
        }
    }

    /// Works out every paragraph's key after an edit that added or removed separators. A paragraph keeps the key of
    /// its first character, else its separator; a paragraph whose candidates are taken is a new record.
    private func rescan(edited: NSRange) {
        guard let storage = textView.textStorage else { return }
        let ms = storage.mutableString
        let length = ms.length
        var newKeys: [SpaceParagraphKey] = []
        var used: Set<SpaceParagraphKey> = []
        var fixes: [(NSRange, SpaceParagraphKey)] = []
        var touched: Set<SpaceParagraphKey> = []
        var loc = 0
        while loc < length {
            let pr = ms.paragraphRange(for: NSRange(location: loc, length: 0))
            func attr(_ i: Int) -> SpaceParagraphKey? {
                (storage.attribute(.spaceBlock, at: i, effectiveRange: nil) as? String).flatMap(SpaceParagraphKey.init(raw:))
            }
            let first = attr(pr.location), last = attr(NSMaxRange(pr) - 1)
            let key = [first, last].compactMap { $0 }.first { !used.contains($0) && paragraphs[$0] != nil }
                ?? fresh(from: first ?? last ?? newKeys.last)
            var eff = NSRange()
            let v = storage.attribute(.spaceBlock, at: pr.location, longestEffectiveRange: &eff, in: pr) as? String
            if v != key.raw || eff != pr { fixes.append((pr, key)) }
            if NSIntersectionRange(pr, NSRange(location: edited.location, length: max(1, edited.length))).length > 0
                || (pr.location <= edited.location && edited.location <= NSMaxRange(pr)) { touched.insert(key) }
            used.insert(key)
            newKeys.append(key)
            hints[key] = pr.location
            loc = NSMaxRange(pr)
        }
        if length == 0 || isSeparator(ms.character(at: length - 1)) {
            let key = tailKey.flatMap { used.contains($0) ? nil : $0 } ?? fresh(from: newKeys.last)
            newKeys.append(key)
            tailKey = key
            if edited.location + edited.length >= length { touched.insert(key) }
        } else { tailKey = nil }

        let old = Set(keys)
        let now = Set(newKeys)
        let at = SpaceClock.now()
        for key in keys where !now.contains(key) {
            if exists(key) {
                pendingExtra.append(key.isItem
                    ? RecordChange(kind: .page, id: key.id, set: ["trashed": .bool(true), "trashedAt": .integer(at)])
                    : RecordChange(kind: .block, id: key.id, set: ["trashed": .bool(true)]))
            }
            paragraphs[key] = nil
            committed[key] = nil
            dirty.remove(key)
        }
        for key in newKeys where !old.contains(key) { touched.insert(key) }
        keys = newKeys
        reindex()
        if !fixes.isEmpty {
            applying = true
            storage.beginEditing()
            for (r, key) in fixes { storage.addAttribute(.spaceBlock, value: key.raw, range: r) }
            storage.endEditing()
            applying = false
        }
        dirty.formUnion(touched)
        // Neighbors change card corners and heading spacing, so restyle one paragraph either side.
        var lo = max(0, edited.location - 1), hi = min(length, NSMaxRange(edited) + 1)
        if lo > 0 { lo = ms.paragraphRange(for: NSRange(location: lo - 1, length: 0)).location }
        if hi < length { hi = NSMaxRange(ms.paragraphRange(for: NSRange(location: hi, length: 0))) }
        applying = true
        restyle(NSRange(location: lo, length: hi - lo))
        applying = false
        fixTypingAttributes()
    }

    private func fresh(from: SpaceParagraphKey?) -> SpaceParagraphKey {
        if let next = nextFresh {
            nextFresh = nil
            let key: SpaceParagraphKey = next.item ? .item(PageID()) : .block(BlockID())
            paragraphs[key] = next.paragraph
            return key
        }
        // Return after a to-do makes the next to-do; after a page link it starts a text paragraph.
        let key: SpaceParagraphKey = from.map(isTodoRow) == true ? .item(PageID()) : .block(BlockID())
        paragraphs[key] = from.flatMap { paragraphs[$0] }.map { prev in
            if from?.isItem == true, !key.isItem { return SpaceParagraph() }
            guard key.isItem else { return prev.continued() }
            var p = SpaceParagraph()
            p.todo = prev.todo
            return p
        } ?? SpaceParagraph()
        return key
    }

    private func exists(_ key: SpaceParagraphKey) -> Bool {
        switch key {
        case .block(let id): store.block(id) != nil
        case .item(let id): store.pages[id] != nil
        }
    }

    // MARK: Committing

    /// Ends the typing run: what's typed so far goes in as one edit, merged into the open undo group.
    func flushTyping() {
        if !dirty.isEmpty { flush(discrete: false) }
        flushTimer?.invalidate()
        flushTimer = nil
    }

    /// Writes dirty text and queued structural changes as one edit. Typing merges into the open typing group.
    func flush(discrete: Bool, name: String = "Typing") {
        flushTimer?.invalidate()
        flushTimer = nil
        firstDirty = nil
        var changes = pendingExtra
        pendingExtra = []
        var assigned: [SpaceParagraphKey: OrderKey] = [:]
        for key in keys where dirty.contains(key) {
            if let change = textChange(key, &assigned) { changes.append(change) }
        }
        dirty = []
        commit(changes, typing: !discrete, name: name)
    }

    private func textChange(_ key: SpaceParagraphKey, _ assigned: inout [SpaceParagraphKey: OrderKey]) -> RecordChange? {
        guard let p = paragraphs[key], let r = range(of: key) else { return nil }
        let text = richText(in: r)
        if !exists(key) {
            // An empty page's lone empty paragraph stays unsaved until it has something in it.
            if keys.count == 1, text.t.isEmpty, p.type == .p { return nil }
            let order = self.order(for: key, assigned)
            assigned[key] = order
            committed[key] = text
            switch key {
            case .block(let id):
                let record = BlockRecord(page: page, order: order, type: p.type, indent: p.indent, text: text, lang: p.lang, blob: p.blob, width: p.width)
                return try? RecordChange.block(id, record)
            case .item(let id):
                var record = PageRecord(parent: page, order: order, title: text.t, view: p.view, created: SpaceClock.now())
                if p.todo { record.props[FieldID.done] = .checkbox(p.done) }
                if let due = p.due { record.props[FieldID.due] = .date(due) }
                return try? RecordChange.page(id, record)
            }
        }
        guard committed[key] != text else { return nil }
        committed[key] = text
        switch key {
        case .block(let id): return RecordChange(kind: .block, id: id, set: ["text": (try? JSONValue(encoding: text)) ?? .null])
        case .item(let id): return RecordChange(kind: .page, id: id, set: ["title": .string(text.t)])
        }
    }

    /// An order key between the nearest saved neighbors in text order.
    func order(for key: SpaceParagraphKey, _ assigned: [SpaceParagraphKey: OrderKey] = [:]) -> OrderKey {
        let i = index[key] ?? keys.count
        func saved(_ k: SpaceParagraphKey) -> OrderKey? {
            if let a = assigned[k] { return a }
            switch k {
            case .block(let id): return store.block(id)?.order
            case .item(let id): return store.pages[id]?.order
            }
        }
        let lower = keys[..<min(i, keys.count)].reversed().lazy.compactMap { k in k == key ? nil : saved(k) }.first
        let upper = keys[min(keys.count, i + 1)...].lazy.compactMap { k in k == key ? nil : saved(k) }.first
        if let lower, let upper, !(lower < upper) { return (try? OrderKey.between(lower, nil)) ?? lower }
        return (try? OrderKey.between(lower, upper)) ?? (try! OrderKey.between(lower, nil))
    }

    private func commit(_ changes: [RecordChange], typing: Bool, name: String) {
        guard !changes.isEmpty else {
            if !typing { typingGroup = nil }
            return
        }
        applying = true
        let entry = store.edit(changes)
        applying = false
        guard let entry else { return }
        if typing, let group = typingGroup {
            group.entry = group.entry.merging(entry)
            return
        }
        let box = UndoBox(entry)
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { $0.perform(box) }
        undo.setActionName(name)
        undo.endUndoGrouping()
        typingGroup = typing ? box : nil
    }

    /// One discrete edit: what's typed first goes in its own group, then `changes` as a new group.
    func commitDiscrete(_ changes: [RecordChange], name: String) {
        flushTyping()
        typingGroup = nil
        pendingExtra += changes
        flush(discrete: true, name: name)
    }

    private func perform(_ box: UndoBox) {
        typingGroup = nil
        applying = true
        let redo = store.undo(box.entry)
        applying = false
        load(keepSelection: true)
        if let redo, !redo.isEmpty {
            let next = UndoBox(redo)
            undo.registerUndo(withTarget: self) { $0.perform(next) }
        }
    }

    func performUndo() {
        flushTyping()
        typingGroup = nil
        if undo.canUndo { undo.undo() }
    }

    func performRedo() {
        flushTyping()
        typingGroup = nil
        if undo.canRedo { undo.redo() }
    }

    var canUndo: Bool { undo.canUndo || !dirty.isEmpty }

    // MARK: Selection

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying else { return }
        let sel = textView.selectedRange()
        // The caret moves inside an edit too; only a move outside one ends the typing run.
        if pendingEdit == nil, let expected = expectedCaret, sel.location != expected || sel.length > 0 {
            flushTyping()
            typingGroup = nil
            expectedCaret = nil
        }
        let key = paragraph(at: sel.location)?.key
        if key != activeKey {
            let old = activeKey
            activeKey = key
            // The "Type / for commands" hint follows the caret; redraw after AppKit finishes moving it.
            DispatchQueue.main.async { [weak self] in for k in [old, key].compactMap({ $0 }) { self?.invalidateLayout(k) } }
        }
        fixTypingAttributes()
        menus.selectionChanged(self)
    }

    /// At a paragraph's start, or in an empty one, typing takes that paragraph's look, never the paragraph before's.
    private func fixTypingAttributes() {
        let sel = textView.selectedRange()
        guard sel.length == 0, let p = paragraph(at: sel.location), let para = paragraphs[p.key] else { return }
        // Mid-paragraph, AppKit's typing attributes are already this paragraph's; only a link must not spread.
        if p.range.length > 0, sel.location > p.range.location, textView.typingAttributes[.link] == nil,
           textView.typingAttributes[.spaceBlock] as? String == p.key.raw { return }
        var attrs = textView.typingAttributes
        attrs.removeValue(forKey: .link)
        if p.range.length == 0 || sel.location == p.range.location {
            if p.range.length > 0, let storage = textView.textStorage {
                attrs = storage.attributes(at: p.range.location, effectiveRange: nil)
                attrs.removeValue(forKey: .link)
            } else {
                attrs = baseAttributes(p.key, para)
            }
            attrs[.paragraphStyle] = paragraphStyle(p.key, para)
        }
        attrs[.spaceBlock] = p.key.raw
        textView.typingAttributes = attrs
    }

    private struct SavedSelection { var key: SpaceParagraphKey; var offset: Int; var length: Int }

    private func savedSelection() -> SavedSelection? {
        let sel = textView.selectedRange()
        guard let p = paragraph(at: sel.location) else { return nil }
        return SavedSelection(key: p.key, offset: sel.location - p.range.location, length: sel.length)
    }

    private func restore(_ s: SavedSelection) {
        guard let r = range(of: s.key) else { return }
        let loc = r.location + min(s.offset, r.length)
        let length = min(s.length, (textView.textStorage?.length ?? 0) - loc)
        textView.setSelectedRange(NSRange(location: loc, length: max(0, length)))
    }

    /// Redraws a paragraph whose decoration changed. An attribute edit notice makes the text view lay it out and
    /// draw it again, which a bare layout invalidation doesn't.
    func invalidateLayout(_ key: SpaceParagraphKey) {
        guard let storage = textView.textStorage, storage.length > 0, let r = range(of: key) else { return }
        let ms = storage.mutableString
        // An empty last paragraph draws as an extra line of the paragraph before it.
        let pr = ms.paragraphRange(for: NSRange(location: min(r.location, storage.length - 1), length: 0))
        let wasApplying = applying
        applying = true
        storage.beginEditing()
        storage.edited(.editedAttributes, range: pr, changeInLength: 0)
        storage.endEditing()
        applying = wasApplying
    }

    // MARK: Layout fragments

    func fragment(at point: CGPoint) -> SpaceBlockFragment? {
        let inset = textView.textContainerOrigin
        let p = CGPoint(x: point.x - inset.x, y: point.y - inset.y)
        return textView.textLayoutManager?.textLayoutFragment(for: p) as? SpaceBlockFragment
    }

    /// Clicks on the parts the text view doesn't own: checkboxes, due dates, New to-do, link rows, Keep and Discard.
    func handleClick(at point: CGPoint) -> Bool {
        let inset = textView.textContainerOrigin
        let p = CGPoint(x: point.x - inset.x, y: point.y - inset.y)
        guard let fragment = fragment(at: point), let key = fragment.paragraphKey, let para = paragraphs[key] else {
            return clickBelowEnd(p)
        }
        let t = fragment.targets()
        if let box = t.checkbox, box.contains(p) { toggleDone(key); return true }
        if let due = t.due, due.contains(p) { menus.openDue(self, key: key, anchor: due.offsetBy(dx: inset.x, dy: inset.y)); return true }
        if let add = t.addRow, add.contains(p) { addItem(after: key); return true }
        if let keep = t.keep, keep.contains(p) { resolveConflict(key, keep: true); return true }
        if let discard = t.discard, discard.contains(p) { resolveConflict(key, keep: false); return true }
        // A link row opens its page, unless the caret is already in it and the click lands on the title.
        if case .item(let id) = key, !isTodoRow(key), let row = t.row, row.contains(p), p.x < 24 || key != activeKey || textView.window?.firstResponder !== textView {
            _ = para
            flushTyping()
            onOpenPage(id)
            return true
        }
        return false
    }

    /// A click under the last paragraph puts the caret in an empty text paragraph at the end, adding one if needed.
    private func clickBelowEnd(_ p: CGPoint) -> Bool {
        guard let tlm = textView.textLayoutManager, let storage = textView.textStorage else { return false }
        var lastBottom: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
            lastBottom = f.layoutFragmentFrame.maxY
            return false
        }
        guard p.y > lastBottom else { return false }
        if let last = keys.last, !last.isItem, paragraphs[last]?.type == .p, range(of: last)?.length == 0 {
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            nextFresh = (false, SpaceParagraph())
            textView.insertText("\n", replacementRange: NSRange(location: storage.length, length: 0))
        }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    // MARK: Commands

    func setType(_ key: SpaceParagraphKey, _ type: BlockType, indent: Int? = nil, extra: [RecordChange] = []) {
        guard case .block(let id) = key, var p = paragraphs[key] else { return }
        flushTyping()
        p.type = type
        if let indent { p.indent = indent }
        if type != .code { p.lang = nil }
        paragraphs[key] = p
        numbers = nil
        restyleText(key)
        var set: [String: JSONValue] = ["type": .string(type.rawValue), "indent": .integer(Int64(p.indent))]
        if type != .code { set["lang"] = .null }
        if exists(key) {
            var changes = extra
            if let i = changes.firstIndex(where: { $0.id == id }) { changes[i].set.merge(set) { $1 } } else { changes.append(RecordChange(kind: .block, id: id, set: set)) }
            commitDiscrete(changes, name: "Turn into")
        } else { dirty.insert(key); flush(discrete: true, name: "Turn into") }
    }

    func setIndent(_ key: SpaceParagraphKey, _ indent: Int) {
        guard case .block(let id) = key, var p = paragraphs[key] else { return }
        let clamped = max(0, min(5, indent))
        guard clamped != p.indent else { return }
        flushTyping()
        p.indent = clamped
        paragraphs[key] = p
        numbers = nil
        restyleText(key)
        if exists(key) { commitDiscrete([RecordChange(kind: .block, id: id, set: ["indent": .integer(Int64(clamped))])], name: "Indent") }
        else { dirty.insert(key); flush(discrete: true, name: "Indent") }
    }

    /// Fonts and paragraph styles again after a type change, and the paragraphs around it.
    private func restyleText(_ key: SpaceParagraphKey) {
        guard let storage = textView.textStorage, let r = range(of: key), let p = paragraphs[key] else { return }
        applying = true
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: key.isItem ? SpacePageMetrics.color(.p, item: p.done && p.todo) : SpacePageMetrics.color(p.type), range: r)
        fixFonts(storage, r, key.isItem ? .p : p.type)
        storage.endEditing()
        let ms = storage.mutableString
        let lo = r.location > 0 ? ms.paragraphRange(for: NSRange(location: r.location - 1, length: 0)).location : 0
        let after = min(storage.length, NSMaxRange(r) + 1)
        let hi = after < storage.length ? NSMaxRange(ms.paragraphRange(for: NSRange(location: after, length: 0))) : storage.length
        restyle(NSRange(location: lo, length: hi - lo))
        applying = false
        fixTypingAttributes()
        invalidateLayout(key)
        // Numbered lists renumber below the change.
        textView.needsDisplay = true
    }

    /// Line-start Markdown shortcuts (docs/space.md "Page view").
    private func checkShortcut(_ key: SpaceParagraphKey, _ range: NSRange) {
        guard case .block = key, let p = paragraphs[key], p.type != .code, let ms = textView.textStorage?.mutableString else { return }
        let caret = textView.selectedRange().location
        guard caret > range.location, caret - range.location <= 4 else { return }
        let prefix = ms.substring(with: NSRange(location: range.location, length: caret - range.location))
        guard let shortcut = SpaceMarkdown.shortcut(prefix) else { return }
        if case .type(let t) = shortcut, t == p.type, t != .p { return }
        // What was typed goes in first, so undoing the shortcut brings the prefix back.
        flushTyping()
        typingGroup = nil
        let prefixRange = NSRange(location: range.location, length: caret - range.location)
        applying = true
        textView.textStorage?.replaceCharacters(in: prefixRange, with: "")
        applying = false
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        var extra: [RecordChange] = []
        if case .block(let id) = key, exists(key), let r = self.range(of: key) {
            let text = richText(in: r)
            committed[key] = text
            extra.append(RecordChange(kind: .block, id: id, set: ["text": (try? JSONValue(encoding: text)) ?? .null]))
        }
        switch shortcut {
        case .todo:
            convertToItem(key, view: .page, todo: true)
        case .type(.divider):
            setType(key, .divider, extra: extra)
            insertParagraph(after: key, SpaceParagraph())
        case .type(let t):
            setType(key, t, extra: extra)
        }
    }

    /// Turns a block into a child page in place: a to-do, or a page link in a view.
    func convertToItem(_ key: SpaceParagraphKey, view: ViewType, todo: Bool) {
        guard case .block(let id) = key, let storage = textView.textStorage, let r = range(of: key) else { return }
        flushTyping()
        let item = SpaceParagraphKey.item(PageID())
        var para = SpaceParagraph()
        para.view = view
        para.todo = todo
        let title = richText(in: r).t
        var changes: [RecordChange] = []
        let order = exists(key) ? store.block(id)!.order : self.order(for: key)
        if exists(key) { changes.append(RecordChange(kind: .block, id: id, set: ["trashed": .bool(true)])) }
        var record = PageRecord(parent: page, order: order, title: title, view: view, created: SpaceClock.now())
        if todo { record.props[FieldID.done] = .checkbox(false) }
        if let change = try? RecordChange.page(item.id, record) { changes.append(change) }
        let becameTodo = todo && !isTodoList
        if becameTodo, let field = try? JSONValue(encoding: FieldDefinition(name: "Done", type: .checkbox, order: (try? OrderKey.between(nil, nil))!)) {
            changes.append(RecordChange(kind: .page, id: page, set: ["fields.done": field]))
            isTodoList = true
        }
        // Swap the key on the paragraph without touching its text.
        paragraphs[key] = nil; committed[key] = nil; dirty.remove(key)
        paragraphs[item] = para
        committed[item] = RichText(t: title)
        if let i = index[key] { keys[i] = item }
        if tailKey == key { tailKey = item }
        reindex()
        // An empty line still has its separator, which names the paragraph; retag it too, or typing
        // after the swap lands on the old key and is dropped.
        applying = true
        let full = NSRange(location: r.location, length: min(r.length + 1, storage.length - r.location))
        if full.length > 0 { storage.addAttribute(.spaceBlock, value: item.raw, range: full) }
        applying = false
        // Text marks don't apply to titles; the paragraph takes the row look.
        applying = true
        if r.length > 0 {
            storage.removeAttribute(.spaceBold, range: r); storage.removeAttribute(.spaceItalic, range: r); storage.removeAttribute(.spaceCode, range: r)
        }
        applying = false
        restyleText(item)
        if becameTodo { applying = true; restyle(NSRange(location: 0, length: storage.length)); applying = false }
        commitDiscrete(changes, name: todo ? "To-do" : "Page")
        textView.setSelectedRange(NSRange(location: r.location + r.length, length: 0))
        fixTypingAttributes()
    }

    /// Puts a new paragraph after `key` and the caret in it.
    func insertParagraph(after key: SpaceParagraphKey, _ para: SpaceParagraph, item: Bool = false) {
        guard let r = range(of: key) else { return }
        textView.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        nextFresh = (item, para)
        textView.insertText("\n", replacementRange: NSRange(location: NSMaxRange(r), length: 0))
        nextFresh = nil
    }

    func toggleDone(_ key: SpaceParagraphKey) {
        guard case .item(let id) = key, var p = paragraphs[key] else { return }
        flushTyping()
        p.done.toggle()
        paragraphs[key] = p
        restyleText(key)
        commitDiscrete([RecordChange(kind: .page, id: id, set: ["props.done": .bool(p.done)])], name: p.done ? "Check" : "Uncheck")
    }

    func setDue(_ key: SpaceParagraphKey, _ due: DateValue?) {
        guard case .item(let id) = key, var p = paragraphs[key] else { return }
        flushTyping()
        p.due = due
        paragraphs[key] = p
        var changes = [RecordChange(kind: .page, id: id, set: ["props.due": due.flatMap { try? JSONValue(encoding: $0) } ?? .null])]
        if due != nil, store.pages[page]?.fields[FieldID.due] == nil,
           let field = try? JSONValue(encoding: FieldDefinition(name: "Due", type: .date, order: (try? OrderKey.between(nil, nil))!)) {
            changes.append(RecordChange(kind: .page, id: page, set: ["fields.due": field]))
        }
        invalidateLayout(key)
        commitDiscrete(changes, name: "Due date")
    }

    func addItem(after key: SpaceParagraphKey) {
        textView.window?.makeFirstResponder(textView)
        var para = SpaceParagraph()
        para.todo = true
        insertParagraph(after: key, para, item: true)
    }

    func resolveConflict(_ key: SpaceParagraphKey, keep: Bool) {
        guard case .block(let id) = key, let i = index[key] else { return }
        flushTyping()
        var changes = [RecordChange(kind: .block, id: id, set: ["trashed": .bool(true)])]
        if keep, i > 0, case .block(let original) = keys[i - 1], let text = store.block(id)?.text {
            changes.append(RecordChange(kind: .block, id: original, set: ["text": (try? JSONValue(encoding: text)) ?? .null]))
        }
        commitDiscrete(changes, name: keep ? "Keep edit" : "Discard edit")
        load(keepSelection: false)
    }

    /// Return: an empty list item or to-do ends the list; a non-empty to-do makes the next one.
    func handleReturn() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0, let (key, r) = paragraph(at: sel.location), let p = paragraphs[key] else { return false }
        if key.isItem {
            if r.length == 0 {
                guard case .item(let id) = key else { return false }
                // An empty to-do leaves the list as a text paragraph.
                let block = SpaceParagraphKey.block(BlockID())
                paragraphs[block] = SpaceParagraph()
                var changes: [RecordChange] = []
                if exists(key) { changes.append(RecordChange(kind: .page, id: id, set: ["trashed": .bool(true), "trashedAt": .integer(SpaceClock.now())])) }
                let order = exists(key) ? store.pages[id]!.order : self.order(for: key)
                if let change = try? RecordChange.block(block.id, BlockRecord(page: page, order: order)) { changes.append(change) }
                paragraphs[key] = nil; committed[key] = nil; committed[block] = RichText()
                if let i = index[key] { keys[i] = block }
                if tailKey == key { tailKey = block }
                reindex()
                if let storage = textView.textStorage, r.location < storage.length {
                    applying = true
                    storage.addAttribute(.spaceBlock, value: block.raw, range: NSRange(location: r.location, length: 1))
                    applying = false
                }
                restyleText(block)
                commitDiscrete(changes, name: "Text")
                return true
            }
            return false
        }
        if p.type == .code { textView.insertLineBreak(nil); return true }
        if r.length == 0, [.bullet, .number, .quote].contains(p.type) {
            if p.indent > 0 { setIndent(key, p.indent - 1) } else { setType(key, .p) }
            return true
        }
        return false
    }

    /// Backspace at a paragraph's start outdents, then turns it into text, before it merges.
    func handleBackspace() -> Bool {
        let sel = textView.selectedRange()
        guard sel.length == 0, let (key, r) = paragraph(at: sel.location), sel.location == r.location, let p = paragraphs[key] else { return false }
        if !key.isItem {
            if p.indent > 0 { setIndent(key, p.indent - 1); return true }
            if [.divider, .image, .file].contains(p.type) { deleteParagraph(key); return true }
            if p.type != .p { setType(key, .p); return true }
        } else if r.length > 0 {
            if r.location > 0 { textView.setSelectedRange(NSRange(location: r.location - 1, length: 0)) }
            return true
        }
        guard r.location > 0, let prev = paragraph(at: r.location - 1), let pp = paragraphs[prev.key] else { return false }
        if !prev.key.isItem, [.divider, .image, .file].contains(pp.type) { deleteParagraph(prev.key); return true }
        if prev.key.isItem, r.length > 0 { textView.setSelectedRange(NSRange(location: NSMaxRange(prev.range), length: 0)); return true }
        return false
    }

    /// Removes a whole paragraph through the text view, so it trashes like any delete.
    func deleteParagraph(_ key: SpaceParagraphKey) {
        guard let storage = textView.textStorage, let r = range(of: key) else { return }
        var full = NSRange(location: r.location, length: min(r.length + 1, storage.length - r.location))
        if NSMaxRange(full) == storage.length, full.location > 0, NSMaxRange(r) == storage.length {
            full = NSRange(location: full.location - 1, length: full.length + 1)
        }
        guard full.length > 0 else { return }
        if textView.shouldChangeText(in: full, replacementString: "") {
            storage.replaceCharacters(in: full, with: "")
            textView.didChangeText()
        }
    }

    func handleTab(backwards: Bool) -> Bool {
        let sel = textView.selectedRange()
        guard let (key, _) = paragraph(at: sel.location), let p = paragraphs[key], !key.isItem else { return true }
        if p.type == .code { return false }
        setIndent(key, p.indent + (backwards ? -1 : 1))
        return true
    }

    /// ⌘B, ⌘I, ⌘U, ⌘E and ⌘⇧X toggle a mark on the selection.
    func toggleMark(_ attribute: NSAttributedString.Key) {
        guard let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let isOn: (Any?) -> Bool = { v in
            if attribute == .underlineStyle || attribute == .strikethroughStyle { return (v as? Int ?? 0) != 0 }
            return v != nil
        }
        let value: Any = attribute == .underlineStyle || attribute == .strikethroughStyle ? NSUnderlineStyle.single.rawValue : true
        if sel.length == 0 {
            var attrs = textView.typingAttributes
            if isOn(attrs[attribute]) { attrs.removeValue(forKey: attribute) } else { attrs[attribute] = value }
            if let p = paragraph(at: sel.location), let para = paragraphs[p.key] {
                attrs[.font] = SpacePageMetrics.font(p.key.isItem ? .p : para.type, bold: attrs[.spaceBold] != nil, italic: attrs[.spaceItalic] != nil, code: attrs[.spaceCode] != nil)
            }
            textView.typingAttributes = attrs
            return
        }
        var allOn = true
        storage.enumerateAttribute(attribute, in: sel) { v, _, stop in if !isOn(v) { allOn = false; stop.pointee = true } }
        flushTyping()
        applying = true
        storage.beginEditing()
        if allOn { storage.removeAttribute(attribute, range: sel) } else { storage.addAttribute(attribute, value: value, range: sel) }
        var loc = sel.location
        while loc < NSMaxRange(sel), let p = paragraph(at: loc) {
            let r = NSIntersectionRange(p.range, sel)
            if let para = paragraphs[p.key] { fixFonts(storage, r, p.key.isItem ? .p : para.type) }
            dirty.insert(p.key)
            loc = NSMaxRange(p.range) + 1
        }
        storage.endEditing()
        applying = false
        flush(discrete: true, name: "Format")
    }

    // MARK: Paste and copy

    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: imageTypes) != nil || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// Images become image blocks, Markdown or HTML with more than one line becomes blocks, one line pastes as text.
    func paste(from pb: NSPasteboard) -> Bool {
        let imageTypes = Self.imageTypes
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.compactMap { url -> (Data, String, String)? in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return (data, url.lastPathComponent, Self.mime(for: url.pathExtension))
            }
            if !files.isEmpty { insertBlobs(files); return true }
        }
        if pb.string(forType: .string) == nil, let type = pb.availableType(from: imageTypes), var data = pb.data(forType: type) {
            if type == .tiff, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { data = png }
            insertBlobs([(data, "Pasted image.png", type == .tiff || type == .png ? "image/png" : "image/\(type.rawValue.split(separator: ".").last ?? "png")")])
            return true
        }
        let plain = pb.string(forType: .string) ?? ""
        let markdownish = plain.contains("\n") || SpaceMarkdown.parse(plain).first.map { $0.type != .p || $0.todo != nil || !$0.text.m.isEmpty } == true
        var blocks: [SpaceMarkdown.Block] = []
        if markdownish {
            blocks = SpaceMarkdown.parse(plain)
        } else if plain.isEmpty, let html = pb.data(forType: .html) {
            blocks = Self.blocks(fromHTML: html)
        }
        if blocks.isEmpty {
            guard !plain.isEmpty else { return false }
            textView.insertText(plain.replacingOccurrences(of: "\t", with: " "), replacementRange: textView.selectedRange())
            return true
        }
        insertBlocks(blocks)
        return true
    }

    func insertBlocks(_ blocks: [SpaceMarkdown.Block]) {
        flushTyping()
        typingGroup = nil
        let out = NSMutableAttributedString()
        var needsTodo = false
        for (i, b) in blocks.enumerated() {
            let key: SpaceParagraphKey
            var para = SpaceParagraph(type: b.type, indent: b.indent)
            para.lang = b.lang
            if let done = b.todo { key = .item(PageID()); para = SpaceParagraph(); para.todo = true; para.done = done; needsTodo = true } else { key = .block(BlockID()) }
            paragraphs[key] = para
            out.append(attributed(key.isItem ? RichText(t: b.text.t) : b.text, key: key, para))
            if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes(key, para))) }
        }
        if needsTodo, !isTodoList, let field = try? JSONValue(encoding: FieldDefinition(name: "Done", type: .checkbox, order: (try? OrderKey.between(nil, nil))!)) {
            pendingExtra.append(RecordChange(kind: .page, id: page, set: ["fields.done": field]))
            isTodoList = true
        }
        textView.insertText(out, replacementRange: textView.selectedRange())
        if needsTodo, let storage = textView.textStorage { applying = true; restyle(NSRange(location: 0, length: storage.length)); applying = false }
        // A one-line paste isn't structural on its own; it still goes in now, as its own group.
        if !dirty.isEmpty || !pendingExtra.isEmpty { flush(discrete: true, name: "Paste") }
    }

    static func blocks(fromHTML data: Data) -> [SpaceMarkdown.Block] {
        guard let s = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return [] }
        var out: [SpaceMarkdown.Block] = []
        let ns = s.string as NSString
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(pr)
            var r = pr
            while r.length > 0, [0x0A, 0x0D, 0x2029].contains(ns.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
            let style = r.length > 0 ? s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle : nil
            var line = s.attributedSubstring(from: r)
            var block = SpaceMarkdown.Block()
            if let list = style?.textLists.last {
                block.type = list.markerFormat == .decimal ? .number : .bullet
                block.indent = min(5, max(0, (style?.textLists.count ?? 1) - 1))
                // AppKit writes the marker into the text as "\t•\t".
                let str = line.string as NSString
                let marker = str.range(of: "^\\t?[^\\t]*\\t", options: .regularExpression)
                if marker.location == 0 { line = line.attributedSubstring(from: NSRange(location: marker.length, length: str.length - marker.length)) }
            }
            let text = line.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if block.type == .p, let font = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font.pointSize >= 18 {
                block.type = font.pointSize >= 24 ? .h1 : font.pointSize >= 20 ? .h2 : .h3
            }
            var marks: [TextMark] = []
            let lead = (line.string as NSString).range(of: "^\\s*", options: .regularExpression).length
            line.enumerateAttributes(in: NSRange(location: 0, length: line.length)) { attrs, rr, _ in
                let start = rr.location - lead, end = NSMaxRange(rr) - lead
                guard end > max(0, start), start < (text as NSString).length else { return }
                let a = max(0, start), b = min((text as NSString).length, end)
                guard a < b else { return }
                if let font = attrs[.font] as? NSFont, block.type == .p || block.type == .bullet || block.type == .number {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { marks.append(TextMark(start: a, end: b, kind: .b)) }
                    if traits.contains(.italic) { marks.append(TextMark(start: a, end: b, kind: .i)) }
                }
                if let url = attrs[.link] as? URL ?? (attrs[.link] as? String).flatMap(URL.init(string:)) {
                    marks.append(TextMark(start: a, end: b, kind: .a, value: url.absoluteString))
                }
            }
            block.text = RichText(t: text, m: marks)
            out.append(block)
        }
        return out
    }

    /// Markdown for the selection. Inside one paragraph it's just the text.
    func markdown(for sel: NSRange) -> String? {
        guard sel.length > 0, let ms = textView.textStorage?.mutableString else { return nil }
        let first = ms.paragraphRange(for: NSRange(location: sel.location, length: 0))
        if NSMaxRange(sel) <= NSMaxRange(contentRange(first)) { return nil }
        var blocks: [SpaceMarkdown.Block] = []
        var loc = sel.location
        while loc < NSMaxRange(sel), let p = paragraph(at: loc), let para = paragraphs[p.key] {
            let r = NSIntersectionRange(p.range, sel)
            let text = r.length > 0 ? richText(in: r) : RichText()
            var b = SpaceMarkdown.Block(type: p.key.isItem ? .p : para.type, indent: para.indent, text: text, lang: para.lang)
            if p.key.isItem, para.todo { b.todo = para.done }
            if para.type == .image || para.type == .file { b.type = .p }
            blocks.append(b)
            loc = NSMaxRange(p.range) + 1
        }
        return SpaceMarkdown.serialize(blocks)
    }

    // MARK: Images and files

    func insertBlobs(_ files: [(Data, String, String)]) {
        guard let blobs else { return }
        let sel = textView.selectedRange()
        let anchor = paragraph(at: sel.location)?.key
        Task { @MainActor [weak self] in
            var anchor = anchor
            for (data, name, mime) in files {
                guard let self else { return }
                let isImage = mime.hasPrefix("image/")
                let limit = isImage ? 20_000_000 : 50_000_000
                guard data.count <= limit else { NSSound.beep(); continue }
                var ref: BlobReference
                do { ref = try await blobs.store(data, name: name, mime: mime) } catch { continue }
                if isImage, let rep = NSBitmapImageRep(data: data) { ref.w = rep.pixelsWide; ref.h = rep.pixelsHigh }
                var para = SpaceParagraph(type: isImage ? .image : .file)
                para.blob = ref
                if let key = anchor, case .block = key, let p = self.paragraphs[key], p.type == .p, self.range(of: key)?.length == 0 {
                    self.setMedia(key, para)
                } else if let key = anchor ?? self.keys.last {
                    self.insertParagraph(after: key, para)
                    anchor = self.paragraph(at: self.textView.selectedRange().location)?.key
                }
            }
        }
    }

    /// An empty text paragraph becomes an image or file block.
    private func setMedia(_ key: SpaceParagraphKey, _ para: SpaceParagraph) {
        guard case .block(let id) = key else { return }
        flushTyping()
        paragraphs[key] = para
        restyleText(key)
        if exists(key), let blob = para.blob.flatMap({ try? JSONValue(encoding: $0) }) {
            commitDiscrete([RecordChange(kind: .block, id: id, set: ["type": .string(para.type.rawValue), "blob": blob])], name: "Image")
        } else {
            dirty.insert(key)
            flush(discrete: true, name: "Image")
        }
    }

    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }

    /// Display size: beside a 220pt caption column, at most 270pt tall.
    func imageSize(_ p: SpaceParagraph) -> CGSize? {
        guard p.type == .image else { return nil }
        // Before the first layout the container has no width yet; size for the full column until it does.
        let containerWidth = textView.textContainer?.size.width ?? 0
        let column = containerWidth > 240 ? containerWidth : SpacePageMetrics.column
        let maxWidth = column - SpacePageMetrics.captionWidth - 20
        var natural = CGSize(width: 4, height: 3)
        if let w = p.blob?.w, let h = p.blob?.h, w > 0, h > 0 { natural = CGSize(width: w, height: h) }
        else if let id = p.blob?.id, let image = images[id] { natural = image.size }
        var width = min(p.width.map { CGFloat($0) } ?? maxWidth, maxWidth, natural.width > 4 ? natural.width : maxWidth)
        var height = width * natural.height / natural.width
        if height > 270 { height = 270; width = height * natural.width / natural.height }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Image sizes follow the column, so their paragraphs restyle when it changes width.
    func columnWidthChanged() {
        let images = keys.filter { paragraphs[$0]?.type == .image }
        guard !images.isEmpty else { return }
        applying = true
        for key in images { if let r = range(of: key) { restyle(r) } }
        applying = false
    }

    func drawImage(_ p: SpaceParagraph, in rect: CGRect) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        if let blob = p.blob, let image = images[blob.id] {
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Themed.color(\.muted).setFill()
            clip.fill()
            if let blob = p.blob { loadImage(blob, width: rect.width) }
        }
        Themed.color(\.border).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 1
        border.stroke()
    }

    /// Decodes once at display size, off the main thread. ponytail: kept while the page is open; release hidden
    /// pixels through the shared image pipeline in piece 16.
    private func loadImage(_ blob: BlobReference, width: CGFloat) {
        guard let blobs, loadingImages.insert(blob.id).inserted else { return }
        let scale = textView.window?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            guard let data = await blobs.data(for: blob) else { return }
            let image = await Task.detached { Self.decode(data, maxPixels: width * scale) }.value
            guard let self, let image else { return }
            self.images[blob.id] = image
            for (key, p) in self.paragraphs where p.blob?.id == blob.id { self.invalidateLayout(key) }
        }
    }

    nonisolated static func decode(_ data: Data, maxPixels: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxPixels))]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func chooseFile(images: Bool) {
        guard let window = textView.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if images { panel.allowedContentTypes = [.image] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let files = panel.urls.compactMap { url -> (Data, String, String)? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return (data, url.lastPathComponent, Self.mime(for: url.pathExtension))
                }
                self.insertBlobs(files)
            }
        }
    }

    // MARK: Item rows and labels

    static let lateColor = NSColor(name: nil) { $0.isDark ? NSColor(srgbRed: 0.941, green: 0.541, blue: 0.518, alpha: 1) : NSColor(srgbRed: 0.80, green: 0.27, blue: 0.24, alpha: 1) }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    /// The due label's text and whether it's overdue. Done items are never overdue.
    static func dueText(_ p: SpaceParagraph, now: Date = Date(), zone: TimeZone = .current) -> (text: String, late: Bool)? {
        guard let due = p.due else { return nil }
        let effective = due.start.isTimed ? (TimeZone(identifier: due.tz ?? "") ?? zone) : zone
        guard let instant = try? due.start.resolved(in: effective) else { return (due.start.rawValue, false) }
        let f = dayFormat
        f.timeZone = zone
        var text = f.string(from: instant)
        if due.start.isTimed {
            let t = DateFormatter(); t.locale = Locale(identifier: "en_AU"); t.timeZone = zone; t.dateFormat = "H:mm"
            text += " " + t.string(from: instant)
        }
        let late: Bool
        if p.done { late = false }
        else if due.start.isTimed { late = instant < now }
        else { late = (try? due.start < DatePoint.from(now, in: zone, timed: false)) ?? false }
        return (late ? "Overdue · " + text : text, late)
    }

    /// The reminder dialog's starting time: the one set, else the item's own time, else 09:00.
    static func reminderTimeText(_ due: DateValue) -> String {
        if case .at(let at)? = due.remind { return String(at.rawValue.suffix(5)) }
        if due.start.isTimed { return String(due.start.rawValue.suffix(5)) }
        return "09:00"
    }

    /// `due` reminding at `time` (H:MM or HH:MM) on its start day, or nil for anything else.
    static func withReminder(_ due: DateValue, time: String) -> DateValue? {
        let parts = time.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) }), let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m),
              let at = try? DatePoint(String(due.start.rawValue.prefix(10)) + String(format: "T%02d:%02d", h, m)) else { return nil }
        var next = due
        next.remind = .at(at)
        return next
    }

    /// "Mon 26 Oct", the due day as the label writes it.
    static func dueDayText(_ due: DateValue) -> String {
        guard let day = try? DatePoint(String(due.start.rawValue.prefix(10))), let instant = try? day.resolved(in: .current) else { return due.start.rawValue }
        let f = dayFormat
        f.timeZone = .current
        return f.string(from: instant)
    }

    private func dueLabel(_ p: SpaceParagraph) -> NSAttributedString {
        if let (text, late) = Self.dueText(p) {
            return NSAttributedString(string: text, attributes: [.font: DSFont.ui(12), .foregroundColor: late ? Self.lateColor : Themed.color(\.mutedForeground)])
        }
        return NSAttributedString(string: "No date", attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.placeholder)])
    }

    func dueLabelWidth(_ p: SpaceParagraph) -> CGFloat {
        dueLabel(p).size().width.rounded(.up) + (p.due != nil ? 19 : 0)
    }

    func drawDue(_ p: SpaceParagraph, rightEdge: CGFloat, midY: CGFloat) {
        let label = dueLabel(p)
        let size = label.size()
        label.draw(at: CGPoint(x: rightEdge - size.width, y: midY - size.height / 2))
        if let (_, late) = Self.dueText(p) {
            SpacePageIcons.draw(p.due?.remind != nil ? .alarmClock : .calendar, in: CGRect(x: rightEdge - size.width - 19, y: midY - 6.5, width: 13, height: 13),
                            color: late ? Self.lateColor : Themed.color(\.iconMuted))
        }
    }

    func conflictLabel(_ p: SpaceParagraph) -> NSAttributedString {
        let f = DateFormatter(); f.dateFormat = "H:mm"
        let at = p.conflict.map { f.string(from: Date(timeIntervalSince1970: TimeInterval($0.at) / 1000)) } ?? ""
        return NSAttributedString(string: "Your edit on \(p.conflict?.device ?? "another device") at \(at)",
                                  attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.secondaryLabel)])
    }

    /// Hint text for empty paragraphs: block names, and "Type / for commands" where the caret is.
    func placeholder(for key: SpaceParagraphKey, _ p: SpaceParagraph, empty: Bool) -> String? {
        guard empty else { return nil }
        let active = key == activeKey && textView.window?.firstResponder === textView
        if key.isItem { return p.todo ? (active ? "To-do" : nil) : "Untitled" }
        switch p.type {
        case .h1: return "Heading 1"
        case .h2: return "Heading 2"
        case .h3: return "Heading 3"
        case .p: return active || keys.count == 1 ? "Type / for commands" : nil
        case .bullet, .number: return active ? "List" : nil
        case .quote: return active ? "Quote" : nil
        case .image: return active ? "Add a caption" : nil
        default: return nil
        }
    }

    // MARK: Hover handle and drag

    /// The paragraph under the pointer and its first line, for the hover handle and +.
    func hoverTarget(at point: CGPoint) -> (key: SpaceParagraphKey, line: CGRect)? {
        guard let fragment = fragment(at: point), let key = fragment.paragraphKey else { return nil }
        let origin = textView.textContainerOrigin
        var line = fragment.lineBox.offsetBy(dx: origin.x, dy: origin.y)
        if isTodoRow(key), let row = fragment.targets().row { line = CGRect(x: line.minX, y: row.minY + origin.y + row.height / 2 - 12, width: line.width, height: 24) }
        if paragraphs[key]?.type == .image, let image = fragment.targets().image { line = CGRect(x: line.minX, y: image.minY + origin.y, width: line.width, height: 24) }
        return (key, line)
    }

    /// The + beside a block: a new empty paragraph after it, with the / menu open.
    func plus(after key: SpaceParagraphKey) {
        textView.window?.makeFirstResponder(textView)
        if let r = range(of: key), r.length == 0, case .block = key, paragraphs[key]?.type == .p {
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
        } else {
            insertParagraph(after: key, SpaceParagraph())
        }
        textView.insertText("/", replacementRange: textView.selectedRange())
    }

    /// Moves a paragraph's record to just before `target`, or to the end for nil.
    func move(_ key: SpaceParagraphKey, before target: SpaceParagraphKey?) {
        guard exists(key), target != key else { return }
        flushTyping()
        var rest = keys.filter { $0 != key && exists($0) }
        let at = target.flatMap { t in rest.firstIndex(of: t) } ?? rest.count
        rest.insert(key, at: at)
        func order(_ k: SpaceParagraphKey) -> OrderKey? {
            switch k {
            case .block(let id): store.block(id)?.order
            case .item(let id): store.pages[id]?.order
            }
        }
        let lower = at > 0 ? order(rest[at - 1]) : nil
        let upper = at + 1 < rest.count ? order(rest[at + 1]) : nil
        let new: OrderKey
        if let lower, let upper, !(lower < upper) { new = (try? OrderKey.between(lower, nil)) ?? lower }
        else { new = (try? OrderKey.between(lower, upper)) ?? (try! OrderKey.between(lower, nil)) }
        commitDiscrete([RecordChange(kind: key.isItem ? .page : .block, id: key.id, set: ["order": .string(new.rawValue)])], name: "Move")
        load(keepSelection: true)
    }
}

/// Holds an undo entry so a typing run can keep merging into the group it registered.
final class UndoBox {
    var entry: UndoEntry
    init(_ entry: UndoEntry) { self.entry = entry }
}

extension SpacePageEditor: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                              in textElement: NSTextElement) -> NSTextLayoutFragment {
        // TextKit lays out on the main thread for an NSTextView.
        nonisolated(unsafe) let fragment = SpaceBlockFragment(textElement: textElement, range: textElement.elementRange)
        MainActor.assumeIsolated { fragment.editor = self }
        return fragment
    }
}
