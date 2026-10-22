import AppKit
import Testing
@testable import DesignSystem

/// Sidebar batch fidelity: SidebarMenuButton, SidebarMenuSub, CommandItem and the hue slider against T3's
/// markup in Chromium (specs from scripts/gen-sidebar-spec.py), plus the sidebar background and grain
/// against the real app's capture (design/reference/02-sidebar-populated.*.png, 2x of 1100x780).
@MainActor @Suite(.fidelity)
struct SidebarFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "command-item": .init(0.04),
        "hue-slider": .init(0.045),
        "sidebar-menu-button": .init(0.035),
        "sidebar-menu-sub": .init(0.035),
    ]

    typealias Native = [String: String]

    @Test func sidebarMenuButton() throws {
        try run("sidebar-menu-button", sidebarBox: true) { n in
            SidebarMenuButtonView(n["title"]!, icon: .folder, size: .init(rawValue: n["size"]!)!,
                                  variant: .init(rawValue: n["variant"]!)!, active: n["active"] == "true")
        }
    }

    @Test func sidebarMenuSub() throws {
        try run("sidebar-menu-sub", sidebarBox: true) { _ in
            SidebarMenuSubView([SidebarMenuButtonView("Settings", icon: .folder, kind: .sub(small: false)),
                                SidebarMenuButtonView("Archive", icon: .folder, kind: .sub(small: false), active: true)])
        }
    }

    @Test func commandItem() throws {
        try run("command-item", sidebarBox: false) { n in
            let row = CommandRowView(CommandPaletteItem(n["title"]!, icon: .folder, shortcut: n["shortcut"]!.isEmpty ? nil : n["shortcut"]))
            row.isHighlighted = n["active"] == "true"
            return row
        }
    }

    @Test func hueSlider() throws {
        try run("hue-slider", sidebarBox: false) { n in ColorHueSliderView(hue: Double(n["hue"]!)!) }
    }

    // MARK: Against the real app

    /// Flat sidebar background with grain: mean and spread per channel, ours vs the capture.
    @Test func sidebarGrainAgainstCapture() throws {
        for theme in ["light", "dark"] {
            let ref = try Self.reference(theme)
            // 2x pixels: a 300x20 strip between thread rows, no text.
            let crop = (x: 20, y: 640, w: 300, h: 20)
            let surface = GrainSurfaceView(fill: Themed.color(\.sidebar, sidebar: true))
            let ours = Snapshot.image(of: surface, size: NSSize(width: 256, height: 128), scale: 2, dark: theme == "dark")
            let r = Self.stats(ref, crop), o = Self.stats(ours, (x: 0, y: 0, w: 512, h: 256))
            let plain = Snapshot.image(of: GrainSurfaceView(fill: Themed.color(\.sidebar, sidebar: true)).withoutGrain(),
                                       size: NSSize(width: 64, height: 16), scale: 2, dark: theme == "dark")
            let p = Self.stats(plain, (x: 0, y: 0, w: 128, h: 32))
            print(String(format: "GRAIN %@: capture mean %.2f sd %.2f | ours mean %.2f sd %.2f | no grain mean %.2f",
                         theme, r.mean, r.sd, o.mean, o.sd, p.mean))
            #expect(abs(r.mean - o.mean) < 1.0)
            #expect(abs(r.sd - o.sd) < 0.5)
        }
    }

    /// The open thread's row in the capture (Sidebar.tsx `bg-sidebar-row-active`, over the grain) vs
    /// SidebarMenuButton's `:active` fill, the same token, over our grain surface.
    @Test func selectedRowFillAgainstCapture() throws {
        for theme in ["light", "dark"] {
            let ref = try Self.reference(theme)
            let crop = (x: 60, y: 985, w: 320, h: 24) // inside the selected row, below the title
            let button = SidebarMenuButtonView("", size: .default)
            let box = GrainSurfaceView(fill: Themed.color(\.sidebar, sidebar: true))
            box.addSubview(button)
            button.frame = NSRect(x: 8, y: 8, width: 240, height: 32)
            button.previewState(FidelityTests.controlState("active"))
            let ours = Snapshot.image(of: box, size: NSSize(width: 256, height: 48), scale: 2, dark: theme == "dark")
            let r = Self.stats(ref, crop), o = Self.stats(ours, (x: 60, y: 24, w: 320, h: 40))
            print(String(format: "ROW %@: capture mean %.2f | ours mean %.2f", theme, r.mean, o.mean))
            #expect(abs(r.mean - o.mean) < 1.5)
        }
    }

    static func reference(_ theme: String) throws -> NSBitmapImageRep {
        let url = FidelityTests.repo.appendingPathComponent("design/reference/02-sidebar-populated.\(theme).png")
        return NSBitmapImageRep(data: try Data(contentsOf: url))!
    }

    /// Mean and standard deviation of all RGB channel values in a pixel rect.
    static func stats(_ rep: NSBitmapImageRep, _ r: (x: Int, y: Int, w: Int, h: Int)) -> (mean: Double, sd: Double) {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let px = FidelityTests.pixels(rep, w, h)
        var values: [Double] = []
        for y in r.y..<(r.y + r.h) { for x in r.x..<(r.x + r.w) { for k in 0..<3 { values.append(Double(px[(y * w + x) * 4 + k])) } } }
        let mean = values.reduce(0, +) / Double(values.count)
        let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        return (mean, sd)
    }

    // MARK: Runner

    /// `bg-sidebar` box with 8px padding around the component, at 8,8 on the --background canvas.
    final class SidebarBox: DSView {
        let child: NSView, childHeight: CGFloat
        init(_ child: NSView, height: CGFloat) {
            self.child = child; self.childHeight = height
            super.init(frame: .zero)
            addSubview(child)
        }
        override func layout() {
            super.layout()
            var w = bounds.width - 16
            if let b = child as? SidebarMenuButtonView, b.size == .icon { w = 32 }
            child.frame = NSRect(x: 8, y: 8, width: w, height: childHeight)
        }
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.sidebar, sidebar: true).cgColor(in: self) }
    }

    func run(_ component: String, sidebarBox: Bool, make: (Native) -> NSView) throws {
        let repo = FidelityTests.repo, out = FidelityTests.out
        let refDir = repo.appendingPathComponent("design/component-reference/\(component)")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/\(component).json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = out.appendingPathComponent(component)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [FidelityTests.Result] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! Native
            for state in spec["states"] as! [String] {
                for theme in spec["themes"] as! [String] {
                    let file = "\(name).\(state).\(theme).png"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                    let css = manifest[name]!
                    let view = make(native)
                    let canvas = FidelityTests.Canvas(frame: .zero)
                    let placed: NSView
                    if sidebarBox {
                        placed = SidebarBox(view, height: css["height"]! - 16)
                    } else {
                        placed = view
                    }
                    canvas.addSubview(placed)
                    placed.frame = NSRect(x: 8, y: 8, width: css["width"]!, height: css["height"]!)
                    let s = FidelityTests.controlState(state)
                    (view as? ControlView)?.previewState(s)
                    if let hue = view as? ColorHueSliderView { hue.showsFocus = s.focusVisible }
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (stats, diff) = FidelityTests.compare(ref, ours)
                    let base = "\(name).\(state).\(theme)"
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    results.append(.init(name: base, differing: stats.0, maxDiff: stats.1, meanDiff: stats.2,
                                         refSize: String(format: "%.2fx%.0f", css["width"]!, css["height"]!),
                                         oursSize: String(format: "%.2fx%.0f", placed.frame.width, placed.frame.height),
                                         files: ("\(component)/\(base).ref.png", "\(component)/\(base).ours.png", "\(component)/\(base).diff.png")))
                }
            }
        }
        results.sort { $0.differing > $1.differing }
        try FidelityTests.writeReport(results, title: component)
        for r in results.prefix(6) {
            print(r.name.padding(toLength: 44, withPad: " ", startingAt: 0), String(format: "%5.2f  %4d  %5.2f", r.differing * 100, r.maxDiff, r.meanDiff))
        }
        let mean = results.map(\.differing).reduce(0, +) / Double(max(1, results.count))
        print(String(format: "FIDELITY %@: %d cases, mean differing %.2f%%", component, results.count, mean * 100))
        Self.ceilings.check(component, results.map { ($0.name, $0.differing) })
    }
}

