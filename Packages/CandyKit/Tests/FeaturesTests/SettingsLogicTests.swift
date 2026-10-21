import Foundation
import Testing
import T3Protocol
@testable import Features

/// Settings search, scope, keybindings and settings decoding, against T3's own test expectations
/// (settingsSearch.test.ts, scopedSettings.test.ts, KeybindingsSettings.logic.test.ts, settings.test.ts).
@MainActor
struct SettingsLogicTests {
    // MARK: Search

    @Test func catalogMatchesT3() {
        let ids = SettingsSearch.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        // The catalog starts with the storage keep rule and Delete now (settingsSearch.ts:167-183).
        #expect(Array(ids.prefix(3)) == ["storage-worktree-keep-when", "storage-delete-now", "storage-worktrees"])
        #expect(SettingsSearch.title("time-format") == "Time format")
        // Keybinding commands follow the "keybindings" item, one per static command.
        let k = ids.firstIndex(of: "keybindings")!
        #expect(ids[k + 1].hasPrefix("keybinding-"))
        #expect(SettingsSearch.items.filter { $0.flags.contains(.secondary) }.count == KeybindingsLogic.staticCommands.count)
    }

    @Test func searchRanksTitlesFirstAndCommandsLast() {
        let results = SettingsSearch.search("model").map(\.id)
        #expect(results.first == "default-model")
        let firstSecondary = results.firstIndex { $0.hasPrefix("keybinding-") }!
        #expect(results[firstSecondary...].allSatisfy { $0.hasPrefix("keybinding-") })
        #expect(SettingsSearch.search("time").first?.id == "time-format")
        #expect(SettingsSearch.search("   ").isEmpty)
    }

    @Test func searchNeedsEveryTokenAndFoldsMarks() {
        // "font" matches several rows; "font code" only the code font (title has both? no: "code" is in its terms).
        let r = SettingsSearch.search("font code").map(\.id)
        #expect(r.first == "code-font")
        #expect(SettingsSearch.normalize("  Ünïcödé   Text ") == "unicode text")
        // Default keys are searchable: "mod+b" finds Sidebar: Toggle.
        #expect(SettingsSearch.search("mod+b").contains { $0.id == "keybinding-sidebar.toggle" })
    }

    @Test func availabilityFilters() {
        var a = SettingsSearchAvailability()
        a.hasThreadAutoSettlement = false
        a.hasCloudPublicConfig = false
        let ids = Set(SettingsSearch.available(a).map(\.id))
        #expect(!ids.contains("auto-settle-inactive-threads"))
        #expect(!ids.contains("t3-connect"))
        #expect(!ids.contains("wsl-backend"))
        #expect(ids.contains("time-format"))
    }

    // MARK: Scope

    static func env(_ id: String, _ label: String, connected: Bool = true, _ settings: [String: JSONValue] = [:]) -> SettingsScopeEnvironment {
        SettingsScopeEnvironment(id: id, label: label, connected: connected, settings: ServerSettingsValues(.object(settings)))
    }

    @Test func scopeResolvesEnvironmentAxis() {
        let envs = [Self.env("a", "Mac"), Self.env("b", "Studio", connected: false)]
        var s = SettingsScopeState(environments: envs, primaryId: "a")
        #expect(s.kind == .all)
        #expect(s.label == "All environments")
        #expect(s.environmentIds == ["a", "b"])
        #expect(s.connected.map(\.id) == ["a"])
        s.selection.machine = "b"
        #expect(s.kind == .environment("b"))
        #expect(s.boundaryMessage == "Reconnect Studio to change its settings.")
        #expect(s.plan(["snoozeLimitedThreads": .bool(true)]).unavailableReason == "Connect Studio to save this setting.")
        s.selection.machine = "gone"
        #expect(s.kind == .unavailable("This environment is no longer available."))
        #expect(s.plan(["snoozeLimitedThreads": .bool(true)]).writes.isEmpty)
    }

    @Test func mixedValuesAndInheritance() {
        let s = SettingsScopeState(environments: [Self.env("a", "Mac", ["responseStreamingMode": .string("turn")]), Self.env("b", "Studio")],
                                   primaryId: "a")
        #expect(s.isMixed(["responseStreamingMode"]))
        #expect(!s.isMixed(["snoozeLimitedThreads"]))
        #expect(s.inheritance(["responseStreamingMode"]).state == .mixed)
        #expect(s.inheritance(["snoozeLimitedThreads"]) == (.default, "Built-in default"))
        // The representative is the primary.
        #expect(s.values.string("responseStreamingMode") == "turn")
        // A write fans out to every connected target.
        #expect(s.plan(["responseStreamingMode": .string("paragraph")]).writes.map(\.environmentId) == ["a", "b"])
        let one = SettingsScopeState(environments: [Self.env("a", "Mac", ["snoozeLimitedThreads": .bool(true)])], primaryId: "a")
        #expect(one.inheritance(["snoozeLimitedThreads"]) == (.environment, "Set on the environment"))
    }

