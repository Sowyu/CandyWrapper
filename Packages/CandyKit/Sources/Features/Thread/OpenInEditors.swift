import AppKit
import T3Protocol

/// "Open in" for a workspace: the editor list, the preferred editor and the `shell.openInEditor` input.
/// Ports packages/contracts/src/editor.ts (`EDITORS`, `LaunchEditorInput`), apps/web/src/editorLabels.ts,
/// apps/web/src/editorPreferences.ts and `resolveOpenInOptions` (components/chat/OpenInPicker.tsx:79-196).
/// Local launches use the server; remote workspace links open through the desktop URL handler.
public enum OpenInEditors {
    /// `EDITORS` in order: ids and labels.
    public static let editors: [(id: String, label: String)] = [
        ("cursor", "Cursor"), ("trae", "Trae"), ("kiro", "Kiro"), ("vscode", "VS Code"), ("vscode-insiders", "VS Code Insiders"),
        ("vscodium", "VSCodium"), ("zed", "Zed"), ("antigravity", "Antigravity"), ("idea", "IntelliJ IDEA"), ("aqua", "Aqua"),
        ("clion", "CLion"), ("datagrip", "DataGrip"), ("dataspell", "DataSpell"), ("goland", "GoLand"), ("phpstorm", "PhpStorm"),
        ("pycharm", "PyCharm"), ("rider", "Rider"), ("rubymine", "RubyMine"), ("rustrover", "RustRover"), ("webstorm", "WebStorm"),
        ("file-manager", "File Manager"),
    ]

    /// `editorLabelForPlatform` on macOS: the file manager is Finder.
    public static func label(_ id: String) -> String {
        id == "file-manager" ? "Finder" : editors.first { $0.id == id }?.label ?? "Editor"
    }

    /// `resolveOpenInOptions`: the editors the server found, in `EDITORS` order.
    public static func options(available: [String]) -> [(id: String, label: String)] {
        let set = Set(available)
        return editors.filter { set.contains($0.id) }.map { ($0.id, label($0.id)) }
    }

    /// `openInEditorMenuLabel` (editorLabels.ts:15-19): "Open in Cursor", or "Open in editor" for none or the file manager.
    public static func menuLabel(_ id: String?) -> String {
        guard let id, id != "file-manager" else { return "Open in editor" }
        return "Open in \(editors.first { $0.id == id }?.label ?? "Editor")"
    }

    /// The reveal item's label (ChatMarkdown.tsx:2390-2397, preview/fileExplorerLabel.ts:12-23): only when the server
    /// reveals in its file manager and has one; the server's own wording first, else by its OS. Nil hides the item.
    public static func revealLabel(_ config: ServerProviderConfig) -> String? {
        guard config.revealsInFileManager, config.availableEditors.contains("file-manager") else { return nil }
        switch config.revealKind ?? (config.platformOS == "darwin" ? "finder" : config.platformOS == "windows" ? "file-explorer" : "files") {
        case "finder": return "Reveal in Finder"
        case "file-explorer": return "Reveal in File Explorer"
        default: return "Reveal in Files"
        }
    }

    /// `t3code:last-editor` in T3's localStorage.
    public static let lastEditorKey = "t3code:last-editor"
    /// `t3code:remote-open-hint-seen` (remoteOpen.ts:195-201): set by the first remote open the OS accepted.
    public static let remoteHintSeenKey = "t3code:remote-open-hint-seen"

    /// The full-color marks of `resolveOpenInOptions` that a tinted icon cannot draw (VS Code, VS Code Insiders,
    /// VSCodium, Antigravity and the JetBrains IDEs), rendered from T3's SVGs and kept once made.
    // ponytail: CoreSVG skips the VS Code marks' inner drop shadows (feGaussianBlur filters); bake PNGs if that ever shows at 16pt
    @MainActor
    public static func image(_ id: String) -> NSImage? {
        if let cached = imageCache[id] { return cached }
        guard let svg = EditorIconSVG.documents[id], let image = NSImage(data: Data(svg.utf8)) else { return nil }
        imageCache[id] = image
        return image
    }
    @MainActor private static var imageCache: [String: NSImage] = [:]

    /// `usePreferredEditor`: the last editor used if the server still has it, else the first available.
    public static func preferred(available: [String], last: String?) -> String? {
        if let last, available.contains(last) { return last }
        return editors.first { available.contains($0.id) }?.id
    }

    /// `LaunchEditorInput`. `reveal` only means something for the file manager.
    public static func launchInput(cwd: String, editor: String, reveal: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = ["cwd": .string(cwd), "editor": .string(editor)]
        if reveal { object["reveal"] = .bool(true) }
        return .object(object)
    }

    public static let remoteSchemes = ["cursor": "cursor", "vscode": "vscode", "vscode-insiders": "vscode-insiders", "vscodium": "vscodium", "zed": "zed"]
    private static let jetBrains = ["idea": "IU", "aqua": "QA", "clion": "CL", "datagrip": "DB", "dataspell": "DS", "goland": "GO", "phpstorm": "PS", "pycharm": "PY", "rider": "RD", "rubymine": "RM", "rustrover": "RR", "webstorm": "WS"]

    /// `buildRemoteOpenUrl` (contracts/editor.ts:180-224). Encode components, preserving path separators and drive
    /// letters. `username` rides in the SSH destination; a file gets `:1:1` so VS Code opens it, not a folder.
    public static func remoteURL(editor: String, host: String, username: String? = nil, path: String, isFile: Bool = false) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let posix = path.replacingOccurrences(of: "\\", with: "/")
        if let product = jetBrains[editor] {
            // URLSearchParams: form encoding keeps only alphanumerics and `*-._`, and a space is `+`.
            let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._ ")
            func form(_ value: String) -> String { (value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "").replacingOccurrences(of: " ", with: "+") }
            let user = username.map { "&u=\(form($0))" } ?? ""
            return URL(string: "jetbrains://gateway/ssh/environment?h=\(form(host))&launchIde=true&ideHint=\(product)&projectHint=\(form(posix))\(user)")
        }
        guard let scheme = remoteSchemes[editor] else { return nil }
        var rooted = posix.hasPrefix("/") ? posix : "/" + posix
        if editor == "zed", posix.lowercased().hasPrefix("c:/") { rooted = String(rooted.dropFirst(3)) }
        let encoded = rooted.components(separatedBy: "/").map(encode).joined(separator: "/")
        if editor == "zed" {
            // Zed reads this segment as ssh URL userinfo, so the `@` stays literal.
            let destination = username.map { "\(encode($0))@\(encode(host))" } ?? encode(host)
            return URL(string: "\(scheme)://ssh/\(destination)\(encoded)")
        }
        let destination = username.map { "\($0)@\(host)" } ?? host
        return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(encode(destination))\(encoded)\(isFile ? ":1:1" : "")")
    }

    /// `resolveRemoteOpenState` (remoteOpen.ts:78-90): an alias splits at its last `@`; a saved username wins.
    public static func sshDestination(alias: String, username: String?) -> (host: String, username: String?) {
        let saved = username?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let at = alias.lastIndex(of: "@") else { return (alias, saved.isEmpty ? nil : saved) }
        return (String(alias[alias.index(after: at)...]), saved.isEmpty ? String(alias[..<at]) : saved)
    }

    /// `shouldShowOpenInPicker` (OpenInPicker.logic.ts:5-25) for local environments: a project and the primary
    /// environment. The controller separately enables remote workspaces with advertised SSH targets.
    public static func showsPicker(hasProject: Bool, environmentId: String?, primaryId: String?) -> Bool {
        hasProject && environmentId != nil && environmentId == primaryId
    }
}
