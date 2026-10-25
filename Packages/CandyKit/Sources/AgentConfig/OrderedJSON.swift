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
        var parser = OrderedJSONParser(text)
        return try parser.parse()
    }

    /// The text `JSON.stringify(value, null, indent)` would write: `"key": value`, `{}` and `[]` when empty, strings
    /// escaped like JavaScript does (only `"`, `\`, and control characters; `/` and non-ASCII stay as they are). No
    /// trailing newline.
    public func serialized(indent: String = "  ") -> String {
        var writer = OrderedJSONWriter(indent: String(decoding: indent.utf16.prefix(10), as: UTF16.self))
        writer.write(self, depth: 0)
        return String(decoding: writer.bytes, as: UTF8.self)
    }

    /// The indent of the first indented line in `text`: two spaces, four spaces or a tab. Two spaces when none.
    public static func detectIndent(_ text: String) -> String {
        for line in text.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }) {
            if line.first == 9 { return "\t" }
            if line.first == 32 {
                return line.prefix(while: { $0 == 32 }).count >= 4 ? "    " : "  "
            }
        }
        return "  "
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

private struct OrderedJSONParser {
    let bytes: [UInt8]
    var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func parse() throws -> OrderedJSON {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        let result = try value()
        skipWhitespace()
        guard index == bytes.count else { throw error("unexpected trailing content") }
        return result
    }

    func error(_ message: String) -> AgentConfigError {
        var line = 1
        var column = 1
        var previous: UInt8 = 0
        for byte in bytes.prefix(index) {
            if byte == 13 { line += 1; column = 1 }
            else if byte == 10 {
                if previous != 13 { line += 1 }
                column = 1
            } else if byte & 0xC0 != 0x80 { column += 1 }
            previous = byte
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), line == 1, index >= 3 { column -= 1 }
        return .unreadable(file: "", line: line, message: "\(message) at column \(column)")
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 32, 9, 10, 13: index += 1
            default: return
            }
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func value() throws -> OrderedJSON {
        guard index < bytes.count else { throw error("expected a value") }
        switch bytes[index] {
        case 123:
            index += 1
            skipWhitespace()
            var members: [OrderedJSON.Member] = []
            if consume(125) { return .object(members) }
            while true {
                guard index < bytes.count, bytes[index] == 34 else { throw error("expected an object key") }
                let key = try string()
                skipWhitespace()
                guard consume(58) else { throw error("expected ':'") }
                skipWhitespace()
                members.append(.init(key: key, value: try value()))
                skipWhitespace()
                if consume(125) { return .object(members) }
                guard consume(44) else { throw error("expected ',' or '}'") }
                skipWhitespace()
            }
        case 91:
            index += 1
            skipWhitespace()
            var elements: [OrderedJSON] = []
            if consume(93) { return .array(elements) }
            while true {
                elements.append(try value())
                skipWhitespace()
                if consume(93) { return .array(elements) }
                guard consume(44) else { throw error("expected ',' or ']'") }
                skipWhitespace()
            }
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return try number()
        default: throw error("unexpected '\(String(decoding: bytes[index...index], as: UTF8.self))'")
        }
    }

    mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard consume(byte) else { throw error("invalid literal") }
        }
    }

    mutating func number() throws -> OrderedJSON {
        let start = index
        _ = consume(45)
        if !consume(48) {
            guard index < bytes.count, (49...57).contains(bytes[index]) else { throw error("expected a digit") }
            index += 1
            digits()
        }
        if consume(46) {
            let start = index
            digits()
            guard index > start else { throw error("expected a fractional digit") }
        }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            let start = index
            digits()
            guard index > start else { throw error("expected an exponent digit") }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func digits() {
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
    }

    mutating func hexUnit() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw error("incomplete Unicode escape") }
            let digit: UInt8
            switch bytes[index] {
            case 48...57: digit = bytes[index] - 48
            case 65...70: digit = bytes[index] - 55
            case 97...102: digit = bytes[index] - 87
            default: throw error("invalid Unicode escape")
            }
            result = result * 16 + UInt32(digit)
            index += 1
        }
        return result
    }

    mutating func string() throws -> String {
        index += 1
        var result: [UInt8] = []
        var start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                result.append(contentsOf: bytes[start..<index])
                index += 1
                return String(decoding: result, as: UTF8.self)
            }
            guard byte >= 32 else { throw error("unescaped control character") }
            if byte != 92 { index += 1; continue }
            result.append(contentsOf: bytes[start..<index])
            index += 1
            guard index < bytes.count else { throw error("unterminated escape") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 34, 92, 47: result.append(escape)
            case 98: result.append(8)
            case 102: result.append(12)
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 117:
                var scalar = try hexUnit()
                if (0xD800...0xDBFF).contains(scalar) {
                    if index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 {
                        let nextEscape = index
                        index += 2
                        let low = try hexUnit()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + (scalar - 0xD800) * 0x400 + low - 0xDC00
                        } else {
                            index = nextEscape
                            scalar = 0xFFFD
                        }
                    } else { scalar = 0xFFFD }
                } else if (0xDC00...0xDFFF).contains(scalar) { scalar = 0xFFFD }
                result.append(contentsOf: String(Unicode.Scalar(scalar)!).utf8)
            default:
                index -= 1
                throw error("invalid string escape")
            }
            start = index
        }
        throw error("unterminated string")
    }
}

private struct OrderedJSONWriter {
    let indent: String
    var bytes: [UInt8] = []

    mutating func append(_ text: String) { bytes.append(contentsOf: text.utf8) }

    mutating func newline(_ depth: Int) {
        guard !indent.isEmpty else { return }
        bytes.append(10)
        for _ in 0..<depth { append(indent) }
    }

    mutating func string(_ text: String) {
        bytes.append(34)
        for byte in text.utf8 {
            switch byte {
            case 34: append("\\\"")
            case 92: append("\\\\")
            case 8: append("\\b")
            case 12: append("\\f")
            case 10: append("\\n")
            case 13: append("\\r")
            case 9: append("\\t")
            case 0...31:
                append("\\u00")
                let hex = Array("0123456789abcdef".utf8)
                bytes.append(hex[Int(byte / 16)])
                bytes.append(hex[Int(byte % 16)])
            default: bytes.append(byte)
            }
        }
        bytes.append(34)
    }

    mutating func write(_ value: OrderedJSON, depth: Int) {
        switch value {
        case .object(let members):
            bytes.append(123)
            for (index, member) in members.enumerated() {
                if index > 0 { bytes.append(44) }
                newline(depth + 1)
                string(member.key)
                append(indent.isEmpty ? ":" : ": ")
                write(member.value, depth: depth + 1)
            }
            if !members.isEmpty { newline(depth) }
            bytes.append(125)
        case .array(let elements):
            bytes.append(91)
            for (index, element) in elements.enumerated() {
                if index > 0 { bytes.append(44) }
                newline(depth + 1)
                write(element, depth: depth + 1)
            }
            if !elements.isEmpty { newline(depth) }
            bytes.append(93)
        case .string(let text): string(text)
        case .number(let text): append(text)
        case .bool(let value): append(value ? "true" : "false")
        case .null: append("null")
        }
    }
}
