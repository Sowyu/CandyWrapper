import Foundation
import Testing
import SpaceModel
import SpacePlanning

struct ReminderPlannerTests {
    @Test func timedReminderKeepsInstantAndZoneWhenDeviceTravels() throws {
        let value = try dateValue("2026-10-27T09:00", tz: "Australia/Melbourne", reminder: .before(15))
        let london = try #require(plan(value, device: "Europe/London").first)
        let tokyo = try #require(plan(value, device: "Asia/Tokyo").first)
        #expect(london.fireDate == instant("2026-10-26T21:45:00Z"))
        #expect(tokyo.fireDate == london.fireDate)
        #expect(tokyo.components == london.components)
        #expect(london.components.timeZone?.identifier == "Australia/Melbourne")
        #expect(london.components.hour == 8 && london.components.minute == 45)
        #expect(london.itemTimeInDeviceZone.rawValue == "2026-10-26T22:00")
        #expect(tokyo.itemTimeInDeviceZone.rawValue == "2026-10-27T07:00")
        #expect(tokyo.id == london.id)
        #expect(london.id == "space.\(id(2)).due.2026-10-27T09:00")
        #expect(london.title == "Buy milk" && london.parentTitle == "Tasks")
    }

    @Test func dateOnlyStaysOnItsDateWithFloatingNineAM() throws {
        let value = try dateValue("2026-10-27")
        let london = try #require(plan(value, device: "Europe/London").first)
        let tokyo = try #require(plan(value, device: "Asia/Tokyo").first)
        #expect(london.components.timeZone == nil && london.components.calendar == nil)
        #expect(tokyo.components == london.components)
        #expect(london.components.day == 27 && london.components.hour == 9)
        #expect(london.fireDate == instant("2026-10-27T09:00:00Z"))
        #expect(tokyo.fireDate == instant("2026-10-27T00:00:00Z"))
        #expect(tokyo.itemTimeInDeviceZone.rawValue == "2026-10-27")
        #expect(tokyo.id == london.id)
    }

    @Test func leadTimeCanCrossMidnightAndWindowCountsReminderTime() throws {
        let value = try dateValue("2026-10-31", reminder: .before(24 * 60))
        let result = try #require(plan(value).first)
        #expect(result.fireDate == instant("2026-10-30T09:00:00Z"))
        #expect(result.components.day == 30 && result.components.hour == 9)
        #expect(result.start.rawValue == "2026-10-31")
    }

    @Test func explicitAtUsesStoredZoneOrFloatingDeviceZone() throws {
        let at = try DatePoint("2026-10-26T18:15")
        let timed = try dateValue("2026-10-27T09:00", tz: "Australia/Melbourne", reminder: .at(at))
        let allDay = try dateValue("2026-10-27", reminder: .at(at))
        #expect(try plan(timed, device: "Asia/Tokyo").first?.fireDate == instant("2026-10-26T07:15:00Z"))
        let floating = try #require(plan(allDay, device: "Asia/Tokyo").first)
        #expect(floating.fireDate == instant("2026-10-26T09:15:00Z"))
        #expect(floating.components.hour == 18 && floating.components.minute == 15)
        #expect(floating.components.timeZone == nil)
    }

    @Test func unknownZoneFallsBackWithoutChangingTheStoredValue() throws {
        let value = try dateValue("2026-10-27T09:00", tz: "Future/Unknown")
        let result = try #require(plan(value, device: "Asia/Tokyo").first)
        #expect(result.components.timeZone?.identifier == "Asia/Tokyo")
        #expect(result.fireDate == instant("2026-10-27T00:00:00Z"))
        #expect(value.tz == "Future/Unknown")
    }

