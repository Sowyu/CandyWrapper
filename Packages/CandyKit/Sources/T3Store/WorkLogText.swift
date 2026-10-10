import Foundation
import T3Protocol

// Pure text helpers behind the timeline labels. Each is a port of the T3 function named in its
// doc comment; G-timeline-data.md sections 3 and 4 describe them.

extension String {
    /// JS `String.prototype.trim`.
    var jsTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// `.replace(/\s+/g, " ")` after a trim.
    var collapsedWhitespace: String { jsTrimmed.replacing(/\s+/, with: " ") }
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// `normalizeCompactToolLabel` (work-log/presentation.ts:113-115): drops a trailing
/// "complete"/"completed".
public func normalizeCompactToolLabel(_ value: String) -> String {
    value.replacing(/\s+(?:complete|completed)\s*$/.ignoresCase(), with: "").jsTrimmed
}

/// `formatDuration` (packages/shared/src/orchestrationTiming.ts:36-53).
public func formatDuration(_ ms: Double) -> String {
    guard ms.isFinite, ms >= 0 else { return "0ms" }
    if ms < 1_000 { return "\(max(1, Int(ms.rounded())))ms" }
    if ms < 10_000 {
        let tenths = (ms / 100).rounded() / 10
        return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
    }
    if ms < 60_000 { return "\(Int((ms / 1_000).rounded()))s" }
    let total = Int((ms / 1_000).rounded())
    let parts = [(total / 3_600, "h"), ((total % 3_600) / 60, "m"), (total % 60, "s")]
    return parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
}

/// `formatTokens` (packages/shared/src/usageFormat.ts:32-45): three significant figures with a
/// unit suffix, `en-US` grouping under 1000.
public func formatTokens(_ value: Double) -> String {
    func trim(_ v: Double) -> String {
        let digits = abs(v) >= 100 ? 0 : abs(v) >= 10 ? 1 : 2
        return String(format: "%.\(digits)f", v).replacing(/\.0+$/, with: "")
    }
    let a = abs(value)
    if a >= 1e12 { return trim(value / 1e12) + "T" }
    if a >= 1e9 { return trim(value / 1e9) + "B" }
    if a >= 1e6 { return trim(value / 1e6) + "M" }
    if a >= 1e3 { return trim(value / 1e3) + "K" }
    return String(Int(value.rounded()))
}

/// `formatCompactDiffCount` (apps/web/src/components/chat/DiffStatLabel.tsx:8-20).
public func formatCompactDiffCount(_ value: Int) -> String {
    func compact(_ scaled: Double, _ unit: String) -> String {
        scaled < 10 ? String(format: "%.1f", scaled).replacing(/\.0$/, with: "") + unit : "\(Int(scaled.rounded()))\(unit)"
    }
    if value < 1_000 { return String(value) }
    if value < 1_000_000 { return compact(Double(value) / 1_000, "k") }
    if value < 1_000_000_000 { return compact(Double(value) / 1_000_000, "m") }
    return compact(Double(value) / 1_000_000_000, "b")
}

/// `toolOutputIndicatesFailure` (packages/shared/src/toolOutput.ts:211-224): providers can
/// report completion while the output describes a failure.
/// One compiled ICU expression and Foundation's case-insensitive search: Swift Regex with
/// `ignoresCase()` was the hot spot of row derivation on long threads.
public func toolOutputIndicatesFailure(_ text: String) -> Bool {
    func has(_ phrase: String) -> Bool { text.range(of: phrase, options: .caseInsensitive) != nil }
    return failurePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        || (has("cannot find path") && has("because it does not exist"))
        || (has("is not recognized") && has("the term '"))
}

/// The single phrases and the three exit-code patterns of toolOutput.ts:211-224, as one alternation.
private let failurePattern = try! NSRegularExpression(pattern: [
    "file not found", "no files found", "enoent", "no such file", "commandnotfoundexception", "command not found",
    "is not recognized as the name of a cmdlet", "a parameter cannot be found that matches parameter name",
    #"<exited with exit code\s+[1-9]\d*\s*>"#, #"exit(?:ed)? with exit code\s+[1-9]\d*"#, #"exit code\s*[:\s]\s*[1-9]\d*\b"#,
].joined(separator: "|"), options: [.caseInsensitive])

/// `shouldCollapseUserMessage` (MessagesTimeline.logic.ts:2286-2311): long user messages clip
/// behind an expand control.
///
/// // ponytail: assistant citation chips are not replaced by their label first; port
/// `collectAssistantCitations` when user messages quote citations.
public func shouldCollapseUserMessage(_ text: String) -> Bool {
    let visible = text.replacing(/!?\[([^\]\n]*)\]\((?:<[^>\n]*>|[^\s)]*)\)/) { String($0.1) }
    guard !visible.jsTrimmed.isEmpty else { return false }
    return visible.utf16.count > 600 || visible.split(separator: "\n", omittingEmptySubsequences: false).count > 8
}

