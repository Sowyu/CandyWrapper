import Foundation

/// Parses UTF-8 JSON text straight into `JSONValue`, one pass over the bytes. It replaced
/// JSONSerialization plus a tree conversion, which built every node twice (an NSObject, then the
/// enum) and cost about twice as much on a big thread snapshot.
///
/// Accepts what JSONSerialization with `.fragmentsAllowed` accepted for UTF-8 text: any value at
/// the top level, a leading byte order mark, one trailing comma in a container, the first of
/// duplicate keys. Numbers become Doubles. A lone UTF-16 surrogate in a `\u` escape becomes U+FFFD
/// and invalid UTF-8 is repaired the same way.
struct JSONScanner {
    private let base: UnsafePointer<UInt8>
    private let end: Int
    private var i = 0
    private var depth = 0
    /// Members of the objects and elements of the arrays being parsed, innermost last. One buffer
    /// for the whole parse, so a container is built once at its final size.
    private var members: [(String, JSONValue)] = []
    private var elements: [JSONValue] = []
    /// Unescaped bytes of the string being read, for strings with escapes.
    private var scratch: [UInt8] = []

    static let maxDepth = 512

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw -> JSONValue in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { throw corrupted() }
            var s = JSONScanner(base: p, end: raw.count)
            if raw.count >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF { s.i = 3 }
            let v = try s.value()
            s.skipSpace()
            guard s.i == s.end else { throw corrupted() }
            return v
        }
    }

    private init(base: UnsafePointer<UInt8>, end: Int) {
        self.base = base
        self.end = end
    }

    static func corrupted() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The given data was not valid JSON."))
    }

    @inline(__always) private mutating func skipSpace() {
        while i < end {
            switch base[i] {
            case 0x20, 0x0A, 0x0D, 0x09: i += 1
            default: return
            }
        }
    }

    private mutating func value() throws -> JSONValue {
        skipSpace()
        guard i < end else { throw Self.corrupted() }
        switch base[i] {
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func literal(_ word: StaticString) throws {
        let n = word.utf8CodeUnitCount
        guard end - i >= n, memcmp(base + i, word.utf8Start, n) == 0 else { throw Self.corrupted() }
        i += n
    }

    private mutating func object() throws -> JSONValue {
        depth += 1
        guard depth <= Self.maxDepth else { throw Self.corrupted() }
        i += 1
        let start = members.count
        skipSpace()
        if i < end, base[i] == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                skipSpace()
                // JSONSerialization allows one trailing comma.
                if i < end, base[i] == UInt8(ascii: "}"), members.count > start { i += 1; break }
                guard i < end, base[i] == UInt8(ascii: "\"") else { throw Self.corrupted() }
                let key = try string()
                skipSpace()
                guard i < end, base[i] == UInt8(ascii: ":") else { throw Self.corrupted() }
                i += 1
                let v = try value()
                members.append((key, v))
                skipSpace()
                guard i < end else { throw Self.corrupted() }
                if base[i] == UInt8(ascii: ",") { i += 1; continue }
                guard base[i] == UInt8(ascii: "}") else { throw Self.corrupted() }
                i += 1
                break
            }
        }
        depth -= 1
        var o = [String: JSONValue](minimumCapacity: members.count - start)
        // Backwards, so the first of duplicate keys wins, as in JSONSerialization.
        for k in (start..<members.count).reversed() { o[members[k].0] = members[k].1 }
        members.removeSubrange(start...)
        return .object(o)
    }

    private mutating func array() throws -> JSONValue {
        depth += 1
        guard depth <= Self.maxDepth else { throw Self.corrupted() }
        i += 1
        let start = elements.count
        skipSpace()
        if i < end, base[i] == UInt8(ascii: "]") {
            i += 1
        } else {
            while true {
                skipSpace()
                if i < end, base[i] == UInt8(ascii: "]"), elements.count > start { i += 1; break }
                elements.append(try value())
                skipSpace()
                guard i < end else { throw Self.corrupted() }
                if base[i] == UInt8(ascii: ",") { i += 1; continue }
                guard base[i] == UInt8(ascii: "]") else { throw Self.corrupted() }
                i += 1
                break
            }
        }
        depth -= 1
        let out = Array(elements[start...])
        elements.removeSubrange(start...)
        return .array(out)
    }

    /// Reads a string; `i` is on its opening quote.
    private mutating func string() throws -> String {
        i += 1
        let start = i
        while i < end {
            let b = base[i]
            if b == UInt8(ascii: "\"") {
                let s = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
                i += 1
                return s
            }
            if b == UInt8(ascii: "\\") { return try escapedString(from: start) }
            guard b >= 0x20 else { throw Self.corrupted() }
            i += 1
        }
        throw Self.corrupted()
    }

    /// The slow path, from the first backslash on.
    private mutating func escapedString(from start: Int) throws -> String {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: UnsafeBufferPointer(start: base + start, count: i - start))
        while i < end {
            let b = base[i]
            switch b {
            case UInt8(ascii: "\""):
                i += 1
                return String(decoding: scratch, as: UTF8.self)
            case UInt8(ascii: "\\"):
                i += 1
                guard i < end else { throw Self.corrupted() }
                let e = base[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): scratch.append(e)
                case UInt8(ascii: "b"): scratch.append(0x08)
                case UInt8(ascii: "f"): scratch.append(0x0C)
                case UInt8(ascii: "n"): scratch.append(0x0A)
                case UInt8(ascii: "r"): scratch.append(0x0D)
                case UInt8(ascii: "t"): scratch.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar) {
                        // A high surrogate wants a low one right after it.
                        if end - i >= 6, base[i] == UInt8(ascii: "\\"), base[i + 1] == UInt8(ascii: "u") {
                            let mark = i
                            i += 2
                            let low = try hex4()
                            if (0xDC00..<0xE000).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                                i = mark
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00..<0xE000).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    for unit in UTF8.encode(Unicode.Scalar(scalar)!)! { scratch.append(unit) }
                default: throw Self.corrupted()
                }
            default:
                guard b >= 0x20 else { throw Self.corrupted() }
                scratch.append(b)
                i += 1
            }
        }
        throw Self.corrupted()
    }

    private mutating func hex4() throws -> UInt32 {
        guard end - i >= 4 else { throw Self.corrupted() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = base[i]
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: throw Self.corrupted()
            }
            v = v << 4 | UInt32(d)
            i += 1
        }
        return v
    }

    @inline(__always) private func isDigit(_ k: Int) -> Bool {
        k < end && base[k] &- UInt8(ascii: "0") < 10
    }

    /// Checks the JSON number grammar. Up to 18 integer digits convert exactly through Int64;
    /// anything else goes through `Double(String)`.
    private mutating func number() throws -> Double {
        let start = i
        let negative = base[i] == UInt8(ascii: "-")
        if negative { i += 1 }
        guard isDigit(i) else { throw Self.corrupted() }
        var integer: Int64 = 0
        let digitsStart = i
        if base[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            while isDigit(i) {
                if i - digitsStart < 18 { integer = integer &* 10 &+ Int64(base[i] &- UInt8(ascii: "0")) }
                i += 1
            }
        }
        var simple = i - digitsStart <= 18
        if i < end, base[i] == UInt8(ascii: ".") {
            i += 1
            guard isDigit(i) else { throw Self.corrupted() }
            while isDigit(i) { i += 1 }
            simple = false
        }
        if i < end, base[i] | 0x20 == UInt8(ascii: "e") {
            i += 1
            if i < end, base[i] == UInt8(ascii: "+") || base[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { throw Self.corrupted() }
            while isDigit(i) { i += 1 }
            simple = false
        }
        if simple { return Double(negative ? -integer : integer) }
        // Swift's own conversion ignores the C locale and rounds correctly.
        let text = String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
        guard let d = Double(text) else { throw Self.corrupted() }
        return d
    }
}
