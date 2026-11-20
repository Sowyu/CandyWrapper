import AppKit
import Testing
import DesignSystem
@testable import Features

/// The thread link picker dialog (4928 ThreadLinkPicker.tsx) against T3's markup in Chromium: three threads with one
/// linked, and no match (spec from scripts/gen-thread-link-picker-spec.py, references in
/// design/component-reference/thread-link-picker). Writes ref, ours and diff PNGs plus report-thread-link-picker.html.
@MainActor @Suite(.fidelity)
struct ThreadLinkPickerFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "threadLinkPicker": .init(0.03, except: ["empty.rest.light": 0.07]),
    ]
    static let out = Fidelity.root.appendingPathComponent("thread-link-picker")

    static func view(_ name: String, size: CGSize) throws -> NSView {
        let picker = ThreadLinkPicker(title: "Link pull request to a thread")
        if name == "rows" {
            picker.candidates = [.init(id: "a", title: "Reply with markdown only", project: "demo-repo", linked: false),
                                 .init(id: "b", title: "Plan a migration", project: "git-demo", linked: true),
                                 .init(id: "c", title: "Add notes and docstring", project: "demo-repo", linked: false)]
        }
        let view = picker.dialog
        view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func threadLinkPicker() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/thread-link-picker")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/thread-link-picker.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                canvas.addSubview(try Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!)))
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='thread-link-picker/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("thread-link-picker", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("threadLinkPicker", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY thread-link-picker: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Thread link picker</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-thread-link-picker.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
