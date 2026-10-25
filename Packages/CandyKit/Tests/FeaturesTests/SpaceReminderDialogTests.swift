import AppKit
import DesignSystem
import Foundation
import SpaceEngine
import SpaceModel
import Testing
@testable import Features

/// Remind me… in the page's date menu and the Table's date cell, with the choices of docs/space.md section 2, `remind`.
@MainActor
struct SpaceReminderDialogTests {
    let timed = try! DateValue(start: DatePoint("2026-10-27T09:00"), tz: "Australia/Melbourne")
    let day = try! DateValue(start: DatePoint("2026-10-27"))

    @Test func choicesFollowTheSpecsBeforeRule() throws {
        #expect(SpaceReminderDialog.choices(timed).map(\.label) == ["At time", "15 minutes before", "1 hour before", "1 day before", "At a set time…"])
        #expect(SpaceReminderDialog.choices(day).map(\.label) == ["On the day, at 9:00", "1 day before, at 9:00", "At a set time…"])
        let melbourne = try #require(TimeZone(identifier: "Australia/Melbourne"))
        func fires(_ value: DateValue, _ choice: Int) throws -> Date? {
            var v = value
            v.remind = SpaceReminderDialog.choices(value)[choice].remind
            return try v.reminderInstant(deviceTimeZone: melbourne)
        }
        let nine = try #require(try timed.start.resolved(in: melbourne))
        #expect(try fires(timed, 0) == nine)
        #expect(try fires(timed, 1) == nine.addingTimeInterval(-15 * 60))
        #expect(try fires(timed, 3) == nine.addingTimeInterval(-86_400))
        // A date-only value counts back from 9:00 on its day.
        #expect(try fires(day, 0) == nine)
        #expect(try fires(day, 1) == nine.addingTimeInterval(-86_400))
    }

    @Test func menuNamesTheReminderAndRemovesIt() throws {
        #expect(SpaceReminderDialog.menuItems(timed, open: {}, set: { _ in }).map(\.title) == ["Remind me…"])
        var set = timed
        set.remind = .before(15)
        var written: DateValue?
        let items = SpaceReminderDialog.menuItems(set, open: {}, set: { written = $0 })
        #expect(items.map(\.title) == ["Reminder: 15 minutes before…", "Remove reminder"])
        items[1].action?()
        #expect(written == timed)
        set.remind = .at(try DatePoint("2026-10-27T07:05"))
        #expect(SpaceReminderDialog.label(set) == "At 07:05")
    }

    @Test func dialogSavesAChoiceOrASetTime() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        defer { window.close() }
        var saved: [DateValue] = []
        func open(_ value: DateValue) throws -> (SelectView, ButtonView, DialogView) {
            let dialog = SpaceReminderDialog.present(in: window, due: value, current: { value }) { saved.append($0) }.panel
            return (try #require(dialog.panelContent.first as? SelectView), try #require(dialog.footerButtons.last as? ButtonView), dialog)
        }

        // A fixed choice shows just the select, and Save writes `before`.
        var (select, save, dialog) = try open(timed)
        #expect(dialog.panelContent.count == 1)
        select.selectedIndex = 1
        save.action?()
        #expect(saved.last?.remind == .before(15))

        // "At a set time…" shows the time field; a bad time shows the error and saves nothing.
        (select, save, dialog) = try open(day)
        select.selectedIndex = 2
        select.onChange?(2)
        let time = try #require(dialog.panelContent.last as? InputView)
        time.text = "25:00"
        save.action?()
        #expect(dialog.panelContent.count == 3 && saved.count == 1)
        time.text = "7:05"
        #expect(dialog.panelContent.count == 2, "typing hides the error")
        save.action?()
        #expect(saved.last?.remind == .at(try DatePoint("2026-10-27T07:05")))
    }

    /// The Table's date cell has the same Remind me… and Remove reminder as the page's to-do date menu.
    @Test func tableDateCellSetsAndRemovesReminders() throws {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Assignments", now: 1)
        var record = store.pages[page]!
        record.fields = ["due": .due(order: try OrderKey("a1"))]
        record.view = .table
        let item = PageID()
        store.edit([try RecordChange.page(page, record),
                    try RecordChange.page(item, PageRecord(parent: page, order: try OrderKey("b0"), title: "Lab 4", props: ["due": .date(timed)], created: 2))])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = SpacePageView(store: store)
        window.contentView = host
        host.show(page)
        host.layoutSubtreeIfNeeded()
        let doc = try #require(host.subviews.compactMap { $0 as? SpaceTableView }.first).doc
        let due = try #require(doc.model.columns.first { $0.id == "due" })
        func menu() throws -> [MenuItem] {
            doc.showDateMenu(0, due, anchor: NSRect(x: 0, y: 0, width: 100, height: 30))
            return try #require(doc.popupMenu).items
        }
        #expect(try menu().map(\.title).contains("Remind me…"))
        var set = timed
        set.remind = .before(24 * 60)
        doc.model.setValue(0, due, .date(set))
        let items = try menu()
        #expect(items.map(\.title).contains("Reminder: 1 day before…"))
        try #require(items.first { $0.title == "Remove reminder" }).action?()
        #expect(store.pages[item]?.props["due"] == .date(timed))
    }
}
