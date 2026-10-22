import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Storage > Cleanup > "Delete now" (StorageSettings.tsx `deleteNow`): it runs
/// `server.runStorageCleanup` on every environment that supports it and that this connection may
/// write, and nowhere else. T3 asks no confirmation; the button stays off until a cleanup rule is on.
@MainActor
struct StorageCleanupDeleteNowTests {
    struct Refused: Error, CustomStringConvertible { var description: String { "refused" } }

    static func env(_ id: String, rules: Bool = true, supported: Bool = true, canWrite: Bool = true) -> SettingsScopeEnvironment {
        let storage: JSONValue = .object(["logsAfterDays": rules ? .number(7) : .null])
        return SettingsScopeEnvironment(id: id, label: "Mac \(id)", settings: ServerSettingsValues(.object(["storageCleanup": storage])),
                                        capabilities: supported ? ["storageCleanup", "storageCleanupRun"] : ["storageCleanup"],
                                        canWrite: canWrite)
    }

    static func page(_ envs: [SettingsScopeEnvironment]) -> (StorageSettingsView, ButtonView, SettingsPageContext) {
        let c = SettingsPageContext()
        c.scope = SettingsScopeState(environments: envs, primaryId: envs.first?.id)
        let page = StorageSettingsView(context: c)
        page.refresh()
        let button = (page.anchor("storage-delete-now") as? SettingsRowView)?.control as! ButtonView
        return (page, button, c)
    }

    @Test func runsOnlyWhereItMayAndReportsEachFailure() async throws {
        let (page, button, c) = Self.page([Self.env("a"), Self.env("b"), Self.env("readonly", canWrite: false),
                                           Self.env("old", supported: false)])
        var calls: [String] = []
        var toasts: [String] = []
        c.toast = { title, message, _ in toasts.append("\(title): \(message ?? "")") }
        c.request = { env, method, _ in
            calls.append("\(env) \(method)")
            if env == "b" { throw Refused() }
            return .object(["finishedAt": .string("2026-10-22T10:00:00.000Z"), "counts": .object(["removed": .number(0), "kept": .number(0), "failed": .number(1)]),
                            "entries": .array([.object(["kind": .string("worktree"), "outcome": .string("failed"), "reason": .string("busy")])])])
        }
        #expect(button.isEnabled && button.title == "Delete now")

        button.performAction()
        #expect(button.title == "Deleting…" && !button.isEnabled)
        // A second click while it runs starts nothing more.
        button.performAction()

        try #require(await eventually { button.isEnabled })
        #expect(calls.sorted() == ["a server.runStorageCleanup", "b server.runStorageCleanup"])
        #expect(toasts.sorted() == ["Cleanup failed on Mac a: busy", "Could not run cleanup on Mac b: refused"])
        #expect(button.title == "Delete now")
        _ = page
    }

    @Test func offWithoutARuleOrAWritableEnvironment() {
        #expect(!Self.page([Self.env("a", rules: false)]).1.isEnabled)
        #expect(!Self.page([Self.env("a", canWrite: false)]).1.isEnabled)
        #expect(Self.page([Self.env("a")]).1.isEnabled)
    }
}
