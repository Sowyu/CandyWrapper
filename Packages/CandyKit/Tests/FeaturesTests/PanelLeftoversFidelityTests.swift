import AppKit
import Testing
import DesignSystem
import T3Store
import T3Protocol
@testable import Features

/// Review draft and SSH fields against official markup in headless Chromium.
@MainActor
struct PanelLeftoversFidelityTests {
    static let out = SidebarFidelityTests.repo.appendingPathComponent("design/panel-leftovers-fidelity")

    static func view(_ name: String, size: CGSize) -> NSView {
        if name == "host-failed" {
            let data = Data(#"{"hosts":[{"id":"host","label":"Build host","kind":"ssh","platforms":[]}],"hostStatus":"failed","hostStatuses":{"host":{"status":"failed"}},"supportsHostRetry":true,"devices":[],"sessions":[],"onboardingCompleted":true,"agentAccessEnabled":false,"hubBasePath":"/api/device-hub","revision":1}"#.utf8)
            let state = try! JSONDecoder().decode(DevicePanelState.self, from: data)
            let view = DeviceHostStatusView(host: state.hosts[0], state: state)
            view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
            return view
        }
        let view: NSView = name == "review-card" ? DiffReviewCommentCardView(text: "Keep the historical revision.") : name == "review-draft" ? DiffReviewAnnotationView() : DeviceHostEditorForm()
        view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        return view
    }

    @Test func panelLeftovers() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/panel-leftovers")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/panel-leftovers.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='panel-leftovers-fidelity/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("panel-leftovers", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY panel-leftovers: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Device panels</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-panel-leftovers.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