    @Test func duplicateLabelsGetTheirURL() {
        var a = Self.env("a", "Mac"), b = Self.env("b", "Mac")
        a.displayURL = "http://a"; b.displayURL = "http://b"
        let s = SettingsScopeState(environments: [a, b], primaryId: "a")
        #expect(s.environmentLabel(a) == "Mac · http://a")
    }

    // MARK: Keybindings

    @Test func commandLabels() {
        #expect(KeybindingsLogic.commandLabel("sidebar.toggle") == "Sidebar: Toggle")
        #expect(KeybindingsLogic.commandLabel("rightPanel.toggleMaximized") == "Right Panel: Toggle Maximized")
        #expect(KeybindingsLogic.commandLabel("usage.period.week") == "Usage: Period: 7 days")
        #expect(KeybindingsLogic.commandLabel("script.build-app.run") == "Run Script: Build App")
        #expect(KeybindingsLogic.commandLabel("composer.sendAlternate") == "Composer: Opposite Queue or Steer Action")
    }

    @Test func rowsSourcesAndConflicts() {
        var rules = Keymap.default.rules
        let rows = KeybindingsLogic.rows(rules)
        #expect(rows.allSatisfy { $0.source == .default })
        // mod+d means terminal.split with terminalFocus and diff.toggle without it: no conflict.
        #expect(rows.first { $0.command == "diff.toggle" }?.conflicts == [])
        // A custom mod+k on the sidebar conflicts with the palette (both can apply).
        rules.append(ResolvedKeybindingRule(key: "mod+k", command: "sidebar.toggle")!)
        let custom = KeybindingsLogic.rows(rules)
        let sidebar = custom.first { $0.command == "sidebar.toggle" && $0.key == "mod+k" }!
        #expect(sidebar.source == .custom)
        #expect(sidebar.defaultKey == "mod+b")
        #expect(sidebar.conflicts == ["Command Palette: Toggle"])
        #expect(KeybindingsLogic.conflictDescription(sidebar.conflicts) == "Conflicts with Command Palette: Toggle.")
        // Sorted by command; usage commands as one block.
        let commands = custom.map(\.command)
        #expect(commands.firstIndex(of: "chat.new")! < commands.firstIndex(of: "sidebar.toggle")!)
        let usage = commands.filter { $0.hasPrefix("usage.") }
        #expect(Array(usage.prefix(4)) == ["usage.open", "usage.cost", "usage.tokens", "usage.limits"])
        // The query filters by command, label, keys, when and source.
        #expect(KeybindingsLogic.rows(rules, query: "custom").map(\.command) == ["sidebar.toggle"])
    }