private extension GrainSurfaceView {
    func withoutGrain() -> GrainSurfaceView { showsGrain = false; return self }
}

/// Rail resize limits and width persistence (sidebar.tsx SidebarRail, threadSidebarWidth.ts).
@MainActor
struct SidebarBehaviourTests {
    func defaults() -> UserDefaults {
        let name = "candywrapper.tests.sidebar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func widthRules() {
        let rules = SidebarWidth()
        #expect(rules.minimum == 208)
        #expect(rules.maximum(viewport: 1100) == 460)
        #expect(rules.maximum(viewport: 700) == 208) // never below the minimum
        #expect(rules.clamp(100, viewport: 1100) == 208)
        #expect(rules.clamp(900, viewport: 1100) == 460)
        #expect(SidebarWidth(brandWidth: 230.2).minimum == 231)
        #expect(SidebarWidth.initial(stored: nil, viewport: 1100) == 256)
        #expect(SidebarWidth.initial(stored: 150, viewport: 1100) == 208)
        #expect(SidebarWidth.initial(stored: 400, viewport: 800) == 208)
        // Growing stops once the main panel would drop under 640px; shrinking always goes through.
        #expect(rules.dragStep(current: 300, proposed: 320, viewport: 1100, wrapperWidth: 1100) == 320)
        #expect(rules.dragStep(current: 300, proposed: 280, viewport: 1100, wrapperWidth: 1100) == 280)
        #expect(rules.dragStep(current: 300, proposed: 470, viewport: 1100, wrapperWidth: 1100) == 460)
        #expect(rules.dragStep(current: 300, proposed: 320, viewport: 2000, wrapperWidth: 900) == 300)
    }

