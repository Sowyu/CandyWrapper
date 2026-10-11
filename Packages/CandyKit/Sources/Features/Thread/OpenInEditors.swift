import Foundation
import T3Protocol

/// "Open in" for a workspace: the editor list, the preferred editor and the `shell.openInEditor` input.
/// Ports packages/contracts/src/editor.ts (`EDITORS`, `LaunchEditorInput`), apps/web/src/editorLabels.ts,
/// apps/web/src/editorPreferences.ts and `resolveOpenInOptions` (components/chat/OpenInPicker.tsx:79-196).
/// The server launches the editor, so a remote environment opens it on its own machine.
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

    /// `shouldShowOpenInPicker` (OpenInPicker.logic.ts:5-25) for local environments: a project and the primary
    /// environment. ponytail: remote environments hide the picker; T3 offers SSH deep links there, add with remote open
    public static func showsPicker(hasProject: Bool, environmentId: String?, primaryId: String?) -> Bool {
        hasProject && environmentId != nil && environmentId == primaryId
    }
}
