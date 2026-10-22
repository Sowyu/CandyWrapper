import AppKit

/// The block structure T3 builds from the draft's lines, and the geometry its stylesheet gives it.
///
/// Lists: consecutive list lines group by indent into nested lists, and a change of kind or marker
/// at one indent starts a sibling list (`buildTiptapContent` pass 2, composer-rich-text-doc.ts:705-758).
/// Geometry: index.css:1775-1860 and 2280-2322 (`.composer-tiptap` lists, quote, headings, tasks).
/// Pure on purpose: the styler lays lines out with it, and the editor's Return, Backspace and Tab
/// read item parents and siblings from it.
enum ComposerBlockLayout {
    enum ListKind: Equatable { case bullet, ordered, task }

    enum Line: Equatable {
        case paragraph
        /// Fence lines and code bodies, which keep their own layout.
        case code
        case rule
        case heading(Int)
        case quote(String)
        /// `marker` is `-`, `*`, `+`, `3.` or `3)`; empty for a task.
        case list(ListKind, indent: String, marker: String)
    }

    struct List {
        var kind: ListKind
        var key: String
        /// The item (line index) this list nests in; nil at the top level.
        var parentItem: Int?
        var items: [Int] = []
    }

    struct Lists {
        var lists: [List] = []
        /// The list each list line belongs to.
        var listOf: [Int: Int] = [:]
        func parent(of item: Int) -> Int? { listOf[item].flatMap { lists[$0].parentItem } }
        /// The items after `item` in its own list.
        func followingSiblings(of item: Int) -> [Int] {
            guard let list = listOf[item] else { return [] }
            return Array(lists[list].items.drop { $0 != item }.dropFirst())
        }
        /// Lists from the outermost to the item's own.
        func chain(of item: Int) -> [Int] {
            var out: [Int] = [], current: Int? = listOf[item]
            while let list = current { out.insert(list, at: 0); current = lists[list].parentItem.flatMap { listOf[$0] } }
            return out
        }
    }

    /// `listKey`: items of one kind and marker family belong to one list.
    static func key(_ kind: ListKind, _ marker: String) -> String {
        switch kind {
        case .task: "task"
        case .ordered: "ordered:" + String(marker.suffix(1))
        case .bullet: "bullet:" + marker
        }
    }

    static func lists(_ lines: [Line]) -> Lists {
        var out = Lists()
        struct Frame { var indent: String; var list: Int; var parentItem: Int? }
        var stack: [Frame] = []
        func open(_ kind: ListKind, _ key: String, parent: Int?) -> Int {
            out.lists.append(List(kind: kind, key: key, parentItem: parent))
            return out.lists.count - 1
        }
        func add(_ line: Int, _ list: Int) { out.lists[list].items.append(line); out.listOf[line] = list }
        for (i, line) in lines.enumerated() {
            guard case .list(let kind, let indent, let marker) = line else { stack = []; continue }
            let key = key(kind, marker)
            while true {
                guard var top = stack.last else {
                    // A leading indented item with no parent flattens but keeps its indent.
                    stack.append(Frame(indent: indent, list: open(kind, key, parent: nil), parentItem: nil))
                    continue
                }
                if top.indent == indent {
                    if out.lists[top.list].key != key { top.list = open(kind, key, parent: top.parentItem); stack[stack.count - 1] = top }
                    add(i, top.list)
                    break
                }
                if !top.indent.isEmpty, !indent.hasPrefix(top.indent) {
                    if stack.count > 1 { stack.removeLast(); continue }
                    top.indent = indent
                    if out.lists[top.list].key != key { top.list = open(kind, key, parent: top.parentItem) }
                    stack[stack.count - 1] = top
                    add(i, top.list)
                    break
                }
                let parent = out.lists[top.list].items.last!
                let list = open(kind, key, parent: parent)
                stack.append(Frame(indent: indent, list: list, parentItem: parent))
                add(i, list)
                break
            }
        }
        return out
    }

    // MARK: Geometry

