import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The changed files card and the diff panel opened from it, against design/reference 47 and 48
/// (the "Add notes and docstring" thread, scrolled so the card sits where T3 put it). 47 compares
/// the main panel above the composer; 48 compares the chat column above the composer and the whole
/// right panel, after clicking notes.md in the card. The diff comes from the recorded
/// `getFullThreadDiff` reply in fixtures/transcripts/03-turn2.jsonl. Writes ref, ours and diff PNGs
/// plus report-changed-files.html to /tmp/candywrapper-fidelity.
@MainActor
struct ChangedFilesFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/changed-files")
    static let size = ThreadFidelityTests.size
    static let thread = "Add notes and docstring"

    /// The panel with the card's top edge at `cardTop` (window points, from the capture plan's log).
    static func render(dark: Bool, openDiff: Bool, cardTop: CGFloat) async throws -> (ThreadPanelView, NSBitmapImageRep) {
        let projection = try #require(try ThreadPreview.projection(titled: thread))
        let panel = ThreadPanelView(frame: NSRect(origin: .zero, size: size))
        panel.bottomInset = ThreadFidelityTests.composerInset
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let patch = try DiffTests.recordedPatch()
        panel.diffPanel.loader = { request in
            let json = try JSONSerialization.data(withJSONObject: ["threadId": projection.thread.id.rawValue, "fromTurnCount": 0, "toTurnCount": 1, "diff": patch])
            return try JSONDecoder().decode(ThreadTurnDiff.self, from: json)
        }
        // The sandbox's diff layout setting is split since the 09 capture.
        panel.diffPanel.layoutStyle = .split
        panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        panel.layoutSubtreeIfNeeded()
        let summary = try #require(TurnDiffs.summaries(projection).first { !$0.files.isEmpty })
        if openDiff {
            panel.model.onOpenTurnDiff?(summary.runId, "notes.md")
            for _ in 0..<200 where panel.diffPanel.list.diff.files.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            panel.layoutSubtreeIfNeeded()
        }
        panel.timeline.scroll(toFraction: 0)
        for _ in 0..<3 {
            let card = try #require(cardView(in: panel))
            let y = card.convert(card.bounds, to: panel).minY
            if abs(y - cardTop) < 0.01 { break }
            panel.timeline.scroll(by: y - cardTop)
            panel.layoutSubtreeIfNeeded()
        }
        return (panel, Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: size, scale: 2, dark: dark))
    }

    static func cardView(in view: NSView) -> ChangedFilesCardView? {
        if let card = view as? ChangedFilesCardView, !card.isHidden, card.superview?.isHidden == false { return card }
        for sub in view.subviews { if let hit = cardView(in: sub) { return hit } }
        return nil
    }

    @Test func cardAndDiff() async throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let W = Int(Self.size.width * 2), compared = Int(ThreadFidelityTests.compared * 2)
        // Chat column width beside the open panel: 844 - 484.
        let chat = 360 * 2
        var lines: [String] = [], images = ""
        for theme in ["light", "dark"] {
            for (reference, openDiff, cardTop) in [("47-changed-files-card", false, 317.5), ("48-diff-turn-file", true, 476.75)] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference/\(reference).\(theme).png"))))
                let (panel, image) = try await Self.render(dark: theme == "dark", openDiff: openDiff, cardTop: cardTop)
                let x0 = full.pixelsWide - W
                let regions: [(String, Int, Int, Int)] = openDiff
                    ? [("chat", 0, chat, compared), ("panel", chat, W - chat, Int(Self.size.height * 2))]
                    : [("main", 0, W, compared)]
                for (name, x, width, height) in regions {
                    let ref = ThreadFidelityTests.crop(full, x: x0 + x, width: width, height: height)
                    let ours = ThreadFidelityTests.crop(image, x: x, width: width, height: height)
                    let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [(name, 0, height / 2)])
                    let base = "\(reference).\(name).\(theme)"
                    try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                    let line = "\(base): \(String(format: "%.2f", total * 100))% differ"
                    print("changed-files", line)
                    lines.append(line)
                    images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='changed-files/\(base).\($0).png'>" }.joined() + "</p>"
                    #expect(total < 0.05, "\(line)")
                }
                if openDiff {
                    #expect(panel.rightPanelOpen)
                    #expect(panel.diffPanel.list.diff.files.map(\.path) == ["hello.py", "notes.md"])
                }
            }
        }
        let html = "<!doctype html><meta charset=utf-8><title>Changed files</title><body style='font:13px -apple-system'>"
            + "<p>T3 web client capture, ours, diff (red where a channel differs by more than \(SidebarFidelityTests.tolerance)/255).</p>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-changed-files.html"), atomically: true, encoding: .utf8)
    }

    /// The tree rows and the expand state: folders start closed, fold-all opens every folder and
    /// clears per-folder overrides, a folder toggle overrides fold-all.
    @Test func folderState() throws {
        let files = [CheckpointFile(path: "src/app/a.swift", additions: 2, deletions: 1), CheckpointFile(path: "src/b.md", additions: 1, deletions: 0),
                     CheckpointFile(path: "README.md", additions: 3, deletions: 0)]
        let closed = ChangedFilesCardView.rows(files, allExpanded: false, overrides: [:])
        #expect(closed.map(\.node.name) == ["src", "README.md"])
        let open = ChangedFilesCardView.rows(files, allExpanded: true, overrides: [:])
        #expect(open.map(\.node.name) == ["src", "app", "a.swift", "b.md", "README.md"])
        #expect(open.map(\.depth) == [0, 1, 2, 1, 0])
        let one = ChangedFilesCardView.rows(files, allExpanded: true, overrides: ["src/app": false])
        #expect(one.map(\.node.name) == ["src", "app", "b.md", "README.md"])
        #expect(ChangedFilesCardView.height(files, allExpanded: false, overrides: [:]) == 40 + 16 + 28.5 + 28)
        #expect(FileTypeIcon.token(for: "x/hello.py") == "python")
        #expect(FileTypeIcon.token(for: "notes.md") == "markdown")
        #expect(FileTypeIcon.token(for: "package.json") == "npm")
        #expect(FileTypeIcon.token(for: "a.unknownext") == "default")
        // No reference has folders; this writes one for eyeballing, `src` open and `src/app` closed.
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let card = ChangedFilesCardView(frame: NSRect(x: 0, y: 0, width: 420, height: 0))
        let summary = TurnDiffSummary(checkpointId: "c", scopeId: "s", runId: "r", checkpointTurnCount: 1, checkpointRef: "ref", status: "ready",
                                      files: files, assistantMessageId: nil, completedAt: T3Timestamp(stringLiteral: "2026-10-10T00:00:00Z"))
        card.configure(summary, allExpanded: false, overrides: ["src": true])
        card.setFrameSize(NSSize(width: 420, height: ChangedFilesCardView.height(files, allExpanded: false, overrides: ["src": true])))
        try Snapshot.writePNG(Snapshot.image(of: card, size: card.frame.size, scale: 2, dark: false), to: Self.out.appendingPathComponent("folders.light.png"))
    }
}
