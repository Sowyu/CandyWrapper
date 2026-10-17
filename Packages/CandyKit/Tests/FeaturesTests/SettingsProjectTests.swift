import Foundation
import Testing
import T3Protocol
@testable import Features

/// The WP7.7b settings logic against T3's own expectations: project overrides (projectSettings.test.ts,
/// scopedSettings.test.ts), project actions (projectScripts.ts, useProjectScriptSettings.ts), the archive list,
/// providers (providerStatus.ts, ProviderModelsSection.tsx), source control discovery and diagnostics formats.
@MainActor
struct SettingsProjectTests {
    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }

    static func env(_ id: String, _ settings: String = "{}", caps: Set<String> = ["projectSettingsOverrides"], connected: Bool = true) -> SettingsScopeEnvironment {
        SettingsScopeEnvironment(id: id, label: id.capitalized, connected: connected, settings: ServerSettingsValues(json(settings)), capabilities: caps)
    }

    /// One project on two environments: "fleet" on server, "fleet-laptop" on laptop.
    static func scope(_ envs: [SettingsScopeEnvironment], machine: String? = nil) -> SettingsScopeState {
        let members = [SettingsScopeProject.Member(environmentId: "server", projectId: "fleet", title: "fleet", workspaceRoot: "/repo"),
                       SettingsScopeProject.Member(environmentId: "laptop", projectId: "fleet-laptop", title: "fleet", workspaceRoot: "/repo")]
        return SettingsScopeState(selection: SettingsScopeSelection(machine: machine, project: "repo"), environments: envs, primaryId: "server",
                                  projects: [SettingsScopeProject(key: "repo", displayName: "fleet", members: members)])
    }

    // MARK: Overrides

    @Test func resolveAppliesOverridesPerKey() {
        let s = ServerSettingsValues(Self.json(#"{"defaultAutoPull": false, "projectSettingsFolded": true, "projectSettingsOverrides": {"p": {"defaultAutoPull": true, "branchNamePrefix": "x"}}}"#))
        let r = ProjectSettings.resolve(s, projectId: "p")
        #expect(r.settings.bool("defaultAutoPull"))
        #expect(r.settings.string("branchNamePrefix") == "x")
        #expect(r.source("defaultAutoPull") == .project)
        #expect(r.source("enableAgentBrowserAccess") == .environment)
        // No overrides: the environment settings, every key inherited.
        #expect(ProjectSettings.resolve(s, projectId: "other").sources.isEmpty)
    }

    @Test func modelOverrideOnDisabledProviderFallsBack() {
        let s = ServerSettingsValues(Self.json(#"""
        {"projectSettingsFolded": true, "providerInstances": {"codex": {"driver": "codex", "enabled": false}},
         "projectSettingsOverrides": {"p": {"textGenerationModelSelection": {"instanceId": "codex", "model": "gpt"}}}}
        """#))
        let r = ProjectSettings.resolve(s, projectId: "p")
        #expect(r.source("textGenerationModelSelection") == .environment)
        #expect(ProjectSettings.providerInstanceEnabled(Self.json(#"{"driver": "cursor"}"#)) == false)
        #expect(ProjectSettings.providerInstanceEnabled(Self.json(#"{"driver": "codex", "config": {"enabled": false}}"#)) == false)
    }

    @Test func legacyFieldsCountUntilTheFold() {
        let legacy = ProjectSettings.Legacy(defaultThreadEnvMode: "worktree")
        let unfolded = ServerSettingsValues(Self.json("{}"))
        #expect(ProjectSettings.resolve(unfolded, projectId: "p", legacy: legacy).settings["defaultThreadEnvMode"] == .string("worktree"))
        let folded = ServerSettingsValues(Self.json(#"{"projectSettingsFolded": true}"#))
        #expect(ProjectSettings.resolve(folded, projectId: "p", legacy: legacy).settings["defaultThreadEnvMode"] == .null)
    }

    /// projectSettings.ts:95-141: the file fills keys the project and environment leave null, the built-in the rest.
    @Test func projectFileTierFillsUnsetFileBackedKeys() {
        let s = ServerSettingsValues(Self.json(#"{"projectSettingsFolded": true, "worktreeSubmodules": "none"}"#))
        let file = T3ProjectFile.parse(#"{"defaultThreadEnvMode": "worktree", "worktreeSubmodules": "top-level"}"#)
        let r = ProjectSettings.resolve(s, projectId: "p", projectFile: .some(file))
        #expect(r.settings["defaultThreadEnvMode"] == .string("worktree"))
        #expect(r.source("defaultThreadEnvMode") == .t3json)
        #expect(r.settings["worktreeSubmodules"] == .string("none"))
        #expect(r.source("worktreeSubmodules") == .environment)
        // A missing file fills the built-in; an unread one leaves null.
        #expect(ProjectSettings.resolve(s, projectId: "p", projectFile: .some(nil)).settings["defaultThreadEnvMode"] == .string("local"))
        #expect(ProjectSettings.resolve(s, projectId: "p").settings["defaultThreadEnvMode"] == .null)
        var scope = Self.scope([Self.env("server")], machine: "server")
        scope.projectFiles = ["server:/repo": file]
        #expect(scope.inheritance(["defaultThreadEnvMode"]) == (.inherited, "Inherited from the repository's t3.json"))
        #expect(scope.values["defaultThreadEnvMode"] == .string("worktree"))
    }

    @Test func projectScopeResolvesMembersAndSources() {
        let s = Self.scope([Self.env("server", #"{"projectSettingsOverrides": {"fleet": {"defaultAutoPull": true}}}"#), Self.env("laptop")])
        #expect(s.isProjectScope)
        #expect(s.label == "fleet / All checkouts")
        #expect(s.environmentIds == ["server", "laptop"])
        #expect(s.targets.map(\.projectId) == ["fleet", "fleet-laptop"])
        #expect(s.values.bool("defaultAutoPull"))
        #expect(s.isMixed(["defaultAutoPull"]))
        #expect(s.inheritance(["defaultAutoPull"]).state == .mixed)
        #expect(s.source(["defaultAutoPull"]) == nil)
        let one = Self.scope([Self.env("server", #"{"projectSettingsOverrides": {"fleet": {"defaultAutoPull": true}}}"#), Self.env("laptop")], machine: "server")
        #expect(one.inheritance(["defaultAutoPull"]) == (.overridden, "Overridden for this project"))
        #expect(one.inheritance(["enableAgentBrowserAccess"]) == (.inherited, "Inherited from Server"))
        #expect(one.inertReason(for: ["enableProviderUpdateChecks"]) == "Environment-wide setting. Select an environment to change it.")
        #expect(one.inertReason(for: ["defaultAutoPull"]) == nil)
        // A project with no checkout on the chosen environment.
        let missing = Self.scope([Self.env("server"), Self.env("laptop"), Self.env("other")], machine: "other")
        #expect(missing.kind == .unavailable("This project has no checkout on this environment."))
    }

    @Test func writesOverridesIntoEachMembersEntry() {
        let s = Self.scope([Self.env("server", #"{"projectSettingsOverrides": {"fleet": {"enableAgentBrowserAccess": false}}}"#), Self.env("laptop")])
        let plan = s.plan(["defaultAutoPull": .bool(true)])
        #expect(plan.unavailableReason == nil)
        #expect(plan.writes.map(\.environmentId) == ["server", "laptop"])
        #expect(plan.writes[0].patch == ["projectSettingsOverrides": Self.json(#"{"fleet": {"enableAgentBrowserAccess": false, "defaultAutoPull": true}}"#)])
        #expect(plan.writes[1].patch == ["projectSettingsOverrides": Self.json(#"{"fleet-laptop": {"defaultAutoPull": true}}"#)])
        // Environment-wide keys and servers without project overrides refuse.
        #expect(s.plan(["enableProviderUpdateChecks": .bool(false)]).unavailableReason == "This setting is environment-wide and cannot be overridden by a project.")
        let old = Self.scope([Self.env("server", caps: []), Self.env("laptop", caps: [])])
        #expect(old.plan(["defaultAutoPull": .bool(true)]).unavailableReason?.contains("update") == true)
    }

    @Test func nullRemovesOnlyNonNullableOverrides() {
        let s = Self.scope([Self.env("server", #"{"projectSettingsOverrides": {"fleet": {"defaultThreadEnvMode": "worktree", "defaultAutoPull": true}}}"#)], machine: "server")
        #expect(s.plan(["defaultThreadEnvMode": .null]).writes[0].patch == ["projectSettingsOverrides": Self.json(#"{"fleet": {"defaultAutoPull": true}}"#)])
        #expect(s.plan(["defaultModelSelection": .null]).writes[0].patch
            == ["projectSettingsOverrides": Self.json(#"{"fleet": {"defaultThreadEnvMode": "worktree", "defaultAutoPull": true, "defaultModelSelection": null}}"#)])
    }

    @Test func partialObjectsAndCleanupRulesComplete() {
        let s = Self.scope([Self.env("server", #"""
        {"projectSettingsOverrides": {"fleet": {"sourceControlWritingStyle": {"mode": "custom", "customInstructions": "Keep it short.", "followChangeRequestTemplates": false}}}}
        """#), Self.env("laptop", #"{"storageCleanup": {"worktreeAfterDays": 30}}"#)])
        let style = s.plan(["sourceControlWritingStyle": .object(["followChangeRequestTemplates": .bool(true)])])
        #expect(style.writes[0].patch["projectSettingsOverrides"]?["fleet"]?["sourceControlWritingStyle"]
            == Self.json(#"{"mode": "custom", "customInstructions": "Keep it short.", "followChangeRequestTemplates": true}"#))
        let cleanup = s.plan(["worktreeCleanup": Self.json(#"{"mode": "custom", "rules": {"worktreeOnDelete": true}}"#)])
        #expect(cleanup.writes[1].patch["projectSettingsOverrides"]?["fleet-laptop"]?["worktreeCleanup"]
            == Self.json(#"{"mode": "custom", "rules": {"worktreeAfterDays": 30, "worktreeSettledAfterDays": null, "worktreeOnDelete": true, "worktreeOnMerge": false, "worktreeUnchanged": false}}"#))
    }

    @Test func clearDropsKeysAndEmptiedEntries() {
        let s = Self.scope([Self.env("server", #"{"projectSettingsOverrides": {"fleet": {"defaultAutoPull": true, "enableAgentBrowserAccess": false}}}"#)], machine: "server")
        #expect(s.planClear(["defaultAutoPull"]).writes[0].patch == ["projectSettingsOverrides": Self.json(#"{"fleet": {"enableAgentBrowserAccess": false}}"#)])
        #expect(s.planClear(["defaultAutoPull", "enableAgentBrowserAccess"]).writes[0].patch == ["projectSettingsOverrides": Self.json(#"{"fleet": null}"#)])
    }

    @Test func worktreeCleanupResolution() {
        let s = ServerSettingsValues(Self.json(#"{"storageCleanup": {"worktreeAfterDays": 5, "worktreeOnMerge": true}, "projectSettingsFolded": true, "projectSettingsOverrides": {"off": {"worktreeCleanup": {"mode": "off"}}}}"#))
        #expect(ProjectSettings.worktreeCleanup(s, projectId: nil)["worktreeAfterDays"] == .number(5))
        #expect(ProjectSettings.worktreeCleanup(s, projectId: "off") == ["worktreeAfterDays": .null, "worktreeSettledAfterDays": .null, "worktreeOnMerge": .bool(false),
                                                                         "worktreeOnDelete": .bool(false), "worktreeUnchanged": .bool(false)])
    }

    // MARK: Actions

    @Test func scriptIdsAndCommands() {
        #expect(ProjectScripts.nextId("Run Tests!", existing: []) == "run-tests")
        #expect(ProjectScripts.nextId("Run tests", existing: ["run-tests", "run-tests-2"]) == "run-tests-3")
        #expect(ProjectScripts.nextId("   ", existing: []) == "script")
        #expect(ProjectScripts.nextId(String(repeating: "a", count: 30), existing: [String(repeating: "a", count: 24)]) == String(repeating: "a", count: 22) + "-2")
        #expect(ProjectScripts.command("lint") == "script.lint.run")
        #expect(ProjectScripts.command("Bad_Id") == nil)
    }

    @Test func savingAScriptTakesItsRoles() {
        let setup = ProjectScript(id: "setup", name: "Setup", command: "bun i", runOnWorktreeCreate: true, runOnSettle: true)
        let input = ProjectScriptInput(name: "Install", command: "pnpm i", runOnWorktreeCreate: true, waitForSetup: true)
        let next = ProjectScripts.applySubmit([setup], id: "install", isNew: true, input: input)
        #expect(next.map(\.id) == ["setup", "install"])
        #expect(next[0].runOnWorktreeCreate == false && next[0].runOnSettle == true)
        #expect(next[1].json == Self.json(#"{"id": "install", "name": "Install", "command": "pnpm i", "icon": "play", "runOnWorktreeCreate": true, "async": false}"#))
        // Preview URL and auto-open travel together.
        let preview = ProjectScripts.build(id: "dev", ProjectScriptInput(name: "Dev", command: "bun dev", previewUrl: "http://localhost:3000", autoOpenPreview: true))
        #expect(preview.json["previewUrl"] == .string("http://localhost:3000") && preview.json["autoOpenPreview"] == .bool(true))
    }

    @Test func editorValidation() {
        #expect(ProjectScripts.validate(ProjectScriptInput(name: "  ", command: "x")) == .failure(.init(message: "Name is required.")))
        #expect(ProjectScripts.validate(ProjectScriptInput(name: "a", command: " ")) == .failure(.init(message: "Command is required.")))
        guard case .success(let ok) = ProjectScripts.validate(ProjectScriptInput(name: " a ", command: " b ", waitForSetup: true, previewUrl: " ", autoOpenPreview: true)) else {
            Issue.record("expected success"); return
        }
        #expect(ok.name == "a" && ok.command == "b" && ok.previewUrl == nil && !ok.autoOpenPreview && !ok.waitForSetup)
    }

    @Test func actionWritesTheOverrideAndTheShortcut() {
        let settings = ServerSettingsValues(Self.json(#"{"projectSettingsFolded": true, "projectSettingsOverrides": {"p": {"defaultAutoPull": true}}}"#))
        let target = ProjectActionsLogic.Target(environmentId: "e", settings: settings, projectId: "p")
        let input = ProjectScriptInput(name: "Lint", command: "bun lint", keybinding: "mod+shift+l")
        let id = ProjectActionsLogic.newId("Lint", targets: [target])
        let writes = ProjectActionsLogic.plan([target], transform: { ProjectScripts.applySubmit($0, id: id, isNew: true, input: input) },
                                              scriptId: id, keybinding: input.keybinding)
        #expect(writes[0].patch == ["projectSettingsOverrides": Self.json(#"""
        {"p": {"defaultAutoPull": true, "defaultProjectScripts": [{"id": "lint", "name": "Lint", "command": "bun lint", "icon": "play", "runOnWorktreeCreate": false}]}}
        """#)])
        #expect(writes[0].bindings == [.upsert(KeybindingTarget(command: "script.lint.run", key: "mod+shift+l"), replace: nil)])
    }

    @Test func resetToTheEnvironmentListDropsUnusedShortcuts() throws {
        let settings = ServerSettingsValues(Self.json(#"""
        {"projectSettingsFolded": true, "projectSettingsOverrides": {"p": {"defaultProjectScripts": [{"id": "lint", "name": "Lint", "command": "x", "icon": "lint", "runOnWorktreeCreate": false}]}}}
        """#))
        let rule = try #require(Keymap.decodeRules(Self.json(#"[{"command": "script.lint.run", "shortcut": {"key": "l", "modKey": true, "metaKey": false, "ctrlKey": false, "altKey": false, "shiftKey": true}}]"#)).first)
        let target = ProjectActionsLogic.Target(environmentId: "e", settings: settings, keybindings: [rule], projectId: "p")
        let writes = ProjectActionsLogic.plan([target], transform: { _ in nil }, scriptId: nil, keybinding: nil)
        #expect(writes[0].patch == ["projectSettingsOverrides": Self.json(#"{"p": null}"#)])
        #expect(writes[0].bindings == [.remove(KeybindingTarget(command: "script.lint.run", key: "mod+shift+l"))])
        // Another project still lists the action: its shortcut stays.
        var shared = target
        shared.otherProjects = [(id: "q", scripts: [ProjectScript(id: "lint", name: "Lint", command: "x")])]
        let kept = ProjectActionsLogic.plan([ProjectActionsLogic.Target(environmentId: "e", settings: ServerSettingsValues(Self.json(#"""
        {"projectSettingsFolded": true, "projectSettingsOverrides": {"p": {"defaultProjectScripts": [{"id": "lint", "name": "Lint", "command": "x", "icon": "lint", "runOnWorktreeCreate": false}]}, "q": {"defaultProjectScripts": [{"id": "lint", "name": "Lint", "command": "x", "icon": "lint", "runOnWorktreeCreate": false}]}}}
        """#)), keybindings: [rule], projectId: "p")], transform: { _ in nil }, scriptId: nil, keybinding: nil)
        #expect(kept[0].bindings.isEmpty)
    }

    @Test func removalPromptLines() {
        let m = SettingsScopeProject.Member(environmentId: "e", projectId: "p", title: "demo", workspaceRoot: "/r", environmentLabel: "Mac")
        #expect(ProjectRemoval.message(members: [m], allMembers: [m], hasOtherMembers: false, groupName: "demo", threadCount: 2)
            == "Remove project \"demo\" and delete its 2 threads?\nPath: /r\nEnvironment: Mac\nThis permanently clears conversation history for those threads and any archived threads.\nThis removes only the project entries, not the files on disk.\nThis action cannot be undone.")
        let copy = ConfirmCopy.resolve("Remove project \"demo\"?\nPath: /r")
        #expect(copy.title == "Remove project \"demo\"?" && copy.description == "Path: /r")
        #expect(ConfirmCopy.resolve("Send SIGKILL to process 1? This cannot be handled.") == ("Send SIGKILL to process 1?", "This cannot be handled."))
    }

    // MARK: Archive

    @Test func archiveGroupsNewestFirst() {
        let snap = ArchivedSnapshot(environmentId: "e", Self.json(#"""
        {"projects": [{"id": "a", "title": "A", "workspaceRoot": "/a"}, {"id": "b", "title": "B", "workspaceRoot": "/b"}],
         "threads": [{"id": "t1", "projectId": "a", "title": "old", "archivedAt": "2026-01-01T00:00:00Z", "createdAt": "2025-01-01T00:00:00Z"},
                     {"id": "t2", "projectId": "a", "title": "new", "archivedAt": "2026-02-01T00:00:00Z", "createdAt": "2025-01-01T00:00:00Z"}]}
        """#))
        let groups = ArchiveLogic.groups([snap], selected: nil)
        #expect(groups.map(\.project.id) == ["a"])
        #expect(groups[0].threads.map(\.title) == ["new", "old"])
        #expect(ArchiveLogic.groups([snap], selected: ["e:b"]).isEmpty)
    }

    // MARK: Providers

    @Test func providerRowsAndSummaries() throws {
        let providers = try Self.json(#"""
        [{"instanceId": "codex", "driver": "codex", "enabled": true, "installed": false, "status": "error", "message": "Could not start Codex CLI.", "models": []},
         {"instanceId": "claudeAgent", "driver": "claudeAgent", "enabled": true, "installed": true, "status": "ready", "version": "2.1.295",
          "auth": {"status": "authenticated", "label": "Claude Max Subscription"}, "models": []}]
        """#).decode(as: [ServerProvider].self)
        let rows = ProvidersLogic.rows(settings: ServerSettingsValues(Self.json(#"{"providerInstances": {"grok": {"driver": "grok", "enabled": true}, "work": {"driver": "codex"}}}"#)), providers: providers)
        #expect(rows.map(\.instanceId) == ["codex", "work", "claudeAgent", "grok"])
        #expect(rows.first { $0.instanceId == "grok" }?.isDirty == true)
        #expect(ProvidersLogic.summary(providers[0]) == ("Not found", "Could not start Codex CLI."))
        #expect(ProvidersLogic.summary(providers[1]).headline == "Authenticated · Claude Max Subscription")
        #expect(ProvidersLogic.versionLabel("2.1.295") == "v2.1.295")
        #expect(ProvidersLogic.versionLabel("agy_acp_server_20260818_01_RC01") == "2026-08-18 RC01")
    }

    @Test func modelsOrderFavoritesVisibleHidden() {
        let custom = ProvidersLogic.customModels(Self.json(#"{"config": {"customModels": ["mine", {"slug": "named", "name": "Named"}]}}"#))
        #expect(custom.map(\.name) == ["mine", "Named"])
        let models = ProvidersLogic.displayModels(live: [], custom: custom, favorites: ["named"], hidden: [], order: [])
        #expect(models.map(\.slug) == ["named", "mine"])
        #expect(ProvidersLogic.customModelError(" ", live: models, custom: ["mine"]) == "Enter a model slug.")
        #expect(ProvidersLogic.customModelError("mine", live: models, custom: ["mine"]) == "That custom model is already saved.")
        let builtIn = [ProvidersLogic.DisplayModel(slug: "a", name: "A", isCustom: false, capabilities: []),
                       ProvidersLogic.DisplayModel(slug: "b", name: "B", isCustom: false, capabilities: [])]
        #expect(ProvidersLogic.customModelError("a", live: builtIn, custom: []) == "That model is already built in.")
        #expect(ProvidersLogic.bulkToggle(builtIn, hidden: ["x"]) == ["x", "a", "b"])
        #expect(ProvidersLogic.bulkToggle(builtIn, hidden: ["a", "b", "x"]) == ["x"])
        #expect(ProvidersLogic.config(Self.json(#"{"driver": "codex", "config": {"binaryPath": "/x"}}"#), set: "binaryPath", to: " ")
            == Self.json(#"{"driver": "codex"}"#))
    }

    // MARK: Source control and diagnostics

    @Test func discoveryFromTheRecording() throws {
        let url = SidebarFidelityTests.repo.appendingPathComponent("fixtures/transcripts/08-settings.jsonl")
        var result: JSONValue?
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let o = try JSONValue(parsing: Data(line.utf8))
            if o["body"]?["_tag"]?.stringValue == "Exit", o["body"]?["requestId"]?.stringValue == "2" { result = o["body"]?["exit"]?["value"] }
        }
        let (vcs, providers) = SourceControlDiscoveryItem.list(try #require(result))
        #expect(vcs.first?.version == "git version 2.54.0 (Apple Git-157)")
        #expect(vcs.first?.summary == "Available")
        #expect(vcs.last?.summary == "Support for Jujutsu is coming soon.")
        #expect(providers.first?.summary.hasPrefix("Not available on this server: Install the GitHub command-line tool") == true)
        #expect(providers.first { $0.kind == "bitbucket" }?.badge == "Not authenticated")
    }

    @Test func diagnosticsFormats() {
        #expect(DiagnosticsFormat.bytes(1536) == "1.50 KB")
        #expect(DiagnosticsFormat.bytes(1_100_000_000) == "1.02 GB")
        #expect(DiagnosticsFormat.duration(950) == "950 ms")
        #expect(DiagnosticsFormat.duration(12_340) == "12.3 s")
        #expect(DiagnosticsFormat.cpuTime(44.7) == "44.7s")
        #expect(DiagnosticsFormat.cpuTime(90) == "1.50m")
        #expect(DiagnosticsFormat.processName("\"/usr/bin/git\" --version") == "git")
        #expect(DiagnosticsFormat.processType(command: "claude --verbose", depth: 0) == "Agent")
        #expect(DiagnosticsFormat.traceId(String(repeating: "a", count: 40)) == String(repeating: "a", count: 18) + "..." + String(repeating: "a", count: 10))
        let procs = [Self.json(#"{"pid": 1, "depth": 0}"#), Self.json(#"{"pid": 2, "depth": 1}"#), Self.json(#"{"pid": 3, "depth": 0}"#)]
        #expect(DiagnosticsFormat.visibleProcesses(procs, collapsed: [1]).compactMap { $0["pid"]?.intValue } == [1, 3])
    }
}
