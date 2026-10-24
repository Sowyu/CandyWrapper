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
    /// Every matching title, including hits beyond the displayed title limit.
    public let titlePageIDs: Set<PageID>
    /// All title matches and their ancestors, including matches beyond any content limit.
    /// Empty for a blank query; the caller should show the unfiltered tree then.
    public let treePageIDs: Set<PageID>
}

/// Derived plaintext lives in memory only. Build and query on the caller's worker actor.
/// This value has no persistence, timers, file access or automatic background work.
public struct SearchIndex: Sendable {
    private struct Block: Sendable {
        var id: BlockID
        var pageSlot: UInt32
        var order: OrderKey
        var text: String
        var folded: FoldedText
    }

    private var hierarchy = PageHierarchy([:])
    private var titles: [FoldedText?] = []
    private var orderedPages: [UInt32] = []
    private var visible: [Bool] = []
    private var parents: [Int] = []
    private var blocks: ContiguousArray<Block?> = []
    private var blockSlots: [BlockID: UInt32] = [:]
    private var freeBlocks: [UInt32] = []
    private var pageBlocks: [UInt32: [UInt32]] = [:]
    // Page slots keep postings compact. A gram indexes pages, never every repeated block.
    private var pageSlots: [PageID: UInt32] = [:]
    private var slotPages: [PageID] = []
    private var orderRanks: [Int] = []
    private var pageGrams: [UInt32: [UInt32]] = [:]
    private var postings: [UInt32: [UInt32]] = [:]

    public init(pages: [PageID: PageRecord] = [:], blocks: [BlockID: BlockRecord] = [:]) {
        self = SearchText.temporaryPool {
            var index = SearchIndex(empty: ())
            index.build(pages: pages, blocks: blocks)
            return index
        }
    }

    private init(empty: Void) {}

    private mutating func build(pages: [PageID: PageRecord], blocks: [BlockID: BlockRecord]) {
        hierarchy = PageHierarchy(pages)
        for (id, page) in pages { titles[Int(slot(for: id))] = SearchText.normalized(page.title) }
        let activeCount = blocks.values.lazy.filter { !$0.trashed }.count
        self.blocks = ContiguousArray(repeating: nil, count: activeCount)
        blockSlots.reserveCapacity(activeCount)
        var nextBlock = 0
        for (id, record) in blocks where !record.trashed {
            let page = slot(for: record.page)
            let blockSlot = UInt32(nextBlock)
            self.blocks[nextBlock] = Block(id: id, pageSlot: page, order: record.order, text: record.text.t,
                                          folded: SearchText.normalized(record.text.t))
            nextBlock += 1
            blockSlots[id] = blockSlot
            pageBlocks[page, default: []].append(blockSlot)
        }
        for page in Array(pageBlocks.keys) { sortBlocks(on: page) }
        for page in slotPages.indices { rebuildGrams(on: UInt32(page)) }
        orderedPages = slotPages.indices.filter { titles[$0] != nil }.map(UInt32.init).sorted(by: titleLess)
        rebuildOrderRanks()
        refreshTreeCache()
    }

    /// Replace only changed records. Pass nil for permanent removal, or the full trashed
    /// record for a soft delete. Only its page's postings need rebuilding after a block edit.
    public mutating func updatePage(_ id: PageID, record: PageRecord?) {
        let old = hierarchy.nodes[id]
        let structureChanged = old == nil || record == nil || old?.parent != record?.parent || old?.trashed != record?.trashed
        hierarchy.update(id, node: record.map { .init(parent: $0.parent, title: $0.title, trashed: $0.trashed) })
        let pageSlot = slot(for: id)
        titles[Int(pageSlot)] = record.map { SearchText.normalized($0.title) }
        orderedPages.removeAll { $0 == pageSlot }
        if record != nil {
            var low = 0, high = orderedPages.count
            while low < high {
                let middle = (low + high) / 2
                if titleLess(orderedPages[middle], pageSlot) { low = middle + 1 } else { high = middle }
            }
            orderedPages.insert(pageSlot, at: low)
        }
        rebuildGrams(on: pageSlot)
        rebuildOrderRanks()
        if structureChanged { refreshTreeCache() }
    }

