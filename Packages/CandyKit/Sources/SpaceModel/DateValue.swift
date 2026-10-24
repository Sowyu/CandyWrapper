import Foundation

/// A Gregorian calendar date, optionally with a wall-clock hour and minute. Never an instant.
public struct DatePoint: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int?
    public let minute: Int?
    public var isTimed: Bool { hour != nil }
    public var description: String { rawValue }

    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 10 || bytes.count == 16,
              bytes[4] == 45, bytes[7] == 45,
              bytes.count == 10 || (bytes[10] == 84 && bytes[13] == 58),
              bytes.indices.allSatisfy({ [4, 7, 10, 13].contains($0) || (48...57).contains(bytes[$0]) }) else {
            throw ModelError.invalidDate(value)
        }
        func part(_ from: Int, _ to: Int) -> Int { Int(String(decoding: bytes[from..<to], as: UTF8.self))! }
        year = part(0, 4); month = part(5, 7); day = part(8, 10)
        hour = bytes.count == 16 ? part(11, 13) : nil
        minute = bytes.count == 16 ? part(14, 16) : nil
        rawValue = value
        guard year >= 1, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour ?? 0), (0...59).contains(minute ?? 0),
              let date = Self.utcCalendar.date(from: components),
              Self.utcCalendar.component(.year, from: date) == year,
              Self.utcCalendar.component(.month, from: date) == month,
              Self.utcCalendar.component(.day, from: date) == day else {
            throw ModelError.invalidDate(value)
        }
    }
    var components: DateComponents { DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0) }
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }

    /// Resolve explicitly like java.time ZonedDateTime.of: earlier in an overlap,
    /// later by the gap's full length when the requested wall-clock time does not exist.
    public func resolved(in zone: TimeZone, dateOnlyHour: Int = 0) throws -> Date {
        var components = components
        if !isTimed { components.hour = dateOnlyHour }
        guard let wall = Self.utcCalendar.date(from: components) else { throw ModelError.invalidDate(rawValue) }
        var offsets = Set<Int>()
        for hours in stride(from: -48, through: 48, by: 6) {
            offsets.insert(zone.secondsFromGMT(for: wall.addingTimeInterval(Double(hours * 3600))))
        }
        var matches: [Date] = []
        var later: [(Date, TimeInterval)] = []
        for offset in offsets {
            let instant = wall.addingTimeInterval(-Double(offset))
            let local = instant.addingTimeInterval(Double(zone.secondsFromGMT(for: instant)))
            let delta = local.timeIntervalSince(wall)
            if delta == 0 { matches.append(instant) }
            else if delta > 0 { later.append((instant, delta)) }
        }
        if let first = matches.min() { return first }
        if let next = later.min(by: { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }) { return next.0 }
        throw ModelError.invalidDate(rawValue)
    }

    public static func from(_ instant: Date, in zone: TimeZone, timed: Bool = true) throws -> Self {
        var calendar = utcCalendar; calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: instant)
        let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        return try Self(timed ? date + String(format: "T%02d:%02d", c.hour!, c.minute!) : date)
    }
    func addingWeeks(_ weeks: Int) throws -> Self {
        guard let dayCount = Int(exactly: weeks), !dayCount.multipliedReportingOverflow(by: 7).overflow,
              let shifted = Self.utcCalendar.date(byAdding: .day, value: dayCount * 7,
                                                  to: Self.utcCalendar.date(from: components)!) else {
            throw ModelError.invalidDateValue
        }
        return try Self.from(shifted, in: Self.utcCalendar.timeZone, timed: isTimed)
    }
}

/// Unknown reminder forms retain their JSON so an older client can write them back.
public enum Reminder: Codable, Hashable, Sendable {
    case before(Int), at(DatePoint), unknown(JSONValue)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(JSONValue.self)
        if case .object(let object) = value, object.count == 1 {
            if case .integer(let minutes) = object["before"], let minutes = Int(exactly: minutes) { self = .before(minutes); return }
            if case .string(let date) = object["at"] {
                let point = try DatePoint(date)
                guard point.isTimed else { throw ModelError.invalidDateValue }
                self = .at(point); return
            }
        }
        self = .unknown(value)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .before(let value): try c.encode(["before": value])
        case .at(let value):
            guard value.isTimed else { throw ModelError.invalidDateValue }
            try c.encode(["at": value])
        case .unknown(let value): try c.encode(value)
        }
    }
}

