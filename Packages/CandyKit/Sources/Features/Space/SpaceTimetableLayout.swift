import Foundation
import SpaceModel

/// One drawn piece of an item in the week grid: the part of one occurrence that falls on one day column.
/// Minutes count wall-clock time in the device's zone from that day's midnight, so a 23-hour or 25-hour day
/// still draws on the same 24 rows.
struct SpaceTimetableSlot: Equatable {
    var item: PageID
    /// Which weekly occurrence this is, 0 for the first.
    var occurrence: Int
    var start: Date
    var end: Date
    var day: Int
    var startMinute: Int
    var endMinute: Int
    /// The item goes on before this day or after it.
    var clippedTop = false
    var clippedBottom = false
    /// Side-by-side placement among overlapping slots on the same day.
    var column = 0
    var columns = 1
}

/// An item without a time, in the strip above the grid. `lane` is its row in the strip.
struct SpaceTimetableAllDay: Equatable {
    var item: PageID
    var firstDay: Int
    var lastDay: Int
    var lane = 0
}

struct SpaceTimetableWeek: Equatable {
    var slots: [SpaceTimetableSlot] = []
    var allDay: [SpaceTimetableAllDay] = []
    var lanes: Int { (allDay.map(\.lane).max() ?? -1) + 1 }
}

