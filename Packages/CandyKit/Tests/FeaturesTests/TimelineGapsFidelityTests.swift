import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The timeline task's surfaces against T3's markup in Chromium (spec from scripts/gen-timeline-gaps-spec.py,
/// references in design/component-reference/timeline-gaps): the plan's save dialog and Implement split, the
/// citation comment popover, the inspector's rich blocks and the attachment preview header.
/// Writes ref, ours and diff PNGs plus `Fidelity.root`/report-timeline-gaps.html.
@MainActor @Suite(.fidelity)
struct TimelineGapsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "timelineGaps": .init(0.075),
    ]
    static let out = Fidelity.root.appendingPathComponent("timeline-gaps")

    static func item(_ fields: [String: JSONValue]) -> TurnItem {
        var o: [String: JSONValue] = ["id": .string("item-1"), "threadId": .string("t"), "ordinal": .number(1), "status": .string("completed"),
                                      "updatedAt": .string("2026-01-01T00:00:00.000Z"), "runId": .string("run-1")]
        o.merge(fields) { _, new in new }
        return try! JSONValueDecoder().decode(TurnItem.self, from: .object(o))
    }

    /// The inspector items the spec draws.
    static func detail(_ name: String) -> WorkDetail {
        let item: TurnItem
        switch name {
        case "file-change":
            item = Self.item(["type": .string("file_change"), "fileName": .string("/tmp/demo-repo/Sources/Login.swift"), "additions": .number(12),
                              "deletions": .number(3), "changes": .array([
                                .object(["operation": .string("update"), "path": .string("/tmp/demo-repo/Sources/Login.swift")]),
                                .object(["operation": .string("rename"), "path": .string("/tmp/demo-repo/Sources/Session.swift"),
                                         "oldPath": .string("Sources/Old.swift"), "fileType": .string("swift"), "mimeType": .string("text/x-swift")]),
                              ])])
        case "web-search":
            item = Self.item(["type": .string("web_search"), "patterns": .array([.string("swift async let")]), "results": .array([
                .object(["title": .string("Concurrency | Swift.org"), "url": .string("https://swift.org/concurrency"),
                         "snippet": .string("Use async let to run child tasks in parallel.")]),
                .object([:]),
            ])])
        case "dynamic-tool":
            item = Self.item(["type": .string("dynamic_tool"), "input": .object(["path": .string("README.md"), "limit": .number(40)]),
                              "output": .string("# Demo repo")])
        case "checkpoint":
            item = Self.item(["type": .string("checkpoint"), "checkpointId": .string("cp-1"), "scopeId": .string("scope-1"),
                              "files": .array([.string("a"), .string("b"), .string("c")])])
        default:
            item = Self.item(["type": .string("fork"), "targetThreadId": .string("t-2")])
        }
        return WorkDetail.inspector(item, workspaceRoot: "/tmp/demo-repo", output: nil, checkpointStatus: { _ in "ready" })
    }

    static func view(_ native: [String: String], css: [String: Double]) -> NSView {
        let width = CGFloat(css["width"]!)
        switch native["kind"] {
        case "save-dialog":
            let dialog = DialogView(title: "Save plan to workspace", message: "Enter a path relative to /tmp/demo-repo.")
            dialog.maxWidth = 576
            dialog.panelContent = [ProposedPlanSaveForm(filename: "fix-login-redirect.md")]
            dialog.footerButtons = [ButtonView("Cancel", variant: .outline, size: .sm), ButtonView("Save", size: .sm)]
            dialog.frame = NSRect(x: 8, y: 8, width: width, height: dialog.height(forWidth: width))
            return dialog
        case "implement-split", "refine":
            let box = DSView(frame: NSRect(x: 8, y: 8, width: width, height: 32))
            let pill = MessageActionPill()
            pill.title = native["kind"] == "refine" ? "Refine" : "Implement"
            pill.widePadding = true
            var x: CGFloat = 0
            if native["kind"] == "implement-split" {
                pill.half = .leading
                let chevron = MessageActionPill()
                chevron.half = .trailing
                let cw = chevron.intrinsicContentSize.width, pw = pill.intrinsicContentSize.width
                pill.frame = NSRect(x: 0, y: 0, width: pw, height: 32)
                chevron.frame = NSRect(x: pw, y: 0, width: cw, height: 32)
                box.addSubview(chevron)
                x = pw
            } else {
                pill.frame = NSRect(x: 0, y: 0, width: pill.intrinsicContentSize.width, height: 32)
            }
            _ = x
            box.addSubview(pill)
            box.layoutSubtreeIfNeeded()
            return box
        case "citation":
            let editor = AssistantCitationCommentEditorView(comment: native["comment"])
            let popover = PopoverView(content: editor, padding: .compact, width: .md)
            popover.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: popover.popupSize)
            popover.layoutSubtreeIfNeeded()
            return popover
        case "inspector":
            let view = WorkDetailView()
            view.detail = detail(native["item"]!)
            view.frame = NSRect(x: 8, y: 8, width: width, height: view.height(forWidth: width))
            view.layoutSubtreeIfNeeded()
            return view
        default:
            let draft = native["variant"] == "draft"
            let surface = FileSurfaceView(frame: NSRect(x: 8, y: 8, width: width, height: draft ? 40 : 28))
            let noop: (@MainActor () -> Void)? = {}
            surface.attachment = FileSurfaceView.AttachmentChrome(origin: draft ? "Draft" : "Attachment", name: draft ? "notes.md" : "report.ts",
                                                                  sizeBytes: draft ? 2048 : 12 * 1024, inline: !draft, onSave: noop,
                                                                  onRemove: draft ? noop : nil, onClose: draft ? noop : nil)
            surface.show(path: draft ? "notes.md" : "report.ts", revealLine: nil)
            surface.setContent(.text(draft ? "# Notes" : "export const answer = 42", truncated: false, byteLength: 24, editable: false))
            surface.wrap = true
            surface.layoutSubtreeIfNeeded()
            return surface
        }
    }

    @Test func timelineGaps() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/timeline-gaps")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/timeline-gaps.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                canvas.addSubview(Self.view(native, css: manifest[name]!))
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='timeline-gaps/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("timeline-gaps", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("timelineGaps", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY timeline-gaps: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Timeline gaps</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-timeline-gaps.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
        #expect(lines.allSatisfy { $0.1 < 0.08 })
    }

    /// The plan helpers against proposedPlan.ts and proposedPlanText.ts.
    @Test func planText() {
        let plan = "# Fix login redirect\n\n## Summary\n\nKeep the session.\n\n" + (1...14).map { "- step \($0)" }.joined(separator: "\n") + "\n"
        #expect(ProposedPlanText.title(plan) == "Fix login redirect")
        #expect(ProposedPlanText.filename(plan) == "fix-login-redirect.md")
        #expect(ProposedPlanText.filename("No heading") == "plan.md")
        #expect(ProposedPlanText.filename("# What's `new`? (v2)") == "whats-new-v2.md")
        #expect(ProposedPlanText.export("# A\n\n") == "# A\n")
        #expect(ProposedPlanText.implementationPrompt("\n# A\n") == "PLEASE IMPLEMENT THIS PLAN:\n# A")
        #expect(ProposedPlanText.implementationThreadTitle(plan) == "Implement Fix login redirect")
        #expect(ProposedPlanText.implementationThreadTitle("x") == "Implement plan")
        let long = ProposedPlanText.implementationThreadTitle("# " + String(repeating: "a", count: 60))
        #expect(long == "Implement " + String(repeating: "a", count: 40) + "...")
        // Ten visible lines; blank lines ride along; then "..." (buildCollapsedProposedPlanPreviewMarkdown).
        let preview = ProposedPlanText.collapsedPreview(plan)
        #expect(preview.hasPrefix("Keep the session.\n\n- step 1"))
        #expect(preview.hasSuffix("- step 9\n\n..."))
        #expect(ProposedPlanText.collapsedPreview("# Only a title") == "Only a title")
    }

    /// The inspector's blocks for each item kind (V2ItemInspector.tsx:222-424).
    @Test func inspectorBlocks() {
        let change = Self.detail("file-change")
        #expect(change.blocks.map(\.text) == ["demo-repo/Sources/Login.swift", "update demo-repo/Sources/Login.swift",
                                              "rename Sources/Old.swift → demo-repo/Sources/Session.swift (swift, text/x-swift)"])
        #expect(change.blocks[0].action == .openDiff(RunId("run-1"), "/tmp/demo-repo/Sources/Login.swift"))
        let web = Self.detail("web-search")
        #expect(web.blocks.map(\.kind) == [.mono(.pattern), .link("https://swift.org/concurrency"), .preview, .link(nil)])
        #expect(web.blocks.last?.text == "Search result")
        let tool = Self.detail("dynamic-tool")
        #expect(tool.blocks.first?.kind == .args([["limit", "40"], ["path", "README.md"]]))
        #expect(Self.detail("checkpoint").blocks.first?.action == .rollBack(checkpointId: "cp-1", scopeId: "scope-1"))
        let notReady = WorkDetail.inspector(Self.item(["type": .string("checkpoint"), "checkpointId": .string("cp-1"), "files": .array([])]),
                                            workspaceRoot: nil, output: nil, checkpointStatus: { _ in "pending" })
        #expect(notReady.blocks.first?.action == nil && notReady.blocks.first?.text == "pending · 0 files")
        #expect(Self.detail("fork").blocks.first?.action == .openFork(ThreadId("t-2")))
        // A failed change shows its patch.
        let failed = WorkDetail.inspector(Self.item(["type": .string("file_change"), "status": .string("failed"), "fileName": .string("a.swift"),
                                                     "diffStr": .string("@@ -1 +1 @@")]), workspaceRoot: nil, output: nil, checkpointStatus: nil)
        #expect(failed.blocks.map(\.text) == ["a.swift", "@@ -1 +1 @@"])
    }
}
