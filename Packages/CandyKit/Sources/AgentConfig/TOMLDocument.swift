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
        case (.table(let x), .table(let y)): x.count == y.count && zip(x, y).allSatisfy { TOMLKey.equal($0.key, $1.key) && $0.value == $1.value }
        default: false
        }
    }

    public subscript(key: String) -> TOMLValue? {
        guard case .table(let pairs) = self else { return nil }
        return pairs.first { TOMLKey.equal($0.key, key) }?.value
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

    private var lines: [TOMLSourceLine]
    private var parsed: TOMLParse
    private var lineEnding: String
    private var endedWithNewline: Bool

    /// Parses `text`; throws `AgentConfigError.unreadable` with the line of the first error, so an invalid file is
    /// never edited.
    public init(_ text: String) throws {
        var parser = TOMLParser(text)
        parsed = try parser.parse()
        self.text = text
        lines = TOMLSourceLine.split(text)
        lineEnding = lines.first { !$0.ending.isEmpty }?.ending ?? "\n"
        endedWithNewline = text.utf8.last == 0x0A
    }

    /// The whole document as one root table.
    public var root: TOMLValue { parsed.root }

    /// The value at a dotted path such as `["mcp_servers", "github", "enabled"]`, wherever the file defined it: a
    /// `[table]` header, a dotted key or an inline table.
    public func value(at path: [String]) -> TOMLValue? {
        path.reduce(Optional(root)) { $0?[$1] }
    }

    // MARK: Standard tables

    /// Whether `[path]` exists as its own header line, like `[mcp_servers.github]` or `[mcp_servers."my server"]`.
    /// A table defined only by an inline table or dotted keys answers false, and the editors below throw
    /// `AgentConfigError.cannotEdit` for it.
    public func hasHeader(_ path: [String]) -> Bool {
        parsed.headers.contains { !$0.isArray && TOMLKey.equal($0.path, path) }
    }

    /// Sets `key = literal` in the `[path]` table. Replaces the value on its existing line (keeping any trailing
    /// comment and the indentation), or inserts a new line after the table's last key/value line. `literal` is
    /// already TOML (`false`, `"text"`), see `TOMLDocument.literal`.
    public mutating func set(_ key: String, to literal: String, inTable path: [String]) throws {
        try set(key, to: literal, section: standardSection(path))
    }

    /// Removes the `key` line from the `[path]` table; no-op when absent.
    public mutating func remove(_ key: String, inTable path: [String]) throws {
        let section = try standardSection(path)
        if let statement = parsed.statements.first(where: { $0.section == section && TOMLKey.equal($0.key, [key]) }) {
            try replace(statement.lines, with: [])
        } else if parsed.headers[section].value[key] != nil {
            throw AgentConfigError.cannotEdit("The key is not a statement in this table's section")
        }
    }

    /// Appends a new `[path]` table with these `key = literal` lines at the end of the file, after one blank line.
    /// Throws `cannotEdit` when the table already exists in any form.
    public mutating func appendTable(_ path: [String], entries: [(key: String, literal: String)]) throws {
        guard !path.isEmpty, value(at: path) == nil,
              !parsed.headers.contains(where: { TOMLKey.equal($0.path, path) }) else {
            throw AgentConfigError.cannotEdit("The table already exists or its path is empty")
        }
        try append(path, entries: entries, isArray: false)
    }

    /// Removes `[path]` and every table under it (`[path.env]` and so on): their header lines and every line up to
    /// the next header that isn't one of them. Comment lines directly above a removed header that belong to no other
    /// table stay. No-op when absent.
    public mutating func removeTable(_ path: [String]) throws {
        guard !path.isEmpty else { throw AgentConfigError.cannotEdit("The root table has no header") }
        let sections = parsed.headers.indices.filter { TOMLKey.hasPrefix(parsed.headers[$0].path, path) }
        guard !sections.isEmpty else {
            if value(at: path) != nil { throw AgentConfigError.cannotEdit("The table has no header") }
            return
        }
        let ranges = sections.map { sectionRange($0) }
        try removeSections(ranges)
    }

    // MARK: Arrays of tables

    /// The entries of `[[path]]`, like `[[skills.config]]`, in file order.
    public func arrayOfTables(_ path: [String]) -> [TOMLValue] {
        parsed.headers.filter { $0.isArray && TOMLKey.equal($0.path, path) }.map(\.value)
    }

    /// Sets `key = literal` in the `index`th `[[path]]` entry, like `set(_:to:inTable:)`.
    public mutating func set(_ key: String, to literal: String, inArrayOfTables path: [String], index: Int) throws {
        try set(key, to: literal, section: arraySection(path, index: index))
    }

    /// Appends a new `[[path]]` entry with these lines at the end of the file, after one blank line.
    public mutating func appendArrayEntry(_ path: [String], entries: [(key: String, literal: String)]) throws {
        try append(path, entries: entries, isArray: true)
    }

    /// Removes the `index`th `[[path]]` entry: its header and its lines up to the next header.
    public mutating func removeArrayEntry(_ path: [String], index: Int) throws {
        let section = try arraySection(path, index: index)
        try removeSections([sectionRange(section)])
    }

    // MARK: Literals

    /// A key as TOML writes it: bare when it's only `A-Za-z0-9_-`, otherwise a basic string with escapes.
    public static func key(_ key: String) -> String {
        let bare = !key.isEmpty && key.unicodeScalars.allSatisfy {
            switch $0.value {
            case 65...90, 97...122, 48...57, 45, 95: true
            default: false
            }
        }
        return bare ? key : literal(key)
    }
    /// A basic string literal with `"`, `\` and control characters escaped.
    public static func literal(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\t": result += "\\t"
            case "\n": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
    public static func literal(_ bool: Bool) -> String { bool ? "true" : "false" }
    /// `["a", "b"]`
    public static func literal(_ strings: [String]) -> String { "[" + strings.map { literal($0) }.joined(separator: ", ") + "]" }
    /// `{ KEY = "value", "x-y" = "z" }`, keys through `key(_:)`.
    public static func inlineTable(_ pairs: [(key: String, value: String)]) -> String {
        pairs.isEmpty ? "{}" : "{ " + pairs.map { "\(key($0.key)) = \(literal($0.value))" }.joined(separator: ", ") + " }"
    }
}

private struct TOMLSourceLine: Sendable {
    var content: String
    var ending: String

    static func split(_ text: String) -> [Self] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        let ended = text.utf8.last == 0x0A
        if ended { parts.removeLast() }
        return parts.enumerated().map { index, part in
            let terminated = index < parts.count - 1 || ended
            if terminated && part.hasSuffix("\r") {
                return Self(content: String(part.dropLast()), ending: "\r\n")
            }
            return Self(content: part, ending: terminated ? "\n" : "")
        }
    }

    var blank: Bool { content.allSatisfy { $0 == " " || $0 == "\t" } }
}