    @Test func timedSpringGapAndAutumnOverlapUseModelRule() throws {
        let gap = try dateValue("2026-03-08T02:30", tz: "America/Los_Angeles")
        let shifted = try #require(plan(gap, now: "2026-03-01T00:00:00Z").first)
        #expect(shifted.fireDate == instant("2026-03-08T10:30:00Z"))
        #expect(shifted.components.hour == 3 && shifted.components.minute == 30)
        #expect(shifted.start.rawValue == "2026-03-08T02:30")
        let overlap = try dateValue("2026-11-01T01:30", tz: "America/Los_Angeles")
        let earlier = try #require(plan(overlap, now: "2026-10-20T00:00:00Z").first)
        #expect(earlier.fireDate == instant("2026-11-01T08:30:00Z"))
        // Replanning after the earlier occurrence must not revive the repeated 01:30.
        #expect(try plan(overlap, now: "2026-11-01T09:00:00Z").isEmpty)
    }

    @Test func halfHourGapAndDateOnlyExplicitTimeResolveCorrectly() throws {
        let value = try dateValue("2026-10-04T02:15", tz: "Australia/Lord_Howe")
        let result = try #require(plan(value).first)
        #expect(result.fireDate == instant("2026-10-03T15:45:00Z"))
        #expect(result.components.hour == 2 && result.components.minute == 45)
        let allDay = try dateValue("2026-03-08", reminder: .at(DatePoint("2026-03-08T02:30")))
        let floating = try #require(plan(allDay, now: "2026-03-01T00:00:00Z", device: "America/Los_Angeles").first)
        #expect(floating.fireDate == instant("2026-03-08T10:30:00Z"))
        #expect(floating.components.hour == 3 && floating.components.timeZone == nil)
    }

    @Test func weeklyStartsKeepWallTimeAcrossDSTWithDistinctStableIDs() throws {
        let value = try dateValue("2026-10-25T09:00", tz: "America/Los_Angeles", weekly: true, reminder: .before(15))
        let result = try plan(value, now: "2026-10-24T00:00:00Z", device: "Europe/Paris")
        #expect(result.count == 5)
        #expect(result[0].fireDate == instant("2026-10-25T15:45:00Z"))
        #expect(result[1].fireDate == instant("2026-11-01T16:45:00Z"))
        #expect(result.allSatisfy { $0.components.hour == 8 && $0.components.minute == 45 })
        #expect(Set(result.map(\.id)).count == 5)
        #expect(result[1].id.hasSuffix(".2026-11-01T09:00"))
        #expect(try plan(value, now: "2026-10-25T16:00:00Z").first?.id == result[1].id)
    }

    @Test func weeklyAtShiftsItsWallTimeWithEachOccurrence() throws {
        let value = try dateValue("2026-10-25T09:00", tz: "America/Los_Angeles", weekly: true,
                                  reminder: .at(DatePoint("2026-10-24T18:00")))
        let result = try plan(value, now: "2026-10-24T00:00:00Z")
        #expect(result[0].fireDate == instant("2026-10-25T01:00:00Z"))
        #expect(result[2].fireDate == instant("2026-11-08T02:00:00Z"))
        #expect(result[2].start.rawValue == "2026-11-08T09:00")
        #expect(result.allSatisfy { $0.components.hour == 18 })
    }

    @Test func weeklyGapDoesNotPermanentlyShiftLaterWeeks() throws {
        let value = try dateValue("2026-03-01T02:30", tz: "America/Los_Angeles", weekly: true)
        let result = try plan(value, now: "2026-03-01T00:00:00Z")
        #expect(result.prefix(3).map { $0.components.hour } == [2, 3, 2])
        #expect(result[1].id.hasSuffix(".2026-03-08T02:30"))
    }

    @Test func weeklyDateOnlyAndAncientStartsUseCalendarWeeks() throws {
        let value = try dateValue("1900-01-01", weekly: true)
        let result = try plan(value, now: "2026-10-20T00:00:00Z", device: "America/Los_Angeles")
        #expect((4...5).contains(result.count))
        #expect(result.allSatisfy { !$0.start.isTimed && $0.components.hour == 9 && $0.components.timeZone == nil })
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone("America/Los_Angeles")
        #expect(result.allSatisfy { calendar.component(.weekday, from: $0.fireDate) == 2 })
        #expect(result.allSatisfy { $0.start.year == 2026 })
    }

