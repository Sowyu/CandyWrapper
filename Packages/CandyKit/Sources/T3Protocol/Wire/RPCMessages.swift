import Foundation

// Effect RPC JSON framing, docs/protocol.md section 2.3 and 2.6.
// Source: .repos/effect-smol/packages/effect/src/rpc/RpcMessage.ts.

/// Request ids are strings or numbers on the wire. The server echoes the id back with the
/// same JSON type and keys its ack latches by it, so an id must round-trip exactly.
public enum RPCRequestID: Hashable, Sendable, Codable, CustomStringConvertible {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) } else { self = .number(try c.decode(Int.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }

    public var description: String {
        switch self {
        case .string(let s): s
        case .number(let n): String(n)
        }
    }
}

/// `Request` frame. `headers` is an array of `[name, value]` pairs; clients send `[]`.
public struct RPCRequest: Codable, Sendable, Equatable {
    public var id: RPCRequestID
    public var tag: String
    public var payload: JSONValue
    public var headers: [[String]]
    public var traceId: String?
    public var spanId: String?
    public var sampled: Bool?

    public init(id: RPCRequestID, tag: String, payload: JSONValue, headers: [[String]] = []) {
        self.id = id
        self.tag = tag
        self.payload = payload
        self.headers = headers
    }
}

/// Client to server message.
public enum RPCClientMessage: Sendable, Equatable {
    case request(RPCRequest)
    case ack(RPCRequestID)
    case interrupt(RPCRequestID)
    case ping
    case eof
}

/// One node of `Exit.Failure.cause`.
public enum RPCCause: Sendable, Equatable {
    /// Expected, declared failure. `error` is a `_tag` object.
    case fail(RPCTypedError)
    /// Unexpected failure: unknown tag, payload decode failure, handler bug.
    case die(JSONValue)
    case interrupt(fiberId: Int?)
    /// A cause node this build doesn't know. Kept so a newer server can't break decoding.
    case unknown(JSONValue)
}

/// A typed RPC error from a `Fail` cause. Decode it by `tag`; `fields` keeps every key.
public struct RPCTypedError: Sendable, Equatable, Error {
    public let tag: String
    public let fields: [String: JSONValue]

    public init(tag: String, fields: [String: JSONValue]) {
        self.tag = tag
        self.fields = fields
    }

    /// `message`, else `detail`. protocol.md 2.6 says to show this to the user.
    public var message: String? { fields["message"]?.stringValue ?? fields["detail"]?.stringValue }

    /// Decodes the full error object (including `_tag`) as a concrete type.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        var object = fields
        object["_tag"] = .string(tag)
        return try JSONValue.object(object).decode(as: T.self)
    }
}

public enum RPCExit: Sendable, Equatable {
    case success(JSONValue)
    case failure([RPCCause])
}

/// Server to client message.
public enum RPCServerMessage: Sendable, Equatable {
    case chunk(requestId: RPCRequestID, values: [JSONValue])
    case exit(requestId: RPCRequestID, exit: RPCExit)
    /// Connection-level defect. The Effect client fails every pending request with it.
    case defect(JSONValue)
    case pong
    case clientProtocolError(JSONValue)
    /// A `_tag` this build doesn't know, including server-sent `Request`. Ignored.
    case unknown(JSONValue)
}

// MARK: - Frames

public enum RPCFrame {
    /// A text frame holds one message or an array of messages (RpcSerialization.ts:129-139).
    public static func decodeServer(_ data: Data) throws -> [RPCServerMessage] {
        try decodeMessages(data)
    }

    public static func decodeClient(_ data: Data) throws -> [RPCClientMessage] {
        try decodeMessages(data)
    }

    /// One message per frame. The server accepts both forms; single messages match the recordings.
    public static func encode(_ message: RPCClientMessage) throws -> Data {
        try encoder.encode(message)
    }

    public static func encode(_ message: RPCServerMessage) throws -> Data {
        try encoder.encode(message)
    }

