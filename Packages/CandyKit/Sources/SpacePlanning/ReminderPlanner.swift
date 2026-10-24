import Foundation
import SpaceModel

public struct PlannedReminder: Equatable, Sendable {
    public let id: String
    public let pageID: PageID
    public let fieldID: String
    /// The occurrence's nominal start in the value's zone, also used in the stable id.
    public let start: DatePoint
    public let fireDate: Date
    /// Timed values carry their effective zone; date-only values carry no zone or calendar.
    public let components: DateComponents
    public let title: String
    public let parentTitle: String?
    /// Format this with the user's locale in the notification adapter.
    public let itemTimeInDeviceZone: DatePoint
}

/// Computes requests only. The notification controller owns permission, scheduling,
/// cancellation, snoozes and when to call this again. No clock or zone is read implicitly.
public enum ReminderPlanner {
    public static let requestLimit = 50
    public static let horizonDays = 30

    /// Future fire times in (now, now + 30 local calendar days], soonest first.
    /// Every date prop participates, including custom fields and temporarily absent schemas.
    public static func plan(pages: [PageID: PageRecord], now: Date,
                            deviceTimeZone: TimeZone) throws -> [PlannedReminder] {
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = deviceTimeZone
        guard let until = deviceCalendar.date(byAdding: .day, value: horizonDays, to: now) else { return [] }
        let hierarchy = PageHierarchy(pages)
        var planned: [PlannedReminder] = []
        for (pageID, page) in pages {
            guard page.props[FieldID.done] != .checkbox(true), hierarchy.path(to: pageID) != nil else { continue }
            for (fieldID, property) in page.props {
                guard case .date(let value) = property, let reminder = value.remind else { continue }
                try value.validate()
                let zone = value.effectiveTimeZone(deviceTimeZone: deviceTimeZone)
                let anchor: DatePoint
                let leadSeconds: Double
                switch reminder {
                case .before(let minutes): anchor = value.start; leadSeconds = Double(minutes) * 60
                case .at(let point):
                    guard point.isTimed else { throw ModelError.invalidDateValue }
                    anchor = point; leadSeconds = 0
                case .unknown: continue
                }
                let firstFire = try anchor.resolved(in: zone, dateOnlyHour: 9).addingTimeInterval(-leadSeconds)
                let weekly = value.repeat == .weekly
                // Jump close to the window instead of walking every week since a years-old start.
                // Two weeks of slack covers offset changes, including a skipped calendar day.
                let estimate = floor(now.timeIntervalSince(firstFire) / (7 * 86_400)) - 2
                guard let firstWeek = weekly ? Int(exactly: max(0, estimate)) : 0 else { continue }
                let count = weekly ? 10 : 1
                for step in 0..<count {
                    let (week, overflow) = firstWeek.addingReportingOverflow(step)
                    guard !overflow,
                          let start = shifted(value.start, weeks: week),
                          let reminderPoint = shifted(anchor, weeks: week) else { continue }
                    let fire = try reminderPoint.resolved(in: zone, dateOnlyHour: 9).addingTimeInterval(-leadSeconds)
                    guard fire > now, fire <= until else { continue }
                    let id = "space.\(pageID.rawValue).\(fieldID).\(start.rawValue)"
                    if planned.count == requestLimit, let last = planned.last,
                       fire > last.fireDate || (fire == last.fireDate && id >= last.id) { continue }
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = zone
                    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
                    // No embedded Calendar either: its zone would pin a floating date-only trigger.
                    components.calendar = nil
                    components.timeZone = value.start.isTimed ? zone : nil
                    let occurrence = try start.resolved(in: zone)
                    let displayTime = value.start.isTimed
                        ? try DatePoint.from(occurrence, in: deviceTimeZone)
                        : start
                    let request = PlannedReminder(id: id, pageID: pageID, fieldID: fieldID, start: start,
                                                  fireDate: fire, components: components, title: page.title,
                                                  parentTitle: page.parent.flatMap { pages[$0]?.title },
                                                  itemTimeInDeviceZone: displayTime)
                    let position = planned.firstIndex { fire < $0.fireDate || (fire == $0.fireDate && id < $0.id) }
                        ?? planned.endIndex
                    planned.insert(request, at: position)
                    if planned.count > requestLimit { planned.removeLast() }
                }
            }
        }
        return planned
    }

    /// Shift wall-clock components, then let DatePoint resolve gaps and overlaps.
    /// An explicit weekly `at` moves seven calendar days with each item occurrence.
    private static func shifted(_ point: DatePoint, weeks: Int) -> DatePoint? {
        if weeks == 0 { return point }
        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = utc
        guard let original = try? point.resolved(in: utc),
              let shifted = calendar.date(byAdding: .weekOfYear, value: weeks, to: original) else { return nil }
        return try? DatePoint.from(shifted, in: utc, timed: point.isTimed)
    }
}
