import Foundation
import Testing
import SpaceModel
import SpacePlanning

struct SearchIndexTests {
    @Test func exactThenLeadingThenOtherTitleWords() {
        let index = SearchIndex(pages: [id(1): page("Milk"), id(2): page("Milk shopping"),
                                        id(3): page("Buy milk"), id(4): page("Mílk"), id(5): page("Silk")])
        #expect(index.search("milk").titles.map(\.pageID) == [1, 4, 2, 3].map(id))
        #expect(index.search("SHOP mil").titles.map(\.pageID) == [id(2)])
        #expect(index.search("ilk").titles.isEmpty)
        #expect(index.search("mlik").titles.isEmpty)
    }

    @Test func allWordsMustMatchTheSameRecord() {
        let index = SearchIndex(pages: [id(1): page("Shopping"), id(2): page("Recipes")],
                                blocks: [id(11): block("Buy milk tomorrow"), id(12): block("bread"),
                                         id(13): block("Milkshake and bread", page: 2)])
        #expect(index.search("MIL bre").content.map(\.page.pageID) == [id(2)])
        #expect(index.search("tom buy").content.map(\.page.pageID) == [id(1)])
        #expect(index.search("shopping milk").content.isEmpty)
        #expect(index.search("ilk", submitted: true).content.isEmpty)
    }

    @Test func contentStartsAtThreeCharactersOrReturn() {
        let index = SearchIndex(pages: [id(1): page("Notes")], blocks: [id(11): block("Go tomorrow")])
        #expect(index.search("go").content.isEmpty)
        #expect(index.search("go", submitted: true).content.count == 1)
        #expect(index.search("tom").content.count == 1)
        #expect(index.search(" go ").content.isEmpty)
        for query in ["", "  \n", "---", "🎉"] {
            #expect(index.search(query, submitted: true) == SearchIndex().search(""))
        }
        #expect(index.search("tom", contentLimit: 0).content.isEmpty)
        #expect(index.search("tom", contentLimit: -1).content.isEmpty)
    }

    @Test func prefixesFoldUnicodeAndPunctuation() {
        let index = SearchIndex(pages: [id(1): page("CAFÉ, Straße / e\u{301}cole"),
                                        id(2): page("Résumé: 東京予定")])
        #expect(index.search("cafe STRASS eco").titles.map(\.pageID) == [id(1)])
        #expect(index.search("résu 東", submitted: true).titles.map(\.pageID) == [id(2)])
        #expect(index.search("cole").titles.isEmpty)
        #expect(index.search("予定").titles.isEmpty)
    }

    @Test func treeIncludesAncestorsAndBreadcrumbUsesCurrentTitles() {
        let index = SearchIndex(pages: [id(1): page("Home"), id(2): page("Work", parent: 1),
                                        id(3): page("Meeting notes", parent: 2), id(4): page("Other")])
        let result = index.search("meet")
        #expect(result.treePageIDs == Set([1, 2, 3].map(id)))
        #expect(result.titles.first?.breadcrumb == ["Home", "Work"])
        #expect(index.search("home").treePageIDs == [id(1)])
    }

