import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// WP7.9's sidebar states against T3's markup in Chromium (spec from scripts/gen-sidebar-leftovers-spec.py,
/// references in design/component-reference/sidebar-leftovers): the empty list's Add project, the rename
/// field, the provider update pill, the hover card and the drag ghost.
/// Writes ref, ours and diff PNGs plus report-sidebar-leftovers.html to /tmp/candywrapper-fidelity.
@MainActor
struct SidebarLeftoversFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/sidebar-leftovers")

    static func make(_ n: [String: String], state: String, size: NSSize) -> NSView {
        func inBox(_ view: NSView, height: CGFloat) -> NSView {
            let box = SidebarSearchFidelityTests.SidebarBox(frame: NSRect(origin: .zero, size: size))
            view.frame = NSRect(x: 8, y: 8, width: size.width - 16, height: height)
            box.addSubview(view)
            view.layoutSubtreeIfNeeded()
            return box
        }
        switch n["kind"] {
        case "no-projects":
            let row = SidebarNoProjectsRowView()
            row.configure(.noProjects)
            if state == "hover" { var s = row.button.state; s.hovered = true; row.button.previewState(s) }
            return inBox(row, height: SidebarItem.noProjects.height)
        case "rename":
            let field = SidebarRenameFieldView()
            field.begin(ThreadId("t"), title: "Create a file named approval-demo.txt")
            if state == "focus-visible" { field.input.previewState(FieldView.State(focused: true)) }
            let box = SidebarSearchFidelityTests.SidebarBox(frame: NSRect(origin: .zero, size: size))
            field.frame = NSRect(x: 8, y: 8, width: 204, height: 22)
            box.addSubview(field)
            field.layoutSubtreeIfNeeded()
            return box
        case "pill":
            let pill = SidebarProviderUpdatePillView()
            pill.show(SidebarProviderUpdatePillModel(key: "k", tone: n["tone"] == "error" ? .error : .warning, title: n["title"]!,
                                                     description: "", dismissible: true))
            return inBox(pill, height: 28)
        case "hover-card":
            var model = SidebarThreadHoverCardModel(title: "Ship the sidebar virtualization")
            model.projectLabel = "candywrapper"
            model.projectIcon = ProjectIconSource(title: "candywrapper", workspaceRoot: "/w/candywrapper")
            model.environmentLabel = "This device"
            model.branch = "m3-skeleton"
            model.terminalProcessCount = 2
            let card = SidebarThreadHoverCardView(model)
            card.frame = NSRect(origin: .zero, size: card.popupSize)
            card.layoutSubtreeIfNeeded()
            return card
        default:
            let count = Int(n["count"]!)!
            return SidebarThreadDragGhostView(title: count > 1 ? "Port the timestamp formatter" : "Ship the sidebar virtualization", count: count)
        }
    }

    @Test func sidebarLeftovers() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/sidebar-leftovers")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/sidebar-leftovers.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for state in spec["states"] as! [String] {
                // Each case keeps only the states its target reacts to (the rest repeat the rest state).
                let target = c["stateTarget"] as? String
                if state != "rest", target == nil || (state == "hover") != (target == "button") { continue }
                for theme in spec["themes"] as! [String] {
                    let base = "\(name).\(state).\(theme)"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                    let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                    let view = Self.make(native, state: state, size: size)
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
                        + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='sidebar-leftovers/\(base).\($0).png'>" }.joined() + "</p>"
                }
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("sidebar-leftovers", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY sidebar-leftovers: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Sidebar leftovers</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-sidebar-leftovers.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.06)
    }
}