    public mutating func updateBlock(_ id: BlockID, record: BlockRecord?) {
        let oldSlot = blockSlots[id]
        let oldPage = oldSlot.flatMap { blocks[Int($0)]?.pageSlot }
        if let oldPage, let oldSlot { pageBlocks[oldPage]?.removeAll { $0 == oldSlot } }
        var newPage: UInt32?
        if let record, !record.trashed {
            let page = slot(for: record.page)
            let blockSlot: UInt32
            if let oldSlot { blockSlot = oldSlot }
            else if let free = freeBlocks.popLast() { blockSlot = free }
            else { blockSlot = UInt32(blocks.count); blocks.append(nil) }
            blocks[Int(blockSlot)] = Block(id: id, pageSlot: page, order: record.order, text: record.text.t,
                                           folded: SearchText.normalized(record.text.t))
            blockSlots[id] = blockSlot
            pageBlocks[page, default: []].append(blockSlot)
            sortBlocks(on: page)
            newPage = page
            rebuildGrams(on: page)
        } else if let oldSlot {
            blocks[Int(oldSlot)] = nil
            blockSlots[id] = nil
            freeBlocks.append(oldSlot)
        }
        if let oldPage {
            if oldPage != newPage { rebuildGrams(on: oldPage) }
            if pageBlocks[oldPage]?.isEmpty == true { pageBlocks[oldPage] = nil }
        }
    }

    /// Release all indexed plaintext when Space closes or is disabled.
    public mutating func removeAll() { self = SearchIndex() }

    public func search(_ query: String, submitted: Bool = false, contentLimit: Int = 50,
                       titleLimit: Int = 50) -> SearchResults {
        SearchText.temporaryPool {
            searchInPool(query, submitted: submitted, contentLimit: contentLimit, titleLimit: titleLimit)
        }
    }

