import AppKit
import DesignSystem

/// `PierreEntryIcon` for files (PierreEntryIcon.tsx, pierre-icons.ts): the @pierre/trees
/// "complete" icon for a path, tinted with T3's per-language color.
public enum FileTypeIcon {
    /// The icon and its theme color for a file path, for rows built outside this module.
    public static func icon(for path: String) -> (IconDefinition, NSColor) {
        (definition(for: path), color(token(for: path)))
    }

    /// The icon token for a path: the file name table, then each extension suffix (`a.test.ts`
    /// tries `test.ts`, then `ts`), the complete set's overrides first; else `default`.
    // ponytail: T3's own extra icons (C#, Java, Kotlin, TOML, video and a few more) fall back to
    // `default`; port the t3-file-icon-* symbols from pierre-icons.ts when someone works in those
    static func token(for path: String) -> String {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let hit = FileIcons.byFileName[name] { return hit }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        for i in parts.indices.dropFirst() {
            let suffix = parts[i...].joined(separator: ".")
            if let hit = FileIcons.completeOverrides[suffix] ?? FileIcons.byExtension[suffix] { return hit }
        }
        return "default"
    }

    @MainActor
    static func view(for path: String, size: CGFloat = 14) -> IconView {
        IconView(definition: definition(for: path), size: size, color: color(token(for: path)))
    }

    static func definition(for path: String) -> IconDefinition {
        FileIcons.symbols[token(for: path)] ?? FileIcons.symbols["default"]!
    }

    static func color(_ token: String) -> NSColor {
        let (light, dark) = FileIcons.colors[token] ?? FileIcons.colors["default"]!
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let l = rgb(light), d = rgb(dark)
        return NSColor(name: nil) { $0.isDark ? d : l }
    }
}
