import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The diff panel against T3. `body`: DiffListView against T3's own @pierre/diffs rendering each
/// patch in Chromium with T3's CSS (spec from scripts/gen-diff-spec.py, references in
/// design/component-reference/diff). `panel`: DiffPanelView against the right panel of
/// design/reference-3824/09-diff-split and 10-diff-unified, rebuilt from the file list those captures show.
/// Writes ref, ours and diff PNGs plus `Fidelity.root`/report-diff.html.
@MainActor @Suite(.fidelity)
struct DiffFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "body": .init(0.07, except: [
            "wrap.split.dark": 0.08,
            "wrap.unified.dark": 0.085,
        ]),
        "panel 09-diff-split": .init(0.085),
        "panel 10-diff-unified": .init(0.085),
    ]
    static let repo = MarkdownFidelityTests.repo
    static let out = Fidelity.root

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
        var rows = "", cases: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                try #require(ref.pixelsHigh > 32, "Diff reference must contain the rendered file, not just the 8px capture padding")
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
                cases.append(("\(name).\(theme)", try Self.record("\(name).\(theme)", ref: ref, ours: ours, rows: &rows)))
            }
        }
        print(String(format: "FIDELITY Diff body: %d cases, mean differing %.2f%%", cases.count, cases.map(\.1).reduce(0, +) / Double(max(cases.count, 1)) * 100))
        try Self.writeReport(rows, file: "report-diff.html")
        Self.ceilings.check("body", cases)
    }

    /// The panel area of the 2200x1560 captures: x from the panel's left border (1234 px) to the
    /// window edge, y from the header row (103 px, under the right panel's tab strip, which is not
    /// part of DiffPanel) to the bottom.
    /// 3824 expands both sandbox files. 09 uses split layout and 10 uses stacked layout.
    @Test(arguments: ["10-diff-unified", "09-diff-split"])
    func panel(_ reference: String) async throws {
        defer { Fidelity.pin() }
        var rows = "", cases: [(String, Double)] = []
        for theme in ["light", "dark"] {
            let full = try #require(NSBitmapImageRep(data: Data(contentsOf: Self.repo.appendingPathComponent("design/reference-3824/\(reference).\(theme).png"))))
            let crop = CGRect(x: 1234, y: 103, width: 966, height: 1457)
            let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: crop)!)
            let panel = DiffPanelView()
            panel.showsRefresh = true
            panel.statStyle = .pierre
            panel.layoutStyle = reference == "09-diff-split" ? .split : .unified
            panel.bodyOffset = 0.5
            let patch = try String(contentsOf: Self.repo.appendingPathComponent("fixtures/3824-panel.patch"), encoding: .utf8)
            panel.workspaceRoot = "/sandbox/demo-repo"
            panel.gitLoader = { cwd, _, _ in
                ReviewDiffPreview(cwd: cwd, sources: [.init(id: "branch", kind: "branch-range", title: "Changes",
                    baseRef: nil, headRef: nil, diff: patch, diffHash: "3824-panel", truncated: false)])
            }
            panel.fileContentsLoader = { _, _, file in
                let old = "def greet(name):\n    return f\"Hello, {name}!\"\n"
                return ReviewDiffFileContents(oldContents: old, newContents: file.path == "hello.py"
                    ? "\"\"\"Small demo module with a greeting helper.\"\"\"\n\n\n" + old : "")
            }
            panel.selectGitScope(.branch)
            for _ in 0..<200 where panel.list.diff.files.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!panel.list.diff.files.isEmpty)
            panel.list.setAllCollapsed(false)
            let ours = FontRuntime.$smoothingOverride.withValue(false) {
                Snapshot.image(of: panel, size: NSSize(width: crop.width / 2, height: crop.height / 2), scale: 2, dark: theme == "dark")
            }
            cases.append(("\(reference).\(theme)", try Self.record("\(reference).\(theme)", ref: ref, ours: ours, rows: &rows)))
        }
        print(String(format: "FIDELITY Diff panel %@: mean differing %.2f%%", reference, cases.map(\.1).reduce(0, +) / 2 * 100))
        try Self.writeReport(rows, file: "report-diff-panel-\(reference).html")
        Self.ceilings.check("panel \(reference)", cases)
    }

    /// The gallery panels, written for review. An export tool,
    /// not a test: runs only with CW_EXPORT=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CW_EXPORT"] != nil, "export tool, set CW_EXPORT=1"))
    func gallery() throws {
        for (i, section) in DiffGallery.sections.enumerated() {
            for theme in ["light", "dark"] {
                let view = section.make()
                let rep = Snapshot.image(of: view, size: NSSize(width: 518, height: section.height), scale: 2, dark: theme == "dark")
                try Snapshot.writePNG(rep, to: Self.out.appendingPathComponent("diff/gallery-\(i).\(theme).png"))
            }
        }
    }
}