    @Test func doneTrashAndHiddenDescendantsAreExcludedButOtherCheckboxesAreNotDone() throws {
        let value = try dateValue("2026-10-27")
        let props: [String: PropertyValue] = ["due": .date(value), "done": .checkbox(true)]
        let pages = [id(1): page("Done", props: props), id(2): page("Trash", trashed: true, props: ["due": .date(value)]),
                     id(3): page("Child of trash", parent: 2, props: ["due": .date(value)]),
                     id(4): page("Active", props: ["due": .date(value), "other": .checkbox(true)]),
                     id(5): page("Orphan", parent: 99, props: ["due": .date(value)]),
                     id(6): page("Cycle", parent: 6, props: ["due": .date(value)])]
        let result = try ReminderPlanner.plan(pages: pages, now: instant("2026-10-01T00:00:00Z"), deviceTimeZone: zone("Etc/UTC"))
        #expect(result.map(\.pageID) == [id(4)])
    }

    @Test func allDatePropsParticipateAndReplanningReplacesRequests() throws {
        let value = try dateValue("2026-10-27")
        var pages = [id(1): page("Task", props: ["due": .date(value), "custom": .date(value)])]
        func current() throws -> [PlannedReminder] {
            try ReminderPlanner.plan(pages: pages, now: instant("2026-10-01T00:00:00Z"), deviceTimeZone: zone("Etc/UTC"))
        }
        let before = try current()
        #expect(Set(before.map(\.fieldID)) == ["due", "custom"])
        pages[id(1)]!.title = "Renamed"
        var edited = value; edited.remind = .before(15)
        pages[id(1)]!.props["due"] = .date(edited)
        let after = try current()
        #expect(Set(before.map(\.id)) == Set(after.map(\.id)))
        #expect(after.allSatisfy { $0.title == "Renamed" })
        pages[id(1)]!.props["done"] = .checkbox(true)
        #expect(try current().isEmpty)
        pages[id(1)]!.props["done"] = .checkbox(false)
        #expect(try current() == after)
        pages[id(1)]!.props.removeValue(forKey: "due")
        #expect(try current().count == 1)
    }

    @Test func soonestFiftyAreDeterministicRegardlessOfDictionaryOrder() throws {
        let pages = try Dictionary(uniqueKeysWithValues: (1...80).reversed().map { n in
            let date = try dateValue(n <= 60 ? "2026-10-02" : "2026-10-03")
            return (id(n), page("Task", props: ["due": .date(date)]))
        })
        let result = try ReminderPlanner.plan(pages: pages, now: instant("2026-10-01T00:00:00Z"), deviceTimeZone: zone("Etc/UTC"))
        #expect(result.count == 50)
        #expect(result.map(\.pageID) == (1...50).map(id))
    }

    @Test func windowUsesFutureFireTimesAndThirtyLocalDays() throws {
        let now = instant("2026-10-24T12:00:00Z") // 14:00 Paris, before the autumn clock change.
        let dates = ["2026-10-24T14:00", "2026-10-24T14:01", "2026-11-23T14:00", "2026-11-23T14:01"]
        let pages = try Dictionary(uniqueKeysWithValues: dates.enumerated().map { index, start in
            (id(index + 1), page("Task", props: ["due": .date(try dateValue(start, tz: "Europe/Paris"))]))
        })
        let result = try ReminderPlanner.plan(pages: pages, now: now, deviceTimeZone: zone("Europe/Paris"))
        #expect(result.map(\.pageID) == [id(2), id(3)])
        #expect(result.last?.fireDate == instant("2026-11-23T13:00:00Z"))
    }

    @Test func noReminderUnknownFormsAndInvalidMutableValues() throws {
        var value = try dateValue("2026-10-27")
        value.remind = nil
        #expect(try plan(value).isEmpty)
        value.remind = .unknown(.object(["future": .integer(1)]))
        #expect(try plan(value).isEmpty)
        value.remind = .before(0); value.tz = "Etc/UTC"
        #expect(throws: ModelError.invalidDateValue) { try plan(value) }
        value.tz = nil; value.remind = .at(try DatePoint("2026-10-26"))
        #expect(throws: ModelError.invalidDateValue) { try plan(value) }
    }
}
