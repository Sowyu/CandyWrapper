import Foundation

/// JSON that keeps its keys in file order, so rewriting `~/.claude.json` or `~/.claude/settings.json` changes only the
/// keys CandyWrapper owns. Numbers keep their literal text.
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// The literal as written, like `1`, `-0.5` or `1e3`.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: OrderedJSON
        public init(key: String, value: OrderedJSON) { self.key = key; self.value = value }
    }
}

extension OrderedJSON {
    /// Parses strict JSON (RFC 8259, no comments or trailing commas). Duplicate keys keep every member in order.
    /// Throws `AgentConfigError.unreadable` with the line and column of the first error.
    public static func parse(_ text: String) throws -> OrderedJSON {
        fatalError("TODO")
    }

    /// The text `JSON.stringify(value, null, indent)` would write: `"key": value`, `{}` and `[]` when empty, strings
    /// escaped like JavaScript does (only `"`, `\`, and control characters; `/` and non-ASCII stay as they are). No
    /// trailing newline.
    public func serialized(indent: String = "  ") -> String {
        fatalError("TODO")
    }

    /// The indent of the first indented line in `text`: two spaces, four spaces or a tab. Two spaces when none.
    public static func detectIndent(_ text: String) -> String {
        fatalError("TODO")
    }

    /// The first member's value under `key` when this is an object.
    public subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let newValue {
                if let i = members.firstIndex(where: { $0.key == key }) { members[i].value = newValue }
                else { members.append(Member(key: key, value: newValue)) }
            } else {
                members.removeAll { $0.key == key }
            }
            self = .object(members)
        }
    }

    public var members: [Member]? { if case .object(let m) = self { m } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [OrderedJSON]? { if case .array(let a) = self { a } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
}