/// `liveThoughtLine` (work-log/presentation.ts:763-776): the first sentence of a reasoning
/// text, or its leading bold heading.
public func liveThoughtLine(_ markdown: String) -> String {
    let heading = markdown.prefixMatch(of: /\s*\*\*([^*\r\n]+)\*\*[ \t]*\r?(?:\n|$)/).map { String($0.1) }
    var text = heading ?? markdown
    text = text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.1) }
    text = text.replacing(/(?m)^[ \t]*(?:#{1,6}|[-*+]|\d+\.)[ \t]+/, with: "")
    text = text.replacing(/`+|\*\*|~~/, with: "")
    text = text.replacing(/(^|[^\w*])[*_]([^*_\n]+)[*_](?![\w*])/) { "\($0.1)\($0.2)" }
    text = text.collapsedWhitespace
    if heading != nil { return text }
    if let end = text.firstMatch(of: /[.?!]["'”’)]?(?=\s)/) { return String(text[..<end.range.upperBound]) }
    return text
}

// MARK: - Tool activity (packages/shared/src/toolActivity.ts)

/// `ToolActivityAction`.
enum ToolActivityAction { case command, read, fileChange, search, other }

/// `toolNameToken` (toolActivity.ts:220-227): server-prefixed MCP names are never local tools.
func toolNameToken(_ value: String?) -> String? {
    guard let trimmed = value?.jsTrimmed.nonEmpty, !trimmed.contains("__"), !trimmed.contains("."), !trimmed.contains("/")
    else { return nil }
    return trimmed.replacing(/[_\s-]/, with: "").lowercased()
}

/// `classifyToolActivity` (toolActivity.ts:229-304). First match wins.
func classifyToolActivity(itemType: String?, requestKind: String? = nil, data: JSONValue?) -> ToolActivityAction {
    let requestKind = requestKind?.jsTrimmed.nonEmpty?.lowercased()
    let kind = data?["kind"]?.stringValue?.jsTrimmed.nonEmpty?.lowercased()
    let toolName = toolNameToken(data?["toolName"]?.stringValue?.jsTrimmed.nonEmpty ?? data?["item"]?["tool"]?.stringValue?.jsTrimmed.nonEmpty)
    switch itemType {
    case "command_execution": return .command
    case "image_view": return .read
    case "file_change": return .fileChange
    case "web_search": return .search
    default: break
    }
    if requestKind == "command" || kind == "execute" { return .command }
    if requestKind == "file-change" || ["edit", "move", "delete", "write"].contains(kind) { return .fileChange }
    if kind == "search" || ["find", "grep", "glob", "rg", "ls"].contains(toolName) { return .search }
    if requestKind == "file-read" || kind == "read" { return .read }
    if ["terminal", "bash", "shell"].contains(toolName) { return .command }
    if toolName == "read" || toolName == "readfile" { return .read }
    return .other
}

/// `collectToolFilePaths` (toolActivity.ts:121-165): structured paths from tool input, depth 4,
/// at most 8, never file bodies.
func collectToolFilePaths(_ data: JSONValue?) -> [String] {
    var paths: [String] = []
    var seen = Set<String>()
    func collect(_ value: JSONValue?, _ depth: Int) {
        guard depth <= 4, paths.count < 8, let value else { return }
        if case .array(let entries) = value {
            for entry in entries {
                collect(entry, depth + 1)
                if paths.count >= 8 { return }
            }
            return
        }
        guard case .object(let record) = value else { return }
        for key in ["path", "filePath", "file_path", "relativePath", "filename", "fileName", "newPath", "oldPath"] {
            guard let candidate = record[key]?.stringValue?.jsTrimmed.nonEmpty, !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            paths.append(candidate)
            if paths.count >= 8 { return }
        }
        for key in ["locations", "item", "input", "result", "rawInput", "data", "changes"] where record[key] != nil {
            collect(record[key], depth + 1)
            if paths.count >= 8 { return }
        }
    }
    collect(data, 0)
    return paths
}

/// `formatSearchToolLabel` (toolActivity.ts:340-364): "Searched files *.ts in web".
func formatSearchToolLabel(_ data: JSONValue?) -> String? {
    let candidates = [data?["rawInput"], data?["input"], data?["item"]?["input"]]
    let input = candidates.first { ($0?.objectValue?.isEmpty == false) } ?? data
    func first(_ keys: [String]) -> String? {
        keys.lazy.compactMap { input?[$0]?.stringValue?.jsTrimmed.nonEmpty }.first
    }
    let query = first(["pattern", "query", "searchTerm", "regex", "grep", "needle"])
    let glob = first(["glob", "globPattern", "glob_pattern", "include", "filePattern", "file_pattern"])
    let target = first(["path", "target_directory", "targetDirectory", "directory", "cwd", "root"])
        .flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last { !$0.isEmpty && $0 != "." } }
        .map(String.init)
    switch (query, glob, target) {
    case (let q?, _, let t?): return "Searched \(q) in \(t)"
    case (_, let g?, let t?): return "Searched files \(g) in \(t)"
    case (_, let g?, nil): return "Searched files \(g)"
    case (let q?, _, _): return "Searched \(q)"
    case (_, _, let t?): return "Searched in \(t)"
    default: return nil
    }
}

/// `formatReadToolLabel` (toolActivity.ts:366-374).
func formatReadToolLabel(_ path: String, extraCount: Int = 0) -> String {
    let suffix = extraCount > 0 ? " +\(extraCount) more" : ""
    let trimmed = path.jsTrimmed
    return trimmed.isEmpty ? "Read file\(suffix)" : "Read \(trimmed)\(suffix)"
}

/// `dynamicToolTitle` (toolActivity.ts:32-39): CUA's `title`, or the skill a Claude `Skill`
/// call loads.
func dynamicToolTitle(_ toolName: String?, _ input: JSONValue?) -> String? {
    if toolName == "cua_repl.js" { return input?["title"]?.stringValue?.jsTrimmed.nonEmpty }
    if toolName == "Skill", let name = input?["skill"]?.stringValue?.jsTrimmed.nonEmpty { return "Skill: \(name)" }
    return nil
}

// MARK: - Paths (apps/web/src/filePathDisplay.ts)

/// `formatWorkspaceRelativePath` (filePathDisplay.ts:19-55): paths under the workspace show as
/// `<rootName>/<relative>`, keeping a `:line:col` suffix.
public func formatWorkspaceRelativePath(_ pathWithPosition: String, workspaceRoot: String?) -> String {
    var path = pathWithPosition
    var suffix = ""
    if let match = path.firstMatch(of: /:(\d+)(?::(\d+))?$/), let line = Int(match.1), line > 0 {
        path = String(path[..<match.range.lowerBound])
        suffix = ":\(line)" + (match.2.flatMap { Int($0) }.flatMap { $0 > 0 ? ":\($0)" : nil } ?? "")
    }
    func normalize(_ p: String) -> String {
        let slashed = p.replacingOccurrences(of: "\\", with: "/")
        return slashed.contains(/^\/[A-Za-z]:[\\\/]/) ? String(slashed.dropFirst()) : slashed
    }
    let normalized = normalize(path)
    var display = normalized
    if let root = workspaceRoot, !root.isEmpty {
        let rootPath = normalize(root.replacing(/[\\\/]+$/, with: ""))
        let label = fileBasename(rootPath)
        let rootWithoutSlash = root.hasPrefix("/") && root.contains(/^\/[A-Za-z]:[\\\/]/) ? String(root.dropFirst()) : root
        let caseInsensitive = rootWithoutSlash.contains(/^[A-Za-z]:(?:[\/\\]|$)/) || rootWithoutSlash.hasPrefix("\\\\")
        let compare = caseInsensitive ? normalized.lowercased() : normalized
        let rootCompare = caseInsensitive ? rootPath.lowercased() : rootPath
        let labelCompare = (caseInsensitive ? label.lowercased() : label) + "/"
        if compare == rootCompare {
            display = label
        } else if compare.hasPrefix(rootCompare + "/") {
            display = "\(label)/\(normalized.dropFirst(rootPath.count + 1))"
        } else if !normalized.hasPrefix("/") {
            let relative = normalized.replacing(/^\.\/+/, with: "").replacing(/^\/+/, with: "")
            display = compare.hasPrefix(labelCompare) ? normalized : "\(label)/\(relative)"
        }
    }
    return display + suffix
}

/// `fileBasename` (packages/shared/src/path.ts:85-92).
func fileBasename(_ path: String) -> String {
    let trimmed = path.replacing(/[\/\\]+$/, with: "")
    guard !trimmed.isEmpty else { return path }
    return String(trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(trimmed))
}

// MARK: - Shell commands (packages/client-runtime/src/work-log/commandLabel.ts)

/// `commandDisplayText` (commandLabel.ts:1381-1384): drops a plain `sh -c` style wrapper and
/// shows control characters as control pictures.
public func commandDisplayText(_ command: String) -> String {
    withVisibleControlCharacters(withoutShellWrapper(command))
}

/// `withVisibleControlCharacters` (commandLabel.ts:1387-1391). Tab, LF and CR stay.
func withVisibleControlCharacters(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x7F: scalars.append("\u{2421}")
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: scalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
        default: scalars.append(scalar)
        }
    }
    return String(scalars)
}

/// `withoutShellWrapper` (commandLabel.ts:1395-1409). A wrapper whose quoting doesn't balance,
/// or that is followed by positional arguments or another statement, stays as it is.
func withoutShellWrapper(_ command: String) -> String {
    let trimmed = command.jsTrimmed
    guard !hasSecondTopLevelStatement(trimmed), let tokens = tokenizeShellCommand(trimmed), let first = tokens.first
    else { return trimmed }
    let program = (first.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? first)
        .replacing(/\.exe$/.ignoresCase(), with: "")
    guard ["sh", "bash", "zsh", "dash", "ash", "ksh", "fish"].contains(program),
        let scriptIndex = shellCommandArgumentIndex(tokens, start: 1), scriptIndex == tokens.count - 1
    else { return trimmed }
    return tokens[scriptIndex].jsTrimmed.nonEmpty ?? trimmed
}

/// `shellCommandArgumentIndex` (commandLabel.ts:202-213): the index of the `-c` script.
func shellCommandArgumentIndex(_ tokens: [String], start: Int) -> Int? {
    var index = start
    while index < tokens.count {
        let option = tokens[index]
        if option == "--" || !option.hasPrefix("-") { return nil }
        if ["-o", "-O", "--rcfile", "--init-file"].contains(option) {
            index += 2
            continue
        }
        if option == "--command" || option.wholeMatch(of: /-[a-zA-Z]*c[a-zA-Z]*/) != nil { return index + 1 }
        index += 1
    }
    return nil
}

/// `tokenizeShellCommand` (commandLabel.ts:225-378): POSIX-ish quoting, `$()`, `${}` and
/// backticks. Nil when quoting doesn't balance.
func tokenizeShellCommand(_ command: String) -> [String]? {
    let input = Array(command.jsTrimmed.unicodeScalars)
    var tokens: [String] = []
    var current = String.UnicodeScalarView()
    var quote: Unicode.Scalar?
    var escaping = false, inBackticks = false, tokenStarted = false
    var substitutionDepth = 0, parameterExpansionDepth = 0
    var index = 0
    func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
    while index < input.count {
        defer { index += 1 }
        let c = input[index]
        let next: Unicode.Scalar? = index + 1 < input.count ? input[index + 1] : nil
        if escaping {
            current.append(c); escaping = false; tokenStarted = true
            continue
        }
        if c == "\\" && quote != "'" {
            let isWindowsPath = quote == nil && String(current).wholeMatch(of: /(?:[A-Za-z]:|\.{1,2})(?:\\[^\s]*)?/) != nil
            if (quote == "\"" || isWindowsPath), let next, !["\"", "\\", "$", "`", "\n"].contains(next) {
                current.append(c); tokenStarted = true
                continue
            }
            escaping = true; tokenStarted = true
            continue
        }
        if inBackticks {
            current.append(c)
            if c == "`" { inBackticks = false }
            tokenStarted = true
            continue
        }
        if let q = quote {
            if c == q { quote = nil } else { current.append(c) }
            tokenStarted = true
            continue
        }
        switch c {
        case "`":
            current.append(c); inBackticks = true
        case "$" where next == "{":
            current.append(contentsOf: "${".unicodeScalars); parameterExpansionDepth += 1; index += 1
        case "{" where parameterExpansionDepth > 0:
            current.append(c); parameterExpansionDepth += 1
        case "}" where parameterExpansionDepth > 0:
            current.append(c); parameterExpansionDepth -= 1
        case "$" where next == "(":
            current.append(contentsOf: "$(".unicodeScalars); substitutionDepth += 1; index += 1
        case "(":
            current.append(c); substitutionDepth += 1
        case ")" where substitutionDepth > 0:
            current.append(c); substitutionDepth -= 1
        case "\"", "'":
            quote = c
        case _ where isSpace(c):
            if substitutionDepth > 0 || parameterExpansionDepth > 0 {
                current.append(c)
            } else {
                if tokenStarted { tokens.append(String(current)) }
                current = String.UnicodeScalarView()
                tokenStarted = false
            }
            continue
        default:
            current.append(c)
        }
        tokenStarted = true
    }
    if quote != nil || escaping || inBackticks || substitutionDepth > 0 || parameterExpansionDepth > 0 { return nil }
    if tokenStarted { tokens.append(String(current)) }
    return tokens
}

