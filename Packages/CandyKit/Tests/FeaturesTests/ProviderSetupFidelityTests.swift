import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// WP7.14b provider setup against the official markup in Chromium.
/// Writes ref, ours and diff PNGs plus report-provider-setup.html to /tmp/candywrapper-fidelity.
@MainActor
struct ProviderSetupFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/provider-setup")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        if n["kind"] == "drivers" { return ProviderAddDriverGrid(choices: [("codex", "Codex"), ("claudeAgent", "Claude")], selected: "codex") }
        let context = SettingsPageContext()
        var provider = ServerProvider(instanceId: ProviderInstanceId(rawValue: "fixture"), driver: "claudeAgent")
        provider.auth = .object(["status": .string(n["kind"] == "signed-in" ? "authenticated" : "unauthenticated")])
        let view = ProviderAuthenticationView(context: context, environment: "fixture", label: "Fixture machine", instance: "fixture", provider: provider, readOnly: false)
        view.apply(.object(["phase": .string("idle")]))
        view.frame.size = size
        return view
    }

    @Test func providerSetup() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/provider-setup")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/provider-setup.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='provider-setup/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("provider-setup", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY provider-setup: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Settings pages 3</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-provider-setup.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