    @Test func groupsAndEdits() {
        let groups = KeybindingsLogic.group(KeybindingsLogic.rows(Keymap.default.rules))
        #expect(groups.map(\.title) == ["Navigation", "Threads", "Composer", "Terminal", "Preview & diff", "Appearance", "Other"])
        let row = KeybindingsLogic.rows(Keymap.default.rules).first { $0.command == "commandPalette.toggle" }!
        let (target, replace) = KeybindingsLogic.saveInput(row: row, key: "mod+shift+k", when: "")
        #expect(KeybindingsLogic.upsertPayload(target, replace: replace) == .object([
            "command": .string("commandPalette.toggle"), "key": .string("mod+shift+k"),
            "replace": .object(["command": .string("commandPalette.toggle"), "key": .string("mod+k"), "when": .string("!terminalFocus")]),
        ]))
        #expect(KeybindingsLogic.resetInput(row)?.0 == KeybindingTarget(command: "commandPalette.toggle", key: "mod+k", when: "!terminalFocus"))
    }

    @Test func whenExpressionsAndRecording() {
        let ast = KeybindingWhenNode.parse("a && (b || !c)")
        #expect(KeybindingsLogic.expression(ast) == "a && (b || !c)")
        #expect(KeybindingsLogic.parseWhen("") == .ok(nil))
        #expect(KeybindingsLogic.parseWhen("a &&") == .invalid("Use variables with !, &&, ||, and parentheses."))
        #expect(KeybindingsLogic.unknownVariables(KeybindingWhenNode.parse("terminalFocus && nope")) == ["nope"])
        #expect(KeybindingsLogic.whenVariableOptions.prefix(4) == ["terminalFocus", "terminalOpen", "isWeb", "isDesktop"])
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "k", physicalKey: "k", meta: true, shift: true)) == "mod+shift+k")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "escape")) == "esc")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "{", physicalKey: "[", meta: true, shift: true)) == "mod+shift+[")
        // The layout character records (#15972): German `ä` and `?` (Shift+ß), but US `?` stays `/` and Option uses the key.
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "ä", physicalKey: "'", meta: true)) == "mod+ä")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "?", physicalKey: "-", meta: true, shift: true)) == "mod+shift+?")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "?", physicalKey: "/", meta: true, shift: true)) == "mod+shift+/")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "-", physicalKey: "/", meta: true)) == "mod+-")
        #expect(KeybindingsLogic.binding(from: KeyStroke(key: "5", physicalKey: "1", alt: true)) == "alt+1")
        #expect(KeybindingsLogic.pillParts("mod+shift+k") == ["⌘", "⇧", "K"])
    }

    // MARK: Settings decode and encode

    @Test func clientSettingsDecodeWithDefaults() {
        let s = ClientSettings(decoding: .object([
            "timestampFormat": .string("24-hour"), "glassOpacity": .number(5), "confirmQuit": .bool(false), "unknown": .bool(true),
        ]))
        #expect(s.string("timestampFormat") == "24-hour")
        #expect(s.int("glassOpacity") == 80)          // out of range: default
        #expect(ClientSettings(decoding: .object(["glassOpacity": .number(10)])).int("glassOpacity") == 10)  // CandyWrapper's floor, under T3's 40
        #expect(s.string("confirmQuit") == "direct")  // legacy boolean
        #expect(s.values["unknown"] == nil)
        #expect(s.bool("showSkillsInSlashMenu"))
        var t = s
        #expect(t.apply(["sendShortcut": .string("mod-enter"), "diffLayout": .string("nope")]) == ["sendShortcut"])
        #expect(ClientSettings(decoding: t.encoded) == t)
    }

    @Test func serverSettingsDefaults() {
        let s = ServerSettingsValues(.object(["sidebarAutoSettleAfterDays": .null, "responseStreamingMode": .string("bogus")]))
        #expect(s["sidebarAutoSettleAfterDays"] == .null)
        #expect(!s.isDefault("sidebarAutoSettleAfterDays"))
        #expect(s.string("responseStreamingMode") == "paragraph")
        #expect(s.bool("enableProviderUpdateChecks"))
        #expect(s.isDefault("backgroundActivity"))
    }

    @Test func backgroundActivityProfiles() {
        let balanced = ServerSettingsValues(nil)
        #expect(BackgroundActivity.profileOption(balanced) == "balanced")
        let custom = ServerSettingsValues(.object(["backgroundActivity": BackgroundActivity.overrideSettings(balanced, ["automaticGitFetchInterval": .number(60_000)])]))
        #expect(BackgroundActivity.profileOption(custom) == "advanced")
        #expect(BackgroundActivity.resolveServer(custom).automaticGitFetchInterval == 60_000)
        // Overrides equal to a preset collapse back to it.
        let back = ServerSettingsValues(.object(["backgroundActivity": BackgroundActivity.overrideSettings(balanced, [:])]))
        #expect(BackgroundActivity.profileOption(back) == "balanced")
        // Legacy flat fields count while backgroundActivity is default.
        let legacy = ServerSettingsValues(.object(["backgroundActivityProfile": .string("performance")]))
        #expect(BackgroundActivity.resolveServer(legacy).profile == "performance")
        #expect(BackgroundActivity.isChanged(legacy))
        let shared = BackgroundActivity.sharedPolicySettings(custom, profile: "battery-saver")
        #expect(shared["baseProfile"] == .string("battery-saver"))
        #expect(shared["overrides"]?["automaticGitFetchInterval"] == .number(60_000))
    }

    @Test func clientStorePersists() {
        let defaults = UserDefaults(suiteName: "settings-logic-tests-\(UUID().uuidString)")!
        let store = ClientSettingsStore(defaults: defaults)
        var seen: Set<String> = []
        store.observe { seen = $0 }
        store.update(["wordWrap": .bool(false)])
        #expect(seen == ["wordWrap"])
        #expect(ClientSettingsStore(defaults: defaults).current.bool("wordWrap") == false)
    }
}
