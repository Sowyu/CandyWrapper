import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The queued messages strip against design/reference 29: two queued messages above the running
/// composer (Stop), with the real footer pickers. Compared at 2x in the main panel's coordinates,
/// the band from the strip's top to the panel's bottom. Writes ref, ours and diff PNGs plus
/// report-queue.html to /tmp/candywrapper-fidelity.
@MainActor
struct QueueFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/queue")

    static func render(dark: Bool, width: CGFloat, pickers: ComposerPickers) throws -> NSBitmapImageRep {
        let panel = ComposerFidelityTests.panel(width: width, dark: dark)
        // Reference 29's thread has nothing behind the strip; the markdown thread scrolled to its end neither.
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.composer.footerControls = [pickers.controlsView]
        panel.composer.runState = ComposerLogic.RunState(activeRunId: RunId("run"), running: true)
        panel.queue.state = ComposerLogic.QueueState(items: [
            .init(runId: RunId("q1"), messageId: nil, text: "second queued message"),
            .init(runId: RunId("q2"), messageId: nil, text: "third queued message"),
        ], activeRunId: RunId("run"), canReorder: true, canPromoteToSteer: true)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: 1)
        return Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: panel.frame.size, scale: 2, dark: dark)
    }

    @Test func queuedMessages() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let width: CGFloat = 844, top = 520, bottom = 780
        var lines: [String] = [], images = ""
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                "design/reference/29-queued-messages.\(theme).png"))))
            let w = Int(width * 2)
            let crop = CGRect(x: full.pixelsWide - w, y: top * 2, width: w, height: (bottom - top) * 2)
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: crop)!)
            let rendered = try Self.render(dark: theme == "dark", width: width, pickers: PickersPreview.pickers())
            let ours = NSBitmapImageRep(cgImage: rendered.cgImage!.cropping(to: CGRect(x: 0, y: top * 2, width: w, height: (bottom - top) * 2))!)
            let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [("all", 0, bottom - top)])
            let base = "29-queued-messages.\(theme)"
            try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
            try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
            try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
            let line = "\(base): \(String(format: "%.2f", total * 100))% differ"
            print("queue", line)
            lines.append(line)
            images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='queue/\(base).\($0).png'>" }.joined() + "</p>"
            #expect(total < 0.05, "\(line)")
        }
        let html = "<!doctype html><meta charset=utf-8><title>Queue</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-queue.html"), atomically: true, encoding: .utf8)
    }
}
