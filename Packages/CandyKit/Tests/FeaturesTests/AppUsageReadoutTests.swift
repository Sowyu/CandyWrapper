import AppKit
import Testing
@testable import Features

/// Redesign's account pill shows CandyWrapper's own CPU and memory where the e-mail used to be.
@MainActor
struct AppUsageReadoutTests {
    typealias L = AppUsageLogic

    @Test func cpuIsTheCPUTimeDeltaOverTheWallDelta() {
        let a = AppUsageSample(cpuSeconds: 10, uptime: 100, footprint: 0)
        #expect(abs(L.cpuPercent(from: a, to: .init(cpuSeconds: 10.02, uptime: 105, footprint: 0)) - 0.4) < 1e-9)
        #expect(L.cpuPercent(from: a, to: .init(cpuSeconds: 17.5, uptime: 105, footprint: 0)) == 150)
        #expect(L.cpuPercent(from: a, to: a) == 0)
    }

    @Test func numbersAreShort() {
        #expect(L.cpuText(0.4) == "0.4%")
        #expect(L.cpuText(12.3) == "12%")
        #expect(L.memoryText(182 << 20) == "182M")
        #expect(L.memoryText(1288 << 20) == "1.3G")
        #expect(L.tooltip(cpu: 0.4, footprint: 182 << 20) == "CandyWrapper CPU 0.4% of one core · Memory 182 MB")
    }

    @Test func metersLightAtLeastOneDotAndCapAtTheEnd() {
        #expect(L.lit(0) == 0)
        #expect(L.lit(0.004) == 1)
        #expect(L.lit(0.5) == 3)
        #expect(L.lit(3) == L.dots)
    }

    @Test func cpuTurnsAmberAfterTwoHotSamples() {
        let v = AppUsageReadoutView(frame: NSRect(x: 0, y: 0, width: 180, height: 16))
        v.show(cpu: 80, footprint: 1 << 28, animated: false)
        #expect(!v.cpuMeter.hot && v.cpuMeter.lit == 5)
        v.show(cpu: 80, footprint: 1 << 28, animated: false)
        #expect(v.cpuMeter.hot)
        v.show(cpu: 1, footprint: 1 << 28, animated: false)
        #expect(!v.cpuMeter.hot && v.cpuLabel.text == "1.0%" && v.memoryLabel.text == "256M")
        #expect(AppUsageSample.read() != nil)
        // Offscreen, nothing samples.
        #expect(!v.isSampling)
    }

    @Test func theAvatarOpensMachines() {
        let row = SidebarAccountRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        var opened = false
        row.onOpenMachines = { opened = true }
        row.avatar.performAction()
        #expect(opened)
    }
}
