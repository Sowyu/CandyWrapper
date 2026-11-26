import AppKit
import Testing
@testable import DesignSystem
import T3Protocol
@testable import T3Store
@testable import Features

/// The open subagent panel floats over the timeline, so timeline rows can scroll under it. In Redesign dark at
/// Glass opacity 10% with no background picture, the card's labels must not read through the panel (the user's
/// 1.14.10 screenshot, 2026-10-28). Redesign's surfaces are opaque and draw no blur. Run alone: theme globals belong
/// to the whole test process.
@MainActor
struct SubagentPanelOverlapTests {
    static let out = FileManager.default.temporaryDirectory.appendingPathComponent("subagent-panel-overlap")

    /// Redesign's surfaces are opaque whatever Reduce Transparency says (the user, 2026-11-21: "no more blurs").
    @Test func pillFillIsOpaque() {
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        probe.appearance = NSAppearance(named: .darkAqua)
        #expect(DitherPill.fill(in: probe).alpha == 1)
    }

    @Test func panelHidesTheRowsUnderIt() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!), glassOpacity: 10)
        input.ditherLight = true; input.ditherDark = true
        input.ditherDim = 20
        input.ditherPicture = nil
        ThemeRuntime.apply(input)
        #expect(ThemeRuntime.isDither(dark: true))

        let width: CGFloat = 860
        let rows = [SubagentPanelOverlapTests.running()] + SubagentStripPanelTests.finishedRows(6)
        let panelHeight = SubagentStripPanelTests.panel(rows).preferredHeight(maxHeight: 1000)
        let size = NSSize(width: width, height: panelHeight)

        func render(card: Bool) -> NSBitmapImageRep {
            let root = DSView(frame: NSRect(origin: .zero, size: size))
            root.layer?.backgroundColor = NSColor.black.cgColor
            if card {
                // A white sheet under the whole panel stands in for the timeline rows that scroll under it.
                let view = DSView(frame: NSRect(origin: .zero, size: size))
                view.layer?.backgroundColor = NSColor.white.cgColor
                root.addSubview(view)
            }
            let panel = SubagentStripPanelTests.panel(rows)
            panel.frame = NSRect(origin: .zero, size: size)
            root.addSubview(panel)
            return Snapshot.image(of: root, size: size, scale: 2, dark: true)
        }
        let probe = SubagentStripPanelTests.panel(rows)
        probe.appearance = NSAppearance(named: .darkAqua)
        #expect(DitherPill.fill(in: probe).alpha == 1)

        let stacked = render(card: true), alone = render(card: false)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try Snapshot.writePNG(stacked, to: Self.out.appendingPathComponent("stacked.dark.png"))

        // Inside the panel's border, the stacked render should match the panel alone. 255 is a full channel swing.  The
        // corner squares are skipped: the sheet shows outside the panel's curve there, as it should.
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
