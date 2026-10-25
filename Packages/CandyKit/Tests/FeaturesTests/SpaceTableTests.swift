import AppKit
import DesignSystem
import Foundation
import SpaceEngine
import SpaceFields
import SpaceModel
import Testing
@testable import Features

/// Table view (docs/space.md "Table" and "View settings"): rows, cells, fields, sort, filter and undo, all through
/// the replica's apply path.
@MainActor
struct SpaceTableTests {
    let melbourne = TimeZone(identifier: "Australia/Melbourne")!

    /// A page with Course (select), Weight (number), Notes (text) and three items.
    func make() throws -> (SpaceTableModel, SpaceReplicaStore, PageID) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Assignments", now: 1)
        var record = store.pages[page]!
        let k = { (s: String) in try OrderKey(s) }
        record.fields = [
            "course": FieldDefinition(name: "Course", type: .select, order: try k("a1"), options: [
                "comp": FieldOption(name: "COMP2310", color: .blue, order: try k("a1")),
                "math": FieldOption(name: "MATH2221", color: .purple, order: try k("a2")),
            ]),
            "weight": FieldDefinition(name: "Weight", type: .number, order: try k("a2")),
            "notes": FieldDefinition(name: "Notes", type: .text, order: try k("a3")),
        ]
        record.view = .table
        var changes = [try RecordChange.page(page, record)]
        for (i, (title, course, weight)) in [("Lab 4", "comp", 10), ("Problem set 7", "math", 5), ("Final exam", "math", 50)].enumerated() {
            changes.append(try RecordChange.page(PageID(), PageRecord(parent: page, order: try k("b\(i)"), title: title,
                props: ["course": .string(course), "weight": .number(Decimal(weight))], created: 2)))
        }
        store.edit(changes)
        let model = SpaceTableModel(store: store, page: page)
        model.now = { Date(timeIntervalSince1970: 1_793_000_000) }
        model.timeZone = { melbourne }
        model.reload()
        return (model, store, page)
    }

    func titles(_ model: SpaceTableModel) -> [String] { model.rows.map(\.page.title) }
    func column(_ model: SpaceTableModel, _ id: String) -> SpaceTableModel.Column { model.columns.first { $0.id == id }! }

    @Test func columnsAreTitleThenFieldsInOrder() throws {
        let (model, _, _) = try make()
        #expect(model.columns.map(\.id) == ["title", "course", "weight", "notes"])
        #expect(titles(model) == ["Lab 4", "Problem set 7", "Final exam"])
        #expect(model.cell(0, column(model, "course")) == .options([model.fields["course"]!.options!["comp"]!]))
        #expect(model.cell(2, column(model, "weight")) == .number("50"))
        #expect(model.cell(0, column(model, "notes")) == .empty)
    }

    @Test func addRowGoesLastAndUndoes() throws {
        let (model, store, page) = try make()
        let id = try #require(model.addRow(title: "Quiz 3"))
        #expect(titles(model).last == "Quiz 3")
        #expect(store.pages[id]?.parent == page)
        #expect(store.pages[id]?.props[FieldID.done] == nil, "not a to-do list")
        model.undo.undo()
        #expect(titles(model) == ["Lab 4", "Problem set 7", "Final exam"])
        model.undo.redo()
        #expect(titles(model).last == "Quiz 3")
    }

    @Test func toDoListRowsStartUnticked() throws {
        let (model, store, page) = try make()
        var record = store.pages[page]!
        record.fields[FieldID.done] = .done(order: try OrderKey("a0"))
        store.put([page: record])
        model.reload()
        let id = try #require(model.addRow())
        #expect(store.pages[id]?.props[FieldID.done] == .checkbox(false))
        let done = column(model, FieldID.done)
        let row = model.rows.firstIndex { $0.id == id }!
        model.toggle(row, done)
        #expect(store.pages[id]?.props[FieldID.done] == .checkbox(true))
    }

    @Test func editingCellsWritesPropsAndUndoes() throws {
        let (model, store, _) = try make()
        let id = model.rows[0].id
        #expect(model.setText(0, column(model, "title"), "Lab 4: cache simulator"))
        #expect(model.setText(0, column(model, "notes"), "Needs week 9 code"))
        #expect(model.setText(0, column(model, "weight"), "12.5"))
        #expect(!model.setText(0, column(model, "weight"), "ten"), "text that isn't a number changes nothing")
        let page = store.pages[id]!
        #expect(page.title == "Lab 4: cache simulator")
        #expect(page.props["notes"] == .string("Needs week 9 code"))
        #expect(page.props["weight"] == .number(Decimal(string: "12.5")!))
        model.undo.undo()
        #expect(store.pages[id]!.props["weight"] == .number(10))
        model.undo.undo()
        #expect(store.pages[id]!.props["notes"] == nil)
        // Clearing a cell removes the key.
        #expect(model.setText(0, column(model, "weight"), ""))
        #expect(store.pages[id]!.props["weight"] == nil)
    }

    @Test func selectAndMultiCells() throws {
        let (model, store, _) = try make()
        let course = column(model, "course")
        let id = model.rows[0].id
        model.toggleOption(0, course, "math")
        #expect(store.pages[id]!.props["course"] == .string("math"))
        model.toggleOption(model.rows.firstIndex { $0.id == id }!, course, "math")
        #expect(store.pages[id]!.props["course"] == nil, "picking the chosen option clears it")
        let option = try #require(model.addOption("GEOG1010", to: course, pickFor: model.rows.firstIndex { $0.id == id }!))
        #expect(model.fields["course"]?.options?[option]?.name == "GEOG1010")
        #expect(store.pages[id]!.props["course"] == .string(option))
        model.undo.undo()
        #expect(model.fields["course"]?.options?[option] == nil, "the option and the pick undo together")
        #expect(store.pages[id]!.props["course"] == nil)
    }

    @Test func dateCellsShowInTheDeviceZoneAndOverdueDueIsRed() throws {
        let (model, store, page) = try make()
        var record = store.pages[page]!
        record.fields[FieldID.due] = .due(order: try OrderKey("a4"))
        store.put([page: record])
        model.reload()
        let due = column(model, FieldID.due)
        model.setValue(0, due, .date(try DateValue(start: DatePoint("2026-10-20"))))
        model.setValue(1, due, .date(try DateValue(start: DatePoint("2026-11-03T09:00"), tz: "Europe/London")))
        // now is 2026-10-26 in Melbourne.
        #expect(model.cell(0, due) == .date("Tue 20 Oct", overdue: true))
        #expect(model.cell(1, due) == .date("Tue 3 Nov 20:00", overdue: false))
    }

    @Test func addFieldWritesColumnsAndRenames() throws {
        let (model, store, page) = try make()
        let id = try #require(model.addField(.url))
        #expect(model.columns.map(\.id) == ["title", "course", "weight", "notes", id])
        #expect(model.fields[id]?.name == "Link")
        #expect(store.pages[page]!.views.table?.cols.map(\.field) == ["course", "weight", "notes", id])
        model.renameField(id, "Submission")
        #expect(column(model, id).name == "Submission")
        model.setText(0, column(model, id), "https://wattle.anu.edu.au/lab4")
        #expect(model.cell(0, column(model, id)) == .link("wattle.anu.edu.au/lab4"))
        #expect(model.addField(.text) != nil && model.fields.values.contains { $0.name == "Text" })
        #expect(model.defaultName(.text) == "Text 2")
    }

    @Test func hideShowResizeAndDelete() throws {
        let (model, store, page) = try make()
        model.setHidden("notes", true)
        #expect(model.columns.map(\.id) == ["title", "course", "weight"])
        model.resize("weight", to: 140)
        #expect(column(model, "weight").width == 140)
        model.resize("title", to: 30)
        #expect(column(model, "title").width == SpaceTableModel.minWidth)
        model.setHidden("notes", false)
        #expect(model.columns.last?.id == "notes")
        model.sort(by: "weight", desc: true)
        model.addFilter(Filter(field: "weight", op: .gt, value: .number(1)))
        model.deleteField("weight")
        #expect(model.fields["weight"] == nil)
        #expect(model.sorts.isEmpty && model.filters.isEmpty)
        #expect(!model.columns.contains { $0.id == "weight" })
        model.undo.undo()
        #expect(model.fields["weight"] != nil && column(model, "weight").width == 140)
        #expect(store.pages[page]!.views.table?.sort == [Sort(field: "weight", desc: true)])
    }

    @Test func sortAndFilter() throws {
        let (model, _, _) = try make()
        model.sort(by: "weight", desc: true)
        #expect(titles(model) == ["Final exam", "Lab 4", "Problem set 7"])
        #expect(!model.canReorder)
        model.addSort("title", desc: false)
        model.sort(by: "course", desc: false)
        #expect(model.sorts == [Sort(field: "course")])
        #expect(titles(model) == ["Lab 4", "Problem set 7", "Final exam"])
        model.clearSort()
        model.addFilter(Filter(field: "course", op: .is, value: .string("math")))
        #expect(titles(model) == ["Problem set 7", "Final exam"])
        #expect(model.describe(model.filters[0]) == "Course is MATH2221")
        model.addFilter(Filter(field: "weight", op: .ge, value: .number(10)))
        #expect(titles(model) == ["Final exam"])
        #expect(model.describe(model.filters[1]) == "Weight ≥ 10")
        model.removeFilter(0)
        #expect(titles(model) == ["Lab 4", "Final exam"])
        model.undo.undo()
        #expect(titles(model) == ["Final exam"])
    }

    @Test func threeSortsAtMost() throws {
        let (model, _, _) = try make()
        for id in ["title", "course", "weight", "notes"] { model.addSort(id, desc: false) }
        #expect(model.sorts.map(\.field) == ["title", "course", "weight"])
    }

    @Test func changingTypeConvertsAndCountsLosses() throws {
        let (model, store, _) = try make()
        model.setText(0, column(model, "notes"), "Group A")
        model.setText(1, column(model, "notes"), "group a")
        model.setText(2, column(model, "notes"), "Group B")
        let toSelect = try #require(model.previewType("notes", to: .select))
        #expect(toSelect.lost == 0, "text becomes options by name")
        model.applyType(toSelect)
        let names = Set(model.fields["notes"]!.options!.values.map(\.name))
        #expect(names == ["Group A", "Group B"])
        #expect(model.cell(1, column(model, "notes")) == model.cell(0, column(model, "notes")))
        model.undo.undo()
        #expect(model.fields["notes"]?.type == .text)
        #expect(store.pages[model.rows[1].id]!.props["notes"] == .string("group a"))

        let toCheckbox = try #require(model.previewType("weight", to: .checkbox))
        #expect(toCheckbox.lost == 3, "10, 5 and 50 aren't 0 or 1")
        #expect(model.previewType(FieldID.title, to: .number) == nil)
    }

    @Test func movingRowsKeepsBlocksInPlace() throws {
        let (model, store, page) = try make()
        // A block between the first two items.
        store.edit([try RecordChange.block(BlockID(), BlockRecord(page: page, order: try OrderKey("b0V"), text: RichText(t: "Notes")))])
        model.reload()
        let last = model.rows[2].id
        #expect(model.moveRow(last, before: model.rows[0].id))
        #expect(titles(model) == ["Final exam", "Lab 4", "Problem set 7"])
        #expect(model.moveRow(last, before: nil))
        #expect(titles(model) == ["Lab 4", "Problem set 7", "Final exam"])
        model.sort(by: "title", desc: false)
        #expect(!model.moveRow(last, before: model.rows[0].id), "a sort turns row drag off")
    }

    @Test func settingsSurviveANewModel() throws {
        let (model, store, page) = try make()
        model.setHidden("notes", true)
        model.sort(by: "weight", desc: false)
        let again = SpaceTableModel(store: store, page: page)
        #expect(again.columns.map(\.id) == ["title", "course", "weight"])
        #expect(again.sorts == [Sort(field: "weight")])
        #expect(again.rows.map(\.page.title) == ["Problem set 7", "Lab 4", "Final exam"])
    }

    @Test func staleSortsAndFiltersAreIgnored() throws {
        let (model, store, page) = try make()
        var record = store.pages[page]!
        record.views.table = TableViewSettings(cols: [TableColumn(field: "gone", width: 100), TableColumn(field: "weight", width: 90)],
                                               sort: [Sort(field: "gone")], filter: [Filter(field: "gone", op: .is, value: .null)])
        store.put([page: record])
        model.reload()
        #expect(model.columns.map(\.id) == ["title", "weight"])
        #expect(model.rows.count == 3)
    }

    /// The view: typing on a selected cell edits it, Return commits, and checkbox cells tick in one click.
    @Test func viewEditsThroughTheKeyboard() throws {
        let (_, store, page) = try make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let host = SpacePageView(store: store)
        window.contentView = host
        host.show(page)
        host.layoutSubtreeIfNeeded()
        let table = try #require(host.subviews.compactMap { $0 as? SpaceTableView }.first)
        let doc = table.doc
        table.layoutSubtreeIfNeeded()
        #expect(doc.visible.count == 3)
        doc.select(0, 3)
        func key(_ chars: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        doc.keyDown(with: key("G", 5))
        #expect(doc.editor.superview === doc)
        doc.editor.stringValue = "Got 9/10"
        _ = doc.control(doc.editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(store.pages[doc.model.rows[0].id]!.props["notes"] == .string("Got 9/10"))
        #expect(doc.editor.superview == nil)
        // The page header moved into the scrolling document at full width.
        let header = try #require(doc.subviews.compactMap { $0 as? SpacePageHeaderView }.first)
        #expect(header.frame.width > 720)
    }

    /// A page with `count` items over five fields, shown in a window in Page view.
    func bigPage(_ count: Int) throws -> (SpaceReplicaStore, PageID, SpacePageView) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Big", now: 1)
        var record = store.pages[page]!
        record.fields = [
            "course": FieldDefinition(name: "Course", type: .select, order: try OrderKey("a1"), options: [
                "a": FieldOption(name: "COMP2310", color: .blue, order: try OrderKey("a1")),
                "b": FieldOption(name: "MATH2221", color: .purple, order: try OrderKey("a2")),
            ]),
            "weight": FieldDefinition(name: "Weight", type: .number, order: try OrderKey("a2")),
            "due": .due(order: try OrderKey("a3")),
            "done": .done(order: try OrderKey("a4")),
            "notes": FieldDefinition(name: "Notes", type: .text, order: try OrderKey("a5")),
        ]
        var changes = [try RecordChange.page(page, record)]
        var order: OrderKey? = nil
        for i in 0..<count {
            order = try OrderKey.between(order, nil)
            changes.append(try RecordChange.page(PageID(), PageRecord(parent: page, order: order!, title: "Assignment \(i)",
                props: ["course": .string(i % 2 == 0 ? "a" : "b"), "weight": .number(Decimal(i % 50)), "done": .checkbox(i % 3 == 0),
                        "due": .date(try DateValue(start: DatePoint("2026-11-\(String(format: "%02d", i % 28 + 1))"))),
                        "notes": .string("Note for row \(i) with some words")], created: 2)))
        }
        store.edit(changes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let host = SpacePageView(store: store)
        window.contentView = host
        host.show(page)
        host.layoutSubtreeIfNeeded()
        return (store, page, host)
    }

    func ms(_ body: () throws -> Void) rethrows -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000
    }

    /// Switches a page to Table and draws the first screen.
    func switchToTable(_ store: SpaceReplicaStore, _ page: PageID, _ host: SpacePageView) throws -> SpaceTableView {
        var record = store.pages[page]!
        record.view = .table
        store.put([page: record])
        host.layoutSubtreeIfNeeded()
        let table = try #require(host.subviews.compactMap { $0 as? SpaceTableView }.first)
        table.layoutSubtreeIfNeeded()
        table.doc.displayIfNeeded()
        return table
    }

    /// docs/space.md section 10: switching views under 50 ms for 1,000 items, and no dropped frames scrolling 5,000
    /// rows. A scroll frame moves the row layers and draws only rows that came into view, so it's measured as
    /// tile plus displayIfNeeded, at 97 points a frame, a fast flick. The full-viewport redraw is the worst case,
    /// for a theme change. The numbers go to stdout and the temp folder; the test fails only on large regressions.
    @Test func bigTableBudgets() throws {
        // The app drains an autorelease pool per event; a test body is one pool, so give each step its own, or
        // the Page view's editor outlives the switch and keeps observing the store.
        let (smallStore, smallPage, smallHost) = try autoreleasepool { try bigPage(1000) }
        try autoreleasepool {
            _ = try switchToTable(smallStore, smallPage, smallHost)
            var small = smallStore.pages[smallPage]!
            small.view = .page
            smallStore.put([smallPage: small])
            smallHost.layoutSubtreeIfNeeded()
        }
        let switch1000 = try ms { _ = try autoreleasepool { try switchToTable(smallStore, smallPage, smallHost) } }

        let (store, page, host) = try autoreleasepool { try bigPage(5000) }
        var table: SpaceTableView!
        let switch5000 = try ms { table = try autoreleasepool { try switchToTable(store, page, host) } }
        let doc = table.doc
        #expect(doc.model.rows.count == 5000)
        let clip = table.scroll.contentView
        var frames: [Double] = []
        let rowRep = doc.visible.values.first!.bitmapImageRepForCachingDisplay(in: doc.visible.values.first!.bounds)!
        for step in 1...300 {
            frames.append(ms {
                let before = Set(doc.visible.map { ObjectIdentifier($0.value).hashValue &+ $0.key })
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 97))
                table.scroll.reflectScrolledClipView(clip)
                doc.tile()
                // Draw the rows that came into view, as Core Animation would on the next frame.
                for (i, v) in doc.visible where !before.contains(ObjectIdentifier(v).hashValue &+ i) { v.cacheDisplay(in: v.bounds, to: rowRep) }
            })
        }
        frames.sort()
        let rep = doc.bitmapImageRepForCachingDisplay(in: clip.bounds)!
        var full: [Double] = []
        for _ in 0..<20 {
            full.append(ms { for v in doc.visible.values { v.needsDisplay = true }; doc.cacheDisplay(in: clip.bounds, to: rep) })
        }
        full.sort()
        let m = doc.model
        let reload = ms { m.reload() }
        let edit = ms { m.toggle(10, m.columns.first { $0.id == "done" }!) }
        // The same kind of edit on a page outside the table runs only the other observers, like the page header's counts.
        let other = store.createPage(title: "Elsewhere", now: 3)
        let others = ms { store.rename(other, "Elsewhere 2") }
        #if DEBUG
        let build = "Debug"
        #else
        let build = "Release"
        #endif
        let line = String(format: "space-table %@: switch to Table 1,000 items %.1f ms, 5,000 items %.1f ms; scroll frame p50 %.2f ms p95 %.2f ms max %.2f ms; full viewport redraw p50 %.1f ms; reload %.1f ms; one cell edit with every observer %.1f ms, of which other observers %.1f ms; %d row views",
                          build, switch1000, switch5000, frames[frames.count / 2], frames[Int(Double(frames.count) * 0.95)], frames.last!, full[full.count / 2], reload, edit, others, doc.visible.count)
        print(line)
        try? line.write(toFile: NSTemporaryDirectory() + "space-table-budgets.txt", atomically: true, encoding: .utf8)
        #expect(doc.visible.count < 40, "only visible rows have views")
        #expect(frames[Int(Double(frames.count) * 0.95)] < 50, "\(line)")
        #expect(switch1000 < 1000, "\(line)")
    }
}
