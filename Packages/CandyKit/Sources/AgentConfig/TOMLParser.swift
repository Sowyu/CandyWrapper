import Foundation

/// TOML does not normalize Unicode key names. Swift String equality otherwise merges distinct spellings.
internal enum TOMLKey {
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    static func equal(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { equal($0, $1) }
    }

    static func hasPrefix(_ path: [String], _ prefix: [String]) -> Bool {
        path.count >= prefix.count && zip(path, prefix).allSatisfy { equal($0, $1) }
    }
}

/// Source locations refer to physical lines, including a statement's entire multi-line value.
internal struct TOMLStatement: Sendable {
    let section: Int?
    let key: [String]
    let lines: Range<Int>
    let prefix: String
    let suffix: String
    let indentation: String
}

internal struct TOMLHeader: Sendable {
    let path: [String]
    let isArray: Bool
    let lines: Range<Int>
    let value: TOMLValue
}

internal struct TOMLParse: Sendable {
    let root: TOMLValue
    let headers: [TOMLHeader]
    let statements: [TOMLStatement]
}

/// Mutable nodes stay inside the parser. Documents hold only immutable, Sendable snapshots.
private final class TOMLNode {
    enum Kind { case scalar, table, array, tableArray }
    enum Origin { case implicit, header, dotted, inline }
    let kind: Kind
    var origin: Origin
    var pairs: [(String, TOMLNode)] = []
    var elements: [TOMLNode] = []
    var scalar: TOMLValue?
    var sealed = false

    init(_ kind: Kind, origin: Origin = .implicit, scalar: TOMLValue? = nil) {
        self.kind = kind
        self.origin = origin
        self.scalar = scalar
    }

    subscript(_ key: String) -> TOMLNode? { pairs.first { TOMLKey.equal($0.0, key) }?.1 }

    var value: TOMLValue {
        switch kind {
        case .scalar: return scalar!
        case .table: return .table(pairs.map { (key: $0.0, value: $0.1.value) })
        case .array, .tableArray: return .array(elements.map(\.value))
        }
    }
}

/// TOML 1.0 grammar. The scanner normalizes CRLF only for parsing; edits use the original physical lines.
internal struct TOMLParser {
    private let input: [Unicode.Scalar]
    private var position = 0
    private var line = 0
    private var lineStart = 0
    private let root = TOMLNode(.table, origin: .header)
    private var statements: [TOMLStatement] = []
    private var headers: [(path: [String], isArray: Bool, lines: Range<Int>, node: TOMLNode)] = []

