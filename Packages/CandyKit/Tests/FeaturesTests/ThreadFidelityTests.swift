import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Whole-panel comparison: our thread panel at 844x780 (the reference window minus the 256pt
/// sidebar), 2x, against design/reference 03a-c (the markdown thread at scroll 0, 0.5 and the end)
/// and 03d (the commands thread). Only the part above T3's composer is compared, since M4 has no
/// composer. Writes ref, ours and diff PNGs plus report-thread-whole.html to /tmp/candywrapper-fidelity.
@MainActor
struct ThreadFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/thread-whole")
    static let size = NSSize(width: 844, height: 780)
    /// The composer's top edge in the references is at 617pt; compare above its shadow.
    static let compared: CGFloat = 600
    /// What T3's floating composer takes from the scroll range: the end of the content sits this far
    /// above the canvas bottom in 03c.
    static let composerInset: CGFloat = {
        if let v = ProcessInfo.processInfo.environment["CW_COMPOSER_INSET"], let d = Double(v) { return CGFloat(d) }
        return 172
    }()

    static func render(_ title: String, fraction: CGFloat, dark: Bool) throws -> NSBitmapImageRep {
        let projection = try #require(try ThreadPreview.projection(titled: title))
        let panel = ThreadPanelView(frame: NSRect(origin: .zero, size: size))
        panel.bottomInset = composerInset
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: fraction)
        return Snapshot.image(of: panel, size: size, scale: 2, dark: dark)
    }

    static func crop(_ rep: NSBitmapImageRep, x: Int, width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(cgImage: rep.cgImage!.cropping(to: CGRect(x: x, y: 0, width: width, height: height))!)
    }

    /// No reference exists for open folds and tool details (H-timeline-visuals.md section 9 item 1);
    /// this writes them for eyeballing: the commands thread with its fold, group and first command open.
    @Test func expandedRowsRender() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.commandsThread))
        for theme in ["light", "dark"] {
            let panel = ThreadPanelView(frame: NSRect(origin: .zero, size: Self.size))
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            for run in projection.runs { panel.model.toggleRun(run.id) }
            for item in panel.model.items {
                if case .workToggle(let t) = item.row.kind { panel.model.toggleGroup(t.groupId) }
            }
            for item in panel.model.items {
                if case .work(let entries, _, _) = item.row.kind, let command = entries.first(where: { $0.command != nil }) {
                    panel.model.toggleEntry(command.id)
                    break
                }
            }
            panel.layoutSubtreeIfNeeded()
            panel.timeline.scroll(toFraction: 1)
            let image = Snapshot.image(of: panel, size: Self.size, scale: 2, dark: theme == "dark")
            try Snapshot.writePNG(image, to: Self.out.appendingPathComponent("expanded.\(theme).png"))
            #expect(panel.model.items.count > 4)
        }
    }

    @Test func wholePanel() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let cases: [(String, String, CGFloat)] = [
            ("03a-kitchen-sink-top", ThreadPreview.markdownThread, 0),
            ("03b-kitchen-sink-middle", ThreadPreview.markdownThread, 0.5),
            ("03c-kitchen-sink-bottom", ThreadPreview.markdownThread, 1),
            ("03d-kitchen-sink-commands", ThreadPreview.commandsThread, 0),
        ]
        let w = Int(Self.size.width * 2), h = Int(Self.compared * 2)
        var lines: [String] = [], images = ""
        for (reference, title, fraction) in cases {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference/\(reference).\(theme).png"))))
                let ref = Self.crop(full, x: full.pixelsWide - w, width: w, height: h)
                let ours = Self.crop(try Self.render(title, fraction: fraction, dark: theme == "dark"), x: 0, width: w, height: h)
                let bands = [("header", 0, 52), ("timeline", 52, Int(Self.compared))]
                let (total, perBand, diff) = SidebarFidelityTests.compare(ref, ours, bands: bands)
                let base = "\(reference).\(theme)"
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                let line = "\(base): \(String(format: "%.2f", total * 100))% differ; "
                    + perBand.map { "\($0.0) \(String(format: "%.2f", $0.1 * 100))%" }.joined(separator: ", ")
                print("thread-whole", line)
                lines.append(line)
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='thread-whole/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        let html = "<!doctype html><meta charset=utf-8><title>Thread panel</title><body style='font:13px -apple-system'>"
            + "<p>T3 web client capture, ours, diff (red where a channel differs by more than \(SidebarFidelityTests.tolerance)/255). Region: the main panel above the composer.</p>"
            + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-thread-whole.html"), atomically: true, encoding: .utf8)
    }
}
