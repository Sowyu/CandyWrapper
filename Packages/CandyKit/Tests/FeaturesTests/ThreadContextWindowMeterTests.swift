import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Redesign's context button: a ring in its pill in every state, never an empty pill.
@MainActor
struct ThreadContextWindowMeterTests {
    private func withDither(_ body: () throws -> Void) rethrows {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var dither = previous
        dither.ditherLight = true; dither.ditherDark = true
        ThemeRuntime.apply(dither)
        try body()
    }

    /// Pixels the meter itself draws, outside the arc layer.
    private func inkedPixels(_ meter: ThreadContextWindowMeterView) throws -> Int {
        let rep = try #require(meter.bitmapImageRepForCachingDisplay(in: meter.bounds))
        meter.cacheDisplay(in: meter.bounds, to: rep)
        var n = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { n += 1 } }
        return n
    }

    enum State: String, CaseIterable { case empty, partial, nearFull, unknown, loading }

    @Test(arguments: State.allCases, [false, true])
    func drawsItsRingInEveryState(state: State, dark: Bool) throws {
        try withDither {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let meter = ThreadContextWindowMeterView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            window.contentView = meter
            defer { window.contentView = nil }
            switch state {
            case .empty: meter.usage = ThreadContextWindowUsage(used: 0, maximum: 1_000_000, automatically: true)
            case .partial: meter.usage = ThreadContextWindowUsage(used: 518_000, maximum: 1_000_000, automatically: true)
            case .nearFull: meter.usage = ThreadContextWindowUsage(used: 950_000, maximum: 1_000_000, automatically: true)
            case .unknown: meter.usage = ThreadContextWindowUsage(used: 40_000, automatically: true)
            case .loading: meter.reserved = true
            }
            meter.layoutSubtreeIfNeeded()
            #expect(meter.capy)
            let inked = try inkedPixels(meter)
            #expect(inked > 40, "\(state) draws no track")
            let fraction: Double = switch state { case .partial: 0.518; case .nearFull: 0.95; default: 0 }
            #expect(meter.arc.isHidden == (fraction == 0))
            #expect(abs(Double(meter.arc.strokeEnd) - fraction) < 0.001)
        }
    }

    /// On 2026-10-27 the Conductor's ring showed as an empty pill: back from another theme, the meter returned above
    /// the queue and the pill it had left behind covered it.
    @Test func theRingStaysAboveItsPillAcrossThemeSwitches() throws {
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        func apply(dither: Bool) {
            var input = previous
            input.ditherLight = dither; input.ditherDark = dither
            ThemeRuntime.apply(input)
        }
        apply(dither: true)
        let panel = ThreadPanelView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = panel
        defer { window.contentView = nil }
        panel.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let projection = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"t"},"runs":[],"updatedAt":"2026-10-22T00:00:00Z"}"#.utf8))
        panel.setProjection(projection, projectTitle: "Sandbox", workspaceRoot: nil)
        let meter = panel.composer.contextWindowMeter
        meter.usage = ThreadContextWindowUsage(used: 518_000, maximum: 1_000_000, automatically: true)
        for dither in [true, false, true] {
            apply(dither: dither)
            panel.needsLayout = true
            panel.layoutSubtreeIfNeeded()
        }
        #expect(meter.superview === panel && !meter.isHidden)
        let pill = try #require(panel.subviews.first { $0 is DitherPillSurface && $0.frame == meter.frame && !$0.isHidden })
        let order = panel.subviews
        #expect(try #require(order.firstIndex(of: pill)) < #require(order.firstIndex(of: meter)))
    }
}
