import AppKit
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The seeded sandbox behind reference-4928 (sandbox-4928-ref). Keep the older gallery and Redesign data unchanged.
@MainActor
enum Screen3824Fixtures {
    static func sidebar(dark: Bool) -> ShellSnapshot {
        let p = "project-demo"
        // The rows of reference-4928/02-sidebar-populated.dark.png, newest first.
        let rows: [(String, SidebarPreview.Kind, Double)] = [
            ("Lighthouse Story", .read, 1),
            ("Lighthouse Story", .read, 4),
            ("Scratch idea", .read, 3),
            ("Document greet and update notes", .done, 5),
            ("Create Approval File", .approval, 6),
            ("CLI Tool Clarification", .input, 7),
            ("Run Shell Commands", .read, 17),
            ("Markdown Response Formatting Request", .read, 17),
        ]
        return SidebarPreview.snapshot(projects: [SidebarPreview.project(p, "demo-repo")], threads: rows.enumerated().map { i, row in
            SidebarPreview.thread("t\(i)", row.0, project: p, kind: row.1, minutesAgo: row.2)
        })
    }

    static func pickers(draft: Bool = false) throws -> ComposerPickers {
        let config = try PickersFidelityTests.recordedConfig(transcript: "24-nightly-3814")
        let context = ComposerSelectionContext(catalog: ProviderCatalog(config.providers), serverDefaults: config.settings)
        let store = ComposerSelectionStore(defaults: nil)
        store.pickModel("3824", instance: draft ? "codex" : "claudeAgent", model: draft ? "gpt-6-astra" : "claude-haiku-5-5", context)
        return ComposerPickers(store: store, draftKey: "3824", context: context)
    }

    static func markdown() throws -> ThreadProjection {
        var projection = try ThreadPreview.projection(titled: ThreadPreview.markdownThread)!
        let text = try String(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("fixtures/screen-4928-markdown.md"), encoding: .utf8)
        for i in projection.messages.indices where projection.messages[i].role == "assistant" { projection.messages[i].text = text }
        func replace(_ item: TurnItem) throws -> TurnItem {
            guard item.type == .assistantMessage else { return item }
            var raw = item.raw.objectValue!
            raw["text"] = .string(text)
            return try JSONDecoder().decode(TurnItem.self, from: JSONEncoder().encode(JSONValue.object(raw)))
        }
        projection.turnItems = try projection.turnItems.map(replace)
        projection.visibleTurnItems = try projection.visibleTurnItems.map { entry in
            var entry = entry
            entry.item = try replace(entry.item)
            return entry
        }
        return projection
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
