import AppKit
import Foundation
import SpaceEngine
import SpaceModel
import Testing
@testable import Features

/// Timetable (docs/space.md "Timetable" and "Date values"): slot layout, overlaps, weekly recurrence, the time zone
/// rule across DST weeks, and edits through the store.
@MainActor
struct SpaceTimetableTests {
    let melbourne = TimeZone(identifier: "Australia/Melbourne")!
    let london = TimeZone(identifier: "Europe/London")!

    func value(_ start: String, _ end: String? = nil, tz: String? = "Australia/Melbourne", weekly: Bool = false) -> DateValue {
        try! DateValue(start: DatePoint(start), end: end.map { try! DatePoint($0) }, tz: start.count > 10 ? tz : nil, repeat: weekly ? .weekly : nil)
    }

    func item(_ title: String, _ v: DateValue, order: String = "a0") -> PageRecord {
        PageRecord(parent: nil, order: try! OrderKey(order), title: title, props: ["when": .date(v)], created: 1)
    }

    func week(_ monday: String, _ zone: TimeZone) -> Date { try! DatePoint(monday).resolved(in: zone) }

    func layout(_ items: [(PageID, PageRecord)], _ monday: String, _ zone: TimeZone, days: Int = 7) -> SpaceTimetableWeek {
        SpaceTimetableLayout.layout(items.map { (id: $0.0, record: $0.1) }, field: "when", weekStart: week(monday, zone), days: days, zone: zone)
    }

    // MARK: Layout

    @Test func weekStartsOnMondayInTheDeviceZone() {
        let sunday = try! DatePoint("2026-10-25T23:30").resolved(in: london)
        #expect(SpaceTimetableLayout.weekStart(containing: sunday, zone: london) == week("2026-10-19", london))
        // The same instant is Monday morning in Melbourne, so its week starts that day.
        #expect(SpaceTimetableLayout.weekStart(containing: sunday, zone: melbourne) == week("2026-10-26", melbourne))
    }

    @Test func timedItemsSitOnTheirDayAndMinutes() {
        let id = PageID()
        let w = layout([(id, item("COMP2310", value("2026-10-27T10:00", "2026-10-27T12:00")))], "2026-10-26", melbourne)
        #expect(w.slots.count == 1)
        #expect(w.slots[0].day == 1)
        #expect(w.slots[0].startMinute == 600 && w.slots[0].endMinute == 720)
        #expect(w.slots[0].columns == 1)
    }

    @Test func noEndShowsOneHour() {
        let w = layout([(PageID(), item("Call", value("2026-10-28T15:30")))], "2026-10-26", melbourne)
        #expect(w.slots.map(\.startMinute) == [930] && w.slots.map(\.endMinute) == [990])
    }

    @Test func itemsOutsideTheWeekOrWithoutADateAreSkipped() {
        var undated = item("Notes", value("2026-10-27T10:00"))
        undated.props = [:]
        let w = layout([(PageID(), item("Next week", value("2026-11-03T10:00"))), (PageID(), undated)], "2026-10-26", melbourne)
        #expect(w.slots.isEmpty && w.allDay.isEmpty)
    }

    @Test func fiveDayWeeksDropTheWeekend() {
        let w = layout([(PageID(), item("Sat", value("2026-10-31T10:00"))), (PageID(), item("Fri", value("2026-10-30T10:00")))], "2026-10-26", melbourne, days: 5)
        #expect(w.slots.map(\.day) == [4])
    }

    @Test func anItemPastMidnightSplitsAcrossTwoDays() {
        let w = layout([(PageID(), item("Night shift", value("2026-10-28T22:00", "2026-10-29T02:00")))], "2026-10-26", melbourne)
        let parts = w.slots.sorted { $0.day < $1.day }
        #expect(parts.map(\.day) == [2, 3])
        #expect(parts[0].startMinute == 1320 && parts[0].endMinute == 1440 && parts[0].clippedBottom)
        #expect(parts[1].startMinute == 0 && parts[1].endMinute == 120 && parts[1].clippedTop)
    }

