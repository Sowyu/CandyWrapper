import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The seeded sandbox behind reference-4928 (sandbox-4928-ref). Keep the older gallery and Redesign data unchanged.
@MainActor
enum Screen3824Fixtures {
    static func sidebar(dark: Bool) -> ShellSnapshot {
        let p = "project-demo"
        // The rows of reference-4928/02-sidebar-populated, newest first, with the ages each theme's capture shows.
        let rows: [(String, SidebarPreview.Kind, Double, Double)] = [
            ("Lighthouse Story", .read, 1, 7),
            ("Lighthouse Story", .read, 4, 10),
            ("Scratch idea", .read, 3, 9),
            ("Document greet and update notes", .done, 5, 11),
            ("Create Approval File", .approval, 6, 12),
            ("CLI Tool Clarification", .input, 7, 13),
            ("Run Shell Commands", .read, 17, 23),
            ("Markdown Response Formatting Request", .read, 17, 23),
        ]
        var threads = rows.enumerated().map { i, row in
            // Every seeded thread but "Scratch idea" ran on main. T3 orders active rows by creation
            // (client-runtime state/threadSort.ts:254-275), so the second story sorts above the older scratch thread
            // although its reply is a minute older.
            var extra: [String: Any] = row.0 == "Scratch idea" ? [:] : ["branch": "main"]
            extra["createdAt"] = SidebarPreview.iso(Double(40 + i))
            return SidebarPreview.thread("t\(i)", row.0, project: p, kind: row.1, minutesAgo: dark ? row.2 : row.3, extra: extra)
        }
        // The footer's Snoozed 1 and Settled 1: "Tidy the README" snoozed until 2027-01-04, "Plan release notes" settled.
        threads.append(SidebarPreview.thread("t8", "Tidy the README", project: p, kind: .waiting, minutesAgo: 30,
                                             extra: ["snoozedUntil": "2027-01-04T09:00:00.000Z", "snoozedAt": SidebarPreview.iso(30)]))
        threads.append(SidebarPreview.thread("t9", "Plan release notes", project: p, kind: .waiting, minutesAgo: 30,
                                             extra: ["settledOverride": "settled", "settledAt": SidebarPreview.iso(30)]))
        return SidebarPreview.snapshot(projects: [SidebarPreview.project(p, "demo-repo")], threads: threads)
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