    @Test func dragPersistsAndResets() {
        let d = defaults()
        let layout = SidebarLayoutView(defaults: d, viewport: 1100)
        layout.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        layout.layoutSubtreeIfNeeded()
        #expect(layout.effectiveWidth == 256)
        #expect(layout.sidebar.frame.width == 256)
        #expect(layout.rail.frame.midX == 255) // centred on the border's inner edge
        let start = layout.beginDrag()
        _ = layout.drag(to: start + 1000, current: start)
        #expect(layout.width == 460)
        layout.endDrag()
        #expect(SidebarWidth.load(d) == 460)
        // A new layout restores the stored width, clamped to its window.
        let restored = SidebarLayoutView(defaults: d, viewport: 1100)
        #expect(restored.width == 460)
        let narrow = SidebarLayoutView(defaults: d, viewport: 900)
        #expect(narrow.width == 260)
        layout.resetWidth()
        #expect(SidebarWidth.load(d) == nil)
        #expect(layout.width == 256)
        #expect(d.object(forKey: "chat_thread_sidebar_width") == nil)
    }

    @Test func collapseHidesContainerAndRail() {
        let layout = SidebarLayoutView(defaults: defaults(), viewport: 1100)
        layout.frame = NSRect(x: 0, y: 0, width: 1100, height: 780)
        layout.toggle()
        layout.layoutSubtreeIfNeeded()
        #expect(!layout.isOpen)
        #expect(layout.sidebar.frame.maxX == 0)
        #expect(layout.main.frame.minX == 0)
        #expect(layout.rail.isHidden)
        // The collapsed sidebar's trigger floats beside the window controls; opening hides it again.
        #expect(!layout.collapsedTrigger.isHidden && !layout.collapsedTrigger.isSidebarOpen)
        #expect(layout.collapsedTrigger.frame == NSRect(x: 91, y: 12, width: 28, height: 28))
        layout.toggle()
        #expect(layout.collapsedTrigger.isHidden)
    }

    /// With panel animations on, every toggle lands at once in the model and the panels slide there;
    /// rapid toggles neither queue nor leave a stale end hiding the collapsed trigger.
    @Test func animatedTogglesRetarget() {
        let previous = SettingsPanelMotion.durationMs
        defer { SettingsPanelMotion.durationMs = previous }
        SettingsPanelMotion.durationMs = 200
        let layout = SidebarLayoutView(defaults: defaults(), viewport: 1100)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = layout
        layout.layoutSubtreeIfNeeded()
        for _ in 0..<3 { layout.toggle() }
        #expect(!layout.isOpen)
        #expect(!layout.collapsedTrigger.isHidden && layout.rail.isHidden)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(layout.slide.isRunning && layout.slide.target == 0)
            // Mid close slide the container keeps its frame (so AppKit still draws it) and its layer moves
            // away; the main panel starts at the sidebar's edge and fills the rest, reflowed (T3's gap width).
            layout.slide.step(at: CACurrentMediaTime() + 0.05)
            let gap = layout.main.frame.minX
            #expect(gap > 0 && gap < 256 && layout.main.frame.width == 1100 - gap)
            #expect(layout.sidebar.frame.minX == 0)
            #expect(layout.sidebar.layer?.affineTransform().tx == gap - 256)
            // It lands exactly on the collapsed layout and stops ticking.
            layout.slide.step(at: CACurrentMediaTime() + 10)
            #expect(!layout.slide.isRunning)
            #expect(layout.sidebar.frame.maxX == 0 && layout.main.frame == NSRect(x: 0, y: 0, width: 1100, height: 780))
            #expect(layout.sidebar.layer?.affineTransform() == .identity)
        }
        // Off again: the next toggle is instant.
        SettingsPanelMotion.durationMs = 0
        layout.toggle()
        layout.layoutSubtreeIfNeeded()
        #expect(layout.isOpen && layout.sidebar.frame.minX == 0 && layout.main.frame.minX == 256)
        #expect(layout.collapsedTrigger.isHidden)
        #expect(!layout.slide.isRunning)
    }

    /// The CSS `ease-out` curve: ends fixed, fast start.
    @Test func easeOutCurve() {
        let curve = CubicBezier(0, 0, 0.58, 1)
        #expect(curve.y(atX: 0) == 0 && abs(curve.y(atX: 1) - 1) < 1e-6)
        #expect(abs(curve.y(atX: 0.5) - 0.6846) < 0.001) // cubic-bezier(0,0,.58,1) at 50%
    }

    /// `COLLAPSED_SIDEBAR_TITLEBAR_INSET_CLASS`: a header under the window controls starts its content at 130.
    @Test func headersClearTheWindowControls() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780), styleMask: [.titled], backing: .buffered, defer: true)
        let root = DSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780))
        window.contentView = root
        let header = TopbarDragView(frame: NSRect(x: 0, y: 0, width: 800, height: 52))
        root.addSubview(header)
        #expect(header.contentStart == 130)
        header.frame.origin.x = 256
        #expect(header.contentStart == 20)
        #expect(TopbarDragView(frame: .zero).contentStart == 20)
    }

    @Test func titlebarInsets() {
        #expect(SidebarMetrics.titlebarContentLeft(windowedMac: true) == 130)
        #expect(SidebarMetrics.titlebarContentLeft(windowedMac: false) == 52)
    }
}