    @Test func allDayItemsStackInTheStrip() {
        let a = PageID(), b = PageID(), c = PageID()
        let w = layout([
            (a, item("Census date", value("2026-10-30"))),
            (b, item("Trip", value("2026-10-29", "2026-10-31"))),
            (c, item("Birthday", value("2026-10-28"))),
        ], "2026-10-26", melbourne)
        #expect(w.slots.isEmpty)
        let byItem = Dictionary(uniqueKeysWithValues: w.allDay.map { ($0.item, $0) })
        #expect(byItem[b]!.firstDay == 3 && byItem[b]!.lastDay == 5)
        #expect(byItem[c]!.lane == 0 && byItem[b]!.lane == 0)
        #expect(byItem[a]!.lane == 1, "the census date shares Friday with the trip")
        #expect(w.lanes == 2)
    }

    @Test func dateOnlyItemsKeepTheirDateInEveryZone() {
        let id = PageID()
        let r = item("Due", value("2026-10-28"))
        #expect(layout([(id, r)], "2026-10-26", melbourne).allDay.map(\.firstDay) == [2])
        #expect(layout([(id, r)], "2026-10-26", london).allDay.map(\.firstDay) == [2])
    }

    // MARK: Overlaps

    @Test func overlappingItemsShareTheColumn() {
        let a = PageID(), b = PageID(), c = PageID(), d = PageID()
        let w = layout([
            (a, item("A", value("2026-10-29T09:00", "2026-10-29T11:00"))),
            (b, item("B", value("2026-10-29T10:00", "2026-10-29T12:00"))),
            (c, item("C", value("2026-10-29T11:00", "2026-10-29T12:30"))),
            (d, item("D", value("2026-10-29T14:00", "2026-10-29T15:00"))),
        ], "2026-10-26", melbourne)
        let s = Dictionary(uniqueKeysWithValues: w.slots.map { ($0.item, $0) })
        #expect(s[a]!.column == 0 && s[b]!.column == 1 && s[c]!.column == 0, "C reuses A's column once A ends")
        #expect([a, b, c].allSatisfy { s[$0]!.columns == 2 })
        #expect(s[d]!.column == 0 && s[d]!.columns == 1, "a later, separate slot gets the full width")
    }

    @Test func touchingItemsDontOverlap() {
        let w = layout([
            (PageID(), item("A", value("2026-10-29T09:00", "2026-10-29T10:00"))),
            (PageID(), item("B", value("2026-10-29T10:00", "2026-10-29T11:00"))),
        ], "2026-10-26", melbourne)
        #expect(w.slots.allSatisfy { $0.columns == 1 && $0.column == 0 })
    }

    @Test func threeAtOnceGetThreeColumns() {
        let ids = (0..<3).map { _ in PageID() }
        let w = layout(ids.map { ($0, item("X", value("2026-10-29T09:00", "2026-10-29T10:00"))) }, "2026-10-26", melbourne)
        #expect(Set(w.slots.map(\.column)) == [0, 1, 2])
        #expect(w.slots.allSatisfy { $0.columns == 3 })
    }

    // MARK: Recurrence

    @Test func weeklyItemsShowEveryWeekFromTheirStart() {
        let id = PageID()
        let r = item("Lecture", value("2026-10-06T09:00", "2026-10-06T10:30", weekly: true))
        let before = layout([(id, r)], "2026-09-28", melbourne)
        #expect(before.slots.isEmpty, "nothing before the first occurrence")
        let first = layout([(id, r)], "2026-10-05", melbourne)
        #expect(first.slots.map(\.occurrence) == [0])
        let later = layout([(id, r)], "2026-10-26", melbourne)
        #expect(later.slots.map(\.occurrence) == [3])
        #expect(later.slots.map(\.day) == [1] && later.slots.map(\.startMinute) == [540] && later.slots.map(\.endMinute) == [630])
        let year = layout([(id, r)], "2027-10-04", melbourne)
        #expect(year.slots.map(\.day) == [1] && year.slots.map(\.startMinute) == [540])
    }

    @Test func oneOffItemsShowOnlyInTheirWeek() {
        let r = item("Exam", value("2026-10-06T09:00", "2026-10-06T11:00"))
        #expect(layout([(PageID(), r)], "2026-10-05", melbourne).slots.count == 1)
        #expect(layout([(PageID(), r)], "2026-10-12", melbourne).slots.isEmpty)
    }

    @Test func weeklyAllDayItemsRepeatOnTheirWeekday() {
        let r = item("Bins", value("2026-10-01", weekly: true))
        #expect(layout([(PageID(), r)], "2026-10-26", london).allDay.map(\.firstDay) == [3])
        #expect(layout([(PageID(), r)], "2026-10-26", melbourne).allDay.map(\.firstDay) == [3])
    }

