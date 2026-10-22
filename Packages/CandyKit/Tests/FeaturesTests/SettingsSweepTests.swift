import DesignSystem
import AppKit
import Testing
import T3Protocol
@testable import Features

@MainActor struct SettingsSweepTests {
    @Test func distinguishesMissingScriptsFromInvalidFiles() {
        #expect(ProjectActionsLogic.validatedFileScripts("{}")?.isEmpty == true)
        #expect(ProjectActionsLogic.validatedFileScripts(#"{"defaultThreadEnvMode":"worktree"}"#)?.isEmpty == true)
        #expect(ProjectActionsLogic.validatedFileScripts(#"{"scripts":false}"#) == nil)
        #expect(ProjectActionsLogic.validatedFileScripts(#"{"scripts":[{"name":"ok","command":"run"},{"name":"bad","command":""}]}"#) == nil)
        #expect(ProjectActionsLogic.validatedFileScripts("{") == nil)
    }
    @Test func unchangedActionShortcutFollowsOfficialRemoval() throws {
        let settings = ServerSettingsValues(.object(["defaultProjectScripts": .array([ProjectScript(id: "lint", name: "Lint", command: "lint").json])]))
        let shortcut = try #require(KeybindingShortcut.parse("mod+shift+l"))
        let rules = [ResolvedKeybindingRule(command: "script.lint.run", shortcut: shortcut)]
        let target = ProjectActionsLogic.Target(environmentId: "e", settings: settings, keybindings: rules)
        let writes = ProjectActionsLogic.plan([target], transform: { $0 }, scriptId: "lint", keybinding: nil)
        #expect(writes[0].bindings == [.remove(KeybindingTarget(command: "script.lint.run", key: "mod+shift+l"))])
    }
    @Test func providerFieldsMatchDriverAndSource() {
        #expect(ProvidersLogic.fields("antigravity").map(\.key) == ["authMethod", "apiKey", "gcpProject", "gcpLocation", "binaryPath"])
        #expect(ProvidersLogic.fields("antigravity").first { $0.key == "apiKey" }?.secret == true)
        // 3315 masks OpenCode's password in settings reads, so the field must never show the mask as a typed value.
        #expect(ProvidersLogic.fields("opencode").first { $0.key == "serverPassword" }.map { $0.secret && $0.redacted } == true)
        #expect(ProvidersLogic.fields("acpRegistry", config: .object(["source": .string("local")])).map(\.key) == ["source", "commandPath"])
        #expect(ProvidersLogic.fields("acpRegistry").map(\.key) == ["source", "agentId", "commandPath", "authMethodId"])
        let instance: JSONValue = .object(["driver": .string("antigravity"), "config": .object(["apiKey": .string("fake")])])
        #expect(ProvidersLogic.config(instance, set: "apiKey", to: "")["config"] == nil)
        #expect(ProvidersLogic.config(instance, set: "binaryPath", to: "")["config"]?["binaryPath"] == .string(""))
    }
    @Test func workspaceDefaultsRespectAllTiersAndInvalidFiles() {
        let file = #"{"defaultThreadEnvMode":"worktree"}"#
        var settings = ServerSettingsValues(.object(["projectSettingsFolded": .bool(true)]))
        #expect(SettingsProjectWorkspaceDefaults.resolve(settings: settings, projectId: "p", legacy: .init(), contents: file) == "worktree")
        settings.raw["defaultThreadEnvMode"] = .string("local")
        #expect(SettingsProjectWorkspaceDefaults.resolve(settings: settings, projectId: "p", legacy: .init(), contents: file) == "local")
        settings.raw["projectSettingsOverrides"] = .object(["p": .object(["defaultThreadEnvMode": .string("worktree")])])
        #expect(SettingsProjectWorkspaceDefaults.resolve(settings: settings, projectId: "p", legacy: .init(), contents: nil) == "worktree")
        #expect(SettingsProjectWorkspaceDefaults.resolve(settings: .init(nil), projectId: "p", legacy: .init(), contents: #"{"defaultThreadEnvMode":"worktree","scripts":false}"#) == "local")
    }
    @Test func viewportBoundsAndRotationRemovePreset() {
        let preset: JSONValue = .object(["_tag": .string("preset"), "presetId": .string("iphone-se")])
        #expect(SettingsBrowserViewport.resized(preset, width: 667, height: 375)?["_tag"] == .string("freeform"))
        #expect(SettingsBrowserViewport.resized(preset, width: 239, height: 800) == nil)
        #expect(SettingsBrowserViewport.resized(preset, width: 3840, height: 2160) != nil)
        #expect(SettingsBrowserViewport.resized(preset, width: 3840, height: 2161) == nil)
        #expect(SettingsBrowserViewport.presets.count == 17)
    }
    @Test func environmentThemesKeepVariantsIndependentAndRejectReservedIds() throws {
        let raw: JSONValue = .object(["id": .string("published"), "name": .string("Published"), "appearance": .string("dark"), "canvas": .string("#101010"), "accent": .string("#ff00ff"), "variants": .object(["light": .object(["canvas": .string("#ffffff")])])])
        let theme = try #require(ThemeLibrary.publishedTheme(raw))
        #expect(theme.id == "published")
        // lenientThemeColorOverrides (themePalette.ts:133-144) stores toCanonicalThemeColor of each override.
        #expect(theme.variants[.light]?[.canvas] == ThemePalette.canonical("#ffffff"))
        #expect(!theme.managed)
        #expect(ThemeLibrary.publishedTheme(.object(["id": .string("dark"), "name": .string("bad"), "appearance": .string("dark"), "colors": .object(["canvas": .string("#000000")])] )) == nil)
        let event = try JSONDecoder().decode(ServerConfigEvent.self, from: Data(#"{"version":1,"type":"environmentThemesUpdated","payload":{"themes":[]}}"#.utf8))
        guard case .environmentThemesUpdated(let values) = event else { Issue.record("Missing theme event"); return }
        #expect(values.isEmpty)
    }
    @Test func nativeNoticesShipOffline() {
        let entries = SettingsOpenSourceLicensesView.nativeEntries()
        #expect(Set(entries.map(\.name)) == ["T3 Code", "SwiftTerm", "Lucide", "pele", "Candy Town by Aya_Lu"])
        #expect(entries.allSatisfy { !$0.noticeText.isEmpty && $0.bundles == ["CandyWrapper"] })
    }
}
