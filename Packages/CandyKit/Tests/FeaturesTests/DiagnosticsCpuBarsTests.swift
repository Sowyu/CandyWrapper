import AppKit
import Testing
import T3Protocol
@testable import Features

/// #41948: the CPU history bars read their values to VoiceOver (DiagnosticsSettings.tsx at 5258).
@MainActor
struct DiagnosticsCpuBarsTests {
    @Test func eachBarHasItsLabel() {
        let bars = CpuBarsView(buckets: [.object(["avgCpuPercent": .number(1.24), "maxCpuPercent": .number(7)]),
                                         .object(["avgCpuPercent": .number(0), "maxCpuPercent": .number(0.5)])])
        bars.frame = NSRect(x: 0, y: 0, width: 400, height: bars.height(forWidth: 400))
        let labels = (bars.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels == ["Average CPU 1.2%, peak CPU 7.0%", "Average CPU 0.0%, peak CPU 0.5%"])
    }
}
