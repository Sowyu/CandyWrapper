import AppKit
import Foundation
import SpaceFields
import SpaceModel
import Testing
@testable import Features

/// Board (docs/space.md section 4, "Board"): grouping by a field, moves between and within columns, new cards and
/// column edits, all through the replica so undo works.
@MainActor
struct SpaceBoardTests {
    let context = FieldContext(now: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(identifier: "UTC")!)

    /// A page with a Stage select of To do, Doing and Done, and `cards` as (title, option name or nil).
    func make(_ cards: [(String, String?)] = [], fields extra: [String: FieldDefinition] = [:]) -> (SpaceReplicaStore, PageID, [String: String]) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Reading list", now: 1)
        var options: [String: FieldOption] = [:], ids: [String: String] = [:]
        var last: OrderKey?
        for (i, name) in ["To do", "Doing", "Done"].enumerated() {
            let order = try! OrderKey.between(last, nil)
            let id = "opt\(i)"
            options[id] = FieldOption(name: name, color: .blue, order: order)
            ids[name] = id
            last = order
        }
        var record = store.pages[page]!
        record.fields["stage"] = FieldDefinition(name: "Stage", type: .select, order: try! OrderKey("a0"), options: options)
        record.fields.merge(extra) { $1 }
        record.view = .board
        store.put([page: record])
        for (title, option) in cards {
            let id = store.createPage(in: page, title: title, now: 2)
            if let option { var r = store.pages[id]!; r.props["stage"] = .string(ids[option]!); store.put([id: r]) }
        }
        return (store, page, ids)
    }

    func columns(_ store: SpaceReplicaStore, _ page: PageID) -> [String] {
        let items = store.content(of: page).compactMap { c -> (PageID, PageRecord)? in if case .page(let id, let r) = c { (id, r) } else { nil } }
        return SpaceBoard.columns(store.pages[page]!, items: items, context: context).map { column in
            column.title + ": " + column.cards.map { store.pages[$0]!.title }.joined(separator: ", ")
        }
    }

    func id(_ store: SpaceReplicaStore, _ title: String) -> PageID { store.pages.first { $0.value.title == title }!.key }

    func board(_ store: SpaceReplicaStore, _ page: PageID) -> SpaceBoardView {
        let board = SpaceBoardView(store: store, page: page, host: nil)
        board.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        board.layoutSubtreeIfNeeded()
        return board
    }

    func lane(_ board: SpaceBoardView, _ title: String) -> SpaceBoardColumn { board.canvas.lanes.first { $0.column.title == title }!.column }

    @Test func boardAddsStatusWhenThePageHasNoSelect() {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Plain", now: 1)
        store.createPage(in: page, title: "Card", now: 2)
        _ = board(store, page)
        let record = store.pages[page]!
        let group = record.views.board!.group
        #expect(record.fields[group]?.name == "Status")
        #expect(columns(store, page) == ["No Status: Card", "Not started: ", "In progress: ", "Done: "])
    }

    @Test func boardGroupsByTheFirstSelectInOptionOrder() {
        let (store, page, _) = make([("Dune", "Doing"), ("Emma", nil), ("Ulysses", "To do"), ("Kim", "Doing")])
        _ = board(store, page)
        #expect(store.pages[page]!.views.board?.group == "stage")
        #expect(columns(store, page) == ["No Stage: Emma", "To do: Ulysses", "Doing: Dune, Kim", "Done: "])
    }

    @Test func hiddenColumnsAndMultiAndCheckboxGroups() {
        let multi = FieldDefinition(name: "Tags", type: .multi, order: try! OrderKey("a1"), options: [
            "x": FieldOption(name: "Fiction", color: .red, order: try! OrderKey("a0")),
            "y": FieldOption(name: "Classic", color: .green, order: try! OrderKey("a1")),
        ])
        let (store, page, ids) = make([("Dune", "Doing"), ("Emma", "Done")], fields: ["tags": multi, FieldID.done: .done(order: try! OrderKey("a2"))])
        var r = store.pages[page]!
        r.views.board = BoardViewSettings(group: "stage", hidden: [ids["Done"]!])
        store.put([page: r])
        #expect(columns(store, page) == ["To do: ", "Doing: Dune"])

        var dune = store.pages[id(store, "Dune")]!
        dune.props["tags"] = .multi(["x", "y"])
        dune.props[FieldID.done] = .checkbox(true)
        store.put([id(store, "Dune"): dune])
        r.views.board = BoardViewSettings(group: "tags")
        store.put([page: r])
        #expect(columns(store, page) == ["No Tags: Emma", "Fiction: Dune", "Classic: Dune"])
        r.views.board = BoardViewSettings(group: FieldID.done)
        store.put([page: r])
        #expect(columns(store, page) == ["Not done: Emma", "Done: Dune"])
    }

    @Test func dragToAnotherColumnSetsTheFieldAndOrderAndUndoes() {
        let (store, page, ids) = make([("Dune", "To do"), ("Emma", "Doing"), ("Kim", "Doing")])
        let b = board(store, page)
        b.move(id(store, "Dune"), from: lane(b, "To do").key, to: lane(b, "Doing"), before: id(store, "Kim"))
        #expect(store.pages[id(store, "Dune")]!.props["stage"] == .string(ids["Doing"]!))
        #expect(columns(store, page) == ["To do: ", "Doing: Emma, Dune, Kim", "Done: "])
        b.undo(nil)
        #expect(columns(store, page) == ["To do: Dune", "Doing: Emma, Kim", "Done: "])
        b.redo(nil)
        #expect(columns(store, page) == ["To do: ", "Doing: Emma, Dune, Kim", "Done: "])
    }

    @Test func dragWithinAColumnReordersAroundBlocks() {
        let (store, page, _) = make([("A", "To do"), ("B", "To do"), ("C", "To do")])
        // A text block between B and C shares the order space; moving C to the top must not jump it.
        let c = store.content(of: page)
        let block = BlockRecord(page: page, order: SpaceBoard.between(c[1].order, c[2].order), type: .p, text: RichText(t: "note"))
        guard case .object(let object) = try! JSONValue(encoding: block) else { Issue.record("encoding"); return }
        store.edit([RecordChange(kind: .block, id: BlockID(), set: object)])
        let b = board(store, page)
        b.move(id(store, "C"), from: lane(b, "To do").key, to: lane(b, "To do"), before: id(store, "A"))
        #expect(columns(store, page).first == "To do: C, A, B")
        b.move(id(store, "A"), from: lane(b, "To do").key, to: lane(b, "To do"), before: nil)
        #expect(columns(store, page).first == "To do: C, B, A")
        let kinds = store.content(of: page).map { if case .page(_, let r) = $0 { r.title } else { "block" } }
        // The column's end is right after its last card.
        #expect(kinds == ["C", "B", "A", "block"])
    }

    @Test func withASortOnMovesChangeOnlyTheField() {
        let (store, page, _) = make([("Kim", "To do"), ("Dune", "Doing")])
        var r = store.pages[page]!
        r.views.board = BoardViewSettings(group: "stage", sort: [Sort(field: FieldID.title, desc: false)])
        store.put([page: r])
        let b = board(store, page)
        let before = store.pages[id(store, "Kim")]!.order
        b.move(id(store, "Kim"), from: lane(b, "To do").key, to: lane(b, "Doing"), before: nil)
        #expect(store.pages[id(store, "Kim")]!.order == before)
        #expect(columns(store, page) == ["To do: ", "Doing: Dune, Kim", "Done: "])
    }

    @Test func multiSelectMoveSwapsTheSourceOption() {
        let field = FieldDefinition(name: "Tags", type: .multi, order: try! OrderKey("a0"), options: [:])
        let value = SpaceBoard.value(moving: .multi(["a", "b"]), from: .option("a"), to: .option("c"), field)
        #expect(value == .array([.string("b"), .string("c")]))
        #expect(SpaceBoard.value(moving: .multi(["a"]), from: .option("a"), to: .empty, field) == .array([]))
        #expect(SpaceBoard.value(moving: nil, from: .empty, to: .checkbox(true), field) == .bool(true))
    }

    @Test func newCardLandsAtTheColumnsEndWithItsValue() {
        let (store, page, ids) = make([("Dune", "Doing"), ("Emma", "To do")], fields: [FieldID.done: .done(order: try! OrderKey("a2"))])
        let b = board(store, page)
        b.newCard(in: lane(b, "Doing"))
        let card = store.pages.first { $0.value.parent == page && $0.value.title.isEmpty }!
        #expect(card.value.props["stage"] == .string(ids["Doing"]!))
        #expect(card.value.props[FieldID.done] == .checkbox(false))
        #expect(columns(store, page)[1] == "Doing: Dune, ")
        b.rename(card.key, "Kim")
        #expect(columns(store, page)[1] == "Doing: Dune, Kim")
    }

    @Test func optionsAddRenameAndDeleteWithUndo() {
        let (store, page, ids) = make([("Dune", "Doing")])
        let b = board(store, page)
        b.addOption()
        #expect(columns(store, page).last == "Option 4: ")
        b.canvas.endEditing(commit: false)
        b.renameOption(ids["Doing"]!, "Reading")
        #expect(columns(store, page)[1] == "Reading: Dune")
        b.commit(SpaceBoard.deleteOption(ids["Doing"]!, page: page, record: store.pages[page]!, items: b.items()), name: "Delete")
        #expect(columns(store, page) == ["No Stage: Dune", "To do: ", "Done: ", "Option 4: "])
        b.undo(nil)
        #expect(columns(store, page)[1] == "Reading: Dune")
    }

    @Test func cardsShowFieldsAsOneMutedLine() {
        let author = FieldDefinition(name: "Author", type: .text, order: try! OrderKey("a1"))
        let (store, page, _) = make([("Dune", "Doing")], fields: ["author": author])
        _ = board(store, page)
        var dune = store.pages[id(store, "Dune")]!
        dune.props["author"] = .string("Frank Herbert")
        store.put([id(store, "Dune"): dune])
        let card = SpaceBoard.card(store.pages[id(store, "Dune")]!, schema: store.pages[page]!)
        #expect(store.pages[page]!.views.board?.show == ["author"])
        #expect(card.meta == "Frank Herbert")
    }
}

@MainActor
struct SpaceBoardMountTests {
    @Test func pageViewMountsTheBoardWithLanes() throws {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Reading list", now: 1)
        let view = SpacePageView(store: store)
        view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        view.show(page)
        var r = store.pages[page]!
        r.view = .board
        store.put([page: r])
        view.layoutSubtreeIfNeeded()
        let board = try #require(view.subviews.compactMap { $0 as? SpaceBoardView }.first)
        board.layoutSubtreeIfNeeded()
        #expect(board.canvas.lanes.map(\.column.title) == ["Not started", "In progress", "Done"])
        #expect(board.canvas.frame.width > 800)
        #expect(board.canvas.frame.height > 100)
        #expect(board.canvas.superview?.frame.height ?? 0 > 100)
    }
}
