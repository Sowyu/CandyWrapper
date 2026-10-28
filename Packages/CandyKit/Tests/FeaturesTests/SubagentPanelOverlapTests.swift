import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// The open subagent panel floats over the timeline, so a changed-files card can scroll under it. In Redesign dark at
/// Glass opacity 10% with no background picture, the card's labels must not read through the panel (the user's
/// 1.14.10 screenshot, 2026-10-28). Reduce Transparency turns the backdrop blur off, and offscreen renders draw none
/// either, so the render matches that case. Run alone: theme globals belong to the whole test process.
@MainActor
struct SubagentPanelOverlapTests {
    static let out = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-panel-overlap")

    /// With Reduce Transparency forced on, the pill fill is opaque, and "Ignore Reduce Transparency" brings back 62% live.
    @Test func ignoreReduceTransparencyBringsBackTheGlassFill() {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous); DitherPill.reduceTransparencyOverride = nil }
        DitherPill.reduceTransparencyOverride = true
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        probe.appearance = NSAppearance(named: .darkAqua)
        var input = previous
        for ignore in [false, true, false] {
            input.ignoreReduceTransparency = ignore
            ThemeRuntime.apply(input)
            #expect(DitherPill.blurs == ignore)
            #expect(DitherPill.fill(in: probe).alpha == (ignore ? 0.62 : 1))
        }
    }

    @Test(arguments: [true, false]) func panelHidesTheChangedFilesCardUnderIt(reduceTransparency: Bool) throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous); DitherPill.reduceTransparencyOverride = nil }
        DitherPill.reduceTransparencyOverride = reduceTransparency
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!), glassOpacity: 10)
        input.ditherLight = true; input.ditherDark = true
        input.ditherDim = 20
        input.ditherPicture = nil
        ThemeRuntime.apply(input)
        #expect(ThemeRuntime.isDither(dark: true))

        let width: CGFloat = 860
        let files = [CheckpointFile(path: "docs/research/subagent-strip.md", additions: 71, deletions: 0),
                     CheckpointFile(path: "Packages/CandyKit/Sources/Thread.swift", additions: 31, deletions: 1),
                     CheckpointFile(path: "PROGRESS.md", additions: 5, deletions: 2)]
        let summary = TurnDiffSummary(checkpointId: "c", scopeId: "s", runId: "r", checkpointTurnCount: 1, checkpointRef: "ref", status: "ready",
                                      files: files, assistantMessageId: nil, completedAt: T3Timestamp(stringLiteral: "2026-10-28T00:00:00Z"))
        let rows = [SubagentPanelOverlapTests.running()] + SubagentStripPanelTests.finishedRows(6)
        let panelHeight = SubagentStripPanelTests.panel(rows).preferredHeight(maxHeight: 1000)
        let size = NSSize(width: width, height: panelHeight)

        func render(card: Bool) -> NSBitmapImageRep {
            let root = DSView(frame: NSRect(origin: .zero, size: size))
            root.layer?.backgroundColor = NSColor.black.cgColor
            if card {
                let view = ChangedFilesCardView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
                view.configure(summary, allExpanded: true, overrides: [:])
                view.frame = NSRect(x: 0, y: 0, width: width,
                                    height: max(panelHeight, ChangedFilesCardView.height(files, allExpanded: true, overrides: [:])))
                root.addSubview(view)
            }
            let panel = SubagentStripPanelTests.panel(rows)
            panel.frame = NSRect(origin: .zero, size: size)
            root.addSubview(panel)
            return Snapshot.image(of: root, size: size, scale: 2, dark: true)
        }
        // With the blur on, the fill stays at Redesign's 62% so the baseline holds; the blur hides the card.
        let probe = SubagentStripPanelTests.panel(rows)
        probe.appearance = NSAppearance(named: .darkAqua)
        #expect(DitherPill.fill(in: probe).alpha == (reduceTransparency ? 1 : 0.62))
        guard reduceTransparency else { return }

        let stacked = render(card: true), alone = render(card: false)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try Snapshot.writePNG(stacked, to: Self.out.appendingPathComponent("stacked.dark.png"))

        // Inside the panel's border, the stacked render should match the panel alone. 255 is a full channel swing. The
        // corner squares are skipped: the card's own corner shows outside the panel's curve there, as it should.
        var worst = 0
        let inset = 4, corner = 40, w = stacked.pixelsWide, h = stacked.pixelsHigh
        for y in inset..<(h - inset) {
            for x in inset..<(w - inset) {
                if (x < corner || x >= w - corner) && (y < corner || y >= h - corner) { continue }
                let a = stacked.colorAt(x: x, y: y)!, b = alone.colorAt(x: x, y: y)!
                let d = [abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)].max()!
                worst = max(worst, Int((d * 255).rounded()))
            }
        }
        #expect(worst <= 2, "card shows through the subagent panel by \(worst)/255, see \(Self.out.path)")
    }

    static func running() -> SubagentStrip.Row {
        let r = SubagentStripPanelTests.row("live", .running)
        return SubagentStrip.Row(id: r.id, key: r.key, number: 9, childThreadId: nil, title: "Final fix: 48 turn-chat dark",
                                 status: r.status, driver: "codex", providerInstanceId: "codex", model: "gpt-6.1-sol", canStop: false,
                                 startedAt: r.startedAt, completedAt: nil)
    }
}
