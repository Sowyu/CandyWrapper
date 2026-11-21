import AppKit
import Testing
@testable import DesignSystem
@testable import Features

/// Opt-in pictures of Redesign's context pill at 10, 50, 80, 95 and 100% in both appearances, for review: set
/// CANDY_RING_RENDER_DIR to a folder. Nothing is compared; ContextRingLevelTests checks the colors' logic.
@MainActor
struct ContextRingRenderTests {
    @Test func renderLevels() throws {
        guard let dir = ProcessInfo.processInfo.environment["CANDY_RING_RENDER_DIR"] else { return }
        let previous = ThemeRuntime.input, motion = Motion.reducedOverride
        defer { ThemeRuntime.apply(previous); Motion.reducedOverride = motion }
        var input = ThemeRuntimeInput(
            light: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .light)!),
            dark: ThemeRuntimeHalf(colors: ThemeDefinition.dither.colors(for: .dark)!))
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        Motion.reducedOverride = true
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            for p in [10.0, 50, 80, 95, 100] {
                let root = DSView(frame: NSRect(x: 0, y: 0, width: 120, height: 46))
                root.wantsLayer = true
                root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                root.layer?.backgroundColor = Themed.color(\.background).cgColor(in: root)
                let pill = DitherPillSurface(), meter = ThreadContextWindowMeterView()
                root.addSubview(pill); root.addSubview(meter)
                meter.usage = ThreadContextWindowUsage(used: p * 10_000, maximum: 1_000_000, autoCompactThreshold: 900_000, automatically: true)
                // The width the panel gives it: the figure's when there is one (this branch), else the square.
                let figure = meter.subviews.compactMap { $0 as? LabelView }.first { !$0.isHidden && !$0.text.isEmpty }
                let w = figure.map { 32 + ceil($0.textWidth) + 8 } ?? 30
                meter.frame = NSRect(x: 120 - 8 - w, y: 8, width: w, height: 30)
                pill.frame = meter.frame
                let rep = Snapshot.image(of: root, size: root.frame.size, scale: 4, dark: dark)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("ring-\(Int(p))-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