/// Whether `splitFirstShellCommand` (commandLabel.ts:459-616) would find a statement after the
/// first one: a top-level `;`, `&`, `|`, `&&`, `||` or newline with more text after it.
///
/// // ponytail: a top-level heredoc counts as a second statement and PowerShell here-strings are
/// not tracked; both only keep a wrapper visible. Port the full splitter if that matters.
func hasSecondTopLevelStatement(_ command: String) -> Bool {
    let s = Array(command.unicodeScalars)
    var quote: Unicode.Scalar?
    var escaping = false, inBackticks = false, inComment = false
    var substitutionDepth = 0, parameterExpansionDepth = 0
    var index = 0
    while index < s.count {
        defer { index += 1 }
        let c = s[index]
        let next: Unicode.Scalar? = index + 1 < s.count ? s[index + 1] : nil
        let previous: Unicode.Scalar? = index > 0 ? s[index - 1] : nil
        if inComment {
            if c != "\n" { continue }
            inComment = false
        }
        if escaping { escaping = false; continue }
        if c == "\\" && quote != "'" { escaping = true; continue }
        if inBackticks { if c == "`" { inBackticks = false }; continue }
        if let q = quote { if c == q { quote = nil }; continue }
        switch c {
        case "\"", "'": quote = c; continue
        case "`": inBackticks = true; continue
        case "#" where previous == nil || previous!.properties.isWhitespace || ";&|(".unicodeScalars.contains(previous!):
            inComment = true; continue
        case "$" where next == "{": parameterExpansionDepth += 1; index += 1; continue
        case "{" where parameterExpansionDepth > 0: parameterExpansionDepth += 1; continue
        case "}" where parameterExpansionDepth > 0: parameterExpansionDepth -= 1; continue
        case "(": substitutionDepth += 1; continue
        case ")" where substitutionDepth > 0: substitutionDepth -= 1; continue
        default: break
        }
        if substitutionDepth > 0 || parameterExpansionDepth > 0 { continue }
        if c == "<", next == "<", index + 2 >= s.count || s[index + 2] != "<" { return true }
        let isDouble = (c == "&" && next == "&") || (c == "|" && (next == "|" || next == "&"))
        let isRedirection = c == "&" && (previous == ">" || previous == "<" || next == ">")
        guard isDouble || ";&|\n".unicodeScalars.contains(c), !isRedirection else { continue }
        let rest = String(String.UnicodeScalarView(s[(index + (isDouble ? 2 : 1))...]))
        return !rest.jsTrimmed.isEmpty
    }
    return false
}
