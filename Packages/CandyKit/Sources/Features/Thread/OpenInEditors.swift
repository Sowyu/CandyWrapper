import Foundation
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

    /// `t3code:last-editor` in T3's localStorage.
    public static let lastEditorKey = "t3code:last-editor"

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

    /// contracts/editor.ts:199-242. Encode components, preserving path separators and drive letters.
    public static func remoteURL(editor: String, host: String, path: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let posix = path.replacingOccurrences(of: "\\", with: "/")
        if let product = jetBrains[editor] {
            func form(_ value: String) -> String { encode(value).replacingOccurrences(of: "%20", with: "+") }
            return URL(string: "jetbrains://gateway/ssh/environment?h=\(form(host))&launchIde=true&ideHint=\(product)&projectHint=\(form(posix))")
        }
        guard let scheme = remoteSchemes[editor] else { return nil }
        var rooted = posix.hasPrefix("/") ? posix : "/" + posix
        if editor == "zed", posix.lowercased().hasPrefix("c:/") { rooted = String(rooted.dropFirst(3)) }
        let encoded = rooted.components(separatedBy: "/").map(encode).joined(separator: "/")
        return URL(string: editor == "zed" ? "\(scheme)://ssh/\(encode(host))\(encoded)" : "\(scheme)://vscode-remote/ssh-remote+\(encode(host))\(encoded)")
    }

    /// `shouldShowOpenInPicker` (OpenInPicker.logic.ts:5-25) for local environments: a project and the primary
    /// environment. The controller separately enables remote workspaces with advertised SSH targets.
    public static func showsPicker(hasProject: Bool, environmentId: String?, primaryId: String?) -> Bool {
        hasProject && environmentId != nil && environmentId == primaryId
    }
}
