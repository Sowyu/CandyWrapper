import AppKit
import Testing
import DesignSystem
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

    /// Release check 1.16.0, m3: at the sidebar's minimum width the memory reading showed a bare "1".
    @Test func aReadingThatDoesNotFitHidesInsteadOfClipping() {
        let v = AppUsageReadoutView(frame: NSRect(x: 0, y: 0, width: 400, height: 16))
        v.show(cpu: 0.4, footprint: 182 << 20, animated: false)
        v.layout()
        #expect(!v.cpuMeter.isHidden && !v.memoryLabel.isHidden)
        v.frame.size.width = 60
        v.layout()
        #expect(v.cpuMeter.isHidden && !v.cpuLabel.isHidden && v.memoryLabel.isHidden)
        for label in [v.cpuLabel, v.memoryLabel] where !label.isHidden { #expect(label.frame.maxX <= v.bounds.width) }
    }

    @Test func numbersAreShort() {
        #expect(L.cpuText(0.4) == "0.4%")
        #expect(L.cpuText(12.3) == "12%")
        #expect(L.memoryText(182 << 20) == "182 MB")
        #expect(L.memoryText(1288 << 20) == "1.3 GB")
        // The tooltip names each meter and where its bar is full.
        #expect(L.tooltip(cpu: 0.4, footprint: 182 << 20)
            == "CandyWrapper's own use\nCPU: 0.4% of one core, the bar full at one core\nMemory: 182 MB, the bar full at 1 GB")
    }

    @Test func metersShowAnyLoadAndCapAtTheEnd() {
        #expect(L.level(0) == 0)
        #expect(L.level(0.004) == RedesignTokens.Meter.least)
        #expect(L.level(0.5) == 0.5)
        #expect(L.level(3) == 1)
    }

    /// Round-0 review, S3: the card showed dot rows and dashes before any reading, read as placeholders.
    @Test func noReadingShowsNothingAndTheNameCentres() {
        let v = AppUsageReadoutView(frame: NSRect(x: 0, y: 0, width: 180, height: 16))
        v.layout()
        #expect(!v.hasReading)
        let anyShown = v.subviews.contains { !$0.isHidden }
        #expect(!anyShown)
        v.show(cpu: nil, footprint: 182 << 20, animated: false)
        v.layout()
        #expect(v.hasReading && !v.memoryLabel.isHidden && !v.memoryMeter.isHidden)
        // CPU waits for its second sample, and the memory reading takes the line's start.
        #expect(v.cpuLabel.isHidden && v.cpuMeter.isHidden && v.memoryMeter.frame.minX == ceil(v.memoryIcon.textWidth) + AppUsageReadoutView.gap)
        // Each reading says what it measures in words (S3, round 2).
        #expect(v.memoryIcon.text == "RAM" && v.cpuIcon.text == "CPU" && !v.memoryIcon.isHidden)
    }

    @Test func cpuTurnsAmberAfterTwoHotSamples() {
        let v = AppUsageReadoutView(frame: NSRect(x: 0, y: 0, width: 180, height: 16))
        v.show(cpu: 80, footprint: 1 << 28, animated: false)
        #expect(!v.cpuMeter.hot && abs(v.cpuMeter.level - 0.8) < 1e-9)
        v.show(cpu: 80, footprint: 1 << 28, animated: false)
        #expect(v.cpuMeter.hot)
        v.show(cpu: 1, footprint: 1 << 28, animated: false)
        #expect(!v.cpuMeter.hot && v.cpuLabel.text == "1.0%" && v.memoryLabel.text == "256 MB")
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