extension TOMLDocument {
    private func standardSection(_ path: [String]) throws -> Int {
        let matches = parsed.headers.indices.filter { !parsed.headers[$0].isArray && TOMLKey.equal(parsed.headers[$0].path, path) }
        guard matches.count == 1 else {
            throw AgentConfigError.cannotEdit("The table needs a single, unambiguous header")
        }
        return matches[0]
    }

    private func arraySection(_ path: [String], index: Int) throws -> Int {
        let matches = parsed.headers.indices.filter { parsed.headers[$0].isArray && TOMLKey.equal(parsed.headers[$0].path, path) }
        guard matches.indices.contains(index) else { throw AgentConfigError.cannotEdit("Array-of-tables index is out of range") }
        return matches[index]
    }

    /// A section's header and statements. Comment and blank lines after its last statement stay: they usually sit
    /// above the next header and belong to it, and keeping a stray comment is better than losing one.
    private func sectionRange(_ section: Int) -> Range<Int> {
        var end = section + 1 < parsed.headers.count ? parsed.headers[section + 1].lines.lowerBound : lines.count
        let floor = parsed.statements.filter { $0.section == section }.map(\.lines.upperBound).max() ?? parsed.headers[section].lines.upperBound
        while end > floor {
            let line = lines[end - 1].content.trimmingCharacters(in: .whitespaces)
            guard line.isEmpty || line.hasPrefix("#") else { break }
            end -= 1
        }
        return parsed.headers[section].lines.lowerBound..<end
    }

