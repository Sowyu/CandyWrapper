import Foundation

// One parse per frame: JSONSerialization builds the tree (no thrown errors on the happy path),
// `JSONValue(foundation:)` converts it with a type switch, and `JSONValueDecoder` reads typed
// models straight from the tree. A `JSONValue` field decoded this way takes its node in O(1).

extension JSONValue {
    /// Parses JSON text. Invalid JSON throws `DecodingError.dataCorrupted`, like `JSONDecoder`.
    public init(parsing data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "The given data was not valid JSON.", underlyingError: error))
        }
        self.init(foundation: object)
    }

    /// Converts a JSONSerialization tree. Booleans are the CFBoolean singletons; every other
    /// NSNumber becomes a Double, as `JSONDecoder` did for `JSONValue`.
    init(foundation object: Any) {
        let cf = object as AnyObject
        switch CFGetTypeID(cf) {
        case Self.dictionaryType:
            let d = unsafeDowncast(cf, to: NSDictionary.self)
            var o = [String: JSONValue](minimumCapacity: d.count)
            d.enumerateKeysAndObjects { k, v, _ in o[JSONValue.native(k as AnyObject)] = JSONValue(foundation: v) }
            self = .object(o)
        case Self.stringType:
            self = .string(JSONValue.native(cf))
        case Self.arrayType:
            let a = unsafeDowncast(cf, to: NSArray.self)
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for v in a { out.append(JSONValue(foundation: v)) }
            self = .array(out)
        case Self.booleanType:
            self = .bool(unsafeDowncast(cf, to: NSNumber.self).boolValue)
        case Self.numberType:
            self = .number(unsafeDowncast(cf, to: NSNumber.self).doubleValue)
        default:
            self = .null
        }
    }

    private static let dictionaryType = CFDictionaryGetTypeID()
    private static let stringType = CFStringGetTypeID()
    private static let arrayType = CFArrayGetTypeID()
    private static let booleanType = CFBooleanGetTypeID()
    private static let numberType = CFNumberGetTypeID()

    /// A native Swift string from a JSONSerialization string: bridged NSStrings hash and compare
    /// through CoreFoundation, native ones are fast, and up to 15 UTF-8 bytes are stored inline.
    /// The bytes are copied straight out of the CFString; going through `as String` and
    /// `makeContiguousUTF8` made a bridged string first and cost about twice as much.
    private static func native(_ object: AnyObject) -> String {
        let s = unsafeDowncast(object, to: CFString.self)
        let length = CFStringGetLength(s)
        // Eight-bit storage holds one byte per character; all below 0x80 it is ASCII, so UTF-8.
        // Counting by length, not by NUL, keeps an escaped \u0000 inside the string.
        if let p = CFStringGetCStringPtr(s, CFStringBuiltInEncodings.UTF8.rawValue) {
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: length)
            if !bytes.contains(where: { $0 >= 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        }
        var used: CFIndex = 0
        let range = CFRange(location: 0, length: length)
        CFStringGetBytes(s, range, CFStringBuiltInEncodings.UTF8.rawValue, 0, false, nil, 0, &used)
        return String(unsafeUninitializedCapacity: used) { buffer in
            CFStringGetBytes(s, range, CFStringBuiltInEncodings.UTF8.rawValue, 0, false, buffer.baseAddress, used, nil)
            return used
        }
    }

    /// Decodes a typed value from this tree, without a round trip through JSON text.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONValueDecoder().decode(T.self, from: self)
    }
}

/// Decodes `Decodable` types from a `JSONValue` with `JSONDecoder`'s default behavior: keys as
/// written, `Date` through its own Codable (deferredToDate), `URL` from a string, integers only
/// from numbers that convert exactly, `null` for a non-optional is `valueNotFound` (Bool: typeMismatch).
public struct JSONValueDecoder: Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try TreeDecoder(value, parent: nil, key: nil).unwrap(T.self, value, nil)
    }
}

/// One node being decoded. The coding path is rebuilt from the parent chain only when needed.
final class TreeDecoder: Decoder {
    let value: JSONValue
    private let parent: TreeDecoder?
    private let key: CodingKey?

