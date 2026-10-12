import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The reference screens no other case covered: find in thread's match paint (design/reference/43-find-in-thread),
/// Go to file (45-go-to-file), Search project contents on a Python file (46-project-search) and the top bar with the
/// sidebar collapsed (31-sidebar-collapsed shows it open, so that case follows T3's source), against T3's markup in
/// Chromium (spec from scripts/gen-reference-screens-spec.py, references in design/component-reference/reference-screens).
/// The narrow window (03n-kitchen-sink-narrow) compares the thread panel at 800pt minus the 208pt sidebar directly.
/// Writes ref, ours and diff PNGs plus report-reference-screens.html to /tmp/candywrapper-fidelity.
@MainActor
struct ReferenceScreensFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/reference-screens")

    static func view(_ native: [String: String], size: CGSize) -> NSView {
        let frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        switch native["case"] {
        case "find":
            let view = MarkdownView(frame: .zero)
            view.setMarkdown(native["markdown"]!)
            view.threadFindQuery = "markdown"
            view.threadFindOccurrence = 0
            view.frame = NSRect(x: 8, y: 8, width: size.width, height: view.height(forWidth: size.width))
            return view
        case "go-to-file":
            let items = ["hello.py", "notes.md", "README.md", "src/answer.ts"].map { path in
                var item = CommandPaletteItem((path as NSString).lastPathComponent, icon: .file, description: path)
                item.glyph = FileTypeIcon.icon(for: path)
                return item
            }
            let palette = CommandPaletteView(content: .results([CommandPaletteGroup("demo-repo", items)]))
            palette.input.placeholder = "Search files\u{2026}"
            palette.footerActionLabel = "Open file"
            palette.escapeLabel = "Back"
            palette.frame = frame
            return palette
        case "project-search":
            let body = ContentSearchView()
            let line = "    return f\"Hello, {name}!\""
            body.apply(matches: [ProjectContentMatch(path: "hello.py", lineNumber: 3, lineContent: line, matchRanges: [.init(start: 13, end: 18)])],
                       status: .results(count: 1, truncated: false, files: 1), empty: "No results found.")
            let palette = CommandPaletteView(content: .custom(body))
            palette.inputAccessory = body.accessory
            palette.input.placeholder = "Search in demo-repo"
            palette.input.text = "hello"
            palette.footerActionLabel = "Open file"
            palette.escapeLabel = "Back"
            palette.frame = frame
            return palette
        default:
            let header = ThreadHeaderView(frame: .zero)
            header.projectTitle = "demo-repo"
            header.threadTitle = "Reply with markdown only"
            header.toggles.forEach { $0.isHidden = true }
            let layout = SidebarLayoutView(mainContent: header, defaults: UserDefaults(suiteName: "candywrapper.fidelity.reference-screens")!,
                                           viewport: size.width)
            layout.setOpen(false)
            layout.frame = frame
            layout.clipsToBounds = true // the window's edge hides the collapsed sidebar in the app
            return layout
        }
    }

    @Test func referenceScreens() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/reference-screens")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/reference-screens.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        func record(_ base: String, _ ref: NSBitmapImageRep, _ ours: NSBitmapImageRep) throws {
            let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
            try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
            try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
            try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
            lines.append((base, total))
            images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='reference-screens/\(base).\($0).png'>" }.joined() + "</p>"
        }
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                let view = Self.view(native, size: CGSize(width: css["width"]!, height: css["height"]!))
                canvas.addSubview(view)
                view.layoutSubtreeIfNeeded()
                try record(base, ref, Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark"))
            }
        }
        // 03n: the 800pt window, so the 640pt breakpoints see the window; the sidebar takes 208pt (SidebarWidth caps it at
        // 800 - 640) and only the thread panel above the composer is compared.
        let window = NSSize(width: 800, height: 780)
        let w = Int((window.width - SidebarMetrics.minWidth) * 2), h = Int(ThreadFidelityTests.compared * 2)
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: repo.appendingPathComponent("design/reference/03n-kitchen-sink-narrow.\(theme).png"))))
            let ref = ThreadFidelityTests.crop(full, x: full.pixelsWide - w, width: w, height: h)
            let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
            let panel = ThreadPanelView(frame: .zero)
            panel.bottomInset = ThreadFidelityTests.composerInset
            panel.model.runShellCommand = { _ in } // a thread with a project: shell blocks show "Run in terminal"
            let layout = SidebarLayoutView(mainContent: panel, defaults: UserDefaults(suiteName: "candywrapper.fidelity.reference-screens")!,
                                           viewport: window.width)
            layout.frame = NSRect(origin: .zero, size: window)
            layout.layoutSubtreeIfNeeded()
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            panel.layoutSubtreeIfNeeded()
            panel.timeline.scroll(toFraction: 1)
            let image = Snapshot.image(of: layout, size: window, scale: 2, dark: theme == "dark")
            try record("03n-narrow.\(theme)", ref, ThreadFidelityTests.crop(image, x: image.pixelsWide - w, width: w, height: h))
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("reference-screens", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY reference-screens: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Reference screens</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-reference-screens.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
