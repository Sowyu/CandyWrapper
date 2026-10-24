import Foundation

/// The checked-in `t3.json` at a workspace root (packages/contracts/src/t3ProjectFile.ts). A file that fails to
/// decode counts as absent (`parseT3ProjectFile`, packages/shared/src/t3ProjectFile.ts:21-24).
public struct T3ProjectFile: Equatable, Sendable {
    /// `T3ProjectFileScript`: a script team members can import.
    public struct Script: Equatable, Sendable {
        public var name: String
        public var command: String
        public var icon: String?
        public var runOnWorktreeCreate: Bool?
        public var runOnSettle: Bool?
        public var async: Bool?
        public var previewUrl: String?
        public var autoOpenPreview: Bool?
    }

    public static let fileName = "t3.json"
    public var iconPath: String?
    public var defaultThreadEnvMode: String?
    public var worktreeSubmodules: String?
    public var scripts: [Script] = []

    /// `ProjectScriptIcon` (contracts/src/project.ts:23-30).
    public static let icons: Set<String> = ["play", "test", "lint", "configure", "build", "debug"]

    /// Lenient JSON (comments and trailing commas, `fromLenientJson`, schemaJson.ts:166-190), then the schema:
    /// trimmed non-empty strings, `iconPath` up to 512, at most 50 scripts, known enums. Unknown keys are ignored.
    public static func parse(_ contents: String) -> T3ProjectFile? {
        guard let data = stripLenientJSON(contents).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var file = T3ProjectFile()
        func trimmed(_ value: Any?, max: Int? = nil) -> String?? {
            guard let value else { return .some(nil) }
            guard let s = value as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // The encoded side is checked before the trim (`isNonEmpty`, `isMaxLength`), then re-validated.
            guard !s.isEmpty, !t.isEmpty, max.map({ s.count <= $0 }) ?? true else { return nil }
            return .some(t)
        }
        func flag(_ value: Any?) -> Bool?? {
            guard let value else { return .some(nil) }
            #if canImport(Darwin)
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return .some(n.boolValue)
            #else
            // swift-corelibs-foundation's JSONSerialization gives a real Bool for true and false, and NSNumber for numbers.
            guard let b = value as? Bool, type(of: value) == Bool.self else { return nil }
            return .some(b)
            #endif
        }
        if let schema = root["$schema"], !(schema is String) { return nil }
        guard let iconPath = trimmed(root["iconPath"], max: 512) else { return nil }
        file.iconPath = iconPath
        for (key, allowed) in [("defaultThreadEnvMode", ["local", "worktree"]), ("worktreeSubmodules", ["recursive", "top-level", "none"])] {
            guard let value = root[key] else { continue }
            guard let s = value as? String, allowed.contains(s) else { return nil }
            if key == "defaultThreadEnvMode" { file.defaultThreadEnvMode = s } else { file.worktreeSubmodules = s }
        }
        if let raw = root["scripts"] {
            guard let list = raw as? [Any], list.count <= 50 else { return nil }
            for item in list {
                guard let o = item as? [String: Any], let name = trimmed(o["name"]) ?? nil, let command = trimmed(o["command"]) ?? nil,
                      let preview = trimmed(o["previewUrl"]), let worktree = flag(o["runOnWorktreeCreate"]), let settle = flag(o["runOnSettle"]),
                      let async = flag(o["async"]), let auto = flag(o["autoOpenPreview"]) else { return nil }
                var icon: String?
                if let value = o["icon"] {
                    guard let s = value as? String, icons.contains(s) else { return nil }
                    icon = s
                }
                file.scripts.append(Script(name: name, command: command, icon: icon, runOnWorktreeCreate: worktree, runOnSettle: settle,
                                           async: async, previewUrl: preview, autoOpenPreview: auto))
            }
        }
        return file
    }

    /// `parseLenientJsonGetter`: strips `//` and `/* */` comments and trailing commas outside string literals.
    static func stripLenientJSON(_ input: String) -> String {
        let string = #""(?:[^"\\]|\\.)*""#
        var out = input
        for (pattern, keep) in [("(\(string))|//[^\n]*", ""), ("(\(string))|/\\*[\\s\\S]*?\\*/", ""), ("(\(string))|,(\\s*[}\\]])", "$2")] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                if m.range(at: 1).location != NSNotFound {
                    result += ns.substring(with: m.range)
                } else if keep == "$2", m.numberOfRanges > 2, m.range(at: 2).location != NSNotFound {
                    result += ns.substring(with: m.range(at: 2))
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    /// `importableScripts` (ProjectScriptsControl.tsx:115-126): file scripts no saved action already covers by
    /// command or, ignoring case, by name.
    public static func importable(_ scripts: [Script], existing: [ProjectScript]) -> [Script] {
        scripts.filter { s in !existing.contains { $0.command == s.command || $0.name.lowercased() == s.name.lowercased() } }
    }

    /// `importFileScript`'s payload (ProjectScriptsControl.tsx:144-156). `keybinding: ""` is T3's `null` (no
    /// shortcut) for a connection that may write settings; nil leaves it unset.
    public static func importInput(_ s: Script, canWriteSettings: Bool) -> ProjectScriptInput {
        ProjectScriptInput(name: s.name, command: s.command, icon: s.icon ?? "play", runOnWorktreeCreate: s.runOnWorktreeCreate ?? false,
                           waitForSetup: s.runOnWorktreeCreate == true && s.async == false, runOnSettle: s.runOnSettle ?? false,
                           keybinding: canWriteSettings ? "" : nil, previewUrl: s.previewUrl,
                           autoOpenPreview: s.previewUrl != nil ? (s.autoOpenPreview ?? false) : false)
    }
}
