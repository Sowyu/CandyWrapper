import AppKit

/// Token classes with pierre-light and pierre-dark colors, the Shiki themes T3 uses for chat code
/// blocks and diffs (`@pierre/diffs`, read from the installed app's app.asar, research note H section 5).
/// Each class is the color a representative TextMate scope resolves to in both theme files.
public enum CodeTokenKind: UInt8, Sendable, CaseIterable {
    case plain           // editor.foreground
    case comment         // comment
    case string          // string
    case constant        // constant.numeric, constant.language
    case keyword         // keyword.control, storage.modifier
    case storage         // storage.type, entity.name.type
    case function        // entity.name.function, support.function
    case variable        // variable.other.readwrite, variable.other.property
    case constantName    // variable.other.constant, variable.language (self, this)
    case parameter       // variable.parameter (Python), markup.bold, constant.other.color
    case parameterPlain  // variable.parameter (the generic rule)
    case `operator`      // keyword.operator.assignment, arithmetic, comparison; support.type.python
    case punctuation     // punctuation, keyword.operator (plain)
    case decorator       // entity.name.function.decorator
    case escape          // constant.character.escape
    case regex           // string.regexp
    case tag             // entity.name.tag, JSON and YAML keys, markup.heading
    case attribute       // entity.other.attribute-name
    case emphasis        // markup.italic, drawn italic

