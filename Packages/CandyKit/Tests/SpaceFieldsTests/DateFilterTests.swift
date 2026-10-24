import Foundation
import Testing
import SpaceModel
import SpaceFields

struct SpaceFieldsDateFilterTests {
    func matches(_ value: DateValue, _ op: FilterOp, _ operand: String? = nil,
                 now: String = "2026-10-27T12:00", zone: String = "Europe/London") throws -> Bool {
        try FieldFilters.matches(item(1, .date(value)), filter: Filter(field: "f", op: op, value: operand.map(JSONValue.string) ?? .null),
                                 fields: ["f": field(.date)], context: context(now, zone: zone))
    }

    @Test func timedFiltersUseDeviceDayWhileAllDayDatesStayPut() throws {
        let meeting = try date("2026-10-27T09:00", tz: "Australia/Melbourne")
        #expect(try matches(meeting, .on, "2026-10-26"))
        #expect(try !matches(meeting, .on, "2026-10-27"))
        #expect(try matches(meeting, .before, "2026-10-27"))
        #expect(try !matches(meeting, .after, "2026-10-26"))
        #expect(try matches(meeting, .on, "2026-10-27", zone: "Australia/Melbourne"))
        #expect(try matches(meeting, .after, "2026-10-26", zone: "Australia/Melbourne"))
        for zone in ["Europe/London", "Pacific/Honolulu", "Pacific/Kiritimati"] {
            #expect(try matches(date("2026-10-27"), .on, "2026-10-27", zone: zone))
            #expect(try !matches(date("2026-10-27"), .before, "2026-10-27", zone: zone))
        }
    }

    @Test func aSkippedCalendarDateStillKeepsItsDateOnlyLabel() throws {
        let skipped = try date("2011-12-30")
        #expect(try matches(skipped, .on, "2011-12-30", now: "2011-12-31T12:00", zone: "Pacific/Apia"))
        #expect(try !matches(skipped, .on, "2011-12-31", now: "2011-12-31T12:00", zone: "Pacific/Apia"))
        #expect(try matches(skipped, .before, "2011-12-31", now: "2011-12-31T12:00", zone: "Pacific/Apia"))
        #expect(try matches(skipped, .overdue, now: "2011-12-31T00:00", zone: "Pacific/Apia"))
    }

    @Test func overdueBoundariesFollowMomentOrEndOfDeviceDay() throws {
        let timed = try date("2026-10-27T09:00", tz: "Australia/Melbourne")
        #expect(try !matches(timed, .overdue, now: "2026-10-26T22:00"))
        #expect(try matches(timed, .overdue, now: "2026-10-26T22:01"))
        let day = try date("2026-10-27")
        for zone in ["Europe/London", "America/New_York", "Australia/Melbourne"] {
            #expect(try !matches(day, .overdue, now: "2026-10-27T23:59", zone: zone))
            #expect(try matches(day, .overdue, now: "2026-10-28T00:00", zone: zone))
        }
        let fallBack = try date("2026-11-01")
        #expect(try !matches(fallBack, .overdue, now: "2026-11-01T23:59", zone: "America/New_York"))
        #expect(try matches(fallBack, .overdue, now: "2026-11-02T00:00", zone: "America/New_York"))
        let springForward = try date("2026-03-08")
        #expect(try !matches(springForward, .overdue, now: "2026-03-08T23:59", zone: "America/New_York"))
        #expect(try matches(springForward, .overdue, now: "2026-03-09T00:00", zone: "America/New_York"))
    }

    @Test func weeksStartMondayAndEndBeforeNextMondayInDeviceZone() throws {
        #expect(try !matches(date("2026-10-25"), .thisWeek))
        #expect(try matches(date("2026-10-26"), .thisWeek))
        #expect(try matches(date("2026-11-01"), .thisWeek))
        #expect(try !matches(date("2026-11-02"), .thisWeek))
        let mondayMelbourne = try date("2026-10-26T09:00", tz: "Australia/Melbourne")
        #expect(try !matches(mondayMelbourne, .thisWeek)) // Sunday night in London.
        #expect(try matches(mondayMelbourne, .thisWeek, zone: "Australia/Melbourne"))
        let newYear = try date("2027-01-03")
        #expect(try matches(newYear, .thisWeek, now: "2026-12-31T12:00"))
        #expect(try !matches(date("2027-01-04"), .thisWeek, now: "2026-12-31T12:00"))
    }

    @Test func gapsOverlapsAndUnknownZonesUseModelResolutionWithoutRewriting() throws {
        let gap = try date("2026-03-08T02:30", tz: "America/New_York")
        #expect(try !matches(gap, .overdue, now: "2026-03-08T07:30", zone: "UTC"))
        #expect(try matches(gap, .overdue, now: "2026-03-08T07:31", zone: "UTC"))
        let overlap = try date("2026-11-01T01:30", tz: "America/New_York")
        #expect(try !matches(overlap, .overdue, now: "2026-11-01T05:30", zone: "UTC"))
        #expect(try matches(overlap, .overdue, now: "2026-11-01T05:31", zone: "UTC"))
        let unknown = try date("2026-10-27T09:00", tz: "Unknown/Zone")
        let bytes = try SpaceJSON.encode(unknown)
        #expect(try matches(unknown, .on, "2026-10-27", zone: "Australia/Melbourne"))
        #expect(try matches(unknown, .overdue, now: "2026-10-27T09:01", zone: "Australia/Melbourne"))
        #expect(try !matches(unknown, .overdue, now: "2026-10-27T09:00", zone: "Australia/Melbourne"))
        #expect(try SpaceJSON.encode(unknown) == bytes)
    }

    @Test func rangesAndWeeklyPropertiesFilterTheirStoredStart() throws {
        let range = try date("2026-10-25", end: "2026-10-29")
        #expect(try !matches(range, .thisWeek))
        #expect(try matches(range, .overdue))
        let weekly = try date("2026-10-20T09:00", tz: "Australia/Melbourne", repeat: .weekly)
        #expect(try !matches(weekly, .thisWeek))
        #expect(try matches(weekly, .overdue))
    }

    @Test func sortDatesByInstantRatherThanWallClockText() throws {
        let earlier = try item(1, .date(date("2026-10-27T09:00", tz: "Australia/Melbourne")))
        let later = try item(2, .date(date("2026-10-26T23:00", tz: "Europe/London")))
        let allDay = try item(3, .date(date("2026-10-27")))
        let result = try FieldQuery.evaluate([allDay, later, earlier], fields: ["f": field(.date)],
                                            sorts: [Sort(field: "f")], context: context())
        #expect(result.map(\.id) == [earlier.id, later.id, allDay.id])
    }
}