    /// `ul` and `ol` padding, the task list's nested padding, and a task's checkbox plus gap.
    static let listPadding: CGFloat = 20, taskNestedPadding: CGFloat = 22, taskGutter: CGFloat = 15.2 + 8
    /// `blockquote`: a 2px rail and 0.8rem of padding.
    static let quoteRail: CGFloat = 2, quoteIndent: CGFloat = 2 + 12.8
    /// `.composer-tiptap ul, ol` and `blockquote` margins (0.65rem); headings 1.25rem above, 0.5rem below.
    static let blockMargin: CGFloat = 10.4, headingTop: CGFloat = 20, headingBottom: CGFloat = 8

    enum BulletStyle: Equatable { case disc, circle, square }

    struct LineGeometry: Equatable {
        /// Where the line's marker box starts and where its text starts.
        var markerX: CGFloat = 0
        var textX: CGFloat = 0
        /// The collapsed CSS margin between this line's box and the line before it.
        var marginBefore: CGFloat = 0
        var bullet: BulletStyle = .disc
    }

    struct Layout {
        var lines: [LineGeometry]
        var lists: Lists
        /// Margin above the first line and below the last, kept inside the editor by its padding.
        var top: CGFloat
        var bottom: CGFloat
    }

    private enum Box: Hashable { case list(Int), quote(Int), heading(Int) }

    static func layout(_ lines: [Line]) -> Layout {
        let lists = lists(lines)
        var contentX: [Int: CGFloat] = [:]
        func hasTaskAncestor(_ list: Int) -> Bool {
            var item = lists.lists[list].parentItem
            while let i = item, let l = lists.listOf[i] {
                if lists.lists[l].kind == .task { return true }
                item = lists.lists[l].parentItem
            }
            return false
        }
        var geometry: [LineGeometry] = []
        var boxes: [[Box]] = []
        var quoteGroup = -1
        for (i, line) in lines.enumerated() {
            var g = LineGeometry()
            var lineBoxes: [Box] = []
            switch line {
            case .list(let kind, _, _):
                let chain = lists.chain(of: i)
                let list = lists.listOf[i]!
                let container = lists.lists[list].parentItem.flatMap { contentX[$0] } ?? 0
                let padding = kind == .task ? (hasTaskAncestor(list) ? taskNestedPadding : 0) : listPadding
                // A bullet or number sits in the padding before the text; a task's box starts it.
                g.markerX = kind == .task ? container + padding : container
                g.textX = container + padding + (kind == .task ? taskGutter : 0)
                contentX[i] = g.textX
                let uls = chain.filter { lists.lists[$0].kind != .ordered }.count
                g.bullet = uls >= 3 ? .square : uls == 2 ? .circle : .disc
                lineBoxes = chain.map { .list($0) }
            case .quote(let prefix):
                if i == 0 || lines[i - 1] != .quote(prefix) { quoteGroup = i }
                g.textX = quoteIndent
                lineBoxes = [.quote(quoteGroup)]
            case .heading:
                lineBoxes = [.heading(i)]
            // ponytail: a rule keeps its 16pt atom on a text line, not `hr`'s 1px and 0.65rem margins; give it a box when drafts with rules look off
            default: break
            }
            geometry.append(g)
            boxes.append(lineBoxes)
        }
        func top(_ box: Box) -> CGFloat {
            switch box {
            case .list(let l): lists.lists[l].kind == .task ? 0 : blockMargin
            case .quote: blockMargin
            // `:first-child` drops a heading's top margin at the start of the draft.
            case .heading(let line): line == 0 ? 0 : headingTop
            }
        }
        func bottom(_ box: Box) -> CGFloat {
            switch box {
            case .list(let l): lists.lists[l].kind == .task ? 0 : blockMargin
            case .quote: blockMargin
            case .heading: headingBottom
            }
        }
        for i in geometry.indices.dropFirst() {
            let closed = boxes[i - 1].filter { !boxes[i].contains($0) }, opened = boxes[i].filter { !boxes[i - 1].contains($0) }
            geometry[i].marginBefore = (closed.map(bottom) + opened.map(top)).max() ?? 0
        }
        // `.composer-tiptap > :first-child` and `> :last-child` drop the outer block's margins at the draft's
        // edges (index.css:2003-2010); a nested list's margin still collapses through it.
        return Layout(lines: geometry, lists: lists,
                      top: boxes.first.map { $0.dropFirst().map(top).max() ?? 0 } ?? 0,
                      bottom: boxes.last.map { $0.dropFirst().map(bottom).max() ?? 0 } ?? 0)
    }
}
