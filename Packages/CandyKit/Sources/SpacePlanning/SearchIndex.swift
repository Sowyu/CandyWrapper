import Foundation
import SpaceModel

public struct SearchPageHit: Equatable, Sendable {
    public let pageID: PageID
    public let title: String
    /// Root first, excluding the page itself.
    public let breadcrumb: [String]
}

public struct SearchSnippet: Equatable, Sendable {
    public let text: String
    /// UTF-16 ranges in text, suitable for bold attributes in a native text view.
    public let highlights: [NSRange]
}

public struct SearchContentHit: Equatable, Sendable {
    public let page: SearchPageHit
    public let blockID: BlockID
    public let snippet: SearchSnippet
}

public struct SearchResults: Equatable, Sendable {
    public let titles: [SearchPageHit]
    public let content: [SearchContentHit]
    /// All title matches and their ancestors, including matches beyond any content limit.
    /// Empty for a blank query; the caller should show the unfiltered tree then.
    public let treePageIDs: Set<PageID>
}

/// Derived plaintext lives in memory only. Build and query on the caller's worker actor.
/// This value has no persistence, timers, file access or automatic background work.
public struct SearchIndex: Sendable {
    private struct Block: Sendable {
        var page: PageID
        var order: OrderKey
        var text: String
        var folded: String
    }

    private var hierarchy: PageHierarchy
    private var titles: [PageID: String]
    private var blocks: [BlockID: Block]

    public init(pages: [PageID: PageRecord] = [:], blocks: [BlockID: BlockRecord] = [:]) {
        hierarchy = PageHierarchy(pages)
        titles = pages.mapValues { SearchText.normalized($0.title) }
        self.blocks = [:]
        for (id, block) in blocks { updateBlock(id, record: block) }
    }

    /// Replace only changed records. Pass nil for permanent removal, or the full trashed
    /// record for a soft delete. Parent moves and renames need no block reindexing.
    public mutating func updatePage(_ id: PageID, record: PageRecord?) {
        hierarchy.nodes[id] = record.map { .init(parent: $0.parent, title: $0.title, trashed: $0.trashed) }
        titles[id] = record.map { SearchText.normalized($0.title) }
    }

    public mutating func updateBlock(_ id: BlockID, record: BlockRecord?) {
        guard let record, !record.trashed else { blocks[id] = nil; return }
        blocks[id] = Block(page: record.page, order: record.order, text: record.text.t,
                           folded: SearchText.normalized(record.text.t))
    }

    /// Release all indexed plaintext when Space closes or is disabled.
    public mutating func removeAll() {
        hierarchy.nodes.removeAll()
        titles.removeAll()
        blocks.removeAll()
    }

    public func search(_ query: String, submitted: Bool = false, contentLimit: Int = 50) -> SearchResults {
        let words = SearchText.words(query)
        guard !words.isEmpty else { return SearchResults(titles: [], content: [], treePageIDs: []) }
        let phrase = " " + words.joined(separator: " ")
        var paths: [PageID: [PageID]] = [:]
        var matching: [PageID] = []
        var tree: Set<PageID> = []
        for (id, text) in titles where SearchText.matches(text, words: words) {
            guard let path = hierarchy.path(to: id) else { continue }
            matching.append(id)
            paths[id] = path
            tree.formUnion(path)
        }
        func rank(_ id: PageID) -> Int {
            let text = titles[id]!
            return text == phrase ? 0 : (text.hasPrefix(phrase) ? 1 : 2)
        }
        func titleLess(_ lhs: PageID, _ rhs: PageID) -> Bool {
            let a = titles[lhs]!, b = titles[rhs]!
            return a == b ? lhs < rhs : a.utf8.lexicographicallyPrecedes(b.utf8)
        }
        matching.sort { rank($0) == rank($1) ? titleLess($0, $1) : rank($0) < rank($1) }
        func hit(_ id: PageID, path: [PageID]) -> SearchPageHit {
            SearchPageHit(pageID: id, title: hierarchy.nodes[id]!.title,
                          breadcrumb: path.dropLast().map { hierarchy.nodes[$0]!.title })
        }
        let titleHits = matching.map { hit($0, path: paths[$0]!) }
        guard contentLimit > 0, submitted || query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return SearchResults(titles: titleHits, content: [], treePageIDs: tree)
        }

        // ponytail: scan folded records; add a trigram index if Release search p95 exceeds 30 ms.
        // A page appears once: title hits lead, otherwise its first matching block supplies the snippet.
        let titleIDs = Set(matching)
        var best: [PageID: BlockID] = [:]
        var hidden: Set<PageID> = []
        for (id, block) in blocks {
            guard !titleIDs.contains(block.page), !hidden.contains(block.page),
                  SearchText.matches(block.folded, words: words) else { continue }
            if paths[block.page] == nil {
                guard let path = hierarchy.path(to: block.page) else { hidden.insert(block.page); continue }
                paths[block.page] = path
            }
            if let priorID = best[block.page], let prior = blocks[priorID],
               prior.order < block.order || (prior.order == block.order && priorID < id) { continue }
            best[block.page] = id
        }
        let content = best.keys.sorted(by: titleLess).prefix(contentLimit).map { pageID in
            let blockID = best[pageID]!
            return SearchContentHit(page: hit(pageID, path: paths[pageID]!), blockID: blockID,
                                    snippet: SearchText.snippet(blocks[blockID]!.text, words: words))
        }
        return SearchResults(titles: titleHits, content: content, treePageIDs: tree)
    }
}

private enum SearchText {
    static let locale = Locale(identifier: "en_US_POSIX")

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    static func words(_ text: String) -> [String] {
        fold(text).unicodeScalars.split(whereSeparator: { !isWord($0) }).map(String.init)
    }

    /// A space before every word makes literal substring searches enforce word prefixes.
    static func normalized(_ text: String) -> String {
        let words = words(text)
        return words.isEmpty ? "" : " " + words.joined(separator: " ")
    }

    static func matches(_ text: String, words: [String]) -> Bool {
        words.allSatisfy { text.range(of: " " + $0, options: .literal) != nil }
    }

    static func highlights(_ text: String, words: [String]) -> [Range<String.Index>] {
        let scalars = text.unicodeScalars
        let tokens = scalars.split(whereSeparator: { !isWord($0) })
        return tokens.compactMap { token in
            let start = token.startIndex, end = token.endIndex
            let folded = fold(String(text[start..<end]))
            guard let longest = words.filter({ folded.hasPrefix($0) }).max(by: { $0.utf8.count < $1.utf8.count }) else { return nil }
            // Walk whole graphemes so decomposed accents and case-fold expansions stay intact.
            var prefixEnd = start
            while prefixEnd < end {
                prefixEnd = text.index(after: prefixEnd)
                if fold(String(text[start..<prefixEnd])).hasPrefix(longest) { break }
            }
            return start..<prefixEnd
        }
    }

    static func snippet(_ text: String, words: [String]) -> SearchSnippet {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ranges = highlights(line, words: words)
        let first = ranges.first?.lowerBound ?? line.startIndex
        let start = line.index(first, offsetBy: -40, limitedBy: line.startIndex) ?? line.startIndex
        let budgetEnd = line.index(start, offsetBy: 180, limitedBy: line.endIndex) ?? line.endIndex
        let end = max(budgetEnd, ranges.first?.upperBound ?? budgetEnd)
        let prefix = start == line.startIndex ? "" : "…"
        let snippet = prefix + line[start..<end] + (end == line.endIndex ? "" : "…")
        return SearchSnippet(text: snippet, highlights: highlights(snippet, words: words).map { NSRange($0, in: snippet) })
    }
}
