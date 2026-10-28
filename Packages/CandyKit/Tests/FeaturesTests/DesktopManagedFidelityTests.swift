import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// WP7.18 SSH password and relay install dialog bodies against the official markup in Chromium
/// (scripts/gen-desktop-managed-spec.py). Writes ref, ours and diff PNGs plus report-desktop-managed.html
/// to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct DesktopManagedFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        // Keep the existing SSH ceilings unchanged during the 3814 visual port.
        "desktopManaged": .init(0.055, except: [
            "ssh.rest.light": 0.19, "ssh.rest.dark": 0.19,
            "ssh-expired.rest.light": 0.19, "ssh-expired.rest.dark": 0.19,
        ]),
    ]
    static let out = Fidelity.root.appendingPathComponent("desktop-managed")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        if n["kind"] == "ssh" {
            return SshPasswordPromptBody(target: "fixture", remaining: n["expired"] == "True" ? "Expired" : "3:00", expired: n["expired"] == "True")
        }
        return RelayClientInstallBody(version: "2026.10.9", stage: n["stage"].flatMap(RelayClientInstallStage.init(rawValue:)))
    }

    @Test func desktopManaged() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/desktop-managed")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/desktop-managed.json"))) as! [String: Any]
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
                view.frame.size = size
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='desktop-managed/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("desktop-managed", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("desktopManaged", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY desktop-managed: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Desktop-managed environments</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-desktop-managed.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.06)
    }
}
