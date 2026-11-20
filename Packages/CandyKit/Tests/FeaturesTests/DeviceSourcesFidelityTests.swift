import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Devices > Device sources (4928) against T3's markup in Chromium (spec from
/// scripts/gen-device-sources-spec.py, references in design/component-reference/device-sources).
@MainActor @Suite(.fidelity)
struct DeviceSourcesFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "deviceSources": .init(0.03),
    ]
    static let out = Fidelity.root.appendingPathComponent("device-sources")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        let context = SettingsPageContext()
        let settings = DeviceSourcesTests.settings()
        context.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "Mac", settings: settings)], primaryId: "a")
        context.subscribe = { _, _, _, receive in
            receive(try! JSONValueEncoder().encode(DeviceSourcesTests.ready))
            return nil
        }
        let section = DeviceSourcesSection(context: context)
        section.setVisible(true)
        section.refresh()
        return SettingsPages2FidelityTests.sized(section.section, size)
    }

    @Test func deviceSources() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/device-sources")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/device-sources.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='device-sources/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("device-sources", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("deviceSources", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY device-sources: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Device sources</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-device-sources.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
