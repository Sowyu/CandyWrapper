import AppKit
import DesignSystem
import Foundation
import Testing
import T3Protocol
@testable import T3Store
@testable import Features

/// The subagent card groups its rows by model when they run on two or more, in the picker's provider and model
/// order, and each row shows its provider's icon. Set CANDY_CARD_RENDER to a folder for pictures.
@MainActor
struct SubagentStripCardTests {
    static func provider(_ id: String, _ driver: String, _ name: String, models: [(String, String)]) -> ServerProvider {
        let list = models.map { #"{"slug":"\#($0.0)","name":"\#($0.1)","isCustom":false,"capabilities":null}"# }.joined(separator: ",")
        let json = #"{"instanceId":"\#(id)","driver":"\#(driver)","displayName":"\#(name)","enabled":true,"installed":true,"status":"ready","auth":{"status":"authenticated"},"models":[\#(list)]}"#
        return try! JSONDecoder().decode(ServerProvider.self, from: Data(json.utf8))
    }
    static let claude = provider("claude", "claudeAgent", "Claude", models: [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5")])
    static let codex = provider("codex", "codex", "Codex", models: [("gpt-6.2-astra", "GPT-6.2 Astra")])

    static func row(_ key: String, _ instance: String, _ driver: String, _ model: String?, _ status: SubagentStrip.Status = .running) -> SubagentStrip.Row {
        let start = T3Timestamp("2026-11-22T10:00:00.000Z")
        let end = status == .done || status == .failed ? T3Timestamp("2026-11-22T10:02:10.000Z") : nil
        return SubagentStrip.Row(id: key, key: key, number: 1, childThreadId: nil, title: key, status: status, driver: driver,
                                 providerInstanceId: instance, model: model, canStop: false, startedAt: start, completedAt: end)
    }

    static func panel(_ rows: [SubagentStrip.Row], providers: [ServerProvider]) -> SubagentStripPanelView {
        let panel = SubagentStripPanelView()
        panel.nowMs = T3Timestamp("2026-11-22T10:03:30.000Z").epochMs
        panel.items = rows.map { .init(row: $0, modelName: ThreadLineageController.modelName($0, providers), group: ThreadLineageController.modelGroup($0, providers)) }
        panel.frame = NSRect(x: 0, y: 0, width: 520, height: panel.preferredHeight(maxHeight: 1000))
        panel.layoutSubtreeIfNeeded()
        return panel
    }

    static func shape(_ panel: SubagentStripPanelView) -> [String] {
        SubagentStripPanelView.entries(panel.items).map {
            switch $0 {
            case .heading(let t, let c): "# \(t)" + (c > 1 ? " \(c)" : "")
            case .row(let i): i.row.key
            }
        }
    }

    @Test func twoModelsGiveTwoHeadedGroupsInPickerOrder() {
        let rows = [Self.row("a", "claude", "claudeAgent", "claude-opus-5-5"), Self.row("b", "codex", "codex", "gpt-6.2-astra"),
                    Self.row("c", "claude", "claudeAgent", "claude-opus-5-5")]
        #expect(Self.shape(Self.panel(rows, providers: [Self.claude, Self.codex])) == ["# Claude Opus 5.5 2", "a", "c", "# GPT-6.2 Astra", "b"])
        #expect(Self.shape(Self.panel(rows, providers: [Self.codex, Self.claude])) == ["# GPT-6.2 Astra", "b", "# Claude Opus 5.5 2", "a", "c"])
        // Within a provider, the provider's model order.
        let two = [Self.row("s", "claude", "claudeAgent", "claude-sonnet-5-5"), Self.row("o", "claude", "claudeAgent", "claude-opus-5-5")]
        #expect(Self.shape(Self.panel(two, providers: [Self.claude])) == ["# Claude Opus 5.5", "o", "# Claude Sonnet 5.5", "s"])
    }

    @Test func oneModelShowsNoHeading() {
        let rows = [Self.row("a", "claude", "claudeAgent", "claude-opus-5-5"), Self.row("b", "claude", "claudeAgent", "claude-opus-5-5", .done)]
        let panel = Self.panel(rows, providers: [Self.claude])
        #expect(Self.shape(panel) == ["a", "b"])
        #expect(panel.headerText == "Claude Opus 5.5")
    }

    @Test func anUnknownModelGoesLastUnderItsProvider() {
        let rows = [Self.row("x", "claude", "claudeAgent", nil), Self.row("a", "codex", "codex", "gpt-6.2-astra"),
                    Self.row("y", "gone", "", nil)]
        #expect(Self.shape(Self.panel(rows, providers: [Self.claude, Self.codex])) == ["# GPT-6.2 Astra", "a", "# Claude", "x", "# Other", "y"])
    }

    @Test func eachRowHasItsProviderIconAndNamesTheModel() {
        let rows = [Self.row("a", "claude", "claudeAgent", "claude-opus-5-5"), Self.row("b", "codex", "codex", "gpt-6.2-astra"),
                    Self.row("c", "gone", "mystery", nil)]
        let views = SubagentStripPanelTests.rows(in: Self.panel(rows, providers: [Self.claude, Self.codex]))
        let byKey = Dictionary(uniqueKeysWithValues: views.map { ($0.item!.row.key, $0) })
        let claudeIcon = byKey["a"]?.provider as? IconView
        #expect(claudeIcon != nil && claudeIcon?.name != .bot)
        #expect((byKey["b"]?.provider as? IconView)?.name == .brandOpenAI)
        #expect((byKey["c"]?.provider as? IconView)?.name == .bot)
        #expect(byKey["b"]?.accessibilityLabel()?.contains("GPT-6.2 Astra") == true)
        #expect(byKey["b"]?.currentTooltip == "GPT-6.2 Astra")
    }

    @Test func headingsCountTowardTheHeightCap() {
        let rows = (0..<8).map { Self.row("r\($0)", $0 < 4 ? "claude" : "codex", $0 < 4 ? "claudeAgent" : "codex", $0 < 4 ? "claude-opus-5-5" : "gpt-6.2-astra") }
        let panel = Self.panel(rows, providers: [Self.claude, Self.codex])
        // Six rows and the two headings above them show; the rest scroll.
        let p = SubagentStripPanelView.self
        #expect(panel.preferredHeight(maxHeight: 1000) == 2 * p.pad + p.header + 6 * p.row + 2 * p.heading)
        #expect(panel.preferredHeight(maxHeight: 150) == 150)
    }

    @Test func theRecordsExecutedModelWins() throws {
        let json = #"{"id":"t","status":"running","driver":"codex","providerInstanceId":"codex","model":"gpt-6","modelSelection":{"instanceId":"codex","model":"gpt-6.1"},"executedModel":"gpt-6.2-astra"}"#
        let record = try #require(ProjectedSubagent(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        #expect(record.ranModel == "gpt-6.2-astra")
        let asked = #"{"id":"t","status":"running","model":"gpt-6","modelSelection":{"instanceId":"codex","model":"gpt-6.1"}}"#
        #expect(ProjectedSubagent(try JSONDecoder().decode(JSONValue.self, from: Data(asked.utf8)))?.ranModel == "gpt-6.1")
    }

    /// Pictures: one model with 2 rows, the user's two models, three models with 6 rows; dark and light, Redesign and
    /// default; provider icon first and status mark first.
    @Test func renderPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["CANDY_CARD_RENDER"] else { return }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous); SubagentStripRowView.providerFirst = true }
        let providers = [Self.claude, Self.codex]
        let sets: [(String, [SubagentStrip.Row])] = [
            ("one", [Self.row("Bug pass over this week's changes", "claude", "claudeAgent", "claude-opus-5-5"),
                     Self.row("Perf pass: thread rendering", "claude", "claudeAgent", "claude-opus-5-5")]),
            ("two", [Self.row("Bug pass over this week's changes", "codex", "codex", "gpt-6.2-astra"),
                     Self.row("Perf pass: thread rendering", "claude", "claudeAgent", "claude-opus-5-5")]),
            ("three", [Self.row("Bug pass over this week's changes", "codex", "codex", "gpt-6.2-astra"),
                       Self.row("Perf pass: thread rendering", "claude", "claudeAgent", "claude-opus-5-5"),
                       Self.row("Sidebar slim rows", "claude", "claudeAgent", "claude-sonnet-5-5"),
                       Self.row("Gallery missing tiles", "claude", "claudeAgent", "claude-opus-5-5", .waiting),
                       Self.row("Diff viewer wrap", "codex", "codex", "gpt-6.2-astra", .done),
                       Self.row("Settings search", "claude", "claudeAgent", "claude-sonnet-5-5", .failed)]),
        ]
        for redesign in [true, false] {
            var input = previous
            input.ditherLight = redesign; input.ditherDark = redesign
            ThemeRuntime.apply(input)
            for dark in [true, false] {
                for (variant, first) in [("icon-first", true), ("status-first", false)] {
                    SubagentStripRowView.providerFirst = first
                    for (name, rows) in sets {
                        let panel = Self.panel(rows, providers: providers)
                        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        panel.frame.origin = NSPoint(x: 12, y: 12)
                        let host = NSView(frame: NSRect(x: 0, y: 0, width: panel.frame.width + 24, height: panel.frame.height + 24))
                        host.appearance = panel.appearance
                        host.wantsLayer = true
                        host.layer?.backgroundColor = (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
                        host.addSubview(panel)
                        host.layoutSubtreeIfNeeded()
                        let rep = Snapshot.image(of: host, size: host.frame.size, scale: 2, dark: dark)
                        let file = "card-\(redesign ? "redesign" : "default")-\(dark ? "dark" : "light")-\(name)-\(variant).png"
                        try Snapshot.writePNG(rep, to: dir.appendingPathComponent(file))
                    }
                }
            }
        }
    }
}
