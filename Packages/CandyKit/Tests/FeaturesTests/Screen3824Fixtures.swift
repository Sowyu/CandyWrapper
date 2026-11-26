import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The seeded sandbox behind reference-4928 (sandbox-4928-ref). Keep the older gallery and Redesign data unchanged.
@MainActor
enum Screen3824Fixtures {
    /// The rows of reference-5258/02-sidebar-populated, top to bottom: sandbox-4928-ref's data as a 5258
    /// client shows it six days later. Approval and Input lead because `sortInboxThreadsByReturn`
    /// (client-runtime state/threadInbox.ts:57-75) takes their latest run's time, so the fixture gives them the
    /// newest anchors. The approval expired when the server restarted, so only Input still shows a status.
    static let sidebarEnvironment = "sandbox"
    static let sidebarActiveThread = ThreadId(EnvironmentScope.key(sidebarEnvironment, "t7"))
    static let sidebarEnvironments = SidebarEnvironments(primaryId: sidebarEnvironment, labels: [sidebarEnvironment: "Sandbox Mac"],
                                                         machines: [sidebarEnvironment: "mac-mini"])

    static func sidebar(dark: Bool) -> ShellSnapshot {
        let p = "project-demo"
        let rows: [(String, SidebarPreview.Kind)] = [
            ("Create Approval File", .read),
            ("CLI Tool Clarification", .input),
            ("Lighthouse Story", .read),
            ("Lighthouse Story", .read),
            ("Scratch idea", .read),
            ("Document greet and update notes", .read),
            ("Run Shell Commands", .read),
            ("Markdown Response Formatting Request", .read),
        ]
        // Six days and two hours: every row reads "6d", as in both captures.
        let age = 6.0 * 1440 + 120
        var threads = rows.enumerated().map { i, row in
            SidebarPreview.thread("t\(i)", row.0, project: p, kind: row.1, minutesAgo: age,
                                  extra: ["createdAt": SidebarPreview.iso(age + Double(i))])
        }
        // "Tidy the README" snoozed until 2027-01-04, "Plan release notes" settled.
        threads.append(SidebarPreview.thread("t8", "Tidy the README", project: p, kind: .waiting, minutesAgo: age + 30,
                                             extra: ["snoozedUntil": "2027-01-04T09:00:00.000Z", "snoozedAt": SidebarPreview.iso(age + 30)]))
        threads.append(SidebarPreview.thread("t9", "Plan release notes", project: p, kind: .waiting, minutesAgo: age + 30,
                                             extra: ["settledOverride": "settled", "settledAt": SidebarPreview.iso(age + 30)]))
        let snapshot = SidebarPreview.snapshot(projects: [SidebarPreview.project(p, "demo-repo")], threads: threads)
        return EnvironmentScope.scope(snapshot, environmentId: sidebarEnvironment)
    }

    static func pickers(draft: Bool = false) throws -> ComposerPickers {
        // The 4928 server config: its Claude list has Fable 5.2, as the 4928 docked picker shows.
        let config = try PickersFidelityTests.recordedConfig(transcript: "26-nightly-4928")
        let context = ComposerSelectionContext(catalog: ProviderCatalog(config.providers), serverDefaults: config.settings)
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("3824", instance: draft ? "codex" : "claudeAgent", model: draft ? "gpt-6-astra" : "claude-haiku-5-5", context)
        return ComposerPickers(store: store, draftKey: "3824", context: context)
    }

    /// The recorded markdown thread of sandbox-4928-ref, as 03a-c and 54 show it.
    static func markdown() throws -> ThreadProjection {
        try #require(try ThreadFidelityTests.projection(ThreadPreview.markdownThread))
    }

    static func contextStrip(_ strip: ComposerContextStripView) {
        strip.showsGitControls = true
        strip.runContext.glyphs = [IconName.folder.definition]
        strip.runContext.text = "Current checkout"
        strip.branch.text = "main"
        strip.showsPermissions = true
        strip.permissions.glyphs = [ComposerPickers.fullAccessGlyph]
        strip.permissions.text = "Full access"
    }
}