    private static func decodeMessages<T: Decodable>(_ data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        let first = data.first { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        if first == UInt8(ascii: "[") { return try decoder.decode([T].self, from: data) }
        return [try decoder.decode(T.self, from: data)]
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

// MARK: - Codable

private enum TagKey: String, CodingKey { case _tag }

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension RPCClientMessage: Codable {
    private enum Keys: String, CodingKey { case _tag, requestId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: ._tag) {
        case "Request": self = .request(try RPCRequest(from: decoder))
        case "Ack": self = .ack(try c.decode(RPCRequestID.self, forKey: .requestId))
        case "Interrupt": self = .interrupt(try c.decode(RPCRequestID.self, forKey: .requestId))
        case "Ping": self = .ping
        case "Eof": self = .eof
        case let tag:
            throw DecodingError.dataCorruptedError(forKey: ._tag, in: c, debugDescription: "Unknown client message \(tag)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .request(let r):
            try c.encode("Request", forKey: ._tag)
            try r.encode(to: encoder)
        case .ack(let id):
            try c.encode("Ack", forKey: ._tag)
            try c.encode(id, forKey: .requestId)
        case .interrupt(let id):
            try c.encode("Interrupt", forKey: ._tag)
            try c.encode(id, forKey: .requestId)
        case .ping: try c.encode("Ping", forKey: ._tag)
        case .eof: try c.encode("Eof", forKey: ._tag)
        }
    }
}

extension RPCServerMessage: Codable {
    private enum Keys: String, CodingKey { case _tag, requestId, values, exit, defect, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: ._tag) {
        case "Chunk":
            self = .chunk(requestId: try c.decode(RPCRequestID.self, forKey: .requestId),
                          values: try c.decode([JSONValue].self, forKey: .values))
        case "Exit":
            self = .exit(requestId: try c.decode(RPCRequestID.self, forKey: .requestId),
                         exit: try c.decode(RPCExit.self, forKey: .exit))
        case "Defect": self = .defect(try c.decodeIfPresent(JSONValue.self, forKey: .defect) ?? .null)
        case "Pong": self = .pong
        case "ClientProtocolError": self = .clientProtocolError(try c.decodeIfPresent(JSONValue.self, forKey: .error) ?? .null)
        default: self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .chunk(let id, let values):
            try c.encode("Chunk", forKey: ._tag)
            try c.encode(id, forKey: .requestId)
            try c.encode(values, forKey: .values)
        case .exit(let id, let exit):
            try c.encode("Exit", forKey: ._tag)
            try c.encode(id, forKey: .requestId)
            try c.encode(exit, forKey: .exit)
        case .defect(let d):
            try c.encode("Defect", forKey: ._tag)
            try c.encode(d, forKey: .defect)
        case .pong: try c.encode("Pong", forKey: ._tag)
        case .clientProtocolError(let e):
            try c.encode("ClientProtocolError", forKey: ._tag)
            try c.encode(e, forKey: .error)
        case .unknown(let raw): try raw.encode(to: encoder)
        }
    }
}

extension RPCExit: Codable {
    private enum Keys: String, CodingKey { case _tag, value, cause }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: ._tag) {
        case "Success": self = .success(try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null)
        case "Failure": self = .failure(try c.decode([RPCCause].self, forKey: .cause))
        case let tag:
            throw DecodingError.dataCorruptedError(forKey: ._tag, in: c, debugDescription: "Unknown exit \(tag)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .success(let v):
            try c.encode("Success", forKey: ._tag)
            try c.encode(v, forKey: .value)
        case .failure(let causes):
            try c.encode("Failure", forKey: ._tag)
            try c.encode(causes, forKey: .cause)
        }
    }
}

extension RPCCause: Codable {
    private enum Keys: String, CodingKey { case _tag, error, defect, fiberId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: ._tag) {
        case "Fail": self = .fail(try c.decode(RPCTypedError.self, forKey: .error))
        case "Die": self = .die(try c.decodeIfPresent(JSONValue.self, forKey: .defect) ?? .null)
        case "Interrupt": self = .interrupt(fiberId: try c.decodeIfPresent(Int.self, forKey: .fiberId))
        default: self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .fail(let e):
            try c.encode("Fail", forKey: ._tag)
            try c.encode(e, forKey: .error)
        case .die(let d):
            try c.encode("Die", forKey: ._tag)
            try c.encode(d, forKey: .defect)
        case .interrupt(let fiberId):
            try c.encode("Interrupt", forKey: ._tag)
            if let fiberId { try c.encode(fiberId, forKey: .fiberId) } else { try c.encodeNil(forKey: .fiberId) }
        case .unknown(let raw): try raw.encode(to: encoder)
        }
    }
}

extension RPCTypedError: Codable {
    public init(from decoder: Decoder) throws {
        // A Fail `error` is normally a `_tag` object. Anything else is kept under `value`.
        let raw = try JSONValue(from: decoder)
        if case .object(var o) = raw, let tag = o["_tag"]?.stringValue {
            o["_tag"] = nil
            self.init(tag: tag, fields: o)
        } else {
            self.init(tag: "", fields: ["value": raw])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(tag, forKey: AnyKey("_tag"))
        for (k, v) in fields { try c.encode(v, forKey: AnyKey(k)) }
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    /// Encodes any Encodable to a JSONValue (for request payloads).
    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    // ponytail: decodes through an intermediate Data copy, decode chunk values straight from the frame if profiling shows this hot
    public func decode<T: Decodable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder().encode(self))
    }
}
