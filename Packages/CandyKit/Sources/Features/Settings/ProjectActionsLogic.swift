import Foundation
import T3Protocol

/// Saving a project's actions on every selected environment (useProjectScriptSettings.ts `persist` and
/// `submit`): the environment default without a project, else the project's override entry, plus the
/// action's shortcut, which is environment-wide.
public enum ProjectActionsLogic {
    /// One environment to save on.
    public struct Target: Equatable, Sendable {
        public var environmentId: String
        /// The raw environment settings, so the override entry is extended rather than rebuilt.
        public var settings: ServerSettingsValues
        public var keybindings: [ResolvedKeybindingRule]
        /// The selected project on this environment, with its own (legacy) scripts.
        public var projectId: String?
        public var projectScripts: [ProjectScript]
        /// Every other project on the environment, for the shortcut-in-use check.
        public var otherProjects: [(id: String, scripts: [ProjectScript])]

        public init(environmentId: String, settings: ServerSettingsValues, keybindings: [ResolvedKeybindingRule] = [], projectId: String? = nil,
                    projectScripts: [ProjectScript] = [], otherProjects: [(id: String, scripts: [ProjectScript])] = []) {
            self.environmentId = environmentId; self.settings = settings; self.keybindings = keybindings; self.projectId = projectId
            self.projectScripts = projectScripts; self.otherProjects = otherProjects
        }

        public static func == (l: Target, r: Target) -> Bool {
            l.environmentId == r.environmentId && l.settings == r.settings && l.keybindings == r.keybindings && l.projectId == r.projectId
                && l.projectScripts == r.projectScripts && l.otherProjects.map(\.id) == r.otherProjects.map(\.id)
                && l.otherProjects.map(\.scripts) == r.otherProjects.map(\.scripts)
        }

        /// The list the editor shows and edits.
        public var current: [ProjectScript] {
            projectId.map { ProjectScripts.resolve(settings, projectId: $0, projectScripts: projectScripts) }
                ?? ProjectScript.list(settings["defaultProjectScripts"])
        }
    }

    /// A shortcut change after the settings write.
    public enum BindingOp: Equatable, Sendable {
        case upsert(KeybindingTarget, replace: KeybindingTarget?)
        case remove(KeybindingTarget)
    }

    public struct Write: Equatable, Sendable {
        public var environmentId: String
        public var patch: [String: JSONValue]
        public var bindings: [BindingOp]
    }

    /// `keybindingValueForCommand`: the config form of the last rule bound to `command`.
    public static func keybindingValue(_ rules: [ResolvedKeybindingRule], command: String?) -> String? {
        guard let command, let rule = rules.last(where: { $0.command == command }) else { return nil }
        return KeybindingsLogic.input(rule.shortcut)
    }

    /// The writes for one change. `transform` maps the current list to the next, nil meaning "reset to the
    /// environment's list". An absent or empty keybinding removes the prior shortcut unless retained elsewhere.
    public static func plan(_ targets: [Target], transform: ([ProjectScript]) -> [ProjectScript]?, scriptId: String?,
                            keybinding: String?) -> [Write] {
        targets.map { t in
            let current = t.current
            let next = transform(current)
            let defaults = ProjectScript.list(t.settings["defaultProjectScripts"])
            let effective = next ?? defaults
            var patch: [String: JSONValue]
            if let projectId = t.projectId {
                let entry: JSONValue
                if let next {
                    var o = t.settings["projectSettingsOverrides"][projectId]?.objectValue ?? [:]
                    o["defaultProjectScripts"] = .array(next.map(\.json))
                    entry = .object(o)
                } else {
                    entry = ProjectSettings.clear(t.settings, projectId: projectId, keys: ["defaultProjectScripts"]).map(JSONValue.object) ?? .null
                }
                patch = ["projectSettingsOverrides": .object([projectId: entry])]
            } else {
                patch = ["defaultProjectScripts": .array((next ?? []).map(\.json))]
            }
            // Shortcuts: the edited script, or every script the change dropped.
            let changed = scriptId.map { [$0] } ?? current.filter { s in !effective.contains { $0.id == s.id } }.map(\.id)
            var bindings: [BindingOp] = []
            for id in changed {
                guard let command = ProjectScripts.command(id) else { continue }
                let previous = keybindingValue(t.keybindings, command: command).map { KeybindingTarget(command: command, key: $0) }
                let retainedElsewhere = !(next?.contains { $0.id == id } ?? false) && (
                    (t.projectId != nil && defaults.contains { $0.id == id })
                    || (t.settings["projectSettingsOverrides"].objectValue ?? [:]).contains { pid, entry in
                        pid != t.projectId && ProjectScript.list(entry["defaultProjectScripts"]).contains { $0.id == id }
                    }
                    || t.otherProjects.contains { p in
                        (t.projectId != nil ? ProjectScripts.resolve(t.settings, projectId: p.id, projectScripts: p.scripts) : p.scripts).contains { $0.id == id }
                    })
                let key = keybinding?.trimmingCharacters(in: .whitespaces) ?? ""
                if keybinding != nil, !key.isEmpty {
                    let target = KeybindingTarget(command: command, key: key)
                    bindings.append(.upsert(target, replace: previous.flatMap { $0.key != key ? $0 : nil }))
                } else if let previous, !retainedElsewhere {
                    bindings.append(.remove(previous))
                }
            }
            return Write(environmentId: t.environmentId, patch: patch, bindings: bindings)
        }
    }

