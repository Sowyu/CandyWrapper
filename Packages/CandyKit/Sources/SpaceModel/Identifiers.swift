import Foundation

/// A lowercase UUID v4. The aliases describe its role without changing its wire form.
public struct SpaceID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init() { rawValue = UUID().uuidString.lowercased() }
    public init(_ value: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value,
              value.utf8.count == 36, value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]) else {
            throw ModelError.invalidID(value)
        }
        rawValue = value
    }
    public var bytes: [UInt8] {
        var value = UUID(uuidString: rawValue)!.uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8) }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public typealias PageID = SpaceID
public typealias BlockID = SpaceID
public typealias RecordID = SpaceID
public typealias DeviceID = SpaceID
public typealias OpID = SpaceID

/// The position in recs is authenticated, so this stays an ordered pair in an array.
public struct RecordRevision: Codable, Hashable, Sendable {
    public var id: RecordID
    public var base: Int64?
    public init(id: RecordID, base: Int64?) { self.id = id; self.base = base }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        id = try c.decode(RecordID.self)
        guard !c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a base revision or null") }
        base = try c.decodeIfPresent(Int64.self)
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected [id, base]") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(id)
        if let base { try c.encode(base) } else { try c.encodeNil() }
    }
}
