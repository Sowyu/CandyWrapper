import Foundation
import T3Protocol
import T3Store

/// shared/projectSettings.ts:95-141. Explicit project/environment values precede t3.json.
public enum SettingsProjectWorkspaceDefaults {
    public static func resolve(settings: ServerSettingsValues, projectId: String, legacy: ProjectSettings.Legacy, contents: String?) -> String {
        resolveWithSource(settings: settings, projectId: projectId, legacy: legacy, contents: contents).mode
    }

    /// The mode and where it came from: the project override, the environment (or the built-in "local"), or t3.json.
    public static func resolveWithSource(settings: ServerSettingsValues, projectId: String, legacy: ProjectSettings.Legacy,
                                         contents: String?) -> (mode: String, source: ProjectSettingSource) {
        let r = ProjectSettings.resolve(settings, projectId: projectId, legacy: legacy)
        if let resolved = r.settings["defaultThreadEnvMode"].stringValue, ["local", "worktree"].contains(resolved) {
            return (resolved, r.source("defaultThreadEnvMode"))
        }
        guard let contents, ProjectActionsLogic.validatedFileScripts(contents) != nil else { return ("local", .environment) }
        let decoder = JSONDecoder(); decoder.allowsJSON5 = true
        guard let mode = (try? decoder.decode(JSONValue.self, from: Data(contents.utf8)))?["defaultThreadEnvMode"]?.stringValue else {
            return ("local", .environment)
        }
        return (mode, .t3json)
    }

    /// `resolveNewThreadEnvMode` (shared/projectSettings.ts:209-243 in 2994, 72fbad7b1): a project made from
    /// just a name (a folder directly inside `newProjectsRoot`) has only its first commit, so until it has
    /// a thread, a new thread works in its checkout even when the environment default is a new worktree.
    /// A project override or a t3.json value still wins. It needs only `newProjectsRoot`, which 2861 sends too.
    public static func newThreadEnvMode(configured: String, source: ProjectSettingSource, workspaceRoot: String?,
                                        newProjectsRoot: String?, projectHasThreads: Bool) -> String {
        guard configured != "local", !projectHasThreads, source == .environment, let workspaceRoot, let newProjectsRoot else { return configured }
        let root = SidebarModel.normalizeProjectPath(newProjectsRoot)
        let folder = SidebarModel.normalizeProjectPath(workspaceRoot)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let isNewProjectFolder = folder.hasPrefix(prefix) && folder.count > prefix.count && !folder.dropFirst(prefix.count).contains("/")
        return isNewProjectFolder ? "local" : configured
    }
}
