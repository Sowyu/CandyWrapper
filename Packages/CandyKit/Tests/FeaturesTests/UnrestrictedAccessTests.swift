import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// CandyWrapper-only Unrestricted access (docs/decisions.md, 2026-11-20). No T3 reference exists for it.
@MainActor @Suite
struct UnrestrictedAccessTests {
    static let variable = UnrestrictedAccess.variable

    static func settings(_ environment: [JSONValue]? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var claude: [String: JSONValue] = ["driver": .string("claudeAgent")]
        if let environment { claude["environment"] = .array(environment) }
        return .object(["providerInstances": .object(["claudeAgent": .object(claude)].merging(extra) { a, _ in a })])
    }
    static func variable(_ name: String, _ value: String, sensitive: Bool = false) -> JSONValue {
        .object(["name": .string(name), "value": .string(value), "sensitive": .bool(sensitive)])
    }

    @Test func readsTheVariableLikeClaudeCode() {
        let instance = { (v: [JSONValue]) in Self.settings(v)["providerInstances"]!["claudeAgent"]! }
        #expect(!UnrestrictedAccess.isOn(.object(["driver": .string("claudeAgent")])))
        for on in ["1", "true", "YES", " on "] { #expect(UnrestrictedAccess.isOn(instance([Self.variable(Self.variable, on)]))) }
        for off in ["0", "", "false", "2"] { #expect(!UnrestrictedAccess.isOn(instance([Self.variable(Self.variable, off)]))) }
        // A sensitive value the server hides still reaches Claude Code.
        let redacted = JSONValue.object(["name": .string(Self.variable), "value": .string(""), "sensitive": .bool(true), "valueRedacted": .bool(true)])
        #expect(UnrestrictedAccess.isOn(instance([redacted])))
    }

    @Test func patchSetsAndRemovesOnlyTheVariable() {
        let settings = Self.settings([Self.variable("ANTHROPIC_BASE_URL", "http://x"), Self.variable(Self.variable, "0")])
        let on = UnrestrictedAccess.payload(settings, instanceId: "claudeAgent", driver: "claudeAgent", on: true)
        #expect(on["patch"] == .object([:]))
        let mutation = on["providerInstanceMutation"]!
        #expect(mutation["operation"] == .string("upsert") && mutation["instanceId"] == .string("claudeAgent"))
        #expect(mutation["instance"]!["environment"] == .array([Self.variable("ANTHROPIC_BASE_URL", "http://x"), Self.variable(Self.variable, "1")]))

        let off = UnrestrictedAccess.payload(settings, instanceId: "claudeAgent", driver: "claudeAgent", on: false)
        #expect(off["providerInstanceMutation"]!["instance"]!["environment"] == .array([Self.variable("ANTHROPIC_BASE_URL", "http://x")]))
        // The last variable gone drops the key, as the Environment list does.
        let lone = UnrestrictedAccess.payload(Self.settings([Self.variable(Self.variable, "1")]), instanceId: "claudeAgent", driver: "claudeAgent", on: false)
        #expect(lone["providerInstanceMutation"]!["instance"] == .object(["driver": .string("claudeAgent")]))
        // The default slot the server has no entry for yet.
        let fresh = UnrestrictedAccess.payload(.object(["providerInstances": .object([:])]), instanceId: "claudeAgent", driver: "claudeAgent", on: true)
        #expect(fresh["providerInstanceMutation"]!["instance"] == .object(["driver": .string("claudeAgent"), "environment": .array([Self.variable(Self.variable, "1")])]))
    }

    @Test func offeredOnlyWhereItCanWork() {
        let settings = Self.settings()
        #expect(UnrestrictedAccess.state(settings: settings, instanceId: "claudeAgent", driver: "claudeAgent", version: "2.1.328", canManage: true)
                == .init(on: false))
        #expect(UnrestrictedAccess.state(settings: settings, instanceId: "codex", driver: "codex", version: nil, canManage: true) == nil)
        #expect(UnrestrictedAccess.state(settings: settings, instanceId: "claudeAgent", driver: "claudeAgent", version: nil, canManage: false) == nil)
        // A server without provider instances ignores instance environments.
        #expect(UnrestrictedAccess.state(settings: .object([:]), instanceId: "claudeAgent", driver: "claudeAgent", version: nil, canManage: true) == nil)
        let old = UnrestrictedAccess.state(settings: settings, instanceId: "claudeAgent", driver: "claudeAgent", version: "2.1.295 (Claude Code)", canManage: true)
        #expect(old?.unsupportedHint == "Checked with Claude Code 2.1.328. This machine has 2.1.295, which may ignore it.")
        #expect(UnrestrictedAccess.state(settings: settings, instanceId: "claudeAgent", driver: "claudeAgent", version: "2.2.0", canManage: true)?.unsupportedHint == nil)
    }

    /// A hand edit in the Environment list publishes the same instance the switch and menu read.
    @Test func switchFollowsAHandEdit() throws {
        var instance = Self.settings()["providerInstances"]!["claudeAgent"]!
        let rows = [ProviderEnvironmentLogic.Draft(id: 1, .init(name: Self.variable, value: "1", sensitive: true))]
        instance = ProviderEnvironmentLogic.instance(instance, environment: try #require(ProviderEnvironmentLogic.publish(rows)))
        #expect(UnrestrictedAccess.isOn(instance))
        instance = ProviderEnvironmentLogic.instance(instance, environment: try #require(ProviderEnvironmentLogic.publish([])))
        #expect(!UnrestrictedAccess.isOn(instance))
    }

    @Test func confirmsOncePerInstance() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnrestrictedAccessTests"))
        defaults.removePersistentDomain(forName: "UnrestrictedAccessTests")
        var ran = 0
        // Not confirmed and no window: nothing runs.
        UnrestrictedAccess.confirm(in: nil, environment: "e1", instance: "claudeAgent", machine: "m", provider: "Claude", defaults: defaults) { ran += 1 }
        #expect(ran == 0 && UnrestrictedAccess.needsConfirm(environment: "e1", instance: "claudeAgent", defaults: defaults))
        UnrestrictedAccess.markConfirmed(environment: "e1", instance: "claudeAgent", defaults: defaults)
        UnrestrictedAccess.confirm(in: nil, environment: "e1", instance: "claudeAgent", machine: "m", provider: "Claude", defaults: defaults) { ran += 1 }
        #expect(ran == 1)
        #expect(UnrestrictedAccess.needsConfirm(environment: "e1", instance: "claudeWork", defaults: defaults))
        #expect(UnrestrictedAccess.needsConfirm(environment: "e2", instance: "claudeAgent", defaults: defaults))
        defaults.removePersistentDomain(forName: "UnrestrictedAccessTests")
    }

    /// The dialog: destructive confirm second, Cancel first so it takes the initial focus.
    @Test func dialogButtons() throws {
        let defaults = try #require(UserDefaults(suiteName: "UnrestrictedAccessDialog"))
        defaults.removePersistentDomain(forName: "UnrestrictedAccessDialog")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        var ran = false
        UnrestrictedAccess.confirm(in: window, environment: "e", instance: "claudeAgent", machine: "Sandbox", provider: "Claude", defaults: defaults) { ran = true }
        let host = try #require(window.contentView?.subviews.compactMap { $0 as? ModalHost }.first)
        let dialog = try #require(Self.find(DialogView.self, in: host))
        #expect(dialog.footerButtons.map { ($0 as? ButtonView)?.title } == ["Cancel", "Turn on Unrestricted"])
        #expect((dialog.footerButtons[1] as? ButtonView)?.variant == .destructive)
        #expect(!ran)
        (dialog.footerButtons[1] as? ButtonView)?.action?()
        #expect(ran && !UnrestrictedAccess.needsConfirm(environment: "e", instance: "claudeAgent", defaults: defaults))
        defaults.removePersistentDomain(forName: "UnrestrictedAccessDialog")
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    // MARK: Menu

    static func titles(_ entries: [PickerMenuEntry]) -> [String] { entries.filter { $0.kind == .option }.map(\.title) }

    @Test func menuForClaudeAndOtherThreads() throws {
        let p = try PickersFidelityTests.pickers()
        // No state from the app: exactly T3's entries.
        #expect(Self.titles(p.accessEntries()) == ["Supervised", "Auto-accept edits", "Auto", "Full access"].filter { t in
            p.current.runtimeModeOptions.contains { ComposerPickers.modes[$0]?.label == t } })
        let base = Self.titles(p.accessEntries())
        p.unrestrictedAccess = { _ in .init(on: false) }
        p.update()
        #expect(Self.titles(p.accessEntries()) == base + ["Unrestricted"])
        #expect(ComposerPermissionsView(modes: p.current.runtimeModeOptions, selected: .fullAccess, unrestricted: p.unrestricted).extraHeight == 0)

        // A Codex draft never shows it, whatever the app reports.
        // The recorded Claude provider relabelled as a Codex instance, the only other ready provider shape at hand.
        let config = try PickersFidelityTests.recordedConfig()
        var codex = try #require(config.providers.first { $0.driver == "claudeAgent" })
        codex.instanceId = "codexWork"; codex.driver = "codex"; codex.displayName = "Codex"
        let ctx = ComposerSelectionContext(catalog: ProviderCatalog([codex]), serverDefaults: config.settings)
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("draft", instance: "codexWork", model: "claude-haiku-5-5", ctx)
        let other = ComposerPickers(store: store, draftKey: "draft", context: ctx)
        other.unrestrictedAccess = { _ in .init(on: true) }
        other.update()
        #expect(other.current.entry?.driver == "codex")
        #expect(other.unrestricted == nil && !Self.titles(other.accessEntries()).contains("Unrestricted"))
    }

    @Test func selectedStateAndPicks() throws {
        let p = try PickersFidelityTests.pickers()
        var state = UnrestrictedAccess.State(on: false)
        p.unrestrictedAccess = { _ in state }
        var picks: [Bool] = []
        p.onUnrestricted = { picks.append($0) }
        p.update()
        #expect(p.current.runtimeMode == .fullAccess && p.accessButton.title == "Full access")

        let off = p.accessEntries()
        #expect(off.first { $0.title == "Full access" }?.checked == true && off.first { $0.title == "Unrestricted" }?.checked == false)
        off.first { $0.title == "Unrestricted" }?.onPick?()
        #expect(picks == [true])

        // The server echo turns it on: the trigger and the checked row follow.
        state = .init(on: true)
        p.update()
        #expect(p.isUnrestricted && p.accessButton.title == "Unrestricted")
        let on = p.accessEntries()
        #expect(on.first { $0.title == "Full access" }?.checked == false && on.first { $0.title == "Unrestricted" }?.checked == true)
        #expect(Self.titles(on).last == "Turn off Unrestricted")
        #expect(ComposerPermissionsView(modes: p.current.runtimeModeOptions, selected: .fullAccess, unrestricted: state).extraHeight > 0)
        on.first { $0.title == "Turn off Unrestricted" }?.onPick?()
        #expect(picks == [true, false])

        // Supervised with it on: the thread is not Unrestricted, though the instance still is.
        on.first { $0.title == "Supervised" }?.onPick?()
        #expect(!p.isUnrestricted && p.accessButton.title == "Supervised")
        #expect(p.accessEntries().first { $0.title == "Unrestricted" }?.checked == false)
        #expect(Self.titles(p.accessEntries()).last == "Turn off Unrestricted")
        p.chooseFullAccess()
        #expect(p.isUnrestricted && p.current.runtimeMode == .fullAccess)
    }

    /// Screen pass 3, item 2: the Turn off row sat at a fixed y over the hint's third line and past the menu's end.
    @Test func turnOffRowSitsBelowTheWholeHint() {
        let view = ComposerPermissionsView(modes: [.approvalRequired, .autoAcceptEdits, .auto, .fullAccess], selected: .fullAccess,
                                           unrestricted: .init(on: true))
        view.frame = NSRect(x: 0, y: 0, width: 288, height: 122 + view.extraHeight)
        view.layoutSubtreeIfNeeded()
        let detail = view.subviews.compactMap { $0 as? TextBlockView }.first { $0.text == UnrestrictedAccess.description }
        let button = view.subviews.compactMap { $0 as? ButtonView }.first
        guard let detail, let button else { Issue.record("missing hint or button"); return }
        #expect(detail.layout(forWidth: detail.bounds.width).height > 32)
        #expect(button.frame.minY >= detail.frame.minY + detail.layout(forWidth: detail.bounds.width).height)
        #expect(button.frame.maxY <= view.bounds.height)
    }
}
