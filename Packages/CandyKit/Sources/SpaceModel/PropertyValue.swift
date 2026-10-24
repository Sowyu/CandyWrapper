import Foundation

/// Props are untagged JSON. A string's field definition distinguishes text, URL and select.
/// Unknown shapes stay intact for a newer client; no schema lookup is needed to decode a page.
public enum PropertyValue: Codable, Hashable, Sendable {
    case string(String), number(Decimal), checkbox(Bool), multi([String]), date(DateValue)
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .unknown(.null) }
        else if let v = try? c.decode(Bool.self) { self = .checkbox(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String].self) { self = .multi(v) }
        else {
            let object = try c.decode(JSONValue.self)
            if case .object(let keys) = object, keys["start"] != nil { self = .date(try c.decode(DateValue.self)) }
            else { self = .unknown(object) }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .checkbox(let v): try c.encode(v)
        case .multi(let v): try c.encode(v)
        case .date(let v): try c.encode(v)
        case .unknown(let v): try c.encode(v)
        }
    }
}

extension PageRecord {
    public var isTodoList: Bool { fields[FieldID.done] != nil }
}
extension BlockRecord {
    public func validate() throws {
        guard (0...5).contains(indent) else { throw ModelError.invalidIndent }
        try text.validate()
    }
}

extension BoardViewSettings {
    public func validate() throws {
        guard sort.count <= 3 else { throw ModelError.invalidViewSettings }
    }
}
extension TableViewSettings {
    public func validate() throws {
        guard sort.count <= 3 else { throw ModelError.invalidViewSettings }
    }
}
extension TimetableViewSettings {
    public func validate() throws {
        guard days == 5 || days == 7, from >= 0, to <= 24, from < to else { throw ModelError.invalidViewSettings }
    }
}
extension FieldDefinition {
    public static func done(order: OrderKey) -> Self { Self(name: "Done", type: .checkbox, order: order) }
    public static func due(order: OrderKey) -> Self { Self(name: "Due", type: .date, order: order) }
}