    /// `submit`: a new action gets an id unique across every list the targets know.
    public static func newId(_ name: String, targets: [Target]) -> String {
        var ids: [String] = []
        for t in targets {
            ids += ProjectScript.list(t.settings["defaultProjectScripts"]).map(\.id)
            ids += (t.settings["projectSettingsOverrides"].objectValue ?? [:]).values.flatMap { ProjectScript.list($0["defaultProjectScripts"]).map(\.id) }
            ids += t.projectScripts.map(\.id) + t.otherProjects.flatMap { $0.scripts.map(\.id) }
        }
        return ProjectScripts.nextId(name, existing: ids)
    }
}

public extension ProjectActionsLogic {
    /// ProjectActionsSettings.tsx:98-129 and contracts/t3ProjectFile.ts:28-111.
    /// A broken entry invalidates the entire file; do not import a misleading partial list.
    static func importableScripts(_ contents: String, existing: [ProjectScript]) -> [ProjectScriptInput] {
        (validatedFileScripts(contents) ?? []).filter { entry in
            !existing.contains { $0.command == entry.command || $0.name.lowercased() == entry.name.lowercased() }
        }
    }

    static func validatedFileScripts(_ contents: String) -> [ProjectScriptInput]? {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let file = try? decoder.decode(JSONValue.self, from: Data(contents.utf8)), file.objectValue != nil else { return nil }
        for key in ["$schema", "iconPath"] {
            if let value = file[key], value.stringValue == nil { return nil }
        }
        if let path = file["iconPath"]?.stringValue, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.count > 512 { return nil }
        if let mode = file["defaultThreadEnvMode"], !["local", "worktree"].contains(mode.stringValue ?? "") { return nil }
        if let mode = file["worktreeSubmodules"], !["recursive", "top-level", "none"].contains(mode.stringValue ?? "") { return nil }
        guard file["scripts"] == nil || file["scripts"]?.arrayValue != nil else { return nil }
        let rows = file["scripts"]?.arrayValue ?? []
        guard rows.count <= 50 else { return nil }
        var out: [ProjectScriptInput] = []
        for row in rows {
            guard let rawName = row["name"]?.stringValue, let rawCommand = row["command"]?.stringValue else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines), command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }
            for key in ["runOnWorktreeCreate", "runOnSettle", "async", "autoOpenPreview"] {
                if let value = row[key], value.boolValue == nil { return nil }
            }
            if let icon = row["icon"], !ProjectScript.icons.contains(icon.stringValue ?? "") { return nil }
            if let url = row["previewUrl"], url.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
            let setup = row["runOnWorktreeCreate"]?.boolValue == true
            let preview = row["previewUrl"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ProjectScriptInput(name: name, command: command, icon: row["icon"]?.stringValue ?? "play", runOnWorktreeCreate: setup,
                                          waitForSetup: setup && row["async"]?.boolValue == false, runOnSettle: row["runOnSettle"]?.boolValue ?? false,
                                          previewUrl: preview, autoOpenPreview: preview != nil && row["autoOpenPreview"]?.boolValue == true))
        }
        return out
    }
}
