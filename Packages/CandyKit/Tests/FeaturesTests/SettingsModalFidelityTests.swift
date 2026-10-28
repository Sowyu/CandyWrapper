import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor @Suite(.fidelity)
struct SettingsModalFidelityTests {
    static let ceilings: FidelityCeilings = ["shell": .init(0.02)]

    @Test func shell() throws {
        let repo = SidebarFidelityTests.repo
        let dir = repo.appendingPathComponent("design/component-reference/settings-modal")
        let out = Fidelity.root.appendingPathComponent("settings-modal")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var cases: [(String, Double)] = []
        for kind in ["settings", "usage"] {
            for dark in [false, true] {
                let name = "\(kind).rest.\(dark ? "dark" : "light")"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(name + ".png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let page = SettingsPageView()
                page.header.isRouteModal = true
                if kind == "settings" { page.header.section = .appearance } else { page.header.plainTitle = "Usage" }
                let nav = kind == "settings" ? DSView(frame: .zero) : nil
                let host = AppRouteModalView(label: kind.capitalized, content: page, navigation: nav)
                host.frame = NSRect(x: 8, y: 8, width: 1100, height: 780)
                canvas.addSubview(host)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: 1116, height: 796), scale: 2, dark: dark)
                let (diff, _, image) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: out.appendingPathComponent(name + ".ours.png"))
                try Snapshot.writePNG(image, to: out.appendingPathComponent(name + ".diff.png"))
                cases.append((name, diff))
            }
        }
        Self.ceilings.check("shell", cases)
    }

    @Test func metricControlsStayAtTheTrailingEdgeOnLimits() {
        for width: CGFloat in [700, 1040] {
            let header = UsageHeaderView()
            header.isRouteModal = true
            header.frame = NSRect(x: 0, y: 0, width: width, height: 48)
            var model = UsagePageView.Model()
            model.metric = "cost"
            header.apply(model)
            header.layoutSubtreeIfNeeded()
            let metric = width >= 896 ? header.metric.frame : header.metricSelect.frame
            model.metric = "limits"
            header.apply(model)
            header.layoutSubtreeIfNeeded()
            let limits = width >= 896 ? header.metric.frame : header.metricSelect.frame
            #expect(metric.maxX == limits.maxX)
            if width >= 896 { #expect(metric == limits) }
            #expect(header.period.isHidden)
            #expect(header.periodSelect.isHidden)
        }
    }

    @Test func closingUnmountsOnlyTheOverlay() {
        let previous = Motion.reducedOverride
        Motion.reducedOverride = true
        defer { Motion.reducedOverride = previous }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let thread = DSView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(thread)
        var dismissed = 0
        weak var released: AppRouteModalView?
        autoreleasepool {
            let host = AppRouteModalView.present(label: "Settings", content: SettingsPageView(), in: window)
            released = host
            host.onDismiss = { dismissed += 1 }
            #expect(window.firstResponder === host)
            #expect(AppRouteModalView.isPresented(in: window))
            host.close(animated: false)
            #expect(dismissed == 1)
            #expect(thread.superview === window.contentView)
            #expect(!AppRouteModalView.isPresented(in: window))
        }
        #expect(released == nil)
        window.close()
    }

    @Test func responsiveFrame() {
        #expect(AppRouteModalView.surfaceFrame(in: NSSize(width: 1100, height: 780)) == NSRect(x: 40, y: 40, width: 1020, height: 700))
        #expect(AppRouteModalView.surfaceFrame(in: NSSize(width: 840, height: 620)) == NSRect(x: 24, y: 24, width: 792, height: 572))
        #expect(AppRouteModalView.surfaceFrame(in: NSSize(width: 1600, height: 1200)) == NSRect(x: 160, y: 120, width: 1280, height: 960))
    }
}