/// The Timetable's placement rules (docs/space.md "Date values" and "Timetable"). Pure, with an explicit device
/// zone, so the tests can view the same records from Melbourne and London and across DST weeks.
enum SpaceTimetableLayout {
    static let snapMinutes = 15

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.firstWeekday = 2
        return c
    }

    /// Monday 00:00 of the week holding `date`, in `zone`.
    static func weekStart(containing date: Date, zone: TimeZone) -> Date {
        let c = calendar(zone)
        let day = c.startOfDay(for: date)
        let back = (c.component(.weekday, from: day) + 5) % 7
        return c.date(byAdding: .day, value: -back, to: day)!
    }

    /// Midnight of each day of the week and the midnight after the last, in `zone`.
    static func dayStarts(_ weekStart: Date, days: Int, zone: TimeZone) -> [Date] {
        let c = calendar(zone)
        return (0...days).map { c.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    /// Wall-clock minutes since midnight of the day starting at `dayStart`.
    static func minute(of date: Date, dayStart: Date, zone: TimeZone) -> Int {
        let c = calendar(zone)
        if date >= c.date(byAdding: .day, value: 1, to: dayStart)! { return 24 * 60 }
        if date <= dayStart { return 0 }
        // Count by wall clock, not elapsed time, so 9:00 sits on the 9:00 row on a DST day too.
        let wall = c.dateComponents([.hour, .minute], from: date)
        return (wall.hour ?? 0) * 60 + (wall.minute ?? 0)
    }

    /// The instant at a wall-clock minute of a day, in `zone`. A minute inside a spring-forward gap moves later.
    static func instant(day dayStart: Date, minute: Int, zone: TimeZone) -> Date {
        let c = calendar(zone)
        if minute >= 24 * 60 { return c.date(byAdding: .day, value: 1, to: dayStart)! }
        let ymd = c.dateComponents([.year, .month, .day], from: dayStart)
        let point = try? DatePoint(String(format: "%04d-%02d-%02dT%02d:%02d", ymd.year!, ymd.month!, ymd.day!, minute / 60, minute % 60))
        return (try? point?.resolved(in: zone)) ?? dayStart.addingTimeInterval(TimeInterval(minute * 60))
    }

    static func snap(_ minute: Int) -> Int {
        let step = snapMinutes
        return min(24 * 60, max(0, ((minute + step / 2) / step) * step))
    }

    /// Places `items` in the week starting at `weekStart`. Items whose `field` holds no date are skipped.
    static func layout(_ items: [(id: PageID, record: PageRecord)], field: String, weekStart: Date, days: Int,
                       zone: TimeZone) -> SpaceTimetableWeek {
        let starts = dayStarts(weekStart, days: days, zone: zone)
        let weekEnd = starts[days]
        var week = SpaceTimetableWeek()
        for (id, record) in items {
            guard case .date(let value)? = record.props[field] else { continue }
            for (index, occ) in occurrences(value, from: weekStart, to: weekEnd, zone: zone) {
                if occ.allDay {
                    let c = calendar(zone)
                    let first = c.dateComponents([.day], from: weekStart, to: c.startOfDay(for: occ.start)).day ?? 0
                    let last = occ.end.map { c.dateComponents([.day], from: weekStart, to: c.startOfDay(for: $0)).day ?? first } ?? first
                    guard last >= 0, first < days else { continue }
                    week.allDay.append(SpaceTimetableAllDay(item: id, firstDay: max(0, first), lastDay: min(days - 1, last)))
                    continue
                }
                // No end, or an end at the start, shows one hour long.
                let end = occ.end.flatMap { $0 > occ.start ? $0 : nil } ?? occ.start.addingTimeInterval(3600)
                for day in 0..<days where occ.start < starts[day + 1] && end > starts[day] {
                    let top = occ.start <= starts[day] ? 0 : minute(of: occ.start, dayStart: starts[day], zone: zone)
                    let bottom = end >= starts[day + 1] ? 24 * 60 : minute(of: end, dayStart: starts[day], zone: zone)
                    week.slots.append(SpaceTimetableSlot(item: id, occurrence: index, start: occ.start, end: end, day: day,
                                                         startMinute: top, endMinute: max(bottom, top),
                                                         clippedTop: occ.start < starts[day], clippedBottom: end > starts[day + 1]))
                }
            }
        }
        week.slots = arrange(week.slots)
        week.allDay = stack(week.allDay)
        return week
    }

    /// The occurrences of `value` that touch [from, to). A weekly value is placed in its own zone first, so its
    /// device-zone time can move by an hour, or to another day, across DST changes.
    static func occurrences(_ value: DateValue, from: Date, to: Date, zone: TimeZone) -> [(Int, DateOccurrence)] {
        guard let first = try? value.occurrence(0, deviceTimeZone: zone) else { return [] }
        func touches(_ o: DateOccurrence) -> Bool {
            if o.allDay { return o.start < to && (o.end ?? o.start) >= from }
            let end = o.end.flatMap { $0 > o.start ? $0 : nil } ?? o.start.addingTimeInterval(3600)
            return o.start < to && end > from
        }
        guard value.repeat == .weekly else { return touches(first) ? [(0, first)] : [] }
        let week = 7 * 86_400.0
        let guess = Int((from.timeIntervalSince(first.start) / week).rounded(.down))
        var out: [(Int, DateOccurrence)] = []
        // One week either side covers zone offsets and multi-day items.
        for index in max(0, guess - 1)...max(0, guess + 2) {
            if let o = try? value.occurrence(index, deviceTimeZone: zone), touches(o) { out.append((index, o)) }
        }
        return out
    }

    /// Overlapping slots in a day share the width: each run of overlapping slots gets as many columns as it needs
    /// at once, and each slot takes the first free column. Slots that only touch don't overlap.
    static func arrange(_ slots: [SpaceTimetableSlot]) -> [SpaceTimetableSlot] {
        var out: [SpaceTimetableSlot] = []
        for day in Set(slots.map(\.day)).sorted() {
            let sorted = slots.filter { $0.day == day }.sorted {
                ($0.startMinute, -$0.endMinute, $0.item.description, $0.occurrence) < ($1.startMinute, -$1.endMinute, $1.item.description, $1.occurrence)
            }
            var cluster: [SpaceTimetableSlot] = []
            var columnEnds: [Int] = []
            var clusterEnd = -1
            func close() {
                let n = columnEnds.count
                out += cluster.map { var s = $0; s.columns = n; return s }
                cluster = []; columnEnds = []
            }
            for var slot in sorted {
                let bottom = max(slot.endMinute, slot.startMinute + 1)
                if slot.startMinute >= clusterEnd { close() }
                if let free = columnEnds.firstIndex(where: { $0 <= slot.startMinute }) {
                    slot.column = free
                    columnEnds[free] = bottom
                } else {
                    slot.column = columnEnds.count
                    columnEnds.append(bottom)
                }
                clusterEnd = max(clusterEnd, bottom)
                cluster.append(slot)
            }
            close()
        }
        return out
    }

    /// All-day items take the first strip row free across their days.
    static func stack(_ items: [SpaceTimetableAllDay]) -> [SpaceTimetableAllDay] {
        var rows: [[ClosedRange<Int>]] = []
        return items.sorted { ($0.firstDay, -$0.lastDay, $0.item.description) < ($1.firstDay, -$1.lastDay, $1.item.description) }.map { item in
            var item = item
            let span = item.firstDay...item.lastDay
            if let free = rows.firstIndex(where: { !$0.contains { $0.overlaps(span) } }) {
                item.lane = free
                rows[free].append(span)
            } else {
                item.lane = rows.count
                rows.append([span])
            }
            return item
        }
    }

    // MARK: Edits

    /// The value after moving or resizing occurrence `index` so it runs from `start` to `end`. The stored zone stays,
    /// and a weekly value's first occurrence moves by the same wall-clock change in that zone.
    static func moved(_ value: DateValue, occurrence index: Int, start: Date, end: Date, zone: TimeZone) throws -> DateValue {
        let stored = value.effectiveTimeZone(deviceTimeZone: zone)
        var seriesStart = start
        if index > 0 {
            // Step back `index` weeks on the stored zone's wall clock, then place that time in the stored zone.
            let wall = try DatePoint.from(start, in: stored)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let shifted = utc.date(byAdding: .day, value: -7 * index, to: try wall.resolved(in: utc.timeZone))!
            seriesStart = try DatePoint.from(shifted, in: utc.timeZone).resolved(in: stored)
        }
        let length = max(TimeInterval(snapMinutes * 60), end.timeIntervalSince(start))
        return try value.settingTime(start: seriesStart, end: seriesStart.addingTimeInterval(length), deviceTimeZone: zone)
    }

    /// A new timed value for a dragged range: it takes the device's zone.
    static func created(start: Date, end: Date, zone: TimeZone) throws -> DateValue {
        try DateValue(start: .from(start, in: zone), end: .from(end, in: zone), tz: zone.identifier)
    }
}
