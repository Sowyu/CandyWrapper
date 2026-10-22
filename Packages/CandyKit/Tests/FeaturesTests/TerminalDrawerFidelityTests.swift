import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The terminal drawer's chrome (with one terminal, empty, and two side by side with the list) against T3's markup in Chromium
/// (spec from scripts/gen-terminal-drawer-spec.py, references in design/component-reference/
/// terminal-drawer). Writes ref, ours and diff PNGs plus report-terminal-drawer.html to
/// `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct TerminalDrawerFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "terminalDrawer": .init(0.035),
    ]
    static let out = Fidelity.root.appendingPathComponent("terminal-drawer")

    static func view(_ name: String, size: CGSize) -> NSView {
        let drawer = TerminalDrawerView(frame: NSRect(x: 8, y: 8, width: size.width, height: size.height))
        drawer.emptyButton.title = "New Terminal (⌘N)"
        if name == "drawer" {
            let surface = TerminalSurfaceView()
            // The reference's canvas is empty, so only the surface's padding box and background
            // are compared; SwiftTerm's cells paint white in offscreen snapshots.
            surface.terminal.isHidden = true
            drawer.surface = surface
        }
        if name == "split" {
            let panes = ["term-1", "term-2"].map { id -> (id: String, surface: TerminalSurfaceView) in
                let surface = TerminalSurfaceView()
                surface.terminal.isHidden = true
                return (id, surface)
            }
            var state = TerminalDrawerState()
            state.newTerminal("term-1")
            state.split("term-2", direction: .horizontal)
            drawer.show(panes, direction: .horizontal, activeId: "term-2",
                        list: TerminalListModel.make(state, label: { TerminalLabels.label($0) }, closeShortcut: nil))
        }
        return drawer
    }

    @Test func terminalDrawer() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/terminal-drawer")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/terminal-drawer.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view = Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!))
                canvas.addSubview(view)
                canvas.frame = NSRect(x: 0, y: 0, width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                view.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='terminal-drawer/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("terminal-drawer", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("terminalDrawer", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY terminal-drawer: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Terminal drawer</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-terminal-drawer.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
