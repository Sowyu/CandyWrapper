import Foundation

/// A TOML value as read, for `~/.codex/config.toml`. Tables keep their keys in file order.
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    /// Offset and local dates and times, kept as written.
    case datetime(String)
    case array([TOMLValue])
    case table([(key: String, value: TOMLValue)])

    public static func == (a: TOMLValue, b: TOMLValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): x == y
        case (.integer(let x), .integer(let y)): x == y
        case (.float(let x), .float(let y)): x == y || (x.isNaN && y.isNaN)
        case (.bool(let x), .bool(let y)): x == y
        case (.datetime(let x), .datetime(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.table(let x), .table(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    public subscript(key: String) -> TOMLValue? {
        guard case .table(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var arrayValue: [TOMLValue]? { if case .array(let a) = self { a } else { nil } }
    public var tableKeys: [String]? { if case .table(let p) = self { p.map(\.key) } else { nil } }
}

/// A TOML file edited line by line: every edit touches only the lines it must, so comments, blank lines, key order and
/// the spelling of untouched values survive byte for byte. Reading goes through a full TOML 1.0 parse.
public struct TOMLDocument: Sendable {
    /// The current text. Edits keep the file's line ending (`\n` or `\r\n`) and whether it ended with a newline.
    public private(set) var text: String

    /// Parses `text`; throws `AgentConfigError.unreadable` with the line of the first error, so an invalid file is
    /// never edited.
    public init(_ text: String) throws {
        fatalError("TODO")
    }

    /// The whole document as one root table.
    public var root: TOMLValue { fatalError("TODO") }

    /// The value at a dotted path such as `["mcp_servers", "github", "enabled"]`, wherever the file defined it: a
    /// `[table]` header, a dotted key or an inline table.
    public func value(at path: [String]) -> TOMLValue? { fatalError("TODO") }

    // MARK: Standard tables

    /// Whether `[path]` exists as its own header line, like `[mcp_servers.github]` or `[mcp_servers."my server"]`.
    /// A table defined only by an inline table or dotted keys answers false, and the editors below throw
    /// `AgentConfigError.cannotEdit` for it.
    public func hasHeader(_ path: [String]) -> Bool { fatalError("TODO") }

    /// Sets `key = literal` in the `[path]` table. Replaces the value on its existing line (keeping any trailing
    /// comment and the indentation), or inserts a new line after the table's last key/value line. `literal` is
    /// already TOML (`false`, `"text"`), see `TOMLDocument.literal`.
    public mutating func set(_ key: String, to literal: String, inTable path: [String]) throws { fatalError("TODO") }

    /// Removes the `key` line from the `[path]` table; no-op when absent.
    public mutating func remove(_ key: String, inTable path: [String]) throws { fatalError("TODO") }

    /// Appends a new `[path]` table with these `key = literal` lines at the end of the file, after one blank line.
    /// Throws `cannotEdit` when the table already exists in any form.
    public mutating func appendTable(_ path: [String], entries: [(key: String, literal: String)]) throws { fatalError("TODO") }

    /// Removes `[path]` and every table under it (`[path.env]` and so on): their header lines and every line up to
    /// the next header that isn't one of them. Comment lines directly above a removed header that belong to no other
    /// table stay. No-op when absent.
    public mutating func removeTable(_ path: [String]) throws { fatalError("TODO") }

    // MARK: Arrays of tables

    /// The entries of `[[path]]`, like `[[skills.config]]`, in file order.
    public func arrayOfTables(_ path: [String]) -> [TOMLValue] { fatalError("TODO") }

    /// Sets `key = literal` in the `index`th `[[path]]` entry, like `set(_:to:inTable:)`.
    public mutating func set(_ key: String, to literal: String, inArrayOfTables path: [String], index: Int) throws { fatalError("TODO") }

    /// Appends a new `[[path]]` entry with these lines at the end of the file, after one blank line.
    public mutating func appendArrayEntry(_ path: [String], entries: [(key: String, literal: String)]) throws { fatalError("TODO") }

    /// Removes the `index`th `[[path]]` entry: its header and its lines up to the next header.
    public mutating func removeArrayEntry(_ path: [String], index: Int) throws { fatalError("TODO") }

    // MARK: Literals

    /// A key as TOML writes it: bare when it's only `A-Za-z0-9_-`, otherwise a basic string with escapes.
    public static func key(_ key: String) -> String { fatalError("TODO") }
    /// A basic string literal with `"`, `\` and control characters escaped.
    public static func literal(_ string: String) -> String { fatalError("TODO") }
    public static func literal(_ bool: Bool) -> String { bool ? "true" : "false" }
    /// `["a", "b"]`
    public static func literal(_ strings: [String]) -> String { "[" + strings.map { literal($0) }.joined(separator: ", ") + "]" }
    /// `{ KEY = "value", "x-y" = "z" }`, keys through `key(_:)`.
    public static func inlineTable(_ pairs: [(key: String, value: String)]) -> String {
        pairs.isEmpty ? "{}" : "{ " + pairs.map { "\(key($0.key)) = \(literal($0.value))" }.joined(separator: ", ") + " }"
    }
}