    init(_ value: JSONValue, parent: TreeDecoder?, key: CodingKey?) {
        self.value = value
        self.parent = parent
        self.key = key
    }

    var codingPath: [CodingKey] {
        var path: [CodingKey] = []
        var node: TreeDecoder? = self
        while let n = node, let k = n.key { path.append(k); node = n.parent }
        return path.reversed()
    }

    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let o) = value else { throw mismatch([String: JSONValue].self, value, nil) }
        return KeyedDecodingContainer(KeyedTree<Key>(decoder: self, object: o))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let a) = value else { throw mismatch([JSONValue].self, value, nil) }
        return UnkeyedTree(decoder: self, array: a)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { self }

    // MARK: Leaves

    func path(_ key: CodingKey?) -> [CodingKey] { key.map { codingPath + [$0] } ?? codingPath }

    func mismatch(_ type: Any.Type, _ v: JSONValue, _ key: CodingKey?) -> DecodingError {
        if v == .null {
            return .valueNotFound(type, .init(codingPath: path(key), debugDescription: "Expected \(type) value but found null instead."))
        }
        return .typeMismatch(type, .init(codingPath: path(key), debugDescription: "Expected to decode \(type) but found \(v.kind) instead."))
    }

    func string(_ v: JSONValue, _ key: CodingKey?) throws -> String {
        if case .string(let s) = v { return s }
        throw mismatch(String.self, v, key)
    }

    func bool(_ v: JSONValue, _ key: CodingKey?) throws -> Bool {
        if case .bool(let b) = v { return b }
        // JSONDecoder reports a null Bool as typeMismatch, unlike every other leaf.
        throw DecodingError.typeMismatch(Bool.self, .init(codingPath: path(key), debugDescription: "Expected to decode Bool but found \(v.kind) instead."))
    }

    func double(_ v: JSONValue, _ key: CodingKey?) throws -> Double {
        if case .number(let d) = v { return d }
        throw mismatch(Double.self, v, key)
    }

    func float(_ v: JSONValue, _ key: CodingKey?) throws -> Float {
        let d = try double(v, key)
        let f = Float(d)
        guard f.isFinite || !d.isFinite else {
            throw DecodingError.dataCorrupted(.init(codingPath: path(key), debugDescription: "Number \(d) does not fit in Float."))
        }
        return f
    }

    // ponytail: numbers are Doubles, so integers past 2^53 lose precision; keep the NSNumber if an id or counter ever gets that big
    func integer<I: FixedWidthInteger>(_ type: I.Type, _ v: JSONValue, _ key: CodingKey?) throws -> I {
        guard case .number(let d) = v else { throw mismatch(I.self, v, key) }
        guard let i = I(exactly: d) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path(key), debugDescription: "Number \(d) does not fit in \(I.self)."))
        }
        return i
    }

    /// Decodes `v`, found under `key` of this node (or this node itself when `key` is nil).
    func unwrap<T: Decodable>(_ type: T.Type, _ v: JSONValue, _ key: CodingKey?) throws -> T {
        // Hot leaf types skip building a child decoder.
        if T.self == JSONValue.self { return v as! T }
        if T.self == String.self { return try string(v, key) as! T }
        if T.self == Bool.self { return try bool(v, key) as! T }
        if T.self == Int.self { return try integer(Int.self, v, key) as! T }
        if T.self == Double.self { return try double(v, key) as! T }
        if T.self == [JSONValue].self, case .array(let a) = v { return a as! T }
        if T.self == [String: JSONValue].self, case .object(let o) = v { return o as! T }
        if T.self == URL.self {
            guard let url = URL(string: try string(v, key)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path(key), debugDescription: "Invalid URL string."))
            }
            return url as! T
        }
        return try T(from: key.map { TreeDecoder(v, parent: self, key: $0) } ?? self)
    }
}

