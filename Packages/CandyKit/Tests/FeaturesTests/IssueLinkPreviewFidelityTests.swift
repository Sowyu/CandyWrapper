import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
@testable import Features

/// An issue link's preview card (4928 IssueLinkPreview.tsx, #38294) against T3's markup in Chromium (spec from
/// scripts/gen-issue-link-preview-spec.py, references in design/component-reference/issue-link-preview).
@MainActor @Suite(.fidelity)
struct IssueLinkPreviewFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "issueLinkPreview": .init(0.065),
    ]
    static let out = Fidelity.root.appendingPathComponent("issue-link-preview")

    static func view(_ name: String, size: CGSize) throws -> NSView {
        let url = SidebarFidelityTests.repo.appendingPathComponent("fixtures/issues/detail.json")
        let d = try JSONDecoder().decode(IssueDetail.self, from: Data(contentsOf: url))
        let view = IssueLinkPreviewView(detail: d, nowMs: T3Timestamp.parseEpochMs("2026-11-19T09:00:00Z")!)
        view.frame = NSRect(x: 8, y: 8, width: size.width, height: view.popupSize.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func issueLinkPreview() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/issue-link-preview")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/issue-link-preview.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='issue-link-preview/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("issue-link-preview", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("issueLinkPreview", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY issue-link-preview: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Issue link preview</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-issue-link-preview.html"), atomically: true, encoding: .utf8)
        // The card's 89.25pt height leaves its border and text on a half pixel, as the pull request card's does.
        #expect(mean < 0.06)
    }
}