    init(_ text: String) {
        input = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)
    }

    mutating func parse() throws -> TOMLParse {
        var table = root
        var section: Int?
        while position < input.count {
            horizontalSpace()
            if take("\n") { continue }
            if peek == "#" { try comment(); continue }
            guard peek != nil else { break }
            let startLine = line
            let startOffset = lineStart
            let keyOffset = position
            if take("[") {
                let isArray = take("[")
                horizontalSpace()
                let path = try keyPath()
                try expect("]", "Expected ']' in table header")
                if isArray { try expect("]", "Expected ']]' in array-of-tables header") }
                table = try defineHeader(path, isArray: isArray, at: startLine)
                headers.append((path, isArray, startLine..<(line + 1), table))
                section = headers.count - 1
                try endStatement()
            } else {
                let path = try keyPath()
                try expect("=", "Expected '=' after key")
                horizontalSpace()
                let valueStart = position
                let node = try value()
                let valueEnd = position
                let endLine = line
                try assign(path, node: node, to: table, at: startLine)
                try endStatement()
                // endStatement consumes the final newline, but it is not part of the value's line range.
                var suffixEnd = valueEnd
                while suffixEnd < input.count && input[suffixEnd] != "\n" { suffixEnd += 1 }
                statements.append(TOMLStatement(
                    section: section, key: path, lines: startLine..<(endLine + 1),
                    prefix: string(startOffset..<valueStart), suffix: string(valueEnd..<suffixEnd),
                    indentation: string(startOffset..<keyOffset)
                ))
            }
        }
        return TOMLParse(
            root: root.value,
            headers: headers.map { TOMLHeader(path: $0.path, isArray: $0.isArray, lines: $0.lines, value: $0.node.value) },
            statements: statements
        )
    }

    /// Validate an editor argument as exactly one value, so it cannot introduce another statement or a comment.
    static func validateLiteral(_ text: String) throws {
        var parser = TOMLParser(text)
        parser.horizontalSpace()
        _ = try parser.value()
        parser.horizontalSpace()
        guard parser.position == parser.input.count else { throw parser.error("Expected one TOML value") }
    }

    private var peek: Unicode.Scalar? { position < input.count ? input[position] : nil }
    private func at(_ offset: Int) -> Unicode.Scalar? {
        position + offset < input.count ? input[position + offset] : nil
    }
    private func string(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(input[range])) }
    private func error(_ message: String, at errorLine: Int? = nil) -> AgentConfigError {
        .unreadable(file: "", line: (errorLine ?? line) + 1, message: message)
    }
    @discardableResult private mutating func advance() -> Unicode.Scalar? {
        guard let character = peek else { return nil }
        position += 1
        if character == "\n" { line += 1; lineStart = position }
        return character
    }
    private mutating func take(_ character: Unicode.Scalar) -> Bool {
        guard peek == character else { return false }
        advance()
        return true
    }
    private mutating func expect(_ character: Unicode.Scalar, _ message: String) throws {
        guard take(character) else { throw error(message) }
    }
    private mutating func horizontalSpace() {
        while peek == " " || peek == "\t" { advance() }
    }
    private mutating func comment() throws {
        while let character = peek, character != "\n" {
            guard !Self.control(character) else { throw error("Control character in comment") }
            advance()
        }
    }
    private mutating func endStatement() throws {
        horizontalSpace()
        if peek == "#" { try comment() }
        guard peek == nil || take("\n") else { throw error("Unexpected text after statement") }
    }
    private mutating func arraySpace() throws {
        while true {
            horizontalSpace()
            if take("\n") { continue }
            if peek == "#" { try comment(); continue }
            return
        }
    }
    private static func control(_ character: Unicode.Scalar) -> Bool {
        (character.value < 0x20 && character != "\t") || character.value == 0x7F
    }
    private static func bare(_ character: Unicode.Scalar) -> Bool {
        switch character.value {
        case 65...90, 97...122, 48...57, 45, 95: return true
        default: return false
        }
    }

    private mutating func keyPath() throws -> [String] {
        var result: [String] = []
        while true {
            horizontalSpace()
            if peek == "\"" || peek == "'" {
                result.append(try quotedString(allowMultiline: false))
            } else {
                let start = position
                while let character = peek, Self.bare(character) { advance() }
                guard position > start else { throw error("Expected a key") }
                result.append(string(start..<position))
            }
            horizontalSpace()
            if !take(".") { return result }
        }
    }

    private mutating func quotedString(allowMultiline: Bool = true) throws -> String {
        let startLine = line
        let quote = advance()!
        let basic = quote == "\""
        let multiline = allowMultiline && peek == quote && at(1) == quote
        if multiline { advance(); advance(); _ = take("\n") }
        var result = String.UnicodeScalarView()
        while let character = peek {
            if character == quote {
                var count = 0
                while at(count) == quote { count += 1 }
                if !multiline { advance(); return String(result) }
                if count >= 3 {
                    guard count <= 5 else { throw error("Too many closing quotes") }
                    for _ in 0..<(count - 3) { result.append(quote) }
                    for _ in 0..<count { advance() }
                    return String(result)
                }
                for _ in 0..<count { result.append(quote); advance() }
                continue
            }
            if basic && character == "\\" {
                advance()
                if multiline && (peek == " " || peek == "\t" || peek == "\n") {
                    horizontalSpace()
                    guard take("\n") else { throw error("A line-ending backslash must be followed by a newline") }
                    while peek == " " || peek == "\t" || peek == "\n" { advance() }
                    continue
                }
                guard let escape = advance() else { throw error("Unterminated string", at: startLine) }
                switch escape {
                case "b": result.append("\u{08}")
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "f": result.append("\u{0C}")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "u", "U":
                    let count = escape == "u" ? 4 : 8
                    var codepoint: UInt32 = 0
                    for _ in 0..<count {
                        guard let digit = peek, let number = Self.hex(digit) else { throw error("Invalid Unicode escape") }
                        codepoint = codepoint * 16 + number
                        advance()
                    }
                    guard let scalar = Unicode.Scalar(codepoint) else { throw error("Invalid Unicode scalar") }
                    result.append(scalar)
                default: throw error("Invalid string escape")
                }
                continue
            }
            if character == "\n" {
                guard multiline else { throw error("Unterminated string", at: startLine) }
            } else if Self.control(character) {
                throw error("Control character in string")
            }
            result.append(character)
            advance()
        }
        throw error("Unterminated string", at: startLine)
    }

    private static func hex(_ character: Unicode.Scalar) -> UInt32? {
        switch character.value {
        case 48...57: return character.value - 48
        case 65...70: return character.value - 65 + 10
        case 97...102: return character.value - 97 + 10
        default: return nil
        }
    }

    private mutating func value() throws -> TOMLNode {
        switch peek {
        case "\"", "'": return TOMLNode(.scalar, scalar: .string(try quotedString()))
        case "[":
            advance()
            let array = TOMLNode(.array)
            try arraySpace()
            if take("]") { return array }
            while true {
                array.elements.append(try value())
                try arraySpace()
                if take("]") { return array }
                try expect(",", "Expected ',' or ']' in array")
                try arraySpace()
                if take("]") { return array }
            }
        case "{":
            advance()
            let table = TOMLNode(.table, origin: .inline)
            horizontalSpace()
            if take("}") { table.sealed = true; return table }
            while true {
                let keyLine = line
                let key = try keyPath()
                try expect("=", "Expected '=' in inline table")
                horizontalSpace()
                let node = try value()
                try assign(key, node: node, to: table, at: keyLine)
                horizontalSpace()
                if take("}") { table.sealed = true; return table }
                try expect(",", "Expected ',' or '}' in inline table")
                horizontalSpace()
                // A trailing comma, comment or newline is not part of TOML 1.0 inline-table syntax.
                guard peek != "}" else { throw error("Trailing comma in inline table") }
            }
        default:
            let start = position
            while let character = peek, ![" ", "\t", "\n", ",", "]", "}", "#"].contains(character) { advance() }
            // RFC 3339 permits exactly one space in place of the date-time 'T'.
            if position - start == 10, peek == " ", Self.matches(string(start..<position), "[0-9]{4}-[0-9]{2}-[0-9]{2}"),
               let next = at(1), (48...57).contains(next.value) {
                advance()
                while let character = peek, ![" ", "\t", "\n", ",", "]", "}", "#"].contains(character) { advance() }
            }
            let token = string(start..<position)
            guard !token.isEmpty else { throw error("Expected a value") }
            return TOMLNode(.scalar, scalar: try atom(token))
        }
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }

    private func atom(_ token: String) throws -> TOMLValue {
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        switch token {
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        let digits = "[0-9](?:_?[0-9])*"
        let integer = "[+-]?(?:0|[1-9](?:_?[0-9])*)"
        let cleaned = token.replacingOccurrences(of: "_", with: "")
        if Self.matches(token, integer) {
            guard let number = Int64(cleaned) else { throw error("Integer is outside the signed 64-bit range") }
            return .integer(number)
        }
        for (prefix, radix, pattern) in [("0x", 16, "[0-9a-fA-F]"), ("0o", 8, "[0-7]"), ("0b", 2, "[01]")] {
            if Self.matches(token, prefix + pattern + "(?:_?" + pattern + ")*") {
                guard let number = Int64(cleaned.dropFirst(2), radix: radix) else { throw error("Integer is outside the signed 64-bit range") }
                return .integer(number)
            }
        }
        if Self.matches(token, integer + "(?:\\." + digits + "(?:[eE][+-]?" + digits + ")?|[eE][+-]?" + digits + ")") {
            guard let number = Double(cleaned) else { throw error("Invalid float") }
            return .float(number)
        }
        if try datetime(token) { return .datetime(token) }
        throw error("Invalid TOML value")
    }

    private func datetime(_ token: String) throws -> Bool {
        let date = "[0-9]{4}-[0-9]{2}-[0-9]{2}"
        let time = "[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?"
        let offset = "(?:[zZ]|[+-][0-9]{2}:[0-9]{2})"
        let hasDate = Self.matches(token, date + "(?:[tT ]" + time + offset + "?)?")
        let isTime = Self.matches(token, time)
        guard hasDate || isTime else { return false }
        let bytes = Array(token.utf8)
        func number(_ start: Int, _ count: Int = 2) -> Int {
            bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        if hasDate {
            let year = number(0, 4), month = number(5), day = number(8)
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...12).contains(month), (1...days[month - 1]).contains(day) else { throw error("Invalid calendar date") }
        }
        if isTime || bytes.count > 10 {
            let start = isTime ? 0 : 11
            guard number(start) <= 23, number(start + 3) <= 59, number(start + 6) <= 60 else { throw error("Invalid time") }
            if let offsetStart = bytes.indices.first(where: { $0 >= start + 8 && (bytes[$0] == 43 || bytes[$0] == 45) }) {
                guard number(offsetStart + 1) <= 23, number(offsetStart + 4) <= 59 else { throw error("Invalid UTC offset") }
            }
        }
        return true
    }

    private func assign(_ path: [String], node: TOMLNode, to table: TOMLNode, at startLine: Int) throws {
        var parent = table
        for key in path.dropLast() {
            guard !parent.sealed else { throw error("Cannot extend an inline table", at: startLine) }
            if let existing = parent[key] {
                guard existing.kind == .table, !existing.sealed,
                      existing.origin != .header else { throw error("Dotted key redefines a table or value", at: startLine) }
                parent = existing
                // An implicit super-table becomes defined when a dotted key addresses it.
                if parent.origin == .implicit { parent.origin = .dotted }
            } else {
                let child = TOMLNode(.table, origin: .dotted)
                parent.pairs.append((key, child))
                parent = child
            }
        }
        guard !parent.sealed, parent[path.last!] == nil else { throw error("Duplicate key or sealed inline table", at: startLine) }
        parent.pairs.append((path.last!, node))
    }

    private func defineHeader(_ path: [String], isArray: Bool, at startLine: Int) throws -> TOMLNode {
        var parent = root
        for key in path.dropLast() {
            guard !parent.sealed else { throw error("Cannot extend an inline table", at: startLine) }
            if let existing = parent[key] {
                if existing.kind == .tableArray, let last = existing.elements.last { parent = last }
                else if existing.kind == .table && !existing.sealed { parent = existing }
                else { throw error("Header conflicts with a value", at: startLine) }
            } else {
                let child = TOMLNode(.table)
                parent.pairs.append((key, child))
                parent = child
            }
        }
        guard !parent.sealed else { throw error("Cannot extend an inline table", at: startLine) }
        let key = path.last!
        if isArray {
            let array: TOMLNode
            if let existing = parent[key] {
                guard existing.kind == .tableArray else { throw error("Array-of-tables header conflicts with a table or value", at: startLine) }
                array = existing
            } else {
                array = TOMLNode(.tableArray)
                parent.pairs.append((key, array))
            }
            let entry = TOMLNode(.table, origin: .header)
            array.elements.append(entry)
            return entry
        }
        if let existing = parent[key] {
            guard existing.kind == .table, existing.origin == .implicit, !existing.sealed else {
                throw error("Table is already defined", at: startLine)
            }
            existing.origin = .header
            return existing
        }
        let child = TOMLNode(.table, origin: .header)
        parent.pairs.append((key, child))
        return child
    }
}