    /// sRGB hex per theme, from pierre-light.json and pierre-dark.json.
    var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .plain: (0x0a0a0a, 0xfafafa)
        case .comment: (0x737373, 0x737373)
        case .string: (0x199f43, 0x5ecc71)
        case .constant: (0x1ca1c7, 0x68cdf2)
        case .keyword, .emphasis: (0xd32a61, 0xff678d)
        case .storage: (0xa631be, 0xd568ea)
        case .function: (0x693acf, 0x9d6afb)
        case .variable: (0xd47628, 0xffa359)
        case .constantName: (0xd5901c, 0xffab16)
        case .parameter: (0xd5a910, 0xffd452)
        case .parameterPlain: (0x636363, 0xa3a3a3)
        case .operator: (0x08c0ef, 0x08c0ef)
        case .punctuation: (0x636363, 0x636363)
        case .decorator: (0x1a85d4, 0x69b1ff)
        case .escape: (0x16a994, 0x61d5c0)
        case .regex: (0x17a5af, 0x64d1db)
        case .tag: (0xd5512f, 0xff855e)
        case .attribute: (0x18a46c, 0x60d199)
        }
    }

    /// A color that follows the drawing appearance, so one layout serves both themes.
    public var color: NSColor { Self.colors[Int(rawValue)] }

    private static let colors: [NSColor] = allCases.map { kind in
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        let light = c(kind.hex.light), dark = c(kind.hex.dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

public struct CodeToken: Sendable, Equatable {
    /// UTF-16 range in the code string.
    public var range: NSRange
    public var kind: CodeTokenKind
}

/// A small native tokenizer per language family that approximates T3's Shiki grammars with the
/// pierre themes. Unknown languages render as plain text, as T3 does when a grammar fails to load.
// ponytail: hand-written lexers, not TextMate grammars; context-dependent scopes (TS parameters, Python
// f-string fields, embedded languages) differ from Shiki. Port a TextMate engine if users notice.
public enum CodeHighlighter {
    public static func tokens(_ code: String, language: String) -> [CodeToken] {
        guard let profile = Profile.named(language.lowercased()) else { return [] }
        var lexer = Lexer(Array(code.utf16), profile)
        lexer.run()
        return lexer.tokens
    }

    /// Whether `language` gets token colors.
    public static func supports(_ language: String) -> Bool { Profile.named(language.lowercased()) != nil }
}

// MARK: - Language profiles

private struct Profile {
    enum Family { case cLike, python, shell, json, yaml, toml, css, markup, diff, sql, markdown }
    var family: Family
    var lineComments: [String] = ["//"]
    var blockComment: (String, String)? = ("/*", "*/")
    var quotes: Set<UInt16> = [0x22, 0x27] // " '
    var keywords: Set<String> = []
    var storage: Set<String> = []
    var constants: Set<String> = ["true", "false", "null"]
    var constantNames: Set<String> = ["this", "self", "super"]
    /// Built-in type names and their color.
    var builtins: [String: CodeTokenKind] = [:]
    /// Color of identifiers that are not keywords, types or calls.
    var identifier: CodeTokenKind = .plain
    /// Color of `=`, `+`, `<` and friends.
    var operators: CodeTokenKind = .operator
    var punctuation: CodeTokenKind = .punctuation
    /// `@name`: decorator color (Python, TS) or keyword (Swift attributes).
    var at: CodeTokenKind? = nil
    var caseInsensitive = false

    static func named(_ id: String) -> Profile? {
        switch id {
        case "ts", "typescript", "tsx", "js", "javascript", "jsx", "mjs", "cjs", "mts", "cts": return .typescript
        case "swift": return .swift
        case "rust", "rs": return .rust
        case "go", "golang": return .go
        case "java", "kotlin", "kt", "c", "cpp", "c++", "h", "hpp", "cs", "csharp", "dart", "scala": return .genericC
        case "python", "py", "python3": return .python
        case "bash", "sh", "zsh", "shell", "shellscript", "console", "fish": return Profile(family: .shell, lineComments: ["#"], blockComment: nil)
        case "json", "jsonc", "json5", "jsonl": return Profile(family: .json, constants: ["true", "false"])
        case "yaml", "yml": return Profile(family: .yaml, lineComments: ["#"], blockComment: nil)
        case "toml", "ini", "gitignore": return Profile(family: .toml, lineComments: ["#", ";"], blockComment: nil)
        case "css", "scss", "less": return Profile(family: .css, lineComments: [])
        case "html", "xml", "svg", "vue", "svelte": return Profile(family: .markup, lineComments: [], blockComment: ("<!--", "-->"))
        case "diff", "patch": return Profile(family: .diff, lineComments: [], blockComment: nil)
        case "sql", "postgres", "postgresql", "mysql", "sqlite": return .sql
        case "markdown", "md", "mdx": return Profile(family: .markdown, lineComments: [], blockComment: nil)
        default: return nil
        }
    }

    static let typescript = Profile(
        family: .cLike, quotes: [0x22, 0x27, 0x60],
        keywords: ["import", "export", "from", "default", "return", "if", "else", "for", "while", "do", "switch", "case", "break",
                   "continue", "throw", "try", "catch", "finally", "await", "yield", "as", "satisfies", "in", "of", "new", "delete",
                   "typeof", "instanceof", "void", "async", "static", "private", "public", "protected", "readonly", "extends",
                   "implements", "declare", "abstract", "override", "keyof", "is"],
        storage: ["const", "let", "var", "function", "class", "interface", "type", "enum", "namespace", "module", "get", "set", "constructor"],
        constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        builtins: ["string": .storage, "number": .storage, "boolean": .storage, "any": .storage, "unknown": .storage,
                   "never": .storage, "object": .storage, "bigint": .storage, "symbol": .storage],
        identifier: .variable, at: .decorator)

    static let swift = Profile(
        family: .cLike, quotes: [0x22],
        keywords: ["import", "return", "if", "else", "guard", "for", "while", "repeat", "switch", "case", "default", "break",
                   "continue", "throw", "throws", "rethrows", "try", "catch", "do", "await", "async", "in", "where", "as", "is",
                   "public", "private", "fileprivate", "internal", "open", "final", "static", "override", "mutating", "lazy",
                   "weak", "unowned", "let", "var", "defer", "inout", "some", "any", "nonisolated", "isolated", "convenience", "required"],
        storage: ["func", "class", "struct", "enum", "protocol", "extension", "init", "deinit", "typealias", "actor", "subscript", "associatedtype"],
        constants: ["true", "false", "nil"],
        builtins: ["Int": .constantName, "Double": .constantName, "Float": .constantName, "Bool": .constantName,
                   "String": .constantName, "Character": .constantName, "UInt": .constantName, "Void": .constantName],
        operators: .punctuation, at: .keyword)

    static let rust = Profile(
        family: .cLike, quotes: [0x22],
        keywords: ["use", "pub", "fn", "return", "if", "else", "for", "while", "loop", "match", "break", "continue", "in", "as",
                   "mut", "ref", "move", "dyn", "impl", "where", "crate", "mod", "async", "await", "unsafe", "extern", "const", "static"],
        storage: ["let", "struct", "enum", "trait", "type", "union"],
        constants: ["true", "false"],
        builtins: ["i8": .storage, "i16": .storage, "i32": .storage, "i64": .storage, "i128": .storage, "isize": .storage,
                   "u8": .storage, "u16": .storage, "u32": .storage, "u64": .storage, "u128": .storage, "usize": .storage,
                   "f32": .storage, "f64": .storage, "bool": .storage, "char": .storage, "str": .storage, "self": .constantName,
                   "Self": .storage, "std": .constantName],
        identifier: .variable)

    static let go = Profile(
        family: .cLike, quotes: [0x22, 0x27, 0x60],
        keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break",
                   "continue", "go", "defer", "select", "chan", "map", "struct", "interface", "type", "var", "const", "fallthrough", "goto"],
        constants: ["true", "false", "nil", "iota"],
        builtins: ["int": .storage, "int8": .storage, "int16": .storage, "int32": .storage, "int64": .storage, "uint": .storage,
                   "uint8": .storage, "uint16": .storage, "uint32": .storage, "uint64": .storage, "float32": .storage,
                   "float64": .storage, "string": .storage, "bool": .storage, "byte": .storage, "rune": .storage, "error": .storage,
                   "any": .storage],
        identifier: .variable)

    static let genericC = Profile(
        family: .cLike,
        keywords: ["import", "package", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break",
                   "continue", "throw", "throws", "try", "catch", "finally", "new", "public", "private", "protected", "static",
                   "final", "abstract", "override", "const", "extern", "inline", "virtual", "namespace", "using", "include",
                   "define", "val", "var", "fun", "when", "is", "as", "in", "sealed", "data", "object", "companion"],
        storage: ["class", "struct", "enum", "interface", "typedef", "union", "void", "int", "long", "short", "char", "float",
                  "double", "bool", "boolean", "byte", "auto", "unsigned", "signed"],
        constants: ["true", "false", "null", "nullptr", "NULL"],
        identifier: .variable, at: .decorator)

    static let python = Profile(
        family: .python, lineComments: ["#"], blockComment: nil,
        keywords: ["import", "from", "as", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                   "try", "except", "finally", "raise", "with", "yield", "await", "async", "pass", "break", "continue",
                   "global", "nonlocal", "del", "assert", "match", "case"],
        storage: ["def", "class", "lambda"],
        constants: ["True", "False", "None"],
        constantNames: ["self", "cls"],
        builtins: ["str": .operator, "int": .operator, "float": .operator, "bool": .operator, "list": .operator,
                   "dict": .operator, "tuple": .operator, "set": .operator, "bytes": .operator, "object": .operator,
                   "print": .function, "len": .function, "range": .function, "open": .function, "isinstance": .function,
                   "enumerate": .function, "zip": .function, "sorted": .function, "super": .function, "type": .function],
        at: .decorator)

    static let sql = Profile(
        family: .sql, lineComments: ["--"],
        keywords: ["select", "from", "where", "and", "or", "not", "as", "group", "by", "order", "having", "limit", "offset",
                   "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "join",
                   "left", "right", "inner", "outer", "on", "union", "all", "distinct", "like", "in", "is", "null", "case",
                   "when", "then", "else", "end", "primary", "key", "foreign", "references", "index", "default", "asc", "desc",
                   "with", "returning", "exists", "between", "name"],
        constants: ["true", "false"],
        punctuation: .plain, caseInsensitive: true)
}

// MARK: - Lexer

private struct Lexer {
    let s: [UInt16]
    let p: Profile
    var i = 0
    var tokens: [CodeToken] = []

    init(_ s: [UInt16], _ p: Profile) { self.s = s; self.p = p }

    mutating func run() {
        switch p.family {
        case .cLike, .python, .sql: code()
        case .shell: shell()
        case .json: json()
        case .yaml, .toml: keyValue()
        case .css: css()
        case .markup: markup()
        case .diff: diff()
        case .markdown: markdown()
        }
    }

    // MARK: Helpers

    func at(_ k: Int = 0) -> UInt16 { i + k < s.count ? s[i + k] : 0 }
    func starts(_ str: String, at pos: Int? = nil) -> Bool {
        let pos = pos ?? i
        var j = pos
        for u in str.utf16 { guard j < s.count, s[j] == u else { return false }; j += 1 }
        return true
    }
    static func isIdentStart(_ c: UInt16) -> Bool { c == 0x5f || c == 0x24 || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c > 0x7f }
    static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }
    static let operatorChars: Set<UInt16> = Set("=+-*/%<>!&|^~?".utf16)
    static let punctuationChars: Set<UInt16> = Set("()[]{},;:.".utf16)

    mutating func emit(_ start: Int, _ end: Int, _ kind: CodeTokenKind) {
        guard end > start, kind != .plain else { return }
        if let last = tokens.last, last.kind == kind, last.range.upperBound == start {
            tokens[tokens.count - 1].range.length += end - start
        } else {
            tokens.append(CodeToken(range: NSRange(location: start, length: end - start), kind: kind))
        }
    }
    func word(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF16.self) }
    mutating func skipToLineEnd() { while i < s.count, s[i] != 0x0a { i += 1 } }
    mutating func identifier() -> (Int, Int) { let a = i; while i < s.count, Self.isIdent(s[i]) { i += 1 }; return (a, i) }

    /// A quoted string from `i`, with escapes, ending at the closing quote or the line end.
    /// Template and f-string fields are left inside the string.
    mutating func string(quote: UInt16, multiline: Bool = false, triple: Bool = false, fields: Bool = false) {
        let a = i
        i += triple ? 3 : 1
        var segment = a
        while i < s.count {
            let c = s[i]
            if quote == 0x60, c == 0x24, at(1) == 0x7b { // template literal field: ${ and } as keywords, the expression lexed
                emit(segment, i, .string)
                emit(i, i + 2, .keyword)
                i += 2
                let b = i
                while i < s.count, s[i] != 0x7d { i += 1 }
                var inner = Lexer(Array(s[b..<i]), p)
                inner.code()
                for t in inner.tokens { emit(b + t.range.location, b + t.range.upperBound, t.kind) }
                if at() == 0x7d { emit(i, i + 1, .keyword); i += 1 }
                segment = i
                continue
            }
            if fields, c == 0x7b { // f-string field: braces in the placeholder color, the expression plain
                if at(1) == 0x7b { i += 2; continue }
                emit(segment, i, .string)
                emit(i, i + 1, .parameter)
                i += 1
                while i < s.count, s[i] != 0x7d, s[i] != quote, s[i] != 0x0a { i += 1 }
                if at() == 0x7d { emit(i, i + 1, .parameter); i += 1 }
                segment = i
                continue
            }
            if c == 0x5c, i + 1 < s.count { // backslash
                emit(segment, i, .string)
                emit(i, i + 2, .escape)
                i += 2; segment = i
                continue
            }
            if triple ? (c == quote && at(1) == quote && at(2) == quote) : c == quote { i += triple ? 3 : 1; break }
            if c == 0x0a && !multiline && !triple { break }
            i += 1
        }
        emit(segment, i, .string)
    }

    mutating func number() {
        let a = i
        if at() == 0x30, at(1) == 0x78 || at(1) == 0x58 { i += 2 } // 0x
        while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2e && Self.isDigit(at(1)) { i += 1 }
        emit(a, i, .constant)
    }

    // MARK: C-like, Python, SQL

    mutating func code() {
        var lastWord = ""
        var fString = false
        // Parameter lists of a definition (`def f(`, `function f(`, `func f(`, `fn f(`).
        var paramsPending = false
        var paramDepth = 0
        var genericDepth = 0
        var lastSignificant: UInt16 = 0
        while i < s.count {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if let comment = p.lineComments.first(where: { starts($0) }) {
                _ = comment
                let a = i; skipToLineEnd(); emit(a, i, .comment); continue
            }
            if let (open, close) = p.blockComment, starts(open) {
                let a = i; i += open.utf16.count
                while i < s.count, !starts(close) { i += 1 }
                i = min(s.count, i + close.utf16.count)
                emit(a, i, .comment); continue
            }
            if p.quotes.contains(c) {
                // Rust lifetimes ('a) are not strings.
                if c == 0x27, p.storage.contains("trait"), !starts("'\\"), at(2) != 0x27 {
                    i += 1; continue
                }
                if p.family == .python, (c == 0x22 || c == 0x27), at(1) == c, at(2) == c {
                    string(quote: c, triple: true, fields: fString); fString = false; lastSignificant = c; continue
                }
                let a = i
                string(quote: c, multiline: c == 0x60, fields: fString); fString = false; lastSignificant = c
                if c == 0x60 { // template literal: the backticks are punctuation
                    replace(a, a + 1, with: .punctuation)
                    if i > a + 1, s[i - 1] == 0x60 { replace(i - 1, i, with: .punctuation) }
                }
                continue
            }
            if Self.isDigit(c) { number(); continue }
            if c == 0x40, let kind = p.at, Self.isIdentStart(at(1)) { // @decorator
                let a = i; i += 1; _ = identifier()
                while at() == 0x2e, Self.isIdentStart(at(1)) { i += 1; _ = identifier() }
                emit(a, i, kind); continue
            }
            if Self.isIdentStart(c) {
                // Python string prefixes: f"...", r'...', b"..."
                if p.family == .python, p.quotes.contains(at(1)), "fFrRbBuU".utf16.contains(c) {
                    fString = c == 0x66 || c == 0x46
                    emit(i, i + 1, .storage); i += 1; continue
                }
                let (a, b) = identifier()
                var name = word(a, b)
                if p.caseInsensitive { name = name.lowercased() }
                let next = nextNonSpace()
                let afterDot = a > 0 && s[a - 1] == 0x2e
                let kind: CodeTokenKind
                if !afterDot && p.keywords.contains(name) { kind = .keyword }
                else if !afterDot && p.storage.contains(name) { kind = .storage }
                else if p.constants.contains(name) { kind = .constant }
                else if p.constantNames.contains(name) { kind = .constantName }
                else if let builtin = p.builtins[name] { kind = builtin }
                else if next == 0x28 || (next == 0x21 && p.storage.contains("trait")) { // call, or a Rust macro
                    if next == 0x21 { i += 1 }
                    kind = lastWord == "class" ? .storage : .function
                }
                else if p.family == .sql { kind = .plain }
                else if lastWord == "class" || lastWord == "struct" || lastWord == "interface" || lastWord == "enum" || lastWord == "type"
                            || lastWord == "protocol" || lastWord == "extends" || lastWord == "implements" || lastWord == "trait" { kind = .storage }
                else if let first = name.utf16.first, first >= 0x41, first <= 0x5a, p.family != .python || lastWord != "import" {
                    // Capitalized: a type. All-caps names (JSON, HTTP) read as constants in TS.
                    kind = name.count > 1 && name.uppercased() == name && p.identifier == .variable ? .constantName : .storage
                }
                else if lastWord == "const" { kind = .constantName }
                else if p.family == .python && (lastWord == "def") { kind = .function }
                else if paramDepth == 1, lastSignificant == 0x28 || lastSignificant == 0x2c { kind = p.family == .python ? .parameter : .parameterPlain }
                else { kind = p.identifier }
                if kind == .function, ["def", "function", "func", "fn"].contains(lastWord) { paramsPending = true }
                emit(a, i, kind)
                lastWord = name
                lastSignificant = s[i - 1]
                continue
            }
            if c == 0x2f, p.family == .cLike, p.quotes.contains(0x60), regexAllowed() { regex(); continue }
            if c == 0x3c, i > 0, Self.isIdent(s[i - 1]), Self.isIdentStart(at(1)) || at(1) == 0x5b || at(1) == 0x7b || at(1) == 0x28 {
                genericDepth += 1; emit(i, i + 1, .punctuation); i += 1; lastSignificant = c; continue // a type argument list
            }
            if c == 0x3e, genericDepth > 0, at(1) != 0x3d {
                genericDepth -= 1; emit(i, i + 1, .punctuation); i += 1; lastSignificant = c; continue
            }
            if Self.operatorChars.contains(c) {
                lastSignificant = c
                let a = i
                while i < s.count, Self.operatorChars.contains(s[i]) { i += 1 }
                let op = word(a, i)
                // Arrows and annotations are punctuation in the grammars.
                let plain = op == "->" || op == "=>" && p.family != .cLike || p.family == .python && paramDepth > 0
                emit(a, i, plain ? .punctuation : p.operators)
                continue
            }
            if Self.punctuationChars.contains(c) {
                if c == 0x28 { if paramsPending { paramsPending = false; paramDepth = 1 } else if paramDepth > 0 { paramDepth += 1 } }
                if c == 0x29, paramDepth > 0 { paramDepth -= 1 }
                lastSignificant = c
                emit(i, i + 1, p.punctuation); i += 1; continue
            }
            i += 1
        }
    }

    func nextNonSpace() -> UInt16 {
        var j = i
        while j < s.count, s[j] == 0x20 { j += 1 }
        return j < s.count ? s[j] : 0
    }

    /// A slash starts a regex after an operator, an opening bracket or a comma, never after a value.
    func regexAllowed() -> Bool {
        var j = i - 1
        while j >= 0, Self.isSpace(s[j]) { j -= 1 }
        guard j >= 0 else { return true }
        return "=(,:[!&|?{};".utf16.contains(s[j])
    }

    mutating func regex() {
        let a = i
        i += 1
        var inClass = false
        while i < s.count, s[i] != 0x0a {
            if s[i] == 0x5c { i += 2; continue }
            if s[i] == 0x5b { inClass = true } else if s[i] == 0x5d { inClass = false }
            else if s[i] == 0x2f, !inClass { i += 1; break }
            i += 1
        }
        emit(a, a + 1, .string)
        emit(a + 1, max(a + 1, i - 1), .regex)
        emit(max(a + 1, i - 1), i, .string)
        let f = i; while i < s.count, Self.isIdent(s[i]) { i += 1 }
        emit(f, i, .keyword)
    }

    // MARK: Shell

    mutating func shell() {
        var commandPosition = true
        let keywords: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case",
                                     "esac", "function", "export", "local", "return", "select", "time"]
        while i < s.count {
            let c = s[i]
            if c == 0x0a { commandPosition = true; i += 1; continue }
            if Self.isSpace(c) { i += 1; continue }
            if c == 0x23 { let a = i; skipToLineEnd(); emit(a, i, .comment); continue } // #
            if c == 0x22 { shellString(); commandPosition = false; continue }
            if c == 0x27 { string(quote: c, multiline: true); commandPosition = false; continue }
            if c == 0x24 { variable(); commandPosition = false; continue } // $
            if "|&;".utf16.contains(c) {
                let a = i; while i < s.count, "|&;".utf16.contains(s[i]) { i += 1 }
                emit(a, i, .punctuation); commandPosition = true; continue
            }
            if "<>()[]{}".utf16.contains(c) || (c == 0x32 && at(1) == 0x3e) {
                if c == 0x5b { commandPosition = false }
                let a = i; i += 1
                while i < s.count, "<>&12".utf16.contains(s[i]) { i += 1 }
                emit(a, i, .punctuation); continue
            }
            let a = i
            while i < s.count, !Self.isSpace(s[i]), !"|&;<>()$\"'".utf16.contains(s[i]) { i += 1 }
            if i == a { i += 1; continue }
            let w = word(a, i)
            if s[a] == 0x3d || w.contains("=") && commandPosition, let eq = w.firstIndex(of: "=") { // NAME=value
                let n = w.distance(from: w.startIndex, to: eq)
                emit(a, a + n, .variable); emit(a + n, a + n + 1, .operator); emit(a + n + 1, i, .string)
            } else if keywords.contains(w) {
                emit(a, i, .keyword)
                if w == "for" { // the loop variable
                    while i < s.count, s[i] == 0x20 { i += 1 }
                    let v = i; while i < s.count, Self.isIdent(s[i]) { i += 1 }
                    emit(v, i, .variable)
                    continue
                }
                commandPosition = w != "export" && w != "local" && w != "in" ? true : commandPosition
                if w == "export" || w == "local" || w == "for" { commandPosition = true }
                continue
            } else if commandPosition {
                emit(a, i, .function); commandPosition = false
            } else if s[a] == 0x2d { // -flag
                emit(a, i, w.count == 2 && p.family == .shell && previousIsTest(a) ? .operator : .parameter)
            } else {
                emit(a, i, .string)
            }
        }
    }

    func previousIsTest(_ a: Int) -> Bool {
        var j = a - 1
        while j >= 0, s[j] == 0x20 { j -= 1 }
        return j >= 0 && s[j] == 0x5b
    }

    mutating func variable() {
        let a = i
        if at(1) == 0x7b { // ${name}
            emit(i, i + 2, .punctuation); i += 2
            let b = i; while i < s.count, s[i] != 0x7d, s[i] != 0x0a { i += 1 }
            emit(b, i, .variable)
            if at() == 0x7d { emit(i, i + 1, .punctuation); i += 1 }
            return
        }
        i += 1
        while i < s.count, Self.isIdent(s[i]) || "?#@*!".utf16.contains(s[i]) && i == a + 1 { i += 1 }
        emit(a, i, .variable)
    }

    mutating func shellString() {
        var segment = i
        i += 1
        while i < s.count {
            if s[i] == 0x5c { i += 2; continue }
            if s[i] == 0x22 { i += 1; break }
            if s[i] == 0x24 { emit(segment, i, .string); variable(); segment = i; continue }
            i += 1
        }
        emit(segment, min(i, s.count), .string)
    }

    // MARK: JSON, YAML, TOML

    mutating func json() {
        while i < s.count {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if starts("//") { let a = i; skipToLineEnd(); emit(a, i, .comment); continue }
            if c == 0x22 {
                let a = i
                string(quote: c)
                if nextNonSpace() == 0x3a { replace(a, i, with: .tag) } // a key
                continue
            }
            if Self.isDigit(c) || c == 0x2d { number(); continue }
            if Self.isIdentStart(c) {
                let (a, b) = identifier()
                let w = word(a, b)
                emit(a, b, w == "null" ? .operator : p.constants.contains(w) ? .constant : .plain)
                continue
            }
            emit(i, i + 1, .punctuation); i += 1
        }
    }

    /// Re-colors a..<b, splitting the tokens it overlaps (a JSON key first lexed as a string, a backtick).
    mutating func replace(_ a: Int, _ b: Int, with kind: CodeTokenKind) {
        var out: [CodeToken] = []
        for t in tokens {
            let lo = t.range.location, hi = t.range.upperBound
            if hi <= a || lo >= b { out.append(t); continue }
            if lo < a { out.append(CodeToken(range: NSRange(location: lo, length: a - lo), kind: t.kind)) }
            if hi > b { out.append(CodeToken(range: NSRange(location: b, length: hi - b), kind: t.kind)) }
        }
        if kind != .plain { out.append(CodeToken(range: NSRange(location: a, length: b - a), kind: kind)) }
        tokens = out.sorted { $0.range.location < $1.range.location }
    }

    mutating func keyValue() {
        let yaml = p.family == .yaml
        var lineStart = true
        while i < s.count {
            let c = s[i]
            if c == 0x0a { lineStart = true; i += 1; continue }
            if Self.isSpace(c) { i += 1; continue }
            if p.lineComments.contains(where: { starts($0) }) { let a = i; skipToLineEnd(); emit(a, i, .comment); continue }
            if lineStart, c == 0x5b, !yaml { // [table]
                emit(i, i + 1, .punctuation); i += 1
                let a = i; while i < s.count, s[i] != 0x5d, s[i] != 0x0a { i += 1 }
                var j = a
                for k in a..<i where s[k] == 0x2e { emit(j, k, .function); j = k + 1 }
                emit(j, i, .function)
                if at() == 0x5d { emit(i, i + 1, .punctuation); i += 1 }
                lineStart = false; continue
            }
            if lineStart, c == 0x2d, at(1) == 0x20 { emit(i, i + 1, .punctuation); i += 1; continue } // list dash
            if lineStart {
                // key: value / key = value
                var j = i
                while j < s.count, s[j] != 0x0a, s[j] != (yaml ? 0x3a : 0x3d) { j += 1 }
                if j < s.count, s[j] != 0x0a, yaml ? (j + 1 >= s.count || Self.isSpace(s[j + 1])) : true {
                    var end = j; while end > i, s[end - 1] == 0x20 { end -= 1 }
                    let key = word(i, end)
                    emit(i, end, yaml ? (key == "on" || key == "true" || key == "false" ? .constant : .tag) : .variable)
                    emit(j, j + 1, yaml ? .punctuation : .punctuation)
                    i = j + 1; lineStart = false; continue
                }
                lineStart = false
            }
            if c == 0x22 || c == 0x27 { string(quote: c); continue }
            if "[]{},".utf16.contains(c) { emit(i, i + 1, .punctuation); i += 1; continue }
            // A scalar up to the line end, a comma or a bracket.
            let a = i
            while i < s.count, s[i] != 0x0a, !(yaml && "[]{},".utf16.contains(s[i]) && flowContext(a)), !(s[i] == 0x23 && i > a && s[i - 1] == 0x20) { i += 1 }
            if !yaml { while i < s.count, s[i] != 0x0a, !",]}".utf16.contains(s[i]) { i += 1 } }
            var end = i; while end > a, s[end - 1] == 0x20 { end -= 1 }
            let w = word(a, end)
            if ["true", "false", "null", "~"].contains(w) || Double(w) != nil { emit(a, end, .constant) }
            else { emit(a, end, yaml ? .string : .plain) }
        }
    }

    func flowContext(_ from: Int) -> Bool {
        var j = from - 1
        while j >= 0, s[j] != 0x0a { if s[j] == 0x5b || s[j] == 0x7b { return true }; j -= 1 }
        return false
    }

    // MARK: CSS

    mutating func css() {
        var depth = 0
        var inValue = false
        while i < s.count {
            let c = s[i]
            if Self.isSpace(c) { i += 1; continue }
            if starts("/*") { let a = i; while i < s.count, !starts("*/") { i += 1 }; i = min(s.count, i + 2); emit(a, i, .comment); continue }
            if c == 0x22 || c == 0x27 { string(quote: c); continue }
            if c == 0x7b { depth += 1; inValue = false; emit(i, i + 1, .punctuation); i += 1; continue }
            if c == 0x7d { depth = max(0, depth - 1); inValue = false; emit(i, i + 1, .punctuation); i += 1; continue }
            if c == 0x3b { inValue = false; emit(i, i + 1, .punctuation); i += 1; continue }
            if c == 0x40 { // @media
                emit(i, i + 1, .punctuation); i += 1
                let (a, b) = identifier(); emit(a, b, .keyword); continue
            }
            let declaration = depth > 0 && !inValue && isDeclarationAhead()
            if declaration {
                let a = i; while i < s.count, s[i] != 0x3a { i += 1 }
                emit(a, i, .operator); emit(i, i + 1, .punctuation); i += 1; inValue = true; continue
            }
            if inValue {
                if c == 0x23 { let a = i; i += 1; _ = identifier(); emit(a, i, .parameter); continue } // #hex
                if Self.isDigit(c) || c == 0x2e && Self.isDigit(at(1)) || c == 0x2d && Self.isDigit(at(1)) {
                    let a = i; i += 1
                    while i < s.count, Self.isDigit(s[i]) || s[i] == 0x2e { i += 1 }
                    emit(a, i, .constant)
                    let u = i; while i < s.count, Self.isIdentStart(s[i]) || s[i] == 0x25 { i += 1 }
                    emit(u, i, .tag); continue
                }
                if c == 0x21 { let a = i; i += 1; _ = identifier(); emit(a, i, .keyword); continue } // !important
                if c == 0x2d, at(1) == 0x2d { let a = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2d { i += 1 }; emit(a, i, .variable); continue }
                if Self.isIdentStart(c) {
                    let a = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2d { i += 1 }
                    emit(a, i, at() == 0x28 ? .function : .parameter); continue
                }
                emit(i, i + 1, .punctuation); i += 1; continue
            }
            // Selectors.
            if c == 0x2e || c == 0x23 || c == 0x3a { // .class #id :pseudo
                let kind: CodeTokenKind = c == 0x2e ? .attribute : c == 0x23 ? .function : .operator
                emit(i, i + 1, .punctuation); i += 1
                if c == 0x3a, at() == 0x3a { emit(i, i + 1, .punctuation); i += 1 }
                let a = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2d { i += 1 }
                emit(a, i, kind); continue
            }
            if Self.isIdentStart(c) { let a = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2d { i += 1 }; emit(a, i, .tag); continue }
            emit(i, i + 1, .punctuation); i += 1
        }
    }

    /// `name:` before the next `;` or `}` inside a rule body (not `a:hover` in a nested selector).
    func isDeclarationAhead() -> Bool {
        var j = i
        while j < s.count, Self.isIdent(s[j]) || s[j] == 0x2d { j += 1 }
        while j < s.count, s[j] == 0x20 { j += 1 }
        return j > i && j < s.count && s[j] == 0x3a
    }

    // MARK: HTML and XML

    mutating func markup() {
        while i < s.count {
            if starts("<!--") {
                let a = i; while i < s.count, !starts("-->") { i += 1 }; i = min(s.count, i + 3); emit(a, i, .comment); continue
            }
            if s[i] == 0x3c, at(1) == 0x2f || at(1) == 0x21 || Self.isIdentStart(at(1)) {
                let a = i; i += at(1) == 0x2f || at(1) == 0x21 ? 2 : 1
                emit(a, i, .punctuation)
                let n = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x2d || s[i] == 0x3a { i += 1 }
                emit(n, i, .tag)
                while i < s.count, s[i] != 0x3e {
                    if Self.isSpace(s[i]) { i += 1; continue }
                    if s[i] == 0x22 || s[i] == 0x27 { string(quote: s[i], multiline: true); continue }
                    if s[i] == 0x3d || s[i] == 0x2f { emit(i, i + 1, .punctuation); i += 1; continue }
                    let b = i; while i < s.count, !Self.isSpace(s[i]), !"=>/\"'".utf16.contains(s[i]) { i += 1 }
                    if i == b { i += 1 }
                    emit(b, i, .attribute)
                }
                if i < s.count { emit(i, i + 1, .punctuation); i += 1 }
                continue
            }
            if s[i] == 0x26 { // &amp;
                let a = i; i += 1
                emit(a, i, .punctuation)
                let b = i; while i < s.count, Self.isIdent(s[i]) || s[i] == 0x23 { i += 1 }
                emit(b, i, .tag)
                if at() == 0x3b { emit(i, i + 1, .punctuation); i += 1 }
                continue
            }
            i += 1
        }
    }

    // MARK: Diff and Markdown

    mutating func diff() {
        while i < s.count {
            let a = i
            skipToLineEnd()
            let line = word(a, i)
            if line.hasPrefix("+++") || line.hasPrefix("---") { emit(a, i, .function) }
            else if line.hasPrefix("@@") {
                emit(a, a + 2, .punctuation)
                if let close = line.dropFirst(2).range(of: "@@") {
                    let off = a + line.utf16.distance(from: line.utf16.startIndex, to: close.lowerBound.samePosition(in: line.utf16)!)
                    emit(off, off + 2, .punctuation)
                }
            }
            else if line.hasPrefix("+") { emit(a, a + 1, .punctuation); emit(a + 1, i, .string) }
            else if line.hasPrefix("-") { emit(a, a + 1, .punctuation); emit(a + 1, i, .tag) }
            i += 1
        }
    }

    mutating func markdown() {
        var inFence = false
        while i < s.count {
            let a = i
            skipToLineEnd()
            let line = word(a, i)
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); emit(a, i, .punctuation); i += 1; continue }
            if inFence { emit(a, i, .string); i += 1; continue }
            if trimmed.hasPrefix("#") { emit(a, i, .tag); i += 1; continue }
            if trimmed.hasPrefix(">") { emit(a, a + 1, .punctuation); emit(a + 1, i, .comment); i += 1; continue }
            var j = a
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                j = a + line.utf16.count - trimmed.utf16.count
                emit(j, j + 1, .tag); j += 1
            }
            inline(from: j, to: i)
            i += 1
        }
    }

    mutating func inline(from start: Int, to end: Int) {
        var k = start
        func find(_ str: String, from: Int) -> Int? {
            var j = from
            while j < end { if starts(str, at: j) { return j }; j += 1 }
            return nil
        }
        while k < end {
            if starts("**", at: k), let close = find("**", from: k + 2) { emit(k, close + 2, .parameter); k = close + 2; continue }
            if s[k] == 0x2a || s[k] == 0x5f, k + 1 < end, !Self.isSpace(s[k + 1]), let close = find(String(UnicodeScalar(UInt8(s[k]))), from: k + 1) {
                emit(k, close + 1, .emphasis); k = close + 1; continue
            }
            if s[k] == 0x60, let close = find("`", from: k + 1) {
                emit(k, k + 1, .punctuation); emit(k + 1, close, .string); emit(close, close + 1, .punctuation); k = close + 1; continue
            }
            if s[k] == 0x5b, let close = find("](", from: k + 1), let paren = find(")", from: close + 2) {
                emit(k, k + 1, .punctuation); emit(k + 1, close, .function); emit(close, close + 1, .punctuation)
                emit(close + 1, close + 2, .tag); emit(close + 2, paren, .keyword); emit(paren, paren + 1, .tag)
                k = paren + 1; continue
            }
            k += 1
        }
    }
}
