import Foundation
import T3Protocol

/// One environment as the settings scope sees it (`EnvironmentPresentation` plus its server config).
public struct SettingsScopeEnvironment: Equatable, Sendable {
    public var id: String
    public var label: String
    public var displayURL: String?
    public var machine: String
    public var connected: Bool
    /// The settings from `server.getConfig`, nil until the config arrives.
    public var settings: ServerSettingsValues?
    public var capabilities: Set<String>
    public var canWrite: Bool

    public init(id: String, label: String, displayURL: String? = nil, machine: String = "server", connected: Bool = true,
                settings: ServerSettingsValues? = nil, capabilities: Set<String> = [], canWrite: Bool = true) {
        self.id = id; self.label = label; self.displayURL = displayURL; self.machine = machine; self.connected = connected
        self.settings = settings; self.capabilities = capabilities; self.canWrite = canWrite
    }
}

/// A logical project for the project picker (`SidebarProjectSnapshot`): the sidebar's group and its
/// physical projects, one per environment and folder.
public struct SettingsScopeProject: Equatable, Sendable {
    /// One checkout (`SidebarProjectGroupMember`).
    public struct Member: Equatable, Sendable {
        public var environmentId: String
        /// The id the server knows.
        public var projectId: String
        public var title: String
        public var workspaceRoot: String
        public var environmentLabel: String?
        public var faviconPath: String?
        public var projectIcon: JSONValue?
        public var scripts: [ProjectScript]
        public var legacy: ProjectSettings.Legacy

        public init(environmentId: String, projectId: String, title: String, workspaceRoot: String, environmentLabel: String? = nil,
                    faviconPath: String? = nil, projectIcon: JSONValue? = nil, scripts: [ProjectScript] = [],
                    legacy: ProjectSettings.Legacy = .init()) {
            self.environmentId = environmentId; self.projectId = projectId; self.title = title; self.workspaceRoot = workspaceRoot
            self.environmentLabel = environmentLabel; self.faviconPath = faviconPath; self.projectIcon = projectIcon; self.scripts = scripts
            self.legacy = legacy
        }

        /// `physicalProjectKey`.
        public var physicalKey: String { environmentId + ":" + workspaceRoot }
    }

    public var key: String
    public var displayName: String
    public var members: [Member]
    /// The group's favicon, from its representative project (`ProjectFavicon project={group}`).
    public var icon: ProjectIconSource?
    public init(key: String, displayName: String, members: [Member] = [], icon: ProjectIconSource? = nil) {
        self.key = key; self.displayName = displayName; self.members = members; self.icon = icon
    }
}

/// The URL search the settings route keeps (`SettingsScopeSearch`): absent means all.
public struct SettingsScopeSelection: Equatable, Sendable {
    public var machine: String?
    public var project: String?
    public init(machine: String? = nil, project: String? = nil) { self.machine = machine; self.project = project }
}

/// Where a row's value comes from (`SettingInheritanceState`).
public enum SettingInheritanceState: Equatable, Sendable { case `default`, environment, inherited, overridden, mixed }

