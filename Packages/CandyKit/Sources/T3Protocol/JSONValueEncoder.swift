import Foundation

/// Encodes `Encodable` types to a `JSONValue` tree with `JSONEncoder`'s default behavior: keys as
/// written, `Date` through its own Codable (deferredToDate), `URL` as its absolute string, a value
/// that encodes nothing as `{}`, and non-finite numbers throw. A `JSONValue` field takes its node in
/// O(1), so a projection's raw wire objects are not walked again. `JSONValue.utf8` then writes the
/// text, which together cost about half of what JSONEncoder did on a big thread.
public struct JSONValueEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try EncodeNode.encode(value, path: [])
    }
}

/// One value being encoded: a scalar, or the object or array its containers write into.
final class EncodeNode: Encoder {
    private enum Storage {
        case empty
        case value(JSONValue)
        case object([String: JSONValue])
        case array([JSONValue])
    }

    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    private var storage = Storage.empty
    /// Containers handed out by `nestedContainer` and `superEncoder`, filled in after this node
    /// handed them out; their values are read when this node finishes.
    private var deferredKeys: [(String, EncodeNode)] = []
    private var deferredIndices: [(Int, EncodeNode)] = []

    init(path: [CodingKey]) { codingPath = path }

    static func encode<T: Encodable>(_ value: T, path: [CodingKey]) throws -> JSONValue {
        if let v = try leaf(value, path: path) { return v }
        let node = EncodeNode(path: path)
        try value.encode(to: node)
        return node.finish()
    }

    /// Hot leaf types skip building a node.
    static func leaf<T: Encodable>(_ value: T, path: [CodingKey]) throws -> JSONValue? {
        if T.self == JSONValue.self { return (value as! JSONValue) }
        if T.self == String.self { return .string(value as! String) }
        if T.self == Bool.self { return .bool(value as! Bool) }
        if T.self == Int.self { return .number(Double(value as! Int)) }
        if T.self == Double.self { return try number(value as! Double, path) }
        if T.self == URL.self { return .string((value as! URL).absoluteString) }
        return nil
    }

    static func number(_ d: Double, _ path: [CodingKey]) throws -> JSONValue {
        guard d.isFinite else {
            throw EncodingError.invalidValue(d, .init(codingPath: path, debugDescription: "Unable to encode \(d) directly in JSON."))
        }
        return .number(d)
    }

    func finish() -> JSONValue {
        switch storage {
        case .empty: return .object([:])
        case .value(let v): return v
        case .object(var o):
            for (k, node) in deferredKeys { o[k] = node.finish() }
            return .object(o)
        case .array(var a):
            for (i, node) in deferredIndices { a[i] = node.finish() }
            return .array(a)
        }
    }

    // MARK: Writing into this node

    func set(_ v: JSONValue, forKey key: String) {
        if case .object(var o) = storage {
            storage = .empty
            o[key] = v
            storage = .object(o)
        } else {
            storage = .object([key: v])
        }
    }

    /// Appends and returns the index.
    @discardableResult
    func append(_ v: JSONValue) -> Int {
        if case .array(var a) = storage {
            storage = .empty
            a.append(v)
            let i = a.count - 1
            storage = .array(a)
            return i
        }
        storage = .array([v])
        return 0
    }

    var count: Int { if case .array(let a) = storage { return a.count }; return 0 }

    func setSingle(_ v: JSONValue) { storage = .value(v) }

    func deferKey(_ key: String, _ node: EncodeNode) {
        set(.object([:]), forKey: key)
        deferredKeys.append((key, node))
    }

    func deferIndex(_ node: EncodeNode) {
        deferredIndices.append((append(.object([:])), node))
    }

    // MARK: Encoder

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .object = storage {} else { storage = .object([:]) }
        return KeyedEncodingContainer(KeyedNode<Key>(node: self))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if case .array = storage {} else { storage = .array([]) }
        return UnkeyedNode(node: self)
    }

    func singleValueContainer() -> SingleValueEncodingContainer { self }
}

extension EncodeNode: SingleValueEncodingContainer {
    func encodeNil() { setSingle(.null) }
    func encode(_ value: Bool) { setSingle(.bool(value)) }
    func encode(_ value: String) { setSingle(.string(value)) }
    func encode(_ value: Double) throws { setSingle(try Self.number(value, codingPath)) }
    func encode(_ value: Float) throws { setSingle(try Self.number(Double(value), codingPath)) }
    func encode(_ value: Int) { setSingle(.number(Double(value))) }
    func encode(_ value: Int8) { setSingle(.number(Double(value))) }
    func encode(_ value: Int16) { setSingle(.number(Double(value))) }
    func encode(_ value: Int32) { setSingle(.number(Double(value))) }
    func encode(_ value: Int64) { setSingle(.number(Double(value))) }
    func encode(_ value: UInt) { setSingle(.number(Double(value))) }
    func encode(_ value: UInt8) { setSingle(.number(Double(value))) }
    func encode(_ value: UInt16) { setSingle(.number(Double(value))) }
    func encode(_ value: UInt32) { setSingle(.number(Double(value))) }
    func encode(_ value: UInt64) { setSingle(.number(Double(value))) }
    func encode<T: Encodable>(_ value: T) throws { setSingle(try Self.encode(value, path: codingPath)) }
}

private struct EncodeIndexKey: CodingKey {
    let intValue: Int?
    init(_ i: Int) { intValue = i }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { nil }
    var stringValue: String { "Index \(intValue ?? 0)" }
}

private struct EncodeSuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) {}
    init?(intValue: Int) { nil }
}

