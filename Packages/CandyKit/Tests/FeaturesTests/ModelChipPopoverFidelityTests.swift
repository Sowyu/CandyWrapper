import AppKit
import Testing
import DesignSystem
@testable import Features

/// The model chip's popover (`ContextChipPopover` with ModelMentionChip's details, 4928) against T3's markup in Chromium
/// (spec from scripts/gen-model-chip-popover-spec.py, references in design/component-reference/model-chip-popover).
@MainActor @Suite(.fidelity)
struct ModelChipPopoverFidelityTests {
    /// Measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = ["modelChipPopover": .init(0.04)]
    static let out = Fidelity.root.appendingPathComponent("model-chip-popover")

    @Test func modelChipPopover() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/model-chip-popover")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/model-chip-popover.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let popover = PopoverView(content: ModelMentionDetailsView(label: native["label"]!, provider: native["provider"]!, source: native["source"]!),
                                      padding: .compact, width: .lg)
            #expect(abs(popover.popupSize.height - CGFloat(manifest[name]?["height"] ?? 0)) <= 1, "\(name) height \(popover.popupSize.height)")
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                popover.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: popover.popupSize)
                canvas.addSubview(popover)
                popover.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                popover.removeFromSuperview()
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                print("model-chip-popover", base, String(format: "%.2f%%", total * 100))
                lines.append((base, total))
            }
        }
        Self.ceilings.check("modelChipPopover", lines)
    }
}
