import AppKit
import Testing
import DesignSystem
@testable import Features

/// The small areas sweep's new states against design/component-reference/small-areas (scripts/gen-small-areas-spec.py).
@MainActor
struct SmallAreasFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/small-areas")

    static func make(_ native: [String: String], size: NSSize) -> NSView {
        switch native["kind"] {
        case "no-active-thread":
            let view = NoActiveThreadStateView(frame: NSRect(origin: .zero, size: size))
            view.layoutSubtreeIfNeeded()
            return view
        case "hover-card":
            var model = SidebarThreadHoverCardModel(title: "Fix the login redirect")
            model.projectLabel = "candywrapper"
            model.projectIcon = ProjectIconSource(title: "candywrapper", workspaceRoot: "/w/candywrapper")
            model.branch = "fix-login"
            model.branchMismatch = true
            let card = SidebarThreadHoverCardView(model)
            card.frame = NSRect(origin: .zero, size: card.popupSize)
            card.layoutSubtreeIfNeeded()
            return card
        case "slow-requests":
            let toast = ToastView(title: "Some requests are slow", message: "2 requests waiting longer than 15s.", kind: .warning)
            toast.details = (expand: "Show requests", collapse: "Hide requests",
                             items: [.init(title: "orchestration.getTurnDiff", detail: "Started 10:42:07 AM"),
                                     .init(title: "projects.searchEntries", detail: "Started 10:42:09 AM")])
            toast.toggleDetailsForTesting()
            toast.frame = NSRect(x: 0, y: 0, width: 360, height: toast.height(forWidth: 360))
            toast.layoutSubtreeIfNeeded()
            return toast
        default:
            let card = PublishChoiceCard(icon: SourceControlBrandGlyph.view(native["provider"]!, size: 20), title: native["label"]!,
                                         description: nil, selected: false, ready: true, hint: nil)
            card.frame = NSRect(origin: .zero, size: size)
            card.layoutSubtreeIfNeeded()
            return card
        }
    }

    @Test func smallAreas() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/small-areas")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/small-areas.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            for theme in ["light", "dark"] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view = Self.make(native, size: NSSize(width: css["width"]!, height: css["height"]!))
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
            }
        }
        for (base, total) in lines { print("small-areas", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY small-areas: %d cases, mean differing %.2f%%, worst %.2f%%", lines.count, mean * 100,
                     (lines.map(\.1).max() ?? 0) * 100))
        #expect(mean < 0.04)
    }
}
