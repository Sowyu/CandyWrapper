import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Renders Redesign's empty, loading and error states to PNGs for review, Redesign dark and light. Opt in with
/// `CANDY_STATES_OUT=<folder>`; without it the test does nothing. It drives the views only through API that main also
/// has, so the same file renders the before pictures there.
@MainActor
struct RedesignStatesRenderTests {
    /// A git failure as the app's diff loader throws it: the RPC's text, which for this tag is the bare tag.
    struct SpawnFailure: LocalizedError {
        var errorDescription: String? = "VcsProcessSpawnError"
        var typed = RPCTypedError(tag: "VcsProcessSpawnError", fields: [
            "operation": .string("review.getDiffPreview"), "command": .string("git"),
            "cwd": .string("/Users/demo/sandbox/demo-repo")])
    }

    static func diffPanel(_ result: @escaping @Sendable () async throws -> String, summaries: Bool = true) -> DiffPanelView {
        let panel = DiffPanelView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        panel.threadId = "t1"
        panel.loader = { _ in
            let diff = try await result()
            let json = try JSONSerialization.data(withJSONObject: ["threadId": "t1", "fromTurnCount": 8, "toTurnCount": 9, "diff": diff])
            return try JSONDecoder().decode(ThreadTurnDiff.self, from: json)
        }
        panel.setSummaries(summaries ? [TurnDiffSummary(checkpointId: "c9", scopeId: "scope", runId: "run9", checkpointTurnCount: 9,
                                                        checkpointRef: "ref", status: "ready", files: [], assistantMessageId: nil,
                                                        completedAt: "2026-10-10T00:00:09Z")] : [])
        return panel
    }

    @Test func render() async throws {
        guard let out = ProcessInfo.processInfo.environment["CANDY_STATES_OUT"] else { return }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride, appearance = NSApp?.appearance
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion; NSApp?.appearance = appearance }
        for dark in [true, false] {
            var input = ThemeRuntimeInput(
                light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
                dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
            input.ditherLight = true; input.ditherDark = true
            ThemeRuntime.apply(input)
            Motion.reducedOverride = true
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            func capture(_ name: String, _ view: NSView, _ size: NSSize) throws {
                let image = RedesignBaselineTests.image(view, size: size, dark: dark)
                try Snapshot.writePNG(image, to: dir.appendingPathComponent("\(name).\(dark ? "dark" : "light").png"))
            }
            let panelSize = NSSize(width: 460, height: 600)

            let failed = Self.diffPanel { throw SpawnFailure() }
            _ = await eventually { failed.message.text != "Loading checkpoint diff..." }
            try capture("diff-error", failed, panelSize)

            let noNet = Self.diffPanel { "" }
            _ = await eventually { noNet.message.text != "Loading checkpoint diff..." }
            try capture("diff-no-net-changes", noNet, panelSize)

            let noTurns = Self.diffPanel({ "" }, summaries: false)
            try capture("diff-no-turns", noTurns, panelSize)

            let loading = Self.diffPanel { try await Task.sleep(for: .seconds(60)); return "" }
            try capture("diff-loading", loading, panelSize)

            let files = FilesPanelView(frame: NSRect(origin: .zero, size: panelSize))
            try capture("files-loading", files, panelSize)
            let filesError = FilesPanelView(frame: NSRect(origin: .zero, size: panelSize))
            filesError.errorText = "Reconnect to the environment and try again."
            try capture("files-error", filesError, panelSize)

            try capture("terminal-empty", TerminalDrawerView(frame: NSRect(origin: .zero, size: panelSize)), NSSize(width: 460, height: 320))
            try capture("browser-empty", BrowserEmptyStateView(frame: NSRect(origin: .zero, size: panelSize)), panelSize)
            let recovery = FirstRunRecoveryView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
            recovery.reason = .connecting
            try capture("still-connecting", recovery, NSSize(width: 800, height: 500))
            try capture("file-failure", FileFailureView(message: "Unable to load file preview.", attemptedPath: "src/missing.swift", cwd: "/Users/demo/sandbox/demo-repo"), panelSize)
            try capture("settings-projects-empty", SettingsProjectListView(entries: [], select: { _ in }), NSSize(width: 640, height: 160))
            try capture("command-palette-empty", CommandPaletteView(content: .empty(message: nil, actionsOnly: false)), NSSize(width: 576, height: 200))

            // `RedesignBaselineTests.image` fills every AsyncImageView with a fixture, so this draws what one shows
            // on failure today: the label centered in 12pt muted text. `extraCaptures` overwrites it on this branch.
            for (name, size, alt) in [("image-unavailable", NSSize(width: 360, height: 200), "diagram.png"),
                                      ("image-unavailable-small", NSSize(width: 240, height: 48), "logo.png")] {
                let label = LabelView(MarkdownImages.unavailableLabel(alt), font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
                label.alignment = .center
                let box = NSView(frame: NSRect(origin: .zero, size: size))
                label.frame = NSRect(x: 4, y: (size.height - 14) / 2, width: size.width - 8, height: 14)
                box.addSubview(label)
                try capture(name, box, size)
            }

            try extraCaptures(capture)
        }
    }
}
