import Foundation
import DesignSystem

/// What CandyWrapper reads from a theme's `css` (EnvironmentTheme.css, contracts server.ts:657). CandyWrapper has
/// no CSS engine, so it honors only the theme color variables T3 itself sets on the root
/// (`APP_THEME_VARIABLES`, themePalette.ts:1653-1715), and ignores every other rule, selector and property.
///
/// Honored, exactly:
/// - `--app-theme-<role>` for each of the 61 `ThemeColorRole`s, the role in kebab case
///   (`--app-theme-canvas`, `--app-theme-muted-foreground`, ...), with `terminalSelection` as
///   `--app-theme-terminal-selection-background`.
/// - Only with `!important`: T3 writes these variables inline on the root (themePalette.ts:1736), so a
///   stylesheet declaration without it loses there too.
/// - Only in top-level rules whose every selector is `:root` or `html` (both appearances), `.dark`,
///   `:root.dark` or `html.dark` (dark), or `:root:not(.dark)` or `html:not(.dark)` (light).
/// - Only values T3's `themeCssValueFetches` passes (shared/src/themeCss.ts:28-30) that are theme colors
///   (`ThemePalette.canonical`). A value that could fetch is dropped before it is parsed.
/// - `var(--theme-background-image)` anywhere outside comments turns on the published background image.
/// Nothing in a theme ever loads a remote resource here: the CSS is never handed to a web view.
public enum ThemeCSSVariables {
    public struct Overrides: Equatable, Sendable {
        public var both: [ThemeColorRole: String] = [:]
        public var light: [ThemeColorRole: String] = [:]
        public var dark: [ThemeColorRole: String] = [:]
        public var isEmpty: Bool { both.isEmpty && light.isEmpty && dark.isEmpty }
        public func colors(for a: ThemeAppearance) -> [ThemeColorRole: String] { both.merging(a == .dark ? dark : light) { $1 } }
    }

    /// `--app-theme-*` to role (themePalette.ts:1653-1715).
    static let roles: [String: ThemeColorRole] = Dictionary(uniqueKeysWithValues: ThemeColorRole.allCases.map { role in
        let kebab = role.rawValue.replacingOccurrences(of: "([A-Z])", with: "-$1", options: .regularExpression).lowercased()
        return (role == .terminalSelection ? "--app-theme-terminal-selection-background" : "--app-theme-\(kebab)", role)
    })

    // MARK: themeCss.ts

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let fetchesByString = regex(#"image-set\(|\bsrc\("#)
    private static let urlNotLocal = regex(#"url\((?![ \t\n\f\r]*["']?(?:data:|#))"#)
    private static let urlOrString = regex(#"url\((?![ \t\n\f\r]*["'])[^)]*|url\([ \t\n\f\r]*("[^"\n\r\f]*"|'[^'\n\r\f]*')|"[^"\n\r\f]*"|'[^'\n\r\f]*'"#)
    private static let localString = regex(#"^["'](?:data:|#)"#)

    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `withoutStrings`: strings removed, keeping `url(` where a quoted url() can load a file.
    static func withoutStrings(_ code: String) -> String {
        let ns = code as NSString
        var out = "", last = 0
        for m in urlOrString.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound {
                let inner = ns.substring(with: m.range(at: 1))
                out += matches(localString, inner) ? "" : "url("
            } else {
                out += token.hasPrefix("\"") || token.hasPrefix("'") ? "" : token
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// `themeCssValueFetches`: a backslash anywhere refuses the value, since an escape can spell `url` or `var`.
    public static func valueFetches(_ value: String) -> Bool {
        if value.contains("\\") { return true }
        let code = withoutStrings(value)
        return matches(fetchesByString, code) || matches(urlNotLocal, code)
    }

    // MARK: Reading

    static func stripComments(_ css: String) -> String {
        css.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
    }

    public static func usesBackgroundImage(_ css: String?) -> Bool {
        guard let css else { return false }
        return stripComments(css).range(of: #"var\(\s*--theme-background-image\b"#, options: .regularExpression) != nil
    }

    private enum Target { case both, light, dark }

    private static func target(_ selector: String) -> Target? {
        switch selector.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased() {
        case ":root", "html": .both
        case ".dark", ":root.dark", "html.dark", ".dark:root": .dark
        case ":root:not(.dark)", "html:not(.dark)": .light
        default: nil
        }
    }

    /// The honored color variables in `css`. Theme CSS holds at most 100,000 characters (server.ts:640).
    public static func overrides(_ css: String?) -> Overrides {
        var result = Overrides()
        guard let css, !css.isEmpty, css.count <= 100_000 else { return result }
        let code = Array(stripComments(css))
        var i = 0, start = 0, depth = 0
        var header = ""
        var quote: Character?
        while i < code.count {
            let c = code[i]
            if let q = quote { if c == q { quote = nil }; i += 1; continue }
            switch c {
            case "\"", "'": quote = c
            case "{":
                if depth == 0 { header = String(code[start..<i]); start = i + 1 }
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return result }
                if depth == 0 {
                    // ponytail: a nested at-rule's inner block is skipped whole; read @media too if themes need it
                    if !header.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") {
                        read(String(code[start..<i]), header: header, into: &result)
                    }
                    start = i + 1
                }
            case ";" where depth == 0:
                start = i + 1 // a top-level statement such as @import: never read
            default: break
            }
            i += 1
        }
        return result
    }

    private static func read(_ body: String, header: String, into result: inout Overrides) {
        let targets = header.split(separator: ",").map { target(String($0)) }
        guard !targets.isEmpty, !targets.contains(where: { $0 == nil }), !body.contains("{") else { return }
        // ponytail: splits on every `;`, so a `;` inside a quoted value ends it early; values here are colors
        for declaration in body.split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let role = roles[name] else { continue }
            var value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bang = value.range(of: #"!\s*important$"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            value = value[..<bang.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !valueFetches(value), let color = ThemePalette.canonical(value) else { continue }
            for t in targets {
                switch t! {
                case .both: result.both[role] = color
                case .light: result.light[role] = color
                case .dark: result.dark[role] = color
                }
            }
        }
    }
}
