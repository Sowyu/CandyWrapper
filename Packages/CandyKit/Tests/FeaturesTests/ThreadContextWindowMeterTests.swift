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
            // Before the provider reports usage Redesign draws nothing: an empty ring said nothing (polish audit 2026-11-21).
            if state == .loading { #expect(inked == 0, "a reserved slot draws nothing"); return }
            #expect(inked > 40, "\(state) draws no track")
            let fraction: Double = switch state { case .partial: 0.518; case .nearFull: 0.95; default: 0 }
            #expect(meter.arc.isHidden == (fraction == 0))
            #expect(abs(Double(meter.arc.strokeEnd) - fraction) < 0.001)
        }
    }

    /// Counts come from the server unchecked. A huge negative `maxTokens` trapped in `tokens`; now any number draws an
    /// empty meter or a full one.
    @Test(arguments: [-1e300, -Double(Int.max) * 4, -5, 0, .nan, .infinity, -.infinity, 1e300, Double(Int.max) * 4])
    func anyServerCountDrawsAnEmptyOrFullMeter(value: Double) throws {
        #expect(ThreadContextWindowUsage.tokens(value).isEmpty == false)
        if !(value > 0) || !value.isFinite { #expect(ThreadContextWindowUsage.tokens(value) == "0") }
        let cases: [(ThreadContextWindowUsage, Double)] = [
            (ThreadContextWindowUsage(used: 1_000, maximum: value, automatically: true), value.isFinite && value > 0 ? min(1, 1_000 / value) : 0),
            (ThreadContextWindowUsage(used: value.isFinite ? max(0, value) : 0, maximum: 1_000, automatically: true), value.isFinite && value > 0 ? min(1, value / 1_000) : 0),
            (ThreadContextWindowUsage(used: 1e300, maximum: value, automatically: true, inputTokens: value, cachedInputTokens: value, outputTokens: value),
             value > 0 ? (value.isFinite ? min(1, 1e300 / value) : 0) : 0),
        ]
        for redesign in [false, true] {
            let draw = {
                for (usage, fraction) in cases {
                    let meter = ThreadContextWindowMeterView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
                    meter.usage = usage
                    meter.layoutSubtreeIfNeeded()
                    _ = try self.inkedPixels(meter)
                    // Redesign's ring never shows less than `Meter.least` of a turn for usage above zero.
                    let want = meter.capy && fraction > 0 ? max(Double(RedesignTokens.Meter.least), fraction) : fraction
                    #expect(abs(Double(meter.arc.strokeEnd) - want) < 0.001, "\(usage)")
                    let details = ThreadContextWindowDetailsView(frame: NSRect(x: 0, y: 0, width: 280, height: 200))
                    _ = details.configure(usage: usage, capy: redesign, model: "m", compactOffered: true, disabled: false, reason: nil)
                    details.layoutSubtreeIfNeeded()
                    _ = usage.redesignSummary
                }
            }
            if redesign { try withDither(draw) } else { try draw() }
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
