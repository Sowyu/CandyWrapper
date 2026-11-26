import AppKit
import Testing
@testable import DesignSystem

/// Redesign draws every corner radius, shadow, surface opacity and animation duration from `RedesignTokens` (docs/research/redesign-system.md).
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
        ("duration", #"[dD]uration"#,
         [#"\b(?:duration|animationDuration)\s*=\s*"# + number,
          #"(?:setAnimationDuration\(|withDuration:\s*|\bduration:\s*)"# + number]),
    ]
    static let flag = #"(?:ThemeRuntime\.isDither\([^)]*\)|isDither|dither\w*|capy|plain|frost)"#

    /// A font weight of 600 or heavier: `weight: .semibold`, `Weight.bold`, or a helper's positional `, .semibold)`.
    /// `RedesignTokens.Weight.chrome(.semibold, ...)` is how a weight reaches 500 under Redesign, so it stays allowed.
    static let heavyWeight = regex(#"(?<!chrome\()(?:weight:\s*|Weight|,\s*)\.(?:semibold|bold|heavy)\b"#)

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

    /// A hard-coded hue on a Redesign path: a `#rrggbb` whose channels differ by more than 40 of 255, or a system hue.
    /// Redesign has one accent, from the palette, and the palette's status colors (docs/research/redesign-polish-audit-2026-11-21.md).
    static let hue = regex(##""#([0-9a-fA-F]{6})"|\.system(?:Blue|Purple|Teal|Green|Indigo|Mint|Cyan|Pink|Orange|Yellow|Red|Brown)\b"##)
    /// Where Redesign's colors are defined, not drawn.
    static let palettes: Set<String> = ["ThemePalette.swift", "DitherAccent.swift", "CandyTheme3669.swift"]

    static func hueHits(_ s: String) -> [Double] {
        matches(hue, s).compactMap { m in
            guard let r = Range(m.range(at: 1), in: s), let v = Int(s[r], radix: 16) else { return 0 }
            let c = [v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff]
            return c.max()! - c.min()! > 40 ? Double(v) : nil
        }
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
            if scoped, !palettes.contains(name) {
                for v in hueHits(redesignArm(s)) {
                    let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    hits.append(Hit(kind: "hue", value: v, place: "\(path):\(i + 1)", line: raw.trimmingCharacters(in: .whitespaces)))
                }
            }
            if scoped {
                for _ in matches(heavyWeight, redesignArm(s)) {
                    let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    hits.append(Hit(kind: "weight", value: 600, place: "\(path):\(i + 1)", line: raw.trimmingCharacters(in: .whitespaces)))
                }
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
        // The picture's own resolve-in (DitherArtView) predates the motion tokens and is owned with the picture.
        let hits = files.flatMap { Self.scan(file: $0, root: Self.repo) }
            .filter { !($0.kind == "duration" && $0.place.contains("DitherArtView.swift")) }
        #expect(hits.isEmpty, "Redesign literals outside RedesignTokens:\n\(hits.map(\.description).joined(separator: "\n"))")
    }

    /// A corner nested in an 8pt surface at 8 or more in floors at 2, near square: that is how the account row's
    /// update check ended up square with no literal radius anywhere. Only the window's 16pt corner leaves room.
    @Test func nestedCornersKeepTheirRoundness() throws {
        let call = Self.regex(#"nested\(in:\s*([^,]+),\s*inset:\s*(\d+(?:\.\d+)?)\)"#)
        var hits: [String] = []
        for file in Self.sources() {
            let s = try String(contentsOf: file, encoding: .utf8)
            for m in Self.matches(call, s) {
                guard let outer = Range(m.range(at: 1), in: s), let inset = Range(m.range(at: 2), in: s),
                      Double(s[inset])! >= 8, !s[outer].lowercased().contains("window") else { continue }
                hits.append("\(file.lastPathComponent): nested(in: \(s[outer]), inset: \(s[inset]))")
            }
        }
        #expect(hits.isEmpty, "Use RedesignTokens.Radius.control for a control inside an 8pt surface:\n\(hits.joined(separator: "\n"))")
    }

    /// Message content keeps its weights (docs/research/redesign-system.md, Type): Markdown, the prompt's rich text and code.
    static let contentFiles = ["Features/Markdown/", "ComposerRichText", "ComposerEditor.swift", "FontRuntime.swift"]

    /// Shared views draw in Redesign too. A weight of 600 or heavier outside Redesign's own branches has to reach a
    /// `LabelView` or `TextBlockView`, which stop chrome at 500 under Redesign, or go through `RedesignTokens.Weight`.
    /// A font built for custom drawing at 600 would bypass both, so this fails on it.
    @Test func sharedChromeWeightsStopAt500() throws {
        let heavy = Self.regex(#"\.(?:semibold|bold|heavy)\b"#)
        let helper = Self.regex(#"func (\w+)\([^)]*\)\s*->\s*(?:LabelView|TextBlockView)\b"#)
        var hits: [String] = []
        for file in Self.sources() where !Self.contentFiles.contains(where: { file.path.contains($0) }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let helpers = Self.matches(helper, text).compactMap { Range($0.range(at: 1), in: text).map { "\(text[$0])(" } }
            let feeds = ["LabelView(", "TextBlockView(", ".font = ", "Weight.chrome(", "UsageStyle.label("] + helpers
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let s = raw.components(separatedBy: "//")[0]
                guard !Self.matches(heavy, s).isEmpty, !s.contains("case "), !feeds.contains(where: { s.contains($0) }) else { continue }
                hits.append("\(file.lastPathComponent):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(hits.isEmpty, "600 or heavier drawn outside LabelView and TextBlockView; wrap it in RedesignTokens.Weight.chrome:\n\(hits.joined(separator: "\n"))")
    }

    /// A label set at 600 draws at 500 in Redesign and keeps 600 in the default themes.
    @MainActor @Test func labelsStopAt500InRedesign() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        func width(_ weight: NSFont.Weight, redesign: Bool) -> CGFloat {
            var input = ThemeRuntimeInput()
            input.ditherLight = redesign; input.ditherDark = redesign
            ThemeRuntime.apply(input)
            let label = LabelView("Workflows", font: DSFont.ui(16, weight: weight))
            label.appearance = NSAppearance(named: .darkAqua)
            return label.textWidth
        }
        #expect(width(.semibold, redesign: true) == width(.medium, redesign: true))
        #expect(width(.semibold, redesign: false) > width(.medium, redesign: false))
        #expect(RedesignTokens.Weight.chrome(.bold, dark: true) == .bold, "the default themes keep T3's weights")
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
            if dither { ring = NSColor.systemPurple; gray = color("#1e1e1e") }
            send = isDither ? color("#2b948b") : color("#346bf1")
            if dither { a.duration = 0.18 }
            a.duration = dither ? RedesignTokens.Motion.fast : 0.2
            if dither { title.font = DSFont.ui(16, weight: .semibold); ok.font = DSFont.ui(16, weight: RedesignTokens.Weight.chrome(.semibold, dark: d)) }
            name.font = dither ? DSFont.ui(13, weight: .medium) : DSFont.ui(14, weight: .bold)
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let hits = Self.scan(file: file, root: dir)
        #expect(hits.filter { $0.kind != "hue" && $0.kind != "weight" }.map(\.value).sorted() == [0.07, 0.18, 0.3, 9, 10], "\(hits)")
        #expect(hits.filter { $0.kind == "weight" }.count == 1, "only the bare .semibold on the Redesign path: \(hits)")
        // The system purple and the teal on the Redesign arm; not the gray, not T3's blue on the stock arm.
        #expect(hits.filter { $0.kind == "hue" }.map(\.value) == [0, Double(0x2b948b)], "\(hits)")
    }
}
