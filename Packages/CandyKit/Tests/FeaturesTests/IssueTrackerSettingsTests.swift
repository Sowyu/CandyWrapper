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
        #expect(IssueTrackerSettingsLogic.connect(tracker: "linear", token: nil) == Self.json(#"{"tracker":"linear","token":null}"#))
        #expect(IssueTrackerSettingsLogic.bind(projectId: "p", tracker: "linear", scope: "ENG")
            == Self.json(#"{"projectId":"p","binding":{"tracker":"linear","scope":"ENG"}}"#))
        #expect(IssueTrackerSettingsLogic.bind(projectId: "p", tracker: "linear", scope: nil) == Self.json(#"{"projectId":"p","binding":null}"#))
        #expect(IssueTrackerSettingsLogic.options(t) == ["Not bound", "Engineering (ENG)", "Ops (OPS)"])
        #expect(IssueTrackerSettingsLogic.selectedIndex(t, binding: .init(tracker: "linear", scope: "OPS")) == 2)
        // Bound to another tracker: this picker shows unbound.
        #expect(IssueTrackerSettingsLogic.selectedIndex(t, binding: .init(tracker: "jira", scope: "OPS")) == 0)
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
        row.details.pickers[0].onChange?(1)
        while !calls.contains(where: { $0.0 == "issueTrackers.bindProject" }) { await Task.yield() }
        #expect(calls.last?.1 == IssueTrackerSettingsLogic.bind(projectId: "p1", tracker: "linear", scope: "ENG"))
    }
}
