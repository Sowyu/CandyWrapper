import Foundation
import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

@MainActor
struct IssueTrackerSettingsTests {
    static func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    static let linear = json("""
    {"tracker":"linear","displayName":"Linear","host":"linear.app","scopeNoun":"team",
     "credential":{"label":"Personal API key","helpUrl":"https://linear.app/settings/account/security"},
     "connected":true,"account":"dev@example.com","detail":null,"workspace":"Acme",
     "scopes":[{"key":"ENG","name":"Engineering"},{"key":"OPS","name":"Ops"}]}
    """)

    static func connection(_ patch: [String: JSONValue] = [:]) throws -> IssueTrackerConnectionList.Connection {
        guard case .object(var o) = linear else { fatalError() }
        for (k, v) in patch { o[k] = v }
        return try JSONValue.object(o).decode(as: IssueTrackerConnectionList.Connection.self)
    }

    @Test func summaryFollowsIssueTrackerSummary() throws {
        let off = try Self.connection(["connected": .bool(false), "account": .null])
        #expect(IssueTrackerSettingsLogic.summary(off, bindings: [:]) == "Not connected. Add a personal api key to list its issues.")
        let rejected = try Self.connection(["account": .null])
        #expect(IssueTrackerSettingsLogic.summary(rejected, bindings: [:]) == "The saved credential was rejected.")
        let on = try Self.connection()
        #expect(IssueTrackerSettingsLogic.summary(on, bindings: [:])
            == "Connected as dev@example.com · no projects linked yet. Pick a team for a project to list its issues.")
        let one = ["p1": IssueTrackerConnectionList.Binding(tracker: "linear", scope: "ENG"),
                   "p2": IssueTrackerConnectionList.Binding(tracker: "jira", scope: "X")]
        #expect(IssueTrackerSettingsLogic.summary(on, bindings: one) == "Connected as dev@example.com · 1 project linked")
    }

    @Test func payloadsAndPickerSelection() throws {
        let t = try Self.connection()
        #expect(IssueTrackerSettingsLogic.connect(t, token: nil) == Self.json(#"{"tracker":"linear","token":null}"#))
        #expect(IssueTrackerSettingsLogic.connect(t, token: "k", addAccount: true) == Self.json(#"{"tracker":"linear","token":"k","addAccount":true}"#))
        let second = try Self.connection(["accountId": .string("acme-2")])
        #expect(IssueTrackerSettingsLogic.connect(second, token: nil) == Self.json(#"{"tracker":"linear","accountId":"acme-2","token":null}"#))
        let eng = IssueTrackerSettingsLogic.binding(for: t, current: [], scopes: ["ENG"])
        #expect(IssueTrackerSettingsLogic.bind(projectId: "p", tracker: t, binding: eng)
            == Self.json(#"{"projectId":"p","binding":{"tracker":"linear","scope":"ENG"}}"#))
        #expect(IssueTrackerSettingsLogic.bind(projectId: "p", tracker: t, binding: nil) == Self.json(#"{"projectId":"p","binding":null}"#))
        // An unbind under an added account names it.
        #expect(IssueTrackerSettingsLogic.bind(projectId: "p", tracker: second, binding: nil)
            == Self.json(#"{"projectId":"p","binding":null,"accountId":"acme-2"}"#))
        // The scope kept from before stays the filing scope.
        let both = IssueTrackerSettingsLogic.binding(for: t, current: ["OPS"], scopes: ["ENG", "OPS"])
        #expect(both == .init(tracker: "linear", scope: "OPS", additionalScopes: ["ENG"]))
        #expect(IssueTrackerSettingsLogic.binding(for: t, current: ["OPS"], scopes: []) == nil)
        #expect(IssueTrackerSettingsLogic.value(t, bound: ["OPS", "ENG"]) == "Ops, Engineering")
        #expect(IssueTrackerSettingsLogic.value(t, bound: []) == "Not bound")
        // Bound to another tracker or account: this picker shows unbound.
        #expect(IssueTrackerSettingsLogic.boundScopes(t, binding: .init(tracker: "jira", scope: "OPS")) == [])
        #expect(IssueTrackerSettingsLogic.boundScopes(t, binding: .init(tracker: "linear", accountId: "acme-2", scope: "OPS")) == [])
        #expect(IssueTrackerSettingsLogic.boundScopes(second, binding: .init(tracker: "linear", accountId: "acme-2", scope: "OPS")) == ["OPS"])
        // A bound key the tracker no longer offers stays listed under its key.
        #expect(IssueTrackerSettingsLogic.scopeOptions(t, bound: ["GONE"]).map(\.name) == ["Engineering", "Ops", "GONE"])
    }

    @Test func accountsListUnderTheirTracker() throws {
        let list = try JSONValue.object([
            "trackers": .array([Self.linear]),
            "accounts": .array([try JSONValueEncoder().encode(Self.connection(["accountId": .string("b"), "workspace": .string("Beta")]))]),
            "bindings": .object(["p1": .object(["tracker": .string("linear"), "scope": .string("ENG")])]),
            "accountBindings": .object(["p2": .object(["tracker": .string("linear"), "accountId": .string("b"), "scope": .string("OPS")])]),
        ]).decode(as: IssueTrackerConnectionList.self)
        let rows = IssueTrackerSettingsLogic.rows(list)
        #expect(rows.map(\.accountId) == [nil, "b"])
        let bindings = IssueTrackerSettingsLogic.bindings(list)
        #expect(IssueTrackerSettingsLogic.summary(rows[1], bindings: bindings) == "Connected as dev@example.com · 1 project linked")
        #expect(IssueTrackerSettingsLogic.canAddAccount(rows[0], list: list, capable: true))
        #expect(!IssueTrackerSettingsLogic.canAddAccount(rows[1], list: list, capable: true))
        #expect(!IssueTrackerSettingsLogic.canAddAccount(rows[0], list: list, capable: false))
    }

    @Test func pageListsTrackersOnlyWhereTheServerHasIssues() async throws {
        let context = SettingsPageContext()
        var calls: [(String, JSONValue)] = []
        context.request = { _, method, payload in
            calls.append((method, payload))
            switch method {
            case "issueTrackers.list": return .object(["trackers": .array([Self.linear]), "bindings": .object([:])])
            case "issueTrackers.bindProject": return .null
            default: return .object([:])
            }
        }
        let member = SettingsScopeProject.Member(environmentId: "a", projectId: "p1", title: "App", workspaceRoot: "/x")
        // A 3824 server: no `issues` capability, no request.
        context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "a", settings: ServerSettingsValues(.object([:])))],
                                           primaryId: "a", projects: [SettingsScopeProject(key: "k", displayName: "App", members: [member])])
        let old = SourceControlSettingsView(context: context)
        old.refresh()
        await Task.yield()
        #expect(!calls.contains { $0.0 == "issueTrackers.list" })

        context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "a", settings: ServerSettingsValues(.object([:])),
                                                                                   capabilities: ["issues"])],
                                           primaryId: "a", projects: [SettingsScopeProject(key: "k", displayName: "App", members: [member])])
        let page = SourceControlSettingsView(context: context)
        page.refresh()
        let section = try #require(page.anchor("issue-trackers") as? SettingsSectionView)
        while section.group.rows.isEmpty { await Task.yield() }
        let row = try #require(section.group.rows.first as? IssueTrackerRow)
        #expect(row.tracker.displayName == "Linear")
        #expect(row.details.pickers.count == 1)
        row.details.pickers[0].onChangeMany?([0])
        while !calls.contains(where: { $0.0 == "issueTrackers.bindProject" }) { await Task.yield() }
        #expect(calls.first { $0.0 == "issueTrackers.bindProject" }?.1
            == Self.json(#"{"projectId":"p1","binding":{"tracker":"linear","scope":"ENG"}}"#))
    }
}
