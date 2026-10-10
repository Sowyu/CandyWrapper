import Foundation

// Building blocks for the domain types: branded ids, open string enums, timestamps and the
// absent-versus-null field wrapper. See docs/protocol.md section 3.

/// A branded id. The brand exists only at compile time; on the wire every id is an opaque string
/// (docs/protocol.md 3.3). Never parse ids for logic.
public struct TaggedID<Tag>: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public enum ThreadIdTag {}
public enum ProjectIdTag {}
public enum RunIdTag {}
public enum ProviderInstanceIdTag {}
public enum RuntimeRequestIdTag {}

public typealias ThreadId = TaggedID<ThreadIdTag>
public typealias ProjectId = TaggedID<ProjectIdTag>
public typealias RunId = TaggedID<RunIdTag>
public typealias ProviderInstanceId = TaggedID<ProviderInstanceIdTag>
public typealias RuntimeRequestId = TaggedID<RuntimeRequestIdTag>

/// A string literal union that stays open: values this build doesn't know decode as themselves
/// instead of failing the whole message. Compare against the static members, and keep a
/// `default` branch in every switch.
public protocol OpenStringEnum: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible where RawValue == String
{
    init(rawValue: String)
}

extension OpenStringEnum {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

/// A `DateTimeUtc` or `IsoDateTime` value. Keeps the server's string for round trips and parses
/// it once to epoch milliseconds, like `Date.parse` in the official client. A string that does
/// not parse keeps `epochMs == nil`, which the sidebar logic treats like JS `NaN`.
public struct T3Timestamp: Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let raw: String
    public let epochMs: Int64?

    public init(_ raw: String) {
        self.raw = raw
        self.epochMs = T3Timestamp.parseEpochMs(raw)
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// Formats like `Date.prototype.toISOString`: UTC, milliseconds, `Z`.
    public init(_ date: Date) {
        self.init(T3Timestamp.fractional.string(from: date))
    }

    public init(epochMs: Int64) {
        self.init(Date(timeIntervalSince1970: Double(epochMs) / 1000))
    }

    public var date: Date? { epochMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    public var isValid: Bool { epochMs != nil }
    public var description: String { raw }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }

    // ISO8601DateFormatter is documented thread-safe; the formatters are built once.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fractional seconds first, then whole seconds. Anything else is invalid.
    public static func parseEpochMs(_ raw: String) -> Int64? {
        if let ms = canonicalEpochMs(raw) { return ms }
        guard let date = fractional.date(from: raw) ?? whole.date(from: raw) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `toISOString` output, `YYYY-MM-DDTHH:MM:SS.sssZ` or without `.sss`, parsed by hand. The
    /// formatter costs about 45 µs and 480 allocations per call; a thread snapshot has hundreds.
    /// Anything else, including out-of-range fields, goes to the formatters.
    static func canonicalEpochMs(_ raw: String) -> Int64? {
        let n = raw.utf8.count
        guard n == 24 || n == 20 else { return nil }
        func daysInMonth(_ m: Int64, _ y: Int64) -> Int64 {
            if m == 2 { return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) ? 29 : 28 }
            return m == 4 || m == 6 || m == 9 || m == 11 ? 30 : 31
        }
        func parse(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
            func num(_ at: Int, _ len: Int) -> Int64? {
                var v: Int64 = 0
                for i in at..<at + len {
                    let d = b[i] &- 0x30
                    guard d < 10 else { return nil }
                    v = v * 10 + Int64(d)
                }
                return v
            }
            guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A, b[n - 1] == 0x5A,
                  let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
                  let h = num(11, 2), let mi = num(14, 2), let s = num(17, 2),
                  y >= 1900, (1...12).contains(mo), d >= 1, d <= daysInMonth(mo, y), h < 24, mi < 60, s < 60
            else { return nil }
            var ms: Int64 = 0
            if n == 24 {
                guard b[19] == 0x2E, let f = num(20, 3) else { return nil }
                ms = f
            }
            // Days since 1970-01-01, proleptic Gregorian (Howard Hinnant's days_from_civil). The
            // formatter switches to Julian before 1583, hence the 1900 floor above.
            let yy = mo <= 2 ? y - 1 : y
            let era = yy / 400
            let yoe = yy - era * 400
            let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            return ((days * 24 + h) * 60 + mi) * 60_000 + s * 1000 + ms
        }
        var raw = raw
        return raw.withUTF8(parse)
    }
}

/// A field where a missing key and an explicit `null` mean different things. The shell's
/// `lastVisitedAt` is the main case: a missing key means the server predates visit tracking.
public enum Tristate<Wrapped> {
    case absent
    case null
    case value(Wrapped)

    public var value: Wrapped? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var isAbsent: Bool {
        if case .absent = self { return true }
        return false
    }

    /// `undefined` becomes `.absent`, `nil` becomes `.null`.
    public init(_ optional: Wrapped?) {
        self = optional.map { .value($0) } ?? .null
    }
}

extension Tristate: Equatable where Wrapped: Equatable {}
extension Tristate: Hashable where Wrapped: Hashable {}
extension Tristate: Sendable where Wrapped: Sendable {}

// The single-value forms are used only outside a keyed container. Keyed containers go through
// the overloads below, which can see whether the key exists.
extension Tristate: Decodable where Wrapped: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(Wrapped.self))
    }
}

extension Tristate: Encodable where Wrapped: Encodable {

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .absent, .null: try c.encodeNil()
        case .value(let v): try c.encode(v)
        }
    }
}

extension KeyedDecodingContainer {
    public func decode<T: Decodable>(_ type: Tristate<T>.Type, forKey key: Key) throws -> Tristate<T> {
        guard contains(key) else { return .absent }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    public mutating func encode<T: Encodable>(_ value: Tristate<T>, forKey key: Key) throws {
        switch value {
        case .absent: break
        case .null: try encodeNil(forKey: key)
        case .value(let v): try encode(v, forKey: key)
        }
    }
}
