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

/// A project group for the project picker (`SidebarProjectSnapshot`).
public struct SettingsScopeProject: Equatable, Sendable {
    public var key: String
    public var displayName: String
    public init(key: String, displayName: String) { self.key = key; self.displayName = displayName }
}

/// The URL search the settings route keeps (`SettingsScopeSearch`): absent means all.
public struct SettingsScopeSelection: Equatable, Sendable {
    public var machine: String?
    public var project: String?
    public init(machine: String? = nil, project: String? = nil) { self.machine = machine; self.project = project }
}

/// Where a row's value comes from (`SettingInheritanceState`).
public enum SettingInheritanceState: Equatable, Sendable { case `default`, environment, inherited, overridden, mixed }

/// The resolved scope (settingsScope.ts `resolveSettingsScope` on the environment axis, plus
/// scopedSettings.ts target selection, mixed detection and write planning).
public struct SettingsScopeState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case all, environment(String), unavailable(String) }

    public var selection: SettingsScopeSelection
    public var environments: [SettingsScopeEnvironment]
    public var primaryId: String?
    public var projects: [SettingsScopeProject]

    public init(selection: SettingsScopeSelection = .init(), environments: [SettingsScopeEnvironment], primaryId: String?,
                projects: [SettingsScopeProject] = []) {
        self.selection = selection; self.environments = environments; self.primaryId = primaryId; self.projects = projects
    }

    // ponytail: the project axis lists projects but only "All projects" applies; project overrides come with the Project page (WP7.7b)
    public var kind: Kind {
        guard let machine = selection.machine else { return .all }
        return environments.contains { $0.id == machine } ? .environment(machine) : .unavailable("This environment is no longer available.")
    }

    public var label: String {
        switch kind {
        case .all: "All environments"
        case .environment(let id): environments.first { $0.id == id }.map(environmentLabel) ?? id
        case .unavailable: "Unavailable selection"
        }
    }

    /// `scope.environmentIds`.
    public var environmentIds: [String] {
        switch kind {
        case .all: environments.map(\.id)
        case .environment(let id): [id]
        case .unavailable: []
        }
    }

    /// `selectScopedSettingsEnvironments`: the selected, connected targets with a config.
    public var connected: [SettingsScopeEnvironment] {
        let ids = Set(environmentIds)
        return environments.filter { ids.contains($0.id) && $0.connected && $0.settings != nil }
    }

    /// The representative target that supplies display values: the primary, else the first connected.
    public var representative: SettingsScopeEnvironment? { connected.first { $0.id == primaryId } ?? connected.first }

    /// Display values: the representative's settings, or the defaults with nothing connected.
    public var values: ServerSettingsValues { representative?.settings ?? ServerSettingsValues(nil) }

    /// `scopedSettingsAreMixed`.
    public func isMixed(_ keys: [String]) -> Bool {
        let targets = connected.compactMap(\.settings)
        guard let first = targets.first else { return false }
        return targets.contains { t in keys.contains { first[$0] != t[$0] } }
    }

    /// Every selected target supports `capability` (`threadAutoSettlement`, `threadRestartContinuation`).
    public func allSupport(_ capability: String) -> Bool {
        !connected.isEmpty && connected.allSatisfy { $0.capabilities.contains(capability) }
    }

    /// `canWriteSettings`: every selected connected target lets this connection write settings.
    public var canWrite: Bool { !connected.isEmpty && connected.allSatisfy(\.canWrite) }

    /// The single environment for per-machine tuning (`isEnvironmentScope`).
    public var isEnvironmentScope: Bool { environmentIds.count == 1 && representative != nil }

    /// `settingsScopeEnvironmentLabel`: a duplicate label gets its URL.
    public func environmentLabel(_ e: SettingsScopeEnvironment) -> String {
        environments.contains { $0.id != e.id && $0.label == e.label } ? "\(e.label) · \(e.displayURL ?? e.id)" : e.label
    }

    /// The row's inheritance indicator at an environment scope (settingsLayout.tsx `inheritance`).
    public func inheritance(_ keys: [String]) -> (state: SettingInheritanceState, summary: String) {
        if isMixed(keys) { return (.mixed, "Mixed across selected environments") }
        let customized = connected.contains { e in keys.contains { !(e.settings?.isDefault($0) ?? true) } }
        return customized ? (.environment, "Set on the environment") : (.default, "Built-in default")
    }

    /// One `server.updateSettings` call.
    public struct Write: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        public var patch: [String: JSONValue]
    }

    /// `planScopedSettingsPatch` at an environment or all scope: the server patch goes to every connected
    /// target. Returns the writes, or the reason nothing can be saved.
    public func plan(_ patch: [String: JSONValue]) -> (writes: [Write], unavailableReason: String?) {
        guard !patch.isEmpty else { return ([], nil) }
        if case .unavailable(let message) = kind { return ([], message) }
        let writes = connected.map { Write(environmentId: $0.id, label: $0.label, patch: patch) }
        if writes.isEmpty {
            if case .environment = kind { return ([], "Connect \(label) to save this setting.") }
            return ([], "Connect an environment to save this setting.")
        }
        return (writes, nil)
    }

    /// The tooltip of an inert server control (settingsLayout.tsx `renderedControl`), or nil when it works.
    public var inertReason: String? {
        if connected.isEmpty { return "Reconnect the selected environment to change this setting." }
        let denied = connected.filter { !$0.canWrite }.map(\.label)
        if !denied.isEmpty { return "This connection lacks permission to change settings on \(denied.joined(separator: ", "))." }
        return nil
    }

    /// The page body's notice instead of rows (settings.tsx `SettingsScopeBoundary`), or nil.
    public var boundaryMessage: String? {
        if case .unavailable(let message) = kind { return message }
        if case .environment = kind, connected.isEmpty { return "Reconnect \(label) to change its settings." }
        return nil
    }
}
