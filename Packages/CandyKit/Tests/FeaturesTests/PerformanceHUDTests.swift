import AppKit
import Testing
@testable import Features

@MainActor
@Suite struct PerformanceHUDTests {
    @Test func readingTurnsCountersIntoRates() {
        let a = ProcessSample(cpuNanos: 1_000_000_000, footprint: 0, wakeups: 100, time: 10)
        let b = ProcessSample(cpuNanos: 1_050_000_000, footprint: 40 * 1_048_576, wakeups: 101, time: 10.5)
        let r = PerformanceReading(from: a, to: b, events: 3, frameMs: 4.2)
        #expect(abs(r.cpu - 10) < 0.001)
        #expect(r.footprintMB == 40)
        #expect(r.wakeupsPerSecond == 2)
        #expect(r.eventsPerSecond == 6)
        #expect(r.text.contains("RAM   40.0 MB"))
    }

    @Test func liveSampleReadsThisProcess() throws {
        let s = try #require(ProcessSample.current())
        #expect(s.footprint > 0)
        #expect(s.cpuNanos > 0)
    }

    /// Hidden costs nothing: no view, no timer, counting off. A window nobody sees gets no timer.
    @Test func samplesOnlyWhileShownInAVisibleWindow() {
        var counting: [Bool] = []
        let hud = PerformanceHUD(events: { 0 }, setCounting: { counting.append($0) })
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(!hud.isShown && !hud.isSampling)
        hud.toggle(in: host)
        #expect(hud.isShown)
        #expect(!hud.isSampling)
        hud.toggle(in: host)
        #expect(!hud.isShown && !hud.isSampling)
        #expect(host.subviews.isEmpty)
        #expect(counting == [true, false])
    }
}