    private func searchInPool(_ query: String, submitted: Bool, contentLimit: Int, titleLimit: Int) -> SearchResults {
        let words = SearchText.words(query)
        guard !words.isEmpty else { return SearchResults(titles: [], content: [], titlePageIDs: [], treePageIDs: []) }
        let needles = words.map { Array((" " + $0).utf8) }
        let phrase = Array((" " + words.joined(separator: " ")).utf8)
        let candidates = candidatePages(needles)
        var matches: [[UInt32]] = [[], [], []]
        var matchedSlots: [UInt32] = []
        var matched = Array(repeating: false, count: slotPages.count)
        for slot in candidates {
            let index = Int(slot)
            guard visible[index], let text = titles[index], text.matches(needles) else { continue }
            let rank = text.bytes == phrase ? 0 : (text.bytes.starts(with: phrase) ? 1 : 2)
            if matches[rank].count < max(0, titleLimit) { matches[rank].append(slot) }
            matched[index] = true
            matchedSlots.append(slot)
        }
        let titleIDs = Set(matchedSlots.map { slotPages[Int($0)] })
        var tree = titleIDs
        var inTree = matched
        for slot in matchedSlots {
            var parent = parents[Int(slot)]
            while parent >= 0 && !inTree[parent] {
                inTree[parent] = true
                tree.insert(slotPages[parent])
                parent = parents[parent]
            }
        }
        let titleHits = matches.joined().prefix(max(0, titleLimit)).map {
            let id = slotPages[Int($0)]
            return hit(id, path: hierarchy.path(to: id)!)
        }
        guard contentLimit > 0, matchedSlots.count != candidates.count,
              submitted || query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return SearchResults(titles: titleHits, content: [], titlePageIDs: titleIDs, treePageIDs: tree)
        }
        var content: [SearchContentHit] = []
        for page in candidates where !matched[Int(page)] && visible[Int(page)] {
            guard let ids = pageBlocks[page] else { continue }
            if let blockSlot = ids.first(where: { blocks[Int($0)]!.folded.matches(needles) }) {
                let block = blocks[Int(blockSlot)]!
                let pageID = slotPages[Int(page)]
                content.append(SearchContentHit(page: hit(pageID, path: hierarchy.path(to: pageID)!), blockID: block.id,
                                                snippet: SearchText.snippet(block.text, words: words)))
                if content.count == contentLimit { break }
            }
        }
        return SearchResults(titles: titleHits, content: content, titlePageIDs: titleIDs, treePageIDs: tree)
    }

    private func hit(_ id: PageID, path: [PageID]) -> SearchPageHit {
        SearchPageHit(pageID: id, title: hierarchy.nodes[id]!.title,
                      breadcrumb: path.dropLast().map { hierarchy.nodes[$0]!.title })
    }

    private func titleLess(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
        let a = titles[Int(lhs)]!.bytes, b = titles[Int(rhs)]!.bytes
        return a == b ? slotPages[Int(lhs)] < slotPages[Int(rhs)] : a.lexicographicallyPrecedes(b)
    }

    private mutating func slot(for page: PageID) -> UInt32 {
        if let slot = pageSlots[page] { return slot }
        let slot = UInt32(slotPages.count)
        pageSlots[page] = slot
        slotPages.append(page)
        orderRanks.append(-1)
        titles.append(nil)
        visible.append(false)
        parents.append(-1)
        return slot
    }

    private mutating func rebuildOrderRanks() {
        orderRanks = Array(repeating: -1, count: slotPages.count)
        for (rank, page) in orderedPages.enumerated() { orderRanks[Int(page)] = rank }
    }

    private mutating func refreshTreeCache() {
        for (index, page) in slotPages.enumerated() {
            visible[index] = hierarchy.visibleIDs.contains(page)
            parents[index] = hierarchy.nodes[page]?.parent.flatMap { pageSlots[$0].map(Int.init) } ?? -1
        }
    }

    private mutating func sortBlocks(on page: UInt32) {
        var ids = pageBlocks[page] ?? []
        ids.sort {
            let a = blocks[Int($0)]!, b = blocks[Int($1)]!
            return a.order == b.order ? a.id < b.id : a.order < b.order
        }
        pageBlocks[page] = ids
    }

    private mutating func rebuildGrams(on slot: UInt32) {
        var grams = Set(Self.prefixGrams(titles[Int(slot)]?.bytes ?? []))
        for id in pageBlocks[slot] ?? [] { grams.formUnion(Self.prefixGrams(blocks[Int(id)]!.folded.bytes)) }
        let old = pageGrams[slot] ?? []
        let oldSet = Set(old)
        for gram in old where !grams.contains(gram) {
            if let index = postings[gram]?.firstIndex(of: slot) { postings[gram]!.remove(at: index) }
            if postings[gram]?.isEmpty == true { postings[gram] = nil }
        }
        for gram in grams where !oldSet.contains(gram) {
            // New page slots append. Edits to an existing page insert into its sorted posting.
            if let last = postings[gram]?.last, last > slot {
                let position = postings[gram]!.firstIndex { $0 > slot }!
                postings[gram]!.insert(slot, at: position)
            } else { postings[gram, default: []].append(slot) }
        }
        pageGrams[slot] = grams.isEmpty ? nil : grams.sorted()
    }

    /// Word-boundary trigrams narrow prefix queries. Tagged one- and two-byte
    /// buckets cover shorter terms without colliding with full trigrams.
    private static func prefixGrams(_ bytes: [UInt8]) -> [UInt32] {
        var result: [UInt32] = []
        for index in bytes.indices where bytes[index] == 32 && index + 1 < bytes.count {
            result.append(0x01000000 | UInt32(bytes[index + 1]))
            if index + 2 < bytes.count && bytes[index + 2] != 32 {
                result.append(0x02000000 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
                if index + 3 < bytes.count && bytes[index + 3] != 32 {
                    result.append(0x03000000 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]))
                }
            }
        }
        return result
    }

    /// The rarest trigram narrows pages. Exact word-prefix checks still decide every hit,
    /// so terms on different blocks and trigram false positives never become results.
    private func candidatePages(_ needles: [[UInt8]]) -> [UInt32] {
        var rarest: [UInt32]?
        for needle in needles {
            let gram: UInt32
            if needle.count >= 4 { gram = 0x03000000 | UInt32(needle[1]) << 16 | UInt32(needle[2]) << 8 | UInt32(needle[3]) }
            else if needle.count == 3 { gram = 0x02000000 | UInt32(needle[1]) << 8 | UInt32(needle[2]) }
            else { gram = 0x01000000 | UInt32(needle[1]) }
            guard let pages = postings[gram] else { return [] }
            if rarest == nil || pages.count < rarest!.count { rarest = pages }
        }
        guard let rarest else { return orderedPages }
        if rarest.count == slotPages.count { return orderedPages }
        if rarest.count >= orderedPages.count / 2 {
            var included = Array(repeating: false, count: slotPages.count)
            for slot in rarest { included[Int(slot)] = true }
            return orderedPages.filter { included[Int($0)] }
        }
        return rarest.filter { orderRanks[Int($0)] >= 0 }.sorted { orderRanks[Int($0)] < orderRanks[Int($1)] }
    }
}

private struct FoldedText: Sendable {
    var bytes: [UInt8]

    func matches(_ needles: [[UInt8]]) -> Bool {
        bytes.withUnsafeBufferPointer { text in
            needles.allSatisfy { needle in
                needle.withUnsafeBufferPointer { word in
                    guard text.count >= word.count else { return false }
                    var offset = 0
                    while offset <= text.count - word.count {
                        if text[offset] == word[0] {
                            var index = 1
                            while index < word.count && text[offset + index] == word[index] { index += 1 }
                            if index == word.count { return true }
                        }
                        offset += 1
                    }
                    return false
                }
            }
        }
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

    /// Drain Foundation's temporary folded strings while retaining only compact bytes.
    static func normalized(_ text: String) -> FoldedText {
        func make() -> FoldedText {
            let words = words(text)
            return FoldedText(bytes: words.isEmpty ? [] : Array((" " + words.joined(separator: " ")).utf8))
        }
        return temporaryPool(make)
    }

    static func temporaryPool<Result>(_ action: () -> Result) -> Result {
        #if canImport(ObjectiveC)
        return autoreleasepool(invoking: action)
        #else
        return action()
        #endif
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
