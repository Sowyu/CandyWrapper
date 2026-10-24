import Foundation

/// Compares ASCII bytes, independent of locale. Existing keys may use any base-62 string.
public struct OrderKey: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let heads = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.allSatisfy({ Self.digits.contains($0) }) else {
            throw ModelError.invalidOrderKey(value)
        }
        rawValue = value
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8) }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(rawValue)
    }

    /// Rocicorp fractional-indexing's default base-62 algorithm (CC0):
    /// https://github.com/rocicorp/fractional-indexing/blob/main/src/index.js
    /// Other clients may supply valid keys outside that algorithm's grammar.
    public static func between(_ lower: Self?, _ upper: Self?) throws -> Self {
        if let lower, let upper, lower >= upper { throw ModelError.noKeyBetween }
        let a = lower.map { Array($0.rawValue.utf8) }
        let b = upper.map { Array($0.rawValue.utf8) }
        let result: [UInt8]
        if (a == nil || canonical(a!)) && (b == nil || canonical(b!)) {
            result = try fractional(a, b)
        } else { result = try general(a ?? [], b) }
        let key = try Self(String(decoding: result, as: UTF8.self))
        guard lower.map({ $0 < key }) ?? true, upper.map({ key < $0 }) ?? true else { throw ModelError.noKeyBetween }
        return key
    }

    private static func integerLength(_ head: UInt8) -> Int? {
        guard let i = heads.firstIndex(of: head) else { return nil }
        return i < 26 ? 27 - i : i - 24
    }
    private static func integer(_ key: [UInt8]) -> [UInt8] {
        Array(key.prefix(integerLength(key[0])!))
    }
    private static var minimum: [UInt8] { [65] + Array(repeating: 48, count: 26) }
    private static func canonical(_ key: [UInt8]) -> Bool {
        guard let length = integerLength(key[0]), key.count >= length, key != minimum else { return false }
        return key.count == length || key.last != 48
    }
    private static func step(_ value: [UInt8], _ direction: Int) -> [UInt8]? {
        var result = value
        for i in (1..<result.count).reversed() {
            let next = digits.firstIndex(of: result[i])! + direction
            if (0..<62).contains(next) { result[i] = digits[next]; return result }
            result[i] = direction > 0 ? 48 : 122
        }
        let index = heads.firstIndex(of: value[0])! + direction
        guard heads.indices.contains(index) else { return nil }
        let head = heads[index]
        let count = integerLength(head)! - 1
        return [head] + Array(repeating: direction > 0 ? 48 : 122, count: count)
    }
    private static func midpoint(_ a: [UInt8], _ b: [UInt8]?) throws -> [UInt8] {
        if let b {
            var prefix = 0
            while prefix < b.count && (prefix < a.count ? a[prefix] : 48) == b[prefix] { prefix += 1 }
            if prefix > 0 {
                return Array(b.prefix(prefix)) + (try midpoint(Array(a.dropFirst(prefix)), Array(b.dropFirst(prefix))))
            }
        }
        let da = a.first.map { digits.firstIndex(of: $0)! } ?? 0
        let db = b?.first.map { digits.firstIndex(of: $0)! } ?? 62
        if db - da > 1 { return [digits[(da + db + 1) / 2]] }
        if let b, b.count > 1 { return [b[0]] }
        return [digits[da]] + (try midpoint(Array(a.dropFirst()), nil))
    }
    private static func fractional(_ a: [UInt8]?, _ b: [UInt8]?) throws -> [UInt8] {
        guard let a else {
            guard let b else { return Array("a0".utf8) }
            let ib = integer(b), fb = Array(b.dropFirst(ib.count))
            if ib == minimum { return ib + (try midpoint([], fb)) }
            if ib != b { return ib }
            guard let previous = step(ib, -1) else { throw ModelError.noKeyBetween }
            return previous
        }
        let ia = integer(a), fa = Array(a.dropFirst(ia.count))
        guard let b else { return try step(ia, 1) ?? (ia + midpoint(fa, nil)) }
        let ib = integer(b), fb = Array(b.dropFirst(ib.count))
        if ia == ib { return ia + (try midpoint(fa, fb)) }
        if let next = step(ia, 1), next.lexicographicallyPrecedes(b) { return next }
        return ia + (try midpoint(fa, nil))
    }
    private static func general(_ a: [UInt8], _ b: [UInt8]?) throws -> [UInt8] {
        guard let b else { return a + [86] }
        var prefix = 0
        while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
        if prefix == a.count {
            let tail = Array(b.dropFirst(prefix))
            if tail.count > 1 { return a + tail.dropLast() }
            guard let first = tail.first, let digit = digits.firstIndex(of: first), digit > 0 else { throw ModelError.noKeyBetween }
            return a + [digits[digit / 2]]
        }
        let da = digits.firstIndex(of: a[prefix])!, db = digits.firstIndex(of: b[prefix])!
        if db - da > 1 { return Array(a.prefix(prefix)) + [digits[(da + db) / 2]] }
        return a + [86]
    }
}

/// Both page and block records share this comparison within a page's content.
public struct RecordPosition: Hashable, Sendable, Comparable {
    public var order: OrderKey
    public var id: RecordID
    public init(order: OrderKey, id: RecordID) { self.order = order; self.id = id }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
    }
}
