import AppKit
import Testing
import DesignSystem
@testable import Features

/// The diff panel against T3. `body`: DiffListView against T3's own @pierre/diffs rendering each
/// patch in Chromium with T3's CSS (spec from scripts/gen-diff-spec.py, references in
/// design/component-reference/diff). `panel`: DiffPanelView against the right panel of
/// design/reference/09-diff-split and 10-diff-unified, rebuilt from the file list those captures show.
/// Writes ref, ours and diff PNGs plus /tmp/candywrapper-fidelity/report-diff.html.
@MainActor
struct DiffFidelityTests {
    static let repo = MarkdownFidelityTests.repo
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity")

    final class Canvas: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    struct Result { var name: String; var share: Double }

    static func record(_ name: String, ref: NSBitmapImageRep, ours: NSBitmapImageRep, rows: inout String) throws -> Double {
        let dir = out.appendingPathComponent("diff")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (share, diff) = MarkdownFidelityTests.compare(ref, ours)
        try Snapshot.writePNG(ref, to: dir.appendingPathComponent("\(name).ref.png"))
        try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(name).ours.png"))
        try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(name).diff.png"))
        let line = String(format: "%@: %.2f%% differ", name, share * 100)
        print("DIFF", line)
        rows += "<tr><td>\(line)</td>" + ["ref", "ours", "diff"].map { "<td><img src='diff/\(name).\($0).png'></td>" }.joined() + "</tr>"
        return share
    }

    static func writeReport(_ rows: String, file: String) throws {
        let html = "<!doctype html><meta charset=utf-8><title>Diff fidelity</title><style>body{font:13px -apple-system}td{vertical-align:top}img{zoom:.5}</style>"
            + "<p>T3 in Chromium, ours, diff (red where a channel differs by more than \(MarkdownFidelityTests.tolerance)/255).</p><table>\(rows)</table>"
        try html.write(to: out.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    @Test func body() throws {
        let refDir = Self.repo.appendingPathComponent("design/component-reference/diff")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appendingPathComponent("design/component-reference/diff.json"))) as! [String: Any]
        var rows = "", total = 0.0, count = 0
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let list = DiffListView()
                list.style = native["style"] as? String == "split" ? .split : .unified
                let scroll = ScrollAreaView(documentView: list)
                scroll.hideScrollbars = true
                let canvas = Canvas(frame: .zero)
                canvas.addSubview(scroll)
                scroll.frame = NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
                list.setDiff(UnifiedDiff(native["patch"] as! String), collapsedByDefault: native["collapsed"] as? Bool ?? false)
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                total += try Self.record("\(name).\(theme)", ref: ref, ours: ours, rows: &rows)
                count += 1
            }
        }
        print(String(format: "FIDELITY Diff body: %d cases, mean differing %.2f%%", count, total / Double(max(count, 1)) * 100))
        try Self.writeReport(rows, file: "report-diff.html")
        #expect(count > 0)
    }

    /// The panel area of the 2200x1560 captures: x from the panel's left border (1234 px) to the
    /// window edge, y from the header row (103 px, under the right panel's tab strip, which is not
    /// part of DiffPanel) to the bottom.
    /// Both captures show the split toggle pressed (the setting stayed split after the 09 capture),
    /// and every file is collapsed, so the two differ only by capture noise.
    @Test(arguments: ["10-diff-unified", "09-diff-split"])
    func panel(_ reference: String) throws {
        var rows = "", total = 0.0
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: Self.repo.appendingPathComponent("design/reference/\(reference).\(theme).png"))))
            let crop = CGRect(x: 1234, y: 103, width: 966, height: 1457)
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: crop)!)
            let panel = DiffPanelView()
            panel.showsRefresh = true
            panel.statStyle = .aligned
            panel.layoutStyle = .split
            panel.bodyOffset = 0.5
            panel.showPatch(DiffPreview.referencePatch(), scopeLabel: "Uncommitted")
            let ours = Snapshot.image(of: panel, size: NSSize(width: crop.width / 2, height: crop.height / 2), scale: 2, dark: theme == "dark")
            total += try Self.record("\(reference).\(theme)", ref: ref, ours: ours, rows: &rows)
        }
        print(String(format: "FIDELITY Diff panel %@: mean differing %.2f%%", reference, total / 2 * 100))
        try Self.writeReport(rows, file: "report-diff-panel-\(reference).html")
    }

    /// The gallery panels, written for review (no reference: T3 shows no expanded file in 09 or 10).
    @Test func gallery() throws {
        for (i, section) in DiffGallery.sections.enumerated() {
            for theme in ["light", "dark"] {
                let view = section.make()
                let rep = Snapshot.image(of: view, size: NSSize(width: 518, height: section.height), scale: 2, dark: theme == "dark")
                try Snapshot.writePNG(rep, to: Self.out.appendingPathComponent("diff/gallery-\(i).\(theme).png"))
            }
        }
    }
}
