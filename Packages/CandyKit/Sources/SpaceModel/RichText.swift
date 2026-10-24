import Foundation

public struct TextMark: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int
    public var kind: MarkKind
    public var value: String?
    public init(start: Int, end: Int, kind: MarkKind, value: String? = nil) {
        self.start = start; self.end = end; self.kind = kind; self.value = value
    }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Int.self)
        end = try c.decode(Int.self)
        kind = try c.decode(MarkKind.self)
        value = c.isAtEnd ? nil : try c.decode(String.self)
        guard c.isAtEnd else { throw ModelError.invalidMark }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start); try c.encode(end); try c.encode(kind)
        if let value { try c.encode(value) }
    }
}

public struct RichText: Codable, Hashable, Sendable {
    public var t: String
    public var m: [TextMark]
    public var extra: [String: JSONValue]
    public init(t: String = "", m: [TextMark] = [], extra: [String: JSONValue] = [:]) {
        self.t = t; self.m = m; self.extra = extra
    }
    /// Call after edits. Offsets count UTF-16 units, never Swift Characters.
    public func validate() throws {
        for mark in m {
            guard mark.start >= 0, mark.start < mark.end, mark.end <= t.utf16.count,
                  (mark.kind != .a && mark.kind != .p) || mark.value != nil else { throw ModelError.invalidMark }
        }
    }
    private var sortedMarks: [TextMark] {
        m.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.kind.rawValue.utf8.lexicographicallyPrecedes($1.kind.rawValue.utf8)
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try ObjectReader(decoder)
        t = try c.required("t"); m = try c.required("m")
        extra = try c.unknown(["t", "m"])
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = try ObjectWriter(encoder, extra: extra, known: ["t", "m"])
        try c.required(t, "t"); try c.required(sortedMarks, "m")
    }
}