    // MARK: Time zone rule

    /// A Tuesday 9:00 Melbourne class seen from London: Melbourne's DST starts on 4 October and London's ends on
    /// 25 October 2026, so the same slot sits at three different London times in three weeks.
    @Test func weeklySlotsStayOnTheirOwnZoneAcrossDST() {
        let id = PageID()
        let r = item("MATH2221", value("2026-09-29T09:00", "2026-09-29T10:30", weekly: true))
        for monday in ["2026-09-28", "2026-10-05", "2026-10-26"] {
            let home = layout([(id, r)], monday, melbourne)
            #expect(home.slots.map(\.day) == [1] && home.slots.map(\.startMinute) == [540], "9:00 every week in Melbourne, \(monday)")
        }
        // 9:00 AEST is 0:00 BST on Tuesday.
        let w1 = layout([(id, r)], "2026-09-28", london)
        #expect(w1.slots.map(\.day) == [1] && w1.slots.map(\.startMinute) == [0])
        // 9:00 AEDT is 23:00 BST on Monday: the slot moves to the day before.
        let w2 = layout([(id, r)], "2026-10-05", london)
        let parts = w2.slots.sorted { $0.day < $1.day }
        #expect(parts.map(\.day) == [0, 1], "it runs past midnight into Tuesday")
        #expect(parts[0].startMinute == 1380 && parts[0].clippedBottom)
        #expect(parts[1].startMinute == 0 && parts[1].endMinute == 30 && parts[1].clippedTop)
        // 9:00 AEDT is 22:00 GMT once London's clocks go back.
        let w3 = layout([(id, r)], "2026-10-26", london)
        #expect(w3.slots.filter { $0.day == 0 }.map(\.startMinute) == [1320])
        #expect(w3.slots.filter { $0.day == 0 }.map(\.endMinute) == [1410])
    }

    @Test func weeklySlotsKeepTheirLengthAcrossDST() {
        let r = item("Seminar", value("2026-09-29T09:00", "2026-09-29T10:30", weekly: true))
        for monday in ["2026-09-28", "2026-10-05"] {
            for slot in layout([(PageID(), r)], monday, melbourne).slots {
                #expect(slot.end.timeIntervalSince(slot.start) == 90 * 60)
            }
        }
    }

    @Test func localSlotsKeepTheirWallClockRowOnTheDSTDay() {
        let r = item("Run", value("2026-10-19T07:00", "2026-10-19T08:00", tz: "Europe/London", weekly: true))
        // London falls back on Sunday 25 October; Monday 7:00 stays on the 7:00 row either side.
        for monday in ["2026-10-19", "2026-10-26"] {
            #expect(layout([(PageID(), r)], monday, london).slots.map(\.startMinute) == [420])
        }
        // A slot on the 25-hour day itself still sits on its wall-clock row.
        let sunday = item("Lie-in", value("2026-10-25T09:00", "2026-10-25T10:00", tz: "Europe/London"))
        #expect(layout([(PageID(), sunday)], "2026-10-19", london).slots.map(\.startMinute) == [540])
    }

    @Test func aTimeInTheSpringGapMovesLater() {
        // 2:30 doesn't exist in Melbourne on 4 October 2026; it shows at 3:30.
        let r = item("Gap", value("2026-10-04T02:30", "2026-10-04T03:45"))
        #expect(layout([(PageID(), r)], "2026-09-28", melbourne).slots.map(\.startMinute) == [210])
    }

    @Test func movingKeepsTheStoredZone() throws {
        let v = value("2026-10-27T09:00", "2026-10-27T10:30")
        // From London, drag the class an hour later: 23:00 GMT on Monday.
        let start = try DatePoint("2026-10-26T23:00").resolved(in: london)
        let moved = try SpaceTimetableLayout.moved(v, occurrence: 0, start: start, end: start.addingTimeInterval(90 * 60), zone: london)
        #expect(moved.tz == "Australia/Melbourne")
        #expect(moved.start.rawValue == "2026-10-27T10:00" && moved.end?.rawValue == "2026-10-27T11:30")
    }

