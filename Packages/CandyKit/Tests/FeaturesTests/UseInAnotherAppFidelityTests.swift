import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// "Use T3 Code in another app (MCP)" (4928) against T3's markup in Chromium (spec from
/// scripts/gen-use-in-another-app-spec.py, references in design/component-reference/use-in-another-app).
@MainActor @Suite(.fidelity)
struct UseInAnotherAppFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "useInAnotherApp": .init(0.03),
    ]
    static let out = Fidelity.root.appendingPathComponent("use-in-another-app")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        if n["kind"] == "authorized" {
            let view = ConnectionsSettingsView()
            var model = ConnectionsPageModel(cloudEnabled: false)
            model.access = .init(summary: "2 clients · 1 pairing link", canRead: true, canWrite: true, offersMcp: true)
            view.set(model)
            let section = view.accessSection
            section.removeFromSuperview()
            section.frame = NSRect(x: 0, y: 0, width: size.width, height: section.height(forWidth: size.width))
            section.layoutSubtreeIfNeeded()
            return section
        }
        let w = UseInAnotherAppDialog(environment: "Mac mini", hostedApproval: false)
        w.gate = n["kind"] == "turn-on" ? .turnOn : .open(mcpURL: "https://prod-a1.t3coderelay.com/mcp")
        if n["kind"] != "turn-on" {
            UseInAnotherAppTests.find(McpAppGrid.self, in: w.body)?.onSelect?(1)
            if n["kind"] != "apps" { (w.dialog.footerButtons.last as? ButtonView)?.performAction() }
            if n["kind"] == "connect" { (w.dialog.footerButtons.last as? ButtonView)?.performAction() }
        }
        let body = w.body
        body.removeFromSuperview()
        body.frame = NSRect(x: 0, y: 0, width: size.width, height: body.height(forWidth: size.width))
        body.layoutSubtreeIfNeeded()
        return body
    }

    @Test func useInAnotherApp() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/use-in-another-app")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/use-in-another-app.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let view = try Self.make(native, size: size)
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='use-in-another-app/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("use-in-another-app", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("useInAnotherApp", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY use-in-another-app: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Use in another app</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-use-in-another-app.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
