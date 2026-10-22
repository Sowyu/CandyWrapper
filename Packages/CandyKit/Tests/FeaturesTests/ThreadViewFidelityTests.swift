import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The thread details card at each density and the context chips in a sent message, against T3's markup in
/// Chromium (spec from scripts/gen-threadview-spec.py, references in design/component-reference/threadview).
/// The full card is the thread details panel of design/reference/44-thread-details-panel.
/// Writes ref, ours and diff PNGs plus /tmp/candywrapper-fidelity/report-threadview.html.
@MainActor
struct ThreadViewFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/threadview")

    static func card(_ density: ThreadDetailsCardView.Density, size: CGSize) -> ThreadDetailsCardView {
        let card = ThreadDetailsCardView(frame: NSRect(origin: NSPoint(x: 8, y: 8), size: size))
        card.runContext.icons = [EnvironmentMachineIcon.definition("mac-mini"), IconName.folder.definition]
        card.runContext.text = "This Mac"
        card.showsOpenIn = true
        card.openIn.primary.icon = IconName.squareArrowOutUpRight.definition
        card.openIn.primary.text = "Open in Finder"
        card.branch.text = "main"
        card.gitActions.primary.icon = IconName.gitCommitHorizontal.definition
        card.gitActions.primary.text = "Commit"
        card.totals.insertions = 4
        card.totals.deletions = 0
        card.density = density
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// The records a sent message carries for each chip in the spec.
    static func chips() -> MarkdownContextChips {
        func record(_ fields: [String: JSONValue]) -> JSONValue { .object(fields.merging(["version": .number(1)]) { a, _ in a }) }
        let records: [String: JSONValue] = [
            "thread_demo": record(["kind": .string("thread"), "contextId": .string("thread_demo"), "label": .string("Fix login redirect"),
                                   "environmentId": .string("env"), "threadId": .string("t1"), "title": .string("Fix login redirect")]),
            "terminal_demo": record(["kind": .string("terminal"), "contextId": .string("terminal_demo"), "label": .string("Terminal 1 lines 4-9"),
                                     "terminalId": .string("default"), "terminalLabel": .string("Terminal 1"), "lineStart": .number(4),
                                     "lineEnd": .number(9), "text": .string("npm test\nok")]),
            "file_demo": record(["kind": .string("file"), "contextId": .string("file_demo"), "label": .string("report.ts"), "attachmentId": .string("a-file"),
                                 "name": .string("report.ts"), "mimeType": .string("text/plain"), "sizeBytes": .number(12 * 1024)]),
            "image_demo": record(["kind": .string("image"), "contextId": .string("image_demo"), "label": .string("screenshot.png"), "attachmentId": .string("a-image"),
                                  "name": .string("screenshot.png"), "mimeType": .string("image/png"), "sizeBytes": .number(48 * 1024)]),
        ]
        let attachments: [String: JSONValue] = [
            "a-file": .object(["type": .string("file"), "id": .string("a-file"), "name": .string("report.ts"), "mimeType": .string("text/plain")]),
            "a-image": .object(["type": .string("image"), "id": .string("a-image"), "name": .string("screenshot.png"), "mimeType": .string("image/png")]),
        ]
        // The live thread title, as `useThreadShell` gives it.
        return MarkdownContextChips(records: records, attachments: attachments, threads: ["t1": .init(title: "Fix login redirect")])
    }

    /// A solid 4x4 picture, the one the reference's `<img>` shows.
    static func solid(_ rgb: [Int]) -> CGImage {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    @Test func threadview() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/threadview")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/threadview.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                if native["kind"] == "pr" {
                    let row = ThreadDetailsPrRowView()
                    row.open.icons = [IconName.gitPullRequestArrow.definition]
                    row.open.iconColor = PullRequestStyle.color(.open)
                    row.open.text = "Add login redirect"
                    row.numberText = "#42"
                    let (icon, color) = PullRequestStyle.checksState("passing")
                    row.checks.icon = icon.definition
                    row.checks.iconColor = color
                    row.action.text = "Merge"
                    row.action.tone = .primary
                    row.frame = NSRect(x: 8, y: 8, width: 246, height: ThreadDetailsPrRowView.height)
                    row.layoutSubtreeIfNeeded()
                    canvas.addSubview(row)
                } else if native["kind"] == "card" {
                    let density: ThreadDetailsCardView.Density = switch native["density"] { case "compact": .compact; case "essential": .essential; default: .full }
                    canvas.addSubview(Self.card(density, size: CGSize(width: css["width"]!, height: css["height"]!)))
                } else {
                    let rgb = native["rgb"]!.split(separator: ",").map { Int($0)! }
                    let image = Self.solid(rgb)
                    MarkdownContextChips.thumbnails["a-image"] = (image, MarkdownContextChips.averageColor(image))
                    let view = MarkdownView(frame: .zero)
                    view.bodyColor = Themed.color(\.foreground)
                    view.contextChips = Self.chips()
                    view.setMarkdown(native["markdown"]!, preservesLineBreaks: true)
                    let width = CGFloat(Double(native["width"]!)!)
                    view.frame = NSRect(x: 8, y: 8, width: width, height: view.height(forWidth: width))
                    canvas.addSubview(view)
                }
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='threadview/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("threadview", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY threadview: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Thread view</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-threadview.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
        #expect(lines.allSatisfy { $0.1 < 0.08 })
    }

    /// `resolveThreadDetailsCardDensity` and what each density shows.
    @Test func densities() {
        #expect(ThreadDetailsCardView.resolveDensity(height: 300, full: 250, compact: 150) == .full)
        #expect(ThreadDetailsCardView.resolveDensity(height: 200, full: 250, compact: 150) == .compact)
        #expect(ThreadDetailsCardView.resolveDensity(height: 100, full: 250, compact: 150) == .essential)
        #expect(ThreadDetailsCardView.resolveDensity(height: 100, full: 0, compact: 150) == .full) // not measured yet
        let card = Self.card(.full, size: CGSize(width: 264, height: 300))
        let full = card.preferredHeight(.full), compact = card.preferredHeight(.compact), essential = card.preferredHeight(.essential)
        // Full: run context, Open in, rule, branch, git actions, Changes. Compact drops run context, the rule and the idle git actions; essential Open in.
        #expect(abs(full - (2 + 8 + 32 + 32 + 10 + 1 + 8 + 32 * 3 + 10)) < 0.01)
        #expect(abs(compact - (full - 32 - 1 - 32)) < 0.01)
        #expect(abs(essential - (compact - 32)) < 0.01)
        #expect(card.density(fitting: full) == .full)
        #expect(card.density(fitting: full - 1) == .compact)
        #expect(card.density(fitting: compact - 1) == .essential)
        card.density = .compact
        #expect(card.runContext.isHidden && card.gitActions.isHidden && !card.openIn.isHidden)
        // A running git action shows in compact (GitActionsControl.tsx:1824).
        card.gitActions.primary.mode = .running(status: "Committing…", output: nil)
        #expect(!card.gitActions.isHidden && abs(card.preferredHeight - (compact + 32)) < 0.01)
        card.density = .essential
        #expect(card.openIn.isHidden)
    }

    /// Each reference kind resolves to its chip, a missing record to the unavailable chip, and an image
    /// chip's accent is its picture's alpha-weighted average color.
    @Test func chipKinds() {
        let chips = Self.chips()
        #expect(chips.chip(kind: "thread", contextId: "thread_demo", label: "x").look.label == "Fix login redirect")
        #expect(chips.chip(kind: "thread", contextId: "thread_demo", label: "x").action == .openThread("t1"))
        #expect(chips.chip(kind: "terminal", contextId: "terminal_demo", label: "x").look.kind == .terminal)
        #expect(chips.chip(kind: "file", contextId: "file_demo", label: "x").look.detail == "12 KB")
        #expect(chips.chip(kind: "image", contextId: "image_demo", label: "x").imageAttachmentId == "a-image")
        #expect(chips.chip(kind: "image", contextId: "missing", label: "gone").look.kind == .unresolved)
        #expect(chips.chip(kind: "file", contextId: "thread_demo", label: "x").look.kind == .unresolved) // kind mismatch
        var stale = chips
        stale.threads = [:]
        #expect(stale.chip(kind: "thread", contextId: "thread_demo", label: "x").tooltip == "Thread no longer available")
        let color = MarkdownContextChips.averageColor(Self.solid([46, 139, 87]))!.usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent * 255 - 46) < 1 && abs(color.greenComponent * 255 - 139) < 1 && abs(color.blueComponent * 255 - 87) < 1)
        // `![name](t3-context://…)` becomes an inline chip, not an image block.
        let doc = MarkdownContextChips.document(MarkdownDocument(parsing: "![a.png](t3-context://v1/image/image_demo)", preservesLineBreaks: true))
        if case .paragraph(let runs)? = doc.blocks.first { #expect(runs.first?.link?.scheme == "t3-context") } else { Issue.record("expected a paragraph") }
    }
}
