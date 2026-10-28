import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The queued messages strip against design/reference 29: two queued messages above the running
/// composer (Stop), with the real footer pickers. Compared at 2x in the main panel's coordinates,
/// the band from the strip's top to the panel's bottom. Writes ref, ours and diff PNGs plus
/// report-queue.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct QueueFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "queuedMessages": .init(0.075),
    ]
    static let out = Fidelity.root.appendingPathComponent("queue")

    static func render(dark: Bool, width: CGFloat, pickers: ComposerPickers) throws -> NSBitmapImageRep {
        let panel = ComposerFidelityTests.panel(width: width, dark: dark)
        // Reference 29's thread has nothing behind the strip; the markdown thread scrolled to its end neither.
        let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.composer.footerControls = [pickers.controlsView]
        panel.composer.runState = ComposerLogic.RunState(activeRunId: RunId("run"), running: true)
        panel.queue.state = ComposerLogic.QueueState(items: [
            .init(runId: RunId("q1"), messageId: nil, text: "First queued note."),
            .init(runId: RunId("q2"), messageId: nil, text: "Second queued note."),
        ], activeRunId: RunId("run"), canPromoteToSteer: true)
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: 1)
        return Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: panel.frame.size, scale: 2, dark: dark)
    }

    /// Component markup also covers sender attribution, editing and multiline queues.
    @Test func queueComponents() throws {
        let repo = SidebarFidelityTests.repo
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/queue.json"))) as! [String: Any]
        let refs = repo.appendingPathComponent("design/component-reference/queue")
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var diffs: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let n = c["native"] as! [String: String], kind = n["kind"]!, text = n["text"]!
            for dark in [false, true] {
                let base = "\(kind).rest.\(dark ? "dark" : "light")"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refs.appendingPathComponent(base + ".png"))))
                let queue = QueuedRunsView()
                queue.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                var message = ChatMessage(id: MessageId("message"), role: .user, text: text, runId: RunId("queued"), createdAt: T3Timestamp("2026-10-28T10:00:00Z"))
                if kind == "agent" { message.createdBy = "agent"; message.senderThreadId = "helper"; queue.senderThreadTitles = ["helper": "Review helper"] }
                if kind == "automation" { message.scheduledTaskId = "task"; queue.scheduledTaskTitles = ["task": "Daily review"] }
                if kind == "server" { message.createdBy = "agent"; message.creationSource = "server" }
                queue.state = .init(items: [.init(runId: RunId("queued"), messageId: message.id, text: text, guestName: kind == "guest" ? "Guest" : nil, message: message)], canPromoteToSteer: true)
                if kind == "editing" { queue.editingRunId = RunId("queued") }
                queue.frame = NSRect(x: 8, y: 8, width: 600, height: queue.height(forWidth: 600))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                canvas.addSubview(queue)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: dark)
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent(base + ".ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent(base + ".diff.png"))
                print("queue-component", base, String(format: "%.2f%%", total * 100))
                diffs.append((base, total))
            }
        }
        Self.ceilings.check("queuedMessages", diffs)
        #expect(diffs.map(\.1).reduce(0, +) / Double(diffs.count) < 0.05)
    }

    @Test func queuedMessages() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let width: CGFloat = 844, top = 520, bottom = 780
        var lines: [String] = [], cases: [(String, Double)] = [], images = ""
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                "design/reference-3824/29-queued-messages.\(theme).png"))))
            let w = Int(width * 2)
            let crop = CGRect(x: full.pixelsWide - w, y: top * 2, width: w, height: (bottom - top) * 2)
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: crop)!)
            let rendered = try Self.render(dark: theme == "dark", width: width, pickers: try Screen3824Fixtures.pickers())
            let ours = NSBitmapImageRep(cgImage: rendered.cgImage!.cropping(to: CGRect(x: 0, y: top * 2, width: w, height: (bottom - top) * 2))!)
            let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [("all", 0, bottom - top)])
            let base = "29-queued-messages.\(theme)"
            try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
            try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
            try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
            let line = "\(base): \(String(format: "%.2f", total * 100))% differ"
            print("queue", line)
            lines.append(line)
            cases.append((base, total))
            images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='queue/\(base).\($0).png'>" }.joined() + "</p>"
            // 3824 ChatView.tsx:2948-2963 puts the queue in the timeline. Keep the old
            // 520...780 composer crop and also compare the bubbles at their new screen position.
            let queue = QueuedRunsView()
            queue.state = .init(items: [
                .init(runId: "q1", messageId: nil, text: "First queued note."),
                .init(runId: "q2", messageId: nil, text: "Second queued note."),
            ], activeRunId: "run", canPromoteToSteer: true)
            queue.frame = NSRect(x: 54, y: 0, width: 736, height: queue.height(forWidth: 736))
            let canvas = GrainSurfaceView(fill: Themed.color(\.background))
            canvas.addSubview(queue)
            let bubbles = Snapshot.image(of: canvas, size: NSSize(width: width, height: 160), scale: 2, dark: theme == "dark")
            let bubblesRef = PickersFidelityTests.crop(full, CGRect(x: 256, y: 266, width: width, height: 160))
            let (bubbleDiff, _, bubbleImage) = SidebarFidelityTests.compare(bubblesRef, bubbles, bands: [])
            let bubbleBase = "29-queued-bubbles.\(theme)"
            try Snapshot.writePNG(bubblesRef, to: Self.out.appendingPathComponent("\(bubbleBase).ref.png"))
            try Snapshot.writePNG(bubbles, to: Self.out.appendingPathComponent("\(bubbleBase).ours.png"))
            try Snapshot.writePNG(bubbleImage, to: Self.out.appendingPathComponent("\(bubbleBase).diff.png"))
            print("queue", bubbleBase, String(format: "%.2f%%", bubbleDiff * 100))
            cases.append((bubbleBase, bubbleDiff))
            images += "<p>\(bubbleBase): \(String(format: "%.2f", bubbleDiff * 100))%<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='queue/\(bubbleBase).\($0).png'>" }.joined() + "</p>"
            #expect(bubbleDiff < 0.05)
            #expect(total < 0.05, "\(line)")
        }
        Self.ceilings.check("queuedMessages", cases)
        let html = "<!doctype html><meta charset=utf-8><title>Queue</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-queue.html"), atomically: true, encoding: .utf8)
    }
}