    private mutating func set(_ key: String, to literal: String, section: Int) throws {
        try validate(literal)
        let statements = parsed.statements.filter { $0.section == section }
        if let statement = statements.first(where: { TOMLKey.equal($0.key, [key]) }) {
            try replace(statement.lines, with: [statement.prefix + literal + statement.suffix])
        } else {
            guard parsed.headers[section].value[key] == nil else {
                throw AgentConfigError.cannotEdit("The key is not a statement in this table's section")
            }
            let insertion = statements.last?.lines.upperBound ?? parsed.headers[section].lines.upperBound
            let indentation = statements.first?.indentation ?? ""
            try replace(insertion..<insertion, with: [indentation + Self.key(key) + " = " + literal])
        }
    }

    private func validate(_ literal: String) throws {
        do { try TOMLParser.validateLiteral(literal) }
        catch { throw AgentConfigError.cannotEdit("Invalid TOML literal: \(error)") }
    }

    private mutating func append(_ path: [String], entries: [(key: String, literal: String)], isArray: Bool) throws {
        guard !path.isEmpty else { throw AgentConfigError.cannotEdit("A header path cannot be empty") }
        for entry in entries { try validate(entry.literal) }
        let brackets = isArray ? ("[[", "]]") : ("[", "]")
        var contents: [String] = []
        if let last = lines.last, !last.blank { contents.append("") }
        contents.append(brackets.0 + path.map(Self.key).joined(separator: ".") + brackets.1)
        contents += entries.map { Self.key($0.key) + " = " + $0.literal }
        try replace(lines.count..<lines.count, with: contents, newlineForEmpty: true)
    }

    /// Apply a splice to a copy. Reparsing must succeed before any part of the document changes.
    private mutating func replace(_ range: Range<Int>, with contents: [String], newlineForEmpty: Bool = false) throws {
        var candidate = lines
        let inserted = contents.flatMap { $0.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }
            .map { TOMLSourceLine(content: $0, ending: lineEnding) }
        candidate.replaceSubrange(range, with: inserted)
        try commit(candidate, trailingNewline: endedWithNewline || (lines.isEmpty && newlineForEmpty))
    }

    private mutating func removeSections(_ ranges: [Range<Int>]) throws {
        var candidate = lines
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let previous = merged.last, previous.upperBound == range.lowerBound {
                merged[merged.count - 1] = previous.lowerBound..<range.upperBound
            } else { merged.append(range) }
        }
        // Work backwards so the recorded source locations stay valid throughout the splice.
        for range in merged.reversed() {
            candidate.removeSubrange(range)
            let point = range.lowerBound
            var start = point
            var end = point
            while start > 0 && candidate[start - 1].blank { start -= 1 }
            while end < candidate.count && candidate[end].blank { end += 1 }
            if end - start > 1 { candidate.removeSubrange((start + 1)..<end) }
        }
        try commit(candidate, trailingNewline: endedWithNewline)
    }

    private mutating func commit(_ candidate: [TOMLSourceLine], trailingNewline: Bool) throws {
        var candidate = candidate
        for index in candidate.indices where candidate[index].ending.isEmpty { candidate[index].ending = lineEnding }
        if !trailingNewline {
            // An empty final physical line would itself leave a trailing newline in the serialized text.
            while candidate.last?.content.isEmpty == true { candidate.removeLast() }
            if !candidate.isEmpty { candidate[candidate.count - 1].ending = "" }
        }
        let newText = candidate.map { $0.content + $0.ending }.joined()
        do {
            let originalLineEnding = lineEnding
            self = try TOMLDocument(newText)
            // Keep the detected style even when the edit removes every original line.
            lineEnding = originalLineEnding
        } catch {
            throw AgentConfigError.cannotEdit("The edit would produce invalid TOML: \(error)")
        }
    }
}