    @Test func movingOneWeeklyOccurrenceMovesTheSeries() throws {
        let v = value("2026-10-06T09:00", "2026-10-06T10:30", weekly: true)
        // Occurrence 3 is Tuesday 27 October; move it to Wednesday 28 at 14:00 Melbourne time.
        let start = try DatePoint("2026-10-28T14:00").resolved(in: melbourne)
        let moved = try SpaceTimetableLayout.moved(v, occurrence: 3, start: start, end: start.addingTimeInterval(3600), zone: melbourne)
        #expect(moved.start.rawValue == "2026-10-07T14:00" && moved.end?.rawValue == "2026-10-07T15:00")
        #expect(moved.repeat == .weekly)
        // Across Melbourne's DST start, the first occurrence keeps the same wall-clock time.
        let early = value("2026-09-29T09:00", "2026-09-29T10:00", weekly: true)
        let s2 = try DatePoint("2026-10-13T11:00").resolved(in: melbourne)
        let m2 = try SpaceTimetableLayout.moved(early, occurrence: 2, start: s2, end: s2.addingTimeInterval(3600), zone: melbourne)
        #expect(m2.start.rawValue == "2026-09-29T11:00")
    }

    @Test func newSlotsTakeTheDeviceZone() throws {
        let start = try DatePoint("2026-10-28T10:00").resolved(in: london)
        let v = try SpaceTimetableLayout.created(start: start, end: start.addingTimeInterval(3600), zone: london)
        #expect(v.tz == "Europe/London" && v.start.rawValue == "2026-10-28T10:00" && v.end?.rawValue == "2026-10-28T11:00")
    }

    @Test func snappingRoundsToQuarterHours() {
        #expect(SpaceTimetableLayout.snap(607) == 600)
        #expect(SpaceTimetableLayout.snap(608) == 615)
        #expect(SpaceTimetableLayout.snap(-20) == 0)
        #expect(SpaceTimetableLayout.snap(1500) == 1440)
    }

    // MARK: The view and the store

    func makeView(zone: TimeZone) -> (SpaceTimetableView, SpaceReplicaStore, PageID) {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Timetable", now: 1)
        let view = SpaceTimetableView(store: store, page: page, zone: zone)
        view.now = { try! DatePoint("2026-10-28T12:00").resolved(in: zone) }
        view.goToToday()
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        view.layoutSubtreeIfNeeded()
        return (view, store, page)
    }

    @Test func thePageViewMountsTheTimetableFullSize() throws {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Uni", now: 1)
        let pageView = SpacePageView(store: store)
        pageView.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        pageView.show(page)
        var r = store.pages[page]!
        r.view = .timetable
        store.put([page: r])
        pageView.layoutSubtreeIfNeeded()
        let view = try #require(pageView.descendants.compactMap { $0 as? SpaceTimetableView }.first)
        #expect(view.frame.size == NSSize(width: 1100, height: 780))
        #expect(view.scroll.frame.height > 300, "the hours fill the space under the day header")
        #expect(pageView.header.frame.minX == SpaceTimetableView.margin && pageView.header.frame.width == 1100 - 2 * SpaceTimetableView.margin)
    }

    @Test func openingAddsAWhenField() {
        let (view, store, page) = makeView(zone: melbourne)
        view.ensureSettings()
        let record = store.pages[page]!
        #expect(record.fields["when"]?.type == .date && record.fields["when"]?.name == "When")
        #expect(record.views.timetable?.field == "when")
    }

    @Test func anExistingDateFieldIsUsed() {
        let store = SpaceReplicaStore(label: "Test Mac")
        let page = store.createPage(title: "Uni", now: 1)
        var r = store.pages[page]!
        r.fields["class"] = FieldDefinition(name: "Class time", type: .date, order: try! OrderKey("a0"))
        store.put([page: r])
        let view = SpaceTimetableView(store: store, page: page, zone: melbourne)
        view.ensureSettings()
        #expect(store.pages[page]!.fields["when"] == nil)
        #expect(store.pages[page]!.views.timetable?.field == "class")
    }