    @Test func trashMissingParentsAndCyclesHideAllTheirContent() {
        let pages = [id(1): page("Hidden", trashed: true), id(2): page("Hidden child", parent: 1),
                     id(3): page("Orphan", parent: 99), id(4): page("Cycle", parent: 5),
                     id(5): page("Cycle", parent: 4), id(6): page("Visible")]
        let blocks = Dictionary(uniqueKeysWithValues: (1...6).map { (id(10 + $0), block("needle", page: $0)) })
        let index = SearchIndex(pages: pages, blocks: blocks.merging([id(99): block("needle", page: 6, trashed: true)]) { $1 })
        #expect(index.search("needle").content.map(\.page.pageID) == [id(6)])
        for query in ["hidden", "orphan", "cycle"] { #expect(index.search(query).titles.isEmpty) }
    }

    @Test func oneResultPerPageUsesFirstBlockInManualOrder() {
        let index = SearchIndex(pages: [id(1): page("Needle"), id(2): page("Beta"), id(3): page("Alpha")],
                                blocks: [id(11): block("needle"), id(12): block("needle late", page: 2, order: "a1"),
                                         id(13): block("needle early", page: 2), id(14): block("needle tie", page: 2),
                                         id(15): block("needle alpha", page: 3)])
        let result = index.search("needle")
        #expect(result.titles.map(\.pageID) == [id(1)])
        #expect(result.content.map(\.page.pageID) == [id(3), id(2)])
        #expect(result.content.map(\.blockID) == [id(15), id(13)])
        #expect(index.search("needle", contentLimit: 1).content.map(\.page.pageID) == [id(3)])
    }

    @Test func snippetRangesAddressOriginalUnicodeAndCollapseLines() throws {
        let index = SearchIndex(pages: [id(1): page("Notes")],
                                blocks: [id(11): block("🥛 Café\n  e\u{301}cole\tStraße and milkshake")])
        let snippet = try #require(index.search("cafe ecole strass milk").content.first?.snippet)
        #expect(snippet.text == "🥛 Café e\u{301}cole Straße and milkshake")
        let ns = snippet.text as NSString
        #expect(snippet.highlights.map { ns.substring(with: $0) } == ["Café", "e\u{301}cole", "Straß", "milk"])
        #expect(snippet.highlights.first?.location == 3)
    }

    @Test func longSnippetCentersOnMatchAndKeepsValidRanges() throws {
        let text = String(repeating: "before ", count: 100) + "résumé\n" + String(repeating: "after ", count: 100)
        let index = SearchIndex(pages: [id(1): page("Notes")], blocks: [id(11): block(text)])
        let snippet = try #require(index.search("resume").content.first?.snippet)
        #expect(snippet.text.hasPrefix("…"))
        #expect(snippet.text.hasSuffix("…"))
        #expect(snippet.text.count <= 182)
        #expect(snippet.highlights.map { (snippet.text as NSString).substring(with: $0) } == ["résumé"])
    }

    @Test func recordUpdatesMatchFreshIndexesWithoutStaleHits() {
        var pages = [id(1): page("Home"), id(2): page("Notes", parent: 1), id(3): page("Other")]
        var blocks = [id(11): block("coffee", page: 2)]
        var index = SearchIndex(pages: pages, blocks: blocks)
        func check(_ current: SearchIndex) {
            let fresh = SearchIndex(pages: pages, blocks: blocks)
            for query in ["home", "notes", "other", "coffee", "milk"] {
                #expect(current.search(query) == fresh.search(query))
            }
        }
        pages[id(1)]!.title = "Other home"; index.updatePage(id(1), record: pages[id(1)]); check(index)
        blocks[id(11)]!.text.t = "milk"; index.updateBlock(id(11), record: blocks[id(11)]); check(index)
        blocks[id(11)]!.page = id(3); index.updateBlock(id(11), record: blocks[id(11)]); check(index)
        pages[id(3)]!.trashed = true; index.updatePage(id(3), record: pages[id(3)]); check(index)
        pages[id(3)]!.trashed = false; index.updatePage(id(3), record: pages[id(3)]); check(index)
        pages[id(2)]!.parent = id(3); index.updatePage(id(2), record: pages[id(2)]); check(index)
        blocks[id(11)]!.trashed = true; index.updateBlock(id(11), record: blocks[id(11)]); check(index)
        blocks[id(11)]!.trashed = false; index.updateBlock(id(11), record: blocks[id(11)]); check(index)
        blocks[id(11)] = nil; index.updateBlock(id(11), record: nil); check(index)
        pages[id(3)] = nil; index.updatePage(id(3), record: nil); check(index)
        index.removeAll()
        #expect(index.search("home").titles.isEmpty)
    }

    @Test func independentWorkerCanBuildAndQuery() async {
        let result = await Task.detached {
            SearchIndex(pages: [id(1): page("Notes")], blocks: [id(11): block("needle")]).search("needle")
        }.value
        #expect(result.content.first?.page.pageID == id(1))
    }
}