public struct DateOccurrence: Hashable, Sendable {
    public var start: Date
    public var end: Date?
    public var allDay: Bool
}

public struct DateValue: Codable, Hashable, Sendable {
    public var start: DatePoint
    public var end: DatePoint?
    /// Kept verbatim, even if Foundation does not know this IANA id.
    public var tz: String?
    public var `repeat`: RepeatRule?
    public var remind: Reminder?
    public var extra: [String: JSONValue]
    private var explicitNulls: Set<String> = []
    private static let known: Set<String> = ["start", "end", "tz", "repeat", "remind"]

    public init(start: DatePoint, end: DatePoint? = nil, tz: String? = nil, repeat rule: RepeatRule? = nil,
                remind: Reminder? = nil, extra: [String: JSONValue] = [:]) throws {
        self.start = start; self.end = end; self.tz = tz; self.repeat = rule; self.remind = remind; self.extra = extra
        try validate()
    }
    public func validate() throws {
        guard start.isTimed == (tz != nil), end.map({ $0.isTimed == start.isTimed && $0 >= start }) ?? true else {
            throw ModelError.invalidDateValue
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        start = try c.required("start"); end = try c.optional("end"); tz = try c.optional("tz")
        self.repeat = try c.optional("repeat"); remind = try c.optional("remind")
        extra = try c.unknown(Self.known); explicitNulls = try c.nulls(["end", "tz", "repeat", "remind"])
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: Self.known)
        try c.required(start, "start"); try c.optional(end, "end", nulls: explicitNulls)
        try c.optional(tz, "tz", nulls: explicitNulls); try c.optional(self.repeat, "repeat", nulls: explicitNulls)
        try c.optional(remind, "remind", nulls: explicitNulls)
    }
    public func effectiveTimeZone(deviceTimeZone: TimeZone) -> TimeZone {
        tz.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone
    }

    /// A weekly timed start stays on its wall-clock weekday in its stored zone.
    /// Its end uses the first occurrence's elapsed length, including across DST.
    public func occurrence(_ index: Int = 0, deviceTimeZone: TimeZone) throws -> DateOccurrence? {
        try validate()
        guard index >= 0, index == 0 || self.repeat == .weekly else { return nil }
        let zone = effectiveTimeZone(deviceTimeZone: deviceTimeZone)
        let shiftedStart = try start.addingWeeks(index).resolved(in: zone)
        let shiftedEnd: Date?
        if let end {
            if start.isTimed {
                let duration = try end.resolved(in: zone).timeIntervalSince(start.resolved(in: zone))
                shiftedEnd = shiftedStart.addingTimeInterval(duration)
            } else { shiftedEnd = try end.addingWeeks(index).resolved(in: zone) }
        } else { shiftedEnd = nil }
        return DateOccurrence(start: shiftedStart, end: shiftedEnd, allDay: !start.isTimed)
    }

    /// Picker instants already reflect the device's zone. Editing keeps the stored zone.
    /// A new timed value (including one made from an all-day value) takes the device's zone.
    public func settingTime(start instant: Date, end endInstant: Date? = nil, deviceTimeZone: TimeZone) throws -> Self {
        try validate()
        let storedZone = tz ?? deviceTimeZone.identifier
        let effective = TimeZone(identifier: storedZone) ?? deviceTimeZone
        var result = self
        result.start = try .from(instant, in: effective)
        result.end = try endInstant.map { try .from($0, in: effective) }
        result.tz = storedZone
        try result.validate()
        return result
    }

    /// Date-only reminders count back from 09:00 in the device's current zone.
    public func reminderInstant(deviceTimeZone: TimeZone) throws -> Date? {
        let zone = effectiveTimeZone(deviceTimeZone: deviceTimeZone)
        switch remind {
        case .before(let minutes): return try start.resolved(in: zone, dateOnlyHour: 9).addingTimeInterval(-Double(minutes) * 60)
        case .at(let point): return try point.resolved(in: zone)
        default: return nil
        }
    }
}