private struct KeyedNode<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: EncodeNode
    var codingPath: [CodingKey] { node.codingPath }

    func encodeNil(forKey key: Key) { node.set(.null, forKey: key.stringValue) }
    func encode(_ value: Bool, forKey key: Key) { node.set(.bool(value), forKey: key.stringValue) }
    func encode(_ value: String, forKey key: Key) { node.set(.string(value), forKey: key.stringValue) }
    func encode(_ value: Double, forKey key: Key) throws { node.set(try EncodeNode.number(value, codingPath + [key]), forKey: key.stringValue) }
    func encode(_ value: Float, forKey key: Key) throws { node.set(try EncodeNode.number(Double(value), codingPath + [key]), forKey: key.stringValue) }
    func encode(_ value: Int, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: Int8, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: Int16, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: Int32, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: Int64, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: UInt, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: UInt8, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: UInt16, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: UInt32, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode(_ value: UInt64, forKey key: Key) { node.set(.number(Double(value)), forKey: key.stringValue) }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        node.set(try EncodeNode.encode(value, path: codingPath + [key]), forKey: key.stringValue)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let child = EncodeNode(path: codingPath + [key])
        node.deferKey(key.stringValue, child)
        return child.container(keyedBy: keyType)
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = EncodeNode(path: codingPath + [key])
        node.deferKey(key.stringValue, child)
        return child.unkeyedContainer()
    }

    func superEncoder() -> Encoder {
        let child = EncodeNode(path: codingPath + [EncodeSuperKey()])
        node.deferKey("super", child)
        return child
    }

    func superEncoder(forKey key: Key) -> Encoder {
        let child = EncodeNode(path: codingPath + [key])
        node.deferKey(key.stringValue, child)
        return child
    }
}

private struct UnkeyedNode: UnkeyedEncodingContainer {
    let node: EncodeNode
    var codingPath: [CodingKey] { node.codingPath }
    var count: Int { node.count }

    private var path: [CodingKey] { codingPath + [EncodeIndexKey(count)] }

    func encodeNil() { node.append(.null) }
    func encode(_ value: Bool) { node.append(.bool(value)) }
    func encode(_ value: String) { node.append(.string(value)) }
    func encode(_ value: Double) throws { node.append(try EncodeNode.number(value, path)) }
    func encode(_ value: Float) throws { node.append(try EncodeNode.number(Double(value), path)) }
    func encode(_ value: Int) { node.append(.number(Double(value))) }
    func encode(_ value: Int8) { node.append(.number(Double(value))) }
    func encode(_ value: Int16) { node.append(.number(Double(value))) }
    func encode(_ value: Int32) { node.append(.number(Double(value))) }
    func encode(_ value: Int64) { node.append(.number(Double(value))) }
    func encode(_ value: UInt) { node.append(.number(Double(value))) }
    func encode(_ value: UInt8) { node.append(.number(Double(value))) }
    func encode(_ value: UInt16) { node.append(.number(Double(value))) }
    func encode(_ value: UInt32) { node.append(.number(Double(value))) }
    func encode(_ value: UInt64) { node.append(.number(Double(value))) }
    func encode<T: Encodable>(_ value: T) throws { node.append(try EncodeNode.encode(value, path: path)) }

    func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = EncodeNode(path: path)
        node.deferIndex(child)
        return child.container(keyedBy: keyType)
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = EncodeNode(path: path)
        node.deferIndex(child)
        return child.unkeyedContainer()
    }

    func superEncoder() -> Encoder {
        let child = EncodeNode(path: path)
        node.deferIndex(child)
        return child
    }
}

// MARK: - Writing JSON text

extension JSONValue {
    /// Compact UTF-8 JSON text, object keys in no particular order. Non-finite numbers, which
    /// `JSONValueEncoder` never produces, are written as `null`.
    public var utf8: Data {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        Self.write(self, to: &out)
        return Data(out)
    }

    private static func write(_ v: JSONValue, to out: inout [UInt8]) {
        switch v {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: b ? "true".utf8 : "false".utf8)
        case .number(let d): writeNumber(d, to: &out)
        case .string(let s): writeString(s, to: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (i, e) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                write(e, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            var first = true
            for (k, e) in o {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                writeString(k, to: &out)
                out.append(UInt8(ascii: ":"))
                write(e, to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeNumber(_ d: Double, to out: inout [UInt8]) {
        guard d.isFinite else { out.append(contentsOf: "null".utf8); return }
        // Integers up to 2^53 as integers; the rest in Swift's shortest round-tripping form.
        if d == d.rounded(.towardZero), abs(d) < 9_007_199_254_740_992 {
            var n = Int64(d)
            if n == 0 { out.append(UInt8(ascii: "0")); return }
            if n < 0 { out.append(UInt8(ascii: "-")); n = -n }
            var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &digits) { buf in
                var k = buf.count
                while n > 0 { k -= 1; buf[k] = UInt8(ascii: "0") + UInt8(n % 10); n /= 10 }
                out.append(contentsOf: buf[k...])
            }
            return
        }
        out.append(contentsOf: d.description.utf8)
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private static func writeString(_ s: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var s = s
        s.withUTF8 { bytes in
            var run = 0
            for (i, b) in bytes.enumerated() {
                guard b < 0x20 || b == UInt8(ascii: "\"") || b == UInt8(ascii: "\\") else { continue }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[run..<i]))
                run = i + 1
                out.append(UInt8(ascii: "\\"))
                switch b {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"): out.append(b)
                case 0x0A: out.append(UInt8(ascii: "n"))
                case 0x0D: out.append(UInt8(ascii: "r"))
                case 0x09: out.append(UInt8(ascii: "t"))
                default: out.append(contentsOf: [UInt8(ascii: "u"), 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0xF)]])
                }
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[run...]))
        }
        out.append(UInt8(ascii: "\""))
    }
}
