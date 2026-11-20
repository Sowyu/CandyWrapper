import Foundation
import T3Protocol

/// The plain-text terminal tail of a command. Cursor moves rewrite a 64-line window, as in
/// shared/terminalOutput.ts:391-535. Partial escape sequences survive frame boundaries.
public struct CommandOutputBuffer: Sendable {
    private var lines: [[Character]] = [[]]
    private var settled = ""
    private var pending = ""
    private var row = 0, column = 0
    private var saved: (Int, Int)?
    public private(set) var truncated = false
    public private(set) var running = true
    public var text: String { settled + lines.map(Self.string).joined(separator: "\n") }
    /// The second cell of a wide character, which prints nothing.
    private static let wideTail: Character = "\u{0}"
    private static func string(_ line: [Character]) -> String { String(line.lazy.filter { $0 != wideTail }) }
    private static let limit = 64 * 1024
    public init() {}

    public mutating func apply(_ frame: CommandOutputFrame) {
        guard frame.kind == "replace" || frame.kind == "append" else { return }
        if frame.kind == "replace" { self = Self() }
        truncated = truncated || frame.truncated
        running = frame.running
        let input = Array(pending + frame.text)
        pending = ""
        var i = 0
        while i < input.count {
            let char = input[i]
            if char == "\u{1b}" {
                let start = i
                i += 1
                guard i < input.count else { pending = input.count - start <= 4096 ? String(input[start...]) : ""; break }
                if input[i] == "[" {
                    i += 1
                    let parameters = i
                    while i < input.count, !(input[i].asciiValue.map { (0x40...0x7e).contains($0) } ?? false) { i += 1 }
                    guard i < input.count else { pending = input.count - start <= 4096 ? String(input[start...]) : ""; break }
                    let args = String(input[parameters..<i]).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                    csi(input[i], args)
                } else if input[i] == "]" || input[i] == "P" || input[i] == "_" || input[i] == "^" {
                    i += 1
                    while i < input.count, input[i] != "\u{7}", !(input[i] == "\u{1b}" && i + 1 < input.count && input[i + 1] == "\\") { i += 1 }
                    guard i < input.count else { pending = String(input[start...].suffix(4096)); break }
                    if input[i] == "\u{1b}" { i += 1 }
                } else if input[i] == "7" { saved = (row, column) }
                else if input[i] == "8", let saved { move(saved.0, saved.1) }
            } else {
                switch char {
                case "\r": column = 0
                case "\n", "\r\n":
                    row += 1; column = 0
                    if row == lines.count { lines.append([]) }
                    while lines.count > 64 {
                        settled += Self.string(lines.removeFirst()) + "\n"
                        row -= 1
                        if let old = saved { saved = (max(0, old.0 - 1), old.1) }
                    }
                case "\u{8}": column = max(0, column - 1)
                case "\t": column = min(Self.limit, (column / 8 + 1) * 8)
                default:
                    let start = i
                    while i < input.count, input[i].unicodeScalars.first.map({ $0.value >= 32 && $0.value != 127 }) == true { i += 1 }
                    if i > start { write(Array(input[start..<i])); continue }
                }
            }
            i += 1
        }
        // Keep a bounded tail even when a command never emits a newline.
        let excess = text.count - Self.limit
        if excess > 0 {
            truncated = true
            var remaining = excess
            let removed = min(remaining, settled.count)
            settled = String(settled.dropFirst(removed)); remaining -= removed
            for index in lines.indices where remaining > 0 {
                let count = min(remaining, lines[index].count)
                lines[index].removeFirst(count); remaining -= count
                if index == row { column = max(0, column - count) }
            }
        }
    }

    /// `characterWidth` (4928 shared/src/terminalOutput.ts, #34332): marks and default-ignorable characters take no
    /// column, East Asian wide and fullwidth characters and emoji take two, so cursor moves land where the
    /// program meant and an overwrite never splits a character.
    // ponytail: the common wide blocks and emoji presentation, not the full EastAsianWidth table; use it if a script misaligns
    static func width(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.allSatisfy({ s in
            switch s.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .spacingMark, .format: return true
            default: return s.properties.isDefaultIgnorableCodePoint
            }
        }) { return 0 }
        if first.properties.isEmojiPresentation || scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch first.value {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1B000...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }

    private mutating func write(_ characters: [Character]) {
        var cells: [Character] = []
        cells.reserveCapacity(characters.count)
        for character in characters {
            switch Self.width(character) {
            case 0:
                // A lone mark joins the character before it.
                if let last = cells.popLast() { cells.append(Character(String(last) + String(character))) }
                else if column > 0, column <= lines[row].count, lines[row][column - 1] != Self.wideTail {
                    lines[row][column - 1] = Character(String(lines[row][column - 1]) + String(character))
                }
            case 2: cells += [character, Self.wideTail]
            default: cells.append(character)
            }
        }
        guard !cells.isEmpty else { return }
        if column > lines[row].count { lines[row] += Array(repeating: " ", count: column - lines[row].count) }
        let end = min(lines[row].count, column + cells.count)
        // An overwrite that cuts a wide character in half blanks the half left over.
        if column > 0, column < lines[row].count, lines[row][column] == Self.wideTail { lines[row][column - 1] = " " }
        if end < lines[row].count, lines[row][end] == Self.wideTail { lines[row][end] = " " }
        lines[row].replaceSubrange(column..<end, with: cells)
        column += cells.count
        if lines[row].count > Self.limit {
            let removed = lines[row].count - Self.limit
            lines[row].removeFirst(removed); column -= removed; truncated = true
            if let old = saved, old.0 == row { saved = (old.0, max(0, old.1 - removed)) }
        }
    }

    private mutating func move(_ r: Int, _ c: Int) {
        row = max(0, min(lines.count - 1, r)); column = max(0, min(Self.limit, c))
    }
    private mutating func eraseLine(_ mode: Int) {
        if mode == 2 { lines[row] = [] }
        else if mode == 1 {
            for index in 0..<min(column + 1, lines[row].count) { lines[row][index] = " " }
        } else if column < lines[row].count { lines[row].removeSubrange(column...) }
    }
    private mutating func csi(_ command: Character, _ parameters: [Int]) {
        let value = parameters.first ?? 0, amount = min(Self.limit, max(1, value))
        switch command {
        case "A": move(row - amount, column)
        case "B": move(row + amount, column)
        case "C", "a": move(row, column + amount)
        case "D": move(row, column - amount)
        case "E": move(row + amount, 0)
        case "F": move(row - amount, 0)
        case "G", "`": move(row, amount - 1)
        case "d": move(amount - 1, column)
        case "H", "f": move(amount - 1, min(Self.limit, max(1, parameters.count > 1 ? parameters[1] : 1)) - 1)
        case "K": eraseLine(value)
        case "J":
            if value == 2 || value == 3 {
                if value == 3 { settled = ""; truncated = true }
                lines = Array(repeating: [], count: lines.count)
            } else if value == 1 {
                for index in 0..<row { lines[index] = [] }; eraseLine(1)
            } else {
                eraseLine(0)
                for index in (row + 1)..<lines.count { lines[index] = [] }
            }
        case "s": saved = (row, column)
        case "u": if let saved { move(saved.0, saved.1) }
        default: break
        }
    }
}
