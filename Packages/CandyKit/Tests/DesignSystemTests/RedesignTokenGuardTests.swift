import Foundation
import Testing

/// Redesign draws every corner radius, shadow and surface opacity from `RedesignTokens` (docs/research/redesign-system.md).
/// This reads the sources and fails on a literal one on a Redesign code path, so a tenth radius can't come back.
///
/// A Redesign code path is a file named `*Dither*` or `*Redesign*`, the body of a `Dither*` or `Redesign*` type, the body
/// of an `if` whose condition names the Redesign flag (`dither`, `isDither`, `capy`, `plain`, `frost`), a line that names
/// Dither, and the first arm of `<flag> ? a : b`. 0 and 1 stay allowed: clear, opaque and square are not styles.
struct RedesignTokenGuardTests {
    struct Hit: CustomStringConvertible {
        let kind: String, value: Double, place: String, line: String
        var description: String { "\(kind) \(value) at \(place): \(line)" }
    }

    static let number = #"(-?\d+(?:\.\d+)?)"#
    static let patterns: [(kind: String, keyword: String, literals: [String])] = [
        ("radius", #"\b(?:cornerRadius|radius)\b"#,
         [#"\b(?:cornerRadius|radius)\s*(?::\s*CGFloat\s*)?[:=][^=\n]*?(?<![\w.(])(?<!inset: )"# + number + #"(?![\w.])"#]),
        ("shadow", #"shadow|BoxShadow"#,
         [#"shadow(?:Radius|Opacity)\s*=[^=\n]*?(?<![\w.])"# + number,
          #"shadowOffset\s*=.*?height:[^)]*?(?<![\w.])"# + number,
          #"BoxShadow\([^)]*?(?:y|blur):\s*"# + number]),
        ("alpha", #"white\(|black\(|alpha:|[oO]pacity|AlphaComponent"#,
         [#"(?:white|black)\("# + number + #"\)"#, #"alpha:\s*"# + number, #"withAlphaComponent\("# + number + #"\)"#,
          #"[oO]pacity\s*=\s*"# + number]),
    ]
    static let flag = #"(?:ThemeRuntime\.isDither\([^)]*\)|isDither|dither\w*|capy|plain|frost)"#

    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// `flag ? a : b` keeps `a`: from after the `?` to the `:` at the same bracket depth.
    static func redesignArm(_ s: String) -> String {
        guard let m = matches(regex(#"(?<![!\w])"# + flag + #"\s*\?"#), s).first,
              let start = Range(m.range, in: s)?.upperBound else { return s }
        let chars = Array(s[start...])
        var depth = 0
        for (j, c) in chars.enumerated() {
            if "([".contains(c) { depth += 1 }
            else if ")]".contains(c) { if depth == 0 { return String(chars[..<j]) }; depth -= 1 }
            else if c == ":", depth == 0, j > 0, chars[j - 1] == " ", j + 1 < chars.count, chars[j + 1] == " " { return String(chars[..<j]) }
        }
        return String(chars)
    }

    static func scan(file url: URL, root: URL) -> [Hit] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let name = url.lastPathComponent
        let whole = name.contains("Dither") || name.contains("Redesign")
        let ternary = regex(#"(?<![!\w])"# + flag + #"\s*\?\s*"# + number + #"\s*:"#)
        let negated = regex(#"!\s*(?:ThemeRuntime\.)?(?:is)?[dD]ither|!dither|!plain|!capy"#)
        let typeStart = regex(#"\b(?:class|struct|enum|extension)\s+(?:Dither|Redesign)\w*"#)
        let ifStart = regex(#"\bif\b[^{]*(?:[dD]ither\b|isDither|plain\b|capy\b)[^{]*\{"#)
        let names = regex(#"[dD]ither|\bcapy\b"#)
        var hits: [Hit] = []
        var depth = 0
        var blocks: [Int] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let s = raw.components(separatedBy: "//")[0]
            var lead = 0
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("}") {
                lead = 1; depth -= 1
                while let last = blocks.last, depth <= last { blocks.removeLast() }
            }
            let neg = !matches(negated, s).isEmpty
            let starts = !matches(typeStart, s).isEmpty || (!matches(ifStart, s).isEmpty && !neg)
            let scoped = whole || !blocks.isEmpty || (!matches(names, s).isEmpty && !neg)
            if scoped {
                let t = matches(ternary, s).first
                let arm = redesignArm(s)
                for (kind, keyword, literals) in patterns {
                    var values: [Double] = []
                    if let t {
                        if !matches(regex(keyword), s).isEmpty, let r = Range(t.range(at: 1), in: s) { values = [Double(s[r])!] }
                    } else {
                        for p in literals {
                            for m in matches(regex(p), arm) { if let r = Range(m.range(at: 1), in: arm) { values.append(Double(arm[r])!) } }
                        }
                    }
                    for v in values where v != 0 && !(kind == "alpha" && v == 1) {
                        let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                        hits.append(Hit(kind: kind, value: v, place: "\(path):\(i + 1)", line: raw.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
            if starts { blocks.append(depth) }
            depth += s.filter { $0 == "{" }.count - s.filter { $0 == "}" }.count + lead
            while let last = blocks.last, depth <= last { blocks.removeLast() }
        }
        return hits
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sources() -> [URL] {
        let roots = [repo.appending(path: "Packages/CandyKit/Sources"), repo.appending(path: "App/Sources")]
        return roots.flatMap { root -> [URL] in
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            return (e?.allObjects as? [URL] ?? []).filter {
                $0.pathExtension == "swift" && !$0.lastPathComponent.contains("generated") && $0.lastPathComponent != "RedesignTokens.swift"
            }
        }
    }

    @Test func redesignDrawsOnlyFromTokens() {
        let files = Self.sources()
        #expect(files.count > 100, "found the sources")
        let hits = files.flatMap { Self.scan(file: $0, root: Self.repo) }
        #expect(hits.isEmpty, "Redesign literals outside RedesignTokens:\n\(hits.map(\.description).joined(separator: "\n"))")
    }

    /// The scanner itself: each kind of literal on a Redesign path is caught, the stock arm and tokens are not.
    @Test func scannerCatchesLiterals() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "RedesignTokenGuard-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Sample.swift")
        try """
        func a() {
            if ThemeRuntime.isDither(dark: dark) {
                layer.cornerRadius = 10
                layer.shadowOpacity = dark ? 0.3 : 0.1
            } else {
                layer.cornerRadius = 6
            }
            box.radius = dither ? 9 : 8
            fill = isDither ? Themed.white(0.07) : Themed.white(0.2)
            box.radius = dither ? RedesignTokens.Radius.control : 22
            layer.cornerRadius = 4
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let hits = Self.scan(file: file, root: dir)
        #expect(hits.map(\.value).sorted() == [0.07, 0.3, 9, 10], "\(hits)")
    }
}
