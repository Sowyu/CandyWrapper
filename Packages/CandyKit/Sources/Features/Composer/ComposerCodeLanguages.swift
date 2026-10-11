import Foundation

/// composer-code-languages.ts:11-110. The info suffix belongs to the fence.
enum ComposerCodeLanguages {
    static let entries: [(id: String, label: String)] = [
        ("", "Plain text"),
        ("bash", "Bash"),
        ("c", "C"),
        ("cpp", "C++"),
        ("csharp", "C#"),
        ("css", "CSS"),
        ("dart", "Dart"),
        ("diff", "Diff"),
        ("dockerfile", "Dockerfile"),
        ("elixir", "Elixir"),
        ("go", "Go"),
        ("graphql", "GraphQL"),
        ("haskell", "Haskell"),
        ("html", "HTML"),
        ("java", "Java"),
        ("javascript", "JavaScript"),
        ("json", "JSON"),
        ("jsx", "JSX"),
        ("kotlin", "Kotlin"),
        ("lua", "Lua"),
        ("markdown", "Markdown"),
        ("php", "PHP"),
        ("powershell", "PowerShell"),
        ("python", "Python"),
        ("r", "R"),
        ("ruby", "Ruby"),
        ("rust", "Rust"),
        ("scala", "Scala"),
        ("scss", "SCSS"),
        ("sql", "SQL"),
        ("svelte", "Svelte"),
        ("swift", "Swift"),
        ("toml", "TOML"),
        ("tsx", "TSX"),
        ("typescript", "TypeScript"),
        ("vue", "Vue"),
        ("xml", "XML"),
        ("yaml", "YAML"),
        ("zig", "Zig"),
    ]
    static let aliases = ["cs": "csharp", "c++": "cpp", "js": "javascript", "md": "markdown", "py": "python", "rb": "ruby", "rs": "rust", "sh": "bash", "shell": "bash", "ts": "typescript", "yml": "yaml", "text": ""]
    static func language(_ info: String) -> String { info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "" }
    static func label(_ info: String) -> String {
        let id = language(info)
        return entries.first { $0.id == (aliases[id.lowercased()] ?? id.lowercased()) }?.label ?? id
    }
    static func filtered(_ query: String, current info: String) -> [(id: String, label: String)] {
        let raw = language(info)
        let current = aliases[raw.lowercased()] ?? raw.lowercased()
        let choices = entries.contains { $0.id == current } ? entries : [(id: raw, label: raw)] + entries
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return choices.filter { needle.isEmpty || $0.id.contains(needle) || $0.label.lowercased().contains(needle) }
    }
    static func replacing(_ info: String, with language: String) -> String {
        let leading = String(info.prefix(while: \.isWhitespace))
        let rest = String(info.dropFirst(leading.count + self.language(info).count))
        if !language.isEmpty { return leading + language + rest }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : leading + "text" + rest
    }
}