/// The resolved scope (settingsScope.ts `resolveSettingsScope`, scopedSettings.ts target resolution, mixed
/// detection and write planning) on both axes: environments and projects.
public struct SettingsScopeState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case all, environment(String), project(String), unavailable(String) }

    /// One (environment, project) pair the scope writes to, with that project's effective settings
    /// (`ScopedSettingsTarget`). Environment scopes have no project.
    public struct Target: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        public var projectId: String?
        public var settings: ServerSettingsValues
        public var sources: [String: ProjectSettingSource]
    }

    public var selection: SettingsScopeSelection
    public var environments: [SettingsScopeEnvironment]
    public var primaryId: String?
    public var projects: [SettingsScopeProject]
    /// Each member's decoded t3.json by `physicalKey` (SettingsScopeContext.tsx `useMemberProjectFiles`): absent
    /// until its read settles, nil for a missing, truncated or invalid file.
    public var projectFiles: [String: T3ProjectFile?]

    public init(selection: SettingsScopeSelection = .init(), environments: [SettingsScopeEnvironment], primaryId: String?,
                projects: [SettingsScopeProject] = [], projectFiles: [String: T3ProjectFile?] = [:]) {
        self.selection = selection; self.environments = environments; self.primaryId = primaryId; self.projects = projects
        self.projectFiles = projectFiles
    }

    public var kind: Kind {
        if let machine = selection.machine, !environments.contains(where: { $0.id == machine }) {
            return .unavailable("This environment is no longer available.")
        }
        if let key = selection.project {
            guard let group = projects.first(where: { $0.key == key }) else { return .unavailable("This project is no longer available.") }
            if members(of: group).isEmpty { return .unavailable("This project has no checkout on this environment.") }
            return .project(key)
        }
        if let machine = selection.machine { return .environment(machine) }
        return .all
    }

    public var isProjectScope: Bool { if case .project = kind { true } else { false } }

    /// The selected project group, at a project scope.
    public var group: SettingsScopeProject? {
        guard case .project(let key) = kind else { return nil }
        return projects.first { $0.key == key }
    }

    private func members(of group: SettingsScopeProject) -> [SettingsScopeProject.Member] {
        group.members.filter { selection.machine == nil || $0.environmentId == selection.machine }
    }

    /// The selected checkouts (`scope.members`).
    public var members: [SettingsScopeProject.Member] { group.map(members(of:)) ?? [] }

    public var label: String {
        switch kind {
        case .all: return "All environments"
        case .environment(let id): return environments.first { $0.id == id }.map(environmentLabel) ?? id
        case .project:
            let env = selection.machine.flatMap { id in environments.first { $0.id == id } }
            return "\(group?.displayName ?? "") / \(env?.label ?? "All checkouts")"
        case .unavailable: return "Unavailable selection"
        }
    }

    /// `scope.environmentIds`.
    public var environmentIds: [String] {
        switch kind {
        case .all: return environments.map(\.id)
        case .environment(let id): return [id]
        case .project:
            var seen = Set<String>()
            return members.compactMap { seen.insert($0.environmentId).inserted ? $0.environmentId : nil }
        case .unavailable: return []
        }
    }

    /// `selectScopedSettingsEnvironments`: the selected, connected environments with a config.
    public var connected: [SettingsScopeEnvironment] {
        let ids = Set(environmentIds)
        return environments.filter { ids.contains($0.id) && $0.connected && $0.settings != nil }
    }

    /// The representative environment: the primary, else the first connected.
    public var representative: SettingsScopeEnvironment? { connected.first { $0.id == primaryId } ?? connected.first }

    /// `resolveScopedSettingsTargets`: members at a project scope, environments otherwise.
    public var targets: [Target] {
        let byId = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if isProjectScope {
            return members.compactMap { m in
                guard let e = byId[m.environmentId], let s = e.settings else { return nil }
                let r = ProjectSettings.resolve(s, projectId: m.projectId, legacy: m.legacy, projectFile: projectFiles[m.physicalKey])
                return Target(environmentId: e.id, label: e.label, projectId: m.projectId, settings: r.settings, sources: r.sources)
            }
        }
        return connected.compactMap { e in e.settings.map { Target(environmentId: e.id, label: e.label, projectId: nil, settings: $0, sources: [:]) } }
    }

    /// The target that supplies display values, the one on the representative environment first.
    public var target: Target? {
        let all = targets
        return all.first { $0.environmentId == representative?.id } ?? all.first
    }

    /// Display values: the representative target's settings, or the defaults with nothing connected.
    public var values: ServerSettingsValues { target?.settings ?? ServerSettingsValues(nil) }

    /// `scopedSettingsAreMixed`.
    public func isMixed(_ keys: [String]) -> Bool {
        let all = targets
        guard let first = all.first else { return false }
        return all.contains { t in keys.contains { first.settings[$0] != t.settings[$0] } }
    }

    /// `scopedSettingsSource`: overridden on every target, inherited on every target, or split (nil).
    public func source(_ keys: [String]) -> ProjectSettingSource? {
        let scoped = keys.filter(ProjectSettings.isScoped)
        let all = targets
        guard !scoped.isEmpty, !all.isEmpty else { return .environment }
        let sources = Set(all.flatMap { t in scoped.map { t.sources[$0] ?? .environment } })
        return sources.count > 1 ? nil : sources.first
    }

    /// Every selected target supports `capability` (`threadAutoSettlement`, `threadRestartContinuation`).
    public func allSupport(_ capability: String) -> Bool {
        !connected.isEmpty && connected.allSatisfy { $0.capabilities.contains(capability) }
    }

    /// Every selected connected target's settings carry `key`, so its server stores it. A setting newer than
    /// the server, like `guestSharingEnabled` on 3473, is absent there and its patch would be dropped.
    public func allStore(_ key: String) -> Bool {
        !connected.isEmpty && connected.allSatisfy { $0.settings?.raw[key] != nil }
    }

    /// `canWriteSettings`: every selected connected target lets this connection write settings.
    public var canWrite: Bool { !connected.isEmpty && connected.allSatisfy(\.canWrite) }

    /// The single environment for per-machine tuning (`isEnvironmentScope`).
    public var isEnvironmentScope: Bool { environmentIds.count == 1 && representative != nil }

    /// `settingsScopeEnvironmentLabel`: a duplicate label gets its URL.
    public func environmentLabel(_ e: SettingsScopeEnvironment) -> String {
        environments.contains { $0.id != e.id && $0.label == e.label } ? "\(e.label) · \(e.displayURL ?? e.id)" : e.label
    }

    /// The row's inheritance indicator (settingsLayout.tsx `inheritance`).
    public func inheritance(_ keys: [String]) -> (state: SettingInheritanceState, summary: String) {
        if isMixed(keys) { return (.mixed, "Mixed across selected environments") }
        let scoped = keys.filter(ProjectSettings.isScoped)
        if isProjectScope {
            switch source(scoped) {
            case .project?: return (.overridden, "Overridden for this project")
            case .t3json?: return (.inherited, "Inherited from the repository's t3.json")
            case .environment? where !scoped.isEmpty:
                let from = environmentIds.count == 1 ? environments.first { $0.id == environmentIds[0] }?.label ?? "environment" : "environment"
                return (.inherited, "Inherited from \(from)")
            default: break
            }
        }
        let byId = Dictionary(connected.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let customized = targets.contains { t in keys.contains { !(byId[t.environmentId]?.settings?.isDefault($0) ?? true) } }
        return customized ? (.environment, "Set on the environment") : (.default, "Built-in default")
    }

    /// One `server.updateSettings` call.
    public struct Write: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        public var patch: [String: JSONValue]
    }

    /// `droppedSettingKeys` (settings/scopedSettings.ts, T3 3105 8ac4b97da): an older server drops keys it does not
    /// know, top-level or nested, and still succeeds. A key counts as dropped when the write asked for a change and
    /// the saved settings still hold the old value. Objects compare field by field; a null clears; strings may come
    /// back trimmed.
    public static func droppedKeys(_ patch: [String: JSONValue], previous: JSONValue, saved: JSONValue) -> [String] {
        func dropped(_ value: JSONValue?, _ before: JSONValue?, _ after: JSONValue?) -> Bool {
            let before = before ?? .null, after = after ?? .null
            guard let value, value != .null else { return before != .null && after == before }
            if case .object(let fields) = value, before.arrayValue == nil, after.arrayValue == nil {
                return fields.contains { key, next in dropped(next, before[key], after[key]) }
            }
            let unchanged = value.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == before.stringValue } ?? (value == before)
            return !unchanged && after == before
        }
        return patch.keys.sorted().filter { dropped(patch[$0], previous[$0], saved[$0]) }
    }

    /// `projectOverrideWrites`: one patch per environment that names each member's new override entry
    /// (null drops it). Environments without `projectSettingsOverrides` are skipped.
    private func overrideWrites(_ update: (_ current: [String: JSONValue], _ settings: ServerSettingsValues, _ projectId: String) -> [String: JSONValue]?) -> [Write] {
        let byId = Dictionary(environments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var entries: [String: [String: JSONValue]] = [:]
        for m in members {
            guard let e = byId[m.environmentId], e.connected, let s = e.settings, e.capabilities.contains("projectSettingsOverrides") else { continue }
            let current = s["projectSettingsOverrides"][m.projectId]?.objectValue ?? [:]
            if entries[e.id] == nil { order.append(e.id) }
            entries[e.id, default: [:]][m.projectId] = update(current, s, m.projectId).map(JSONValue.object) ?? .null
        }
        return order.map { id in Write(environmentId: id, label: byId[id]!.label, patch: ["projectSettingsOverrides": .object(entries[id]!)]) }
    }

    /// `planScopedSettingsPatch` for server keys. Environment scopes send the patch to every connected
    /// target; a project scope writes the scopable keys into each member's override entry. Returns the
    /// writes, or the reason nothing can be saved.
    public func plan(_ patch: [String: JSONValue]) -> (writes: [Write], unavailableReason: String?) {
        guard !patch.isEmpty else { return ([], nil) }
        if case .unavailable(let message) = kind { return ([], message) }
        if isProjectScope {
            if patch.keys.contains(where: { !ProjectSettings.isScoped($0) }) {
                return ([], "This setting is environment-wide and cannot be overridden by a project.")
            }
            let writes = overrideWrites { current, settings, projectId in
                // Object values arrive as partial patches; an override stores the whole value.
                let effective = ProjectSettings.resolve(settings, projectId: projectId).settings
                var next = current
                for (key, value) in patch {
                    if key == "worktreeCleanup", value["mode"]?.stringValue == "custom" {
                        var rules = ProjectSettings.worktreeCleanup(settings, projectId: projectId)
                        for (k, v) in value["rules"]?.objectValue ?? [:] { rules[k] = v }
                        next[key] = .object(["mode": .string("custom"), "rules": .object(rules)])
                        continue
                    }
                    // A picker's "Inherit" sends null; for keys whose override can't be null that removes it.
                    if value == .null, !ProjectSettings.nullableKeys.contains(key) {
                        next.removeValue(forKey: key)
                        continue
                    }
                    if case .object(let o) = value, case .object(var base) = effective[key] {
                        for (k, v) in o { base[k] = v }
                        next[key] = .object(base)
                    } else {
                        next[key] = value
                    }
                }
                return next
            }
            return writes.isEmpty ? ([], "Connect the selected checkouts, or update their environments, to save a project override.") : (writes, nil)
        }
        let writes = connected.map { e -> Write in
            var p = patch
            // `forDestination` (scopedSettings.ts:221-225): the idle compaction mode in the form this server reads.
            if let mode = p.removeValue(forKey: "idleCompaction")?.stringValue {
                p.removeValue(forKey: "compactIdleThreads")
                p.merge((e.settings ?? ServerSettingsValues(nil)).idleCompactionPatch(mode)) { _, new in new }
            }
            // A worktree rule edit where the environment already has its own `worktreeCleanup` goes there too.
            if let s = e.settings, s["worktreeCleanup"] != .null, let storage = patch["storageCleanup"]?.objectValue,
               storage.keys.contains(where: { $0.hasPrefix("worktree") }) {
                var rules = ProjectSettings.worktreeCleanup(s, projectId: nil)
                for (k, v) in storage where k.hasPrefix("worktree") { rules[k] = v }
                p["worktreeCleanup"] = .object(["mode": .string("custom"), "rules": .object(rules)])
            }
            return Write(environmentId: e.id, label: e.label, patch: p)
        }
        if writes.isEmpty {
            if case .environment = kind { return ([], "Connect \(label) to save this setting.") }
            return ([], "Connect an environment to save this setting.")
        }
        return (writes, nil)
    }

    /// `planScopedSettingsClear`: drops the keys' overrides so the selected checkouts inherit again.
    public func planClear(_ keys: [String]) -> (writes: [Write], unavailableReason: String?) {
        guard isProjectScope else { return ([], nil) }
        let writes = overrideWrites { _, settings, projectId in ProjectSettings.clear(settings, projectId: projectId, keys: keys) }
        return writes.isEmpty ? ([], "Connect the selected checkouts, or update their environments, to reset this override.") : (writes, nil)
    }

    /// The tooltip of an inert server control (settingsLayout.tsx `renderedControl`), or nil when it works.
    /// At a project scope a row with no overridable key is environment-wide.
    public func inertReason(for keys: [String]) -> String? {
        if connected.isEmpty { return "Reconnect the selected environment to change this setting." }
        let denied = connected.filter { !$0.canWrite }.map(\.label)
        if !denied.isEmpty { return "This connection lacks permission to change settings on \(denied.joined(separator: ", "))." }
        if isProjectScope, !keys.isEmpty, !keys.contains(where: ProjectSettings.isScoped) {
            return "Environment-wide setting. Select an environment to change it."
        }
        return nil
    }

    public var inertReason: String? { inertReason(for: []) }

    /// The page body's notice instead of rows (settings.tsx `SettingsScopeBoundary`), or nil.
    public var boundaryMessage: String? {
        if case .unavailable(let message) = kind { return message }
        if case .environment = kind, connected.isEmpty { return "Reconnect \(label) to change its settings." }
        return nil
    }
}

/// Server setting saves, one at a time. Each plans when its turn comes, from the settings the saves before it
/// returned: a project override write replaces the whole entry (T3 serverSettings.ts:259-278), so two plans made
/// from one snapshot erase each other's change (audit SU1).
@MainActor
public final class SettingsWriteQueue {
    private var tail: Task<Void, Never>?
    public init() {}

    public func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await work() }
    }

    /// Waits for every save queued so far.
    public func settled() async { await tail?.value }
}
