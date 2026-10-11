import Foundation
import T3Protocol

/// shared/projectSettings.ts:95-141. Explicit project/environment values precede t3.json.
public enum SettingsProjectWorkspaceDefaults {
    public static func resolve(settings: ServerSettingsValues, projectId: String, legacy: ProjectSettings.Legacy, contents: String?) -> String {
        let resolved = ProjectSettings.resolve(settings, projectId: projectId, legacy: legacy).settings["defaultThreadEnvMode"].stringValue
        if let resolved, ["local", "worktree"].contains(resolved) { return resolved }
        guard let contents, ProjectActionsLogic.validatedFileScripts(contents) != nil else { return "local" }
        let decoder = JSONDecoder(); decoder.allowsJSON5 = true
        return (try? decoder.decode(JSONValue.self, from: Data(contents.utf8)))?["defaultThreadEnvMode"]?.stringValue ?? "local"
    }
}
