import AppKit
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The copied sandbox behind reference-3824. Keep the older gallery and Redesign data unchanged.
@MainActor
enum Screen3824Fixtures {
    static func sidebar(dark: Bool) -> ShellSnapshot {
        let p = "project-demo"
        let rows: [(String, SidebarPreview.Kind, Double)] = [
            ("Write a Lighthouse Story", .read, 3),
            ("Create Approval Text File", .approval, 4),
            ("Create Approval Demo File", .done, 5),
            ("Set Purpose and Language Preferences", .input, 6),
            ("Write a Lighthouse Story", .read, 65),
            ("Wait 45 Seconds Before Replying", .done, 66),
            ("Wait 45 Seconds", .read, 67),
            ("Document Hello Demo", .read, 68),
            ("Run Basic Shell Commands", .read, 69),
            ("Format a Markdown Reply", .read, 70),
        ]
        return SidebarPreview.snapshot(projects: [SidebarPreview.project(p, "demo-repo")], threads: rows.enumerated().filter { !dark || $0.offset != 0 }.map { i, row in
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
        let text = try String(contentsOf: SidebarFidelityTests.repo.appendingPathComponent("fixtures/screen-3824-markdown.md"), encoding: .utf8)
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
