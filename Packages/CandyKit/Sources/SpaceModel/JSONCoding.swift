import Foundation

/// Compact, deterministic JSON for the shared Mac and Android fixtures. Object keys sort;
/// array order, Unicode text, nulls and unknown values survive a read and write.
public enum SpaceJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Integers never pass through Double, including unknown values from a newer client.
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Decimal)
    case string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsigned(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public enum ModelError: Error, Equatable, Sendable {
    case invalidID(String), invalidOrderKey(String), noKeyBetween
    case invalidDate(String), invalidDateValue, invalidMark, invalidIndent, invalidViewSettings
}

struct ObjectKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

struct ObjectReader {
    let container: KeyedDecodingContainer<ObjectKey>
    init(_ decoder: Decoder) throws { container = try decoder.container(keyedBy: ObjectKey.self) }
    func required<T: Decodable>(_ key: String) throws -> T { try container.decode(T.self, forKey: ObjectKey(key)) }
    func optional<T: Decodable>(_ key: String) throws -> T? { try container.decodeIfPresent(T.self, forKey: ObjectKey(key)) }
    func nulls(_ keys: [String]) throws -> Set<String> {
        try Set(keys.filter { try container.contains(ObjectKey($0)) && container.decodeNil(forKey: ObjectKey($0)) })
    }
    func unknown(_ known: Set<String>) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            result[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return result
    }
}

struct ObjectWriter {
    var container: KeyedEncodingContainer<ObjectKey>
    init(_ encoder: Encoder, extra: [String: JSONValue], known: Set<String>) throws {
        container = encoder.container(keyedBy: ObjectKey.self)
        for (key, value) in extra where !known.contains(key) { try container.encode(value, forKey: ObjectKey(key)) }
    }
    mutating func required<T: Encodable>(_ value: T, _ key: String) throws { try container.encode(value, forKey: ObjectKey(key)) }
    mutating func optional<T: Encodable>(_ value: T?, _ key: String, nulls: Set<String>) throws {
        if let value { try container.encode(value, forKey: ObjectKey(key)) }
        else if nulls.contains(key) { try container.encodeNil(forKey: ObjectKey(key)) }
    }
}