    @Test func dragToCreateMoveResizeAndUndo() throws {
        let (view, store, page) = makeView(zone: london)
        let start = try DatePoint("2026-10-28T10:00").resolved(in: london)
        let id = try #require(view.create(start: start, end: start.addingTimeInterval(3600)))
        view.rename(id, "Study group")
        #expect(store.pages[id]?.parent == page && store.pages[id]?.title == "Study group")
        guard case .date(let created)? = store.pages[id]?.props["when"] else { Issue.record("no date"); return }
        #expect(created.tz == "Europe/London" && created.start.rawValue == "2026-10-28T10:00")
        #expect(view.week.slots.map(\.day) == [2] && view.week.slots.map(\.startMinute) == [600])

        // Resize to 11:30, then move to Thursday 14:00.
        let slot = view.week.slots[0]
        view.move(slot, start: slot.start, end: slot.start.addingTimeInterval(90 * 60), name: "Resize")
        #expect(view.week.slots.map(\.endMinute) == [690])
        let thursday = try DatePoint("2026-10-29T14:00").resolved(in: london)
        view.move(view.week.slots[0], start: thursday, end: thursday.addingTimeInterval(90 * 60), name: "Move")
        #expect(view.week.slots.map(\.day) == [3] && view.week.slots.map(\.startMinute) == [840])

        view.performUndo()
        #expect(view.week.slots.map(\.day) == [2] && view.week.slots.map(\.endMinute) == [690])
        view.performUndo()
        #expect(view.week.slots.map(\.endMinute) == [660])
        view.performRedo()
        #expect(view.week.slots.map(\.endMinute) == [690])
        // Every edit went through the replica as a pending op, which is what the encrypted writer saves.
        #expect(store.replica.pending.count >= 5)
    }

    @Test func repeatWeeklyFromTheMenuAction() throws {
        let (view, store, _) = makeView(zone: melbourne)
        let start = try DatePoint("2026-10-27T09:00").resolved(in: melbourne)
        let id = try #require(view.create(start: start, end: start.addingTimeInterval(3600)))
        view.toggleWeekly(id)
        guard case .date(let v)? = store.pages[id]?.props["when"] else { Issue.record("no date"); return }
        #expect(v.repeat == .weekly)
        view.shiftWeek(5)
        #expect(view.week.slots.map(\.occurrence) == [5])
        view.trash(id)
        #expect(view.week.slots.isEmpty)
    }

    @Test func changingTheDeviceZoneMovesSlots() throws {
        let (view, store, page) = makeView(zone: melbourne)
        let id = PageID()
        store.put([id: PageRecord(parent: page, order: try OrderKey("a0"), title: "MATH2221",
                                  props: ["when": .date(value("2026-10-27T09:00", "2026-10-27T10:30"))], created: 1)])
        view.ensureSettings()
        #expect(view.week.slots.map(\.day) == [1] && view.week.slots.map(\.startMinute) == [540])
        view.zone = london
        #expect(view.week.slots.map(\.day) == [0] && view.week.slots.map(\.startMinute) == [1320])
    }

    @Test func filtersHideItems() throws {
        let (view, store, page) = makeView(zone: melbourne)
        view.ensureSettings()
        var r = store.pages[page]!
        r.fields["kind"] = FieldDefinition(name: "Kind", type: .text, order: try OrderKey("a5"))
        r.views.timetable?.filter = [Filter(field: "kind", op: .is, value: .string("class"))]
        store.put([page: r])
        let a = PageID(), b = PageID()
        var ra = PageRecord(parent: page, order: try OrderKey("a0"), title: "Lecture", props: ["when": .date(value("2026-10-27T09:00"))], created: 1)
        ra.props["kind"] = .string("class")
        let rb = PageRecord(parent: page, order: try OrderKey("a1"), title: "Gym", props: ["when": .date(value("2026-10-27T17:00"))], created: 1)
        store.put([a: ra, b: rb])
        #expect(view.week.slots.map(\.item) == [a])
    }

    @Test func slotColorsComeFromTheFirstSelectValue() throws {
        let (view, store, page) = makeView(zone: melbourne)
        var r = store.pages[page]!
        r.fields["course"] = FieldDefinition(name: "Course", type: .select, order: try OrderKey("a1"),
                                             options: ["m": FieldOption(name: "MATH", color: .purple, order: try OrderKey("a0"))])
        r.fields["room"] = FieldDefinition(name: "Room", type: .text, order: try OrderKey("a2"))
        store.put([page: r])
        let record = PageRecord(parent: page, order: try OrderKey("a0"), title: "x", props: ["course": .string("m"), "room": .string("Hanna Neumann 1.28")], created: 1)
        #expect(view.color(of: record) == .purple)
        #expect(view.subtitle(of: record) == "Hanna Neumann 1.28")
        #expect(view.color(of: PageRecord(order: try OrderKey("a0"), created: 1)) == .gray)
    }
}

private extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}
