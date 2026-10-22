import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Search result rows, draft rows, status lines and the project scope popup against T3's markup in
/// Chromium (spec from scripts/gen-sidebar-search-spec.py, references in design/component-reference/sidebar-search).
/// Writes ref, ours and diff PNGs plus report-sidebar-search.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct SidebarSearchFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "sidebarSearch": .init(0.06),
    ]
    static let out = Fidelity.root.appendingPathComponent("sidebar-search")

    /// The page's `--background` behind each case.
    final class Canvas: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    /// `data-app-sidebar bg-sidebar`, 240 wide with 8px padding.
    final class SidebarBox: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.sidebar, sidebar: true).cgColor(in: self) }
    }

    static func make(_ n: [String: String], hovered: Bool, size: NSSize) -> NSView {
        let flag = { (k: String) in n[k] == "true" }
        func place(_ rows: [(SidebarRowBase, SidebarItem)]) -> NSView {
            let box = SidebarBox(frame: NSRect(origin: .zero, size: size))
            var y: CGFloat = 8
            for (view, item) in rows {
                view.frame = NSRect(x: 8, y: y, width: size.width - 16, height: item.height)
                box.addSubview(view)
                view.configure(item)
                if hovered, view is SidebarDraftRowView || view is SidebarSearchResultRowView {
                    var s = view.state; s.hovered = true; view.previewState(s)
                }
                view.layoutSubtreeIfNeeded()
                y += item.height + 1
            }
            return box
        }
        switch n["kind"] {
        case "result":
            let match = n["source"].map { ThreadSearchMatch(threadId: ThreadId("t"), projectId: ProjectId("p"), source: $0, snippet: n["snippet"]!) }
            let model = SidebarSearchResultModel(id: ThreadId("t"), index: 0, title: n["title"]!, projectTitle: "demo-repo",
                                                 timeLabel: n["time"]!, match: match, query: n["query"] ?? "",
                                                 isHighlighted: flag("highlighted"), isActive: false)
            return place([(SidebarSearchResultRowView(), .searchResult(model))])
        case "draft":
            let model = SidebarDraftRowModel(id: "d", projectLabel: n["project"], projectTitle: n["project"], preview: n["preview"]!,
                                             isActive: flag("active"))
            var rows: [(SidebarRowBase, SidebarItem)] = [(SidebarDraftRowView(), .draft(model))]
            if flag("divider") { rows.append((SidebarDividerRowView(), .draftDivider)) }
            return place(rows)
        case "status":
            return place([(SidebarEmptyTextRowView(), .emptyText(n["text"]!, search: flag("search")))])
        default:
            let snap = SidebarPreview.snapshot(projects: [SidebarPreview.project("p1", "demo-repo"), SidebarPreview.project("p2", "candywrapper")],
                                               threads: [SidebarPreview.thread("a", "A", project: "p1", kind: .read, minutesAgo: 1),
                                                         SidebarPreview.thread("b", "B", project: "p2", kind: .read, minutesAgo: 9)])
            let view = SidebarProjectScopeView(groups: SidebarListBuilder.projectScopeGroups(snapshot: snap), selectedKey: nil, minimumWidth: size.width)
            if let q = n["query"], !q.isEmpty { view.search.text = q; view.setQuery(q) }
            view.highlighted = n["highlighted"].flatMap(Int.init)
            let popup = PickerPopupView(view)
            popup.frame = NSRect(origin: .zero, size: popup.popupSize)
            popup.layoutSubtreeIfNeeded()
            return popup
        }
    }

    @Test func sidebarSearch() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-search")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-search.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for state in spec["states"] as! [String] {
                // Hover only reaches the cases with a state target; the rest repeat their rest state.
                if state == "hover", c["stateTarget"] == nil { continue }
                for theme in spec["themes"] as! [String] {
                    let base = "\(name).\(state).\(theme)"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                    let canvas = Canvas(frame: .zero)
                    let view = Self.make(native, hovered: state == "hover", size: size)
                    view.frame.origin = NSPoint(x: 8, y: 8)
                    canvas.addSubview(view)
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                    try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                    lines.append((base, total))
                    images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                        + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='sidebar-search/\(base).\($0).png'>" }.joined() + "</p>"
                }
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("sidebar-search", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("sidebarSearch", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY sidebar-search: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Sidebar search</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-sidebar-search.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.06)
    }
}