extension TreeDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool { value == .null }
    func decode(_ type: Bool.Type) throws -> Bool { try bool(value, nil) }
    func decode(_ type: String.Type) throws -> String { try string(value, nil) }
    func decode(_ type: Double.Type) throws -> Double { try double(value, nil) }
    func decode(_ type: Float.Type) throws -> Float { try float(value, nil) }
    func decode(_ type: Int.Type) throws -> Int { try integer(type, value, nil) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type, value, nil) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type, value, nil) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type, value, nil) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type, value, nil) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type, value, nil) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type, value, nil) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type, value, nil) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type, value, nil) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type, value, nil) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try unwrap(type, value, nil) }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    init(_ i: Int) { intValue = i }
    init?(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { nil }
    var stringValue: String { "Index \(intValue ?? 0)" }
}

private struct SuperKey: CodingKey {
    static let key = SuperKey()
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) {}
    init?(intValue: Int) { nil }
}

private struct KeyedTree<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: TreeDecoder
    let object: [String: JSONValue]

    var codingPath: [CodingKey] { decoder.codingPath }
    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    private func value(_ key: Key) throws -> JSONValue {
        guard let v = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: decoder.codingPath, debugDescription: "No value associated with key \(key.stringValue)."))
        }
        return v
    }

    private func get<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T {
        try decoder.unwrap(type, try value(key), key)
    }

    func decodeNil(forKey key: Key) throws -> Bool { try value(key) == .null }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decoder.bool(try value(key), key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decoder.string(try value(key), key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decoder.double(try value(key), key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decoder.float(try value(key), key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decoder.integer(type, try value(key), key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decoder.integer(type, try value(key), key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decoder.integer(type, try value(key), key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decoder.integer(type, try value(key), key) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try get(type, key) }

    // One lookup instead of the default contains + decodeNil + decode.
    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard let v = object[key.stringValue], v != .null else { return nil }
        return try decoder.unwrap(type, v, key)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try TreeDecoder(try value(key), parent: decoder, key: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try TreeDecoder(try value(key), parent: decoder, key: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        TreeDecoder(object["super"] ?? .null, parent: decoder, key: SuperKey.key)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        TreeDecoder(object[key.stringValue] ?? .null, parent: decoder, key: key)
    }
}

private struct UnkeyedTree: UnkeyedDecodingContainer {
    let decoder: TreeDecoder
    let array: [JSONValue]
    var currentIndex = 0

    init(decoder: TreeDecoder, array: [JSONValue]) {
        self.decoder = decoder
        self.array = array
    }

    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private mutating func next<T>(_ type: T.Type, _ read: (TreeDecoder, JSONValue, CodingKey) throws -> T) throws -> T {
        let key = IndexKey(currentIndex)
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(
                codingPath: decoder.path(key), debugDescription: "Unkeyed container is at end."))
        }
        let v = try read(decoder, array[currentIndex], key)
        currentIndex += 1
        return v
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, .init(
                codingPath: decoder.path(IndexKey(currentIndex)), debugDescription: "Unkeyed container is at end."))
        }
        if array[currentIndex] == .null { currentIndex += 1; return true }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try next(type) { try $0.bool($1, $2) } }
    mutating func decode(_ type: String.Type) throws -> String { try next(type) { try $0.string($1, $2) } }
    mutating func decode(_ type: Double.Type) throws -> Double { try next(type) { try $0.double($1, $2) } }
    mutating func decode(_ type: Float.Type) throws -> Float { try next(type) { try $0.float($1, $2) } }
    mutating func decode(_ type: Int.Type) throws -> Int { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next(type) { try $0.integer(type, $1, $2) } }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next(type) { try $0.unwrap(type, $1, $2) } }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try next(KeyedDecodingContainer<NestedKey>.self) { try TreeDecoder($1, parent: $0, key: $2).container(keyedBy: type) }
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try next(UnkeyedDecodingContainer.self) { try TreeDecoder($1, parent: $0, key: $2).unkeyedContainer() }
    }

    mutating func superDecoder() throws -> Decoder {
        try next(Decoder.self) { TreeDecoder($1, parent: $0, key: $2) }
    }
}

extension JSONValue {
    /// For error messages.
    var kind: String {
        switch self {
        case .null: "null"
        case .bool: "bool"
        case .number: "number"
        case .string: "a string"
        case .array: "an array"
        case .object: "a dictionary"
        }
    }
}
