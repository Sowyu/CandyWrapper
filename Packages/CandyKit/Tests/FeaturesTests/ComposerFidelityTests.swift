import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The composer against design/reference: 03a (at rest over the markdown thread), 01 (running,
/// Stop), 04 and 04n (the new-thread page). Compared at 2x in the main panel's coordinates.
/// The footer's model, traits and access pickers belong to another work package, so the test
/// fills the slots with stand-ins drawn like `ComposerControl` (icon, label, chevron).
/// Writes ref, ours and diff PNGs plus report-composer.html to /tmp/candywrapper-fidelity.
@MainActor
struct ComposerFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/composer")
    static let sidebar = 256

    /// A `ComposerControl size="sm"` look-alike: 28 tall, px 10, gap 6, 14px medium label.
    final class StandIn: DSView {
        let icon: IconView, label: LabelView, chevron: IconView
        let showsLabel: Bool
        init(_ icon: IconName, _ text: String, label: Bool = true, brand: Bool = false) {
            self.icon = IconView(name: icon, size: 16, strokeColor: brand ? .labelColor : Themed.color(\.mutedForeground))
            self.label = LabelView(text, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.secondaryLabel))
            self.label.lineHeight = 20
            chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.iconMuted))
            showsLabel = label
            super.init(frame: .zero)
            [self.icon, self.label, chevron].forEach(addSubview)
            self.label.isHidden = !label
        }
        override var intrinsicContentSize: NSSize {
            let text: CGFloat = showsLabel ? ceil(label.textWidth) + 6 : 0
            return NSSize(width: 42 + text + 10, height: 28)
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 10, y: 6, width: 16, height: 16)
            var x: CGFloat = 32
            if showsLabel { label.frame = NSRect(x: x, y: 4, width: ceil(label.textWidth), height: 20); x += ceil(label.textWidth) + 6 }
            chevron.frame = NSRect(x: x - 2, y: 7, width: 14, height: 14)
        }
    }

    static func fill(_ composer: ComposerView, model: String, accessLabel: Bool = true) {
        composer.footerControls = [StandIn(.brandClaudeAI, model, brand: true), StandIn(.brain, "Medium"),
                                   StandIn(.lockOpen, "Full access", label: accessLabel)]
    }

    static func panel(width: CGFloat, dark: Bool) -> ThreadPanelView {
        let panel = ThreadPanelView(frame: NSRect(x: 0, y: 0, width: width, height: 780))
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return panel
    }

    static func render(_ reference: String, dark: Bool, width: CGFloat) throws -> NSBitmapImageRep {
        let panel = panel(width: width, dark: dark)
        switch reference {
        case "03a-kitchen-sink-top":
            let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            fill(panel.composer, model: "Claude Haiku 5.5")
        case "01-running-turn":
            // Only the composer band is compared; scrolled to the end, nothing sits behind it.
            let projection = try #require(try ThreadPreview.projection(titled: ThreadPreview.markdownThread))
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            fill(panel.composer, model: "Claude Haiku 5.5")
            panel.composer.runState = ComposerLogic.RunState(activeRunId: RunId("run"), running: true)
        default:
            panel.setDraft(projectTitle: "demo-repo")
            panel.composer.placeholderInput.disconnected = true
            fill(panel.composer, model: "Claude Fable 5.1", accessLabel: width > 600)
        }
        panel.layoutSubtreeIfNeeded()
        panel.timeline.scroll(toFraction: reference == "01-running-turn" ? 1 : 0)
        return Snapshot.image(of: ThreadFidelityTests.onSurface(panel), size: panel.frame.size, scale: 2, dark: dark)
    }

    @Test func composer() throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        // Reference, panel width, compared rows (pt).
        let cases: [(String, CGFloat, Int, Int)] = [
            ("03a-kitchen-sink-top", 844, 600, 780),
            ("01-running-turn", 844, 600, 780),
            ("04-new-thread-draft", 844, 0, 780),
            ("04n-new-thread-narrow", 592, 0, 780),
        ]
        var lines: [String] = [], images = ""
        for (reference, width, top, bottom) in cases {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference/\(reference).\(theme).png"))))
                let w = Int(width * 2)
                let crop = CGRect(x: full.pixelsWide - w, y: top * 2, width: w, height: (bottom - top) * 2)
                let ref = NSBitmapImageRep(cgImage: full.cgImage!.cropping(to: crop)!)
                let rendered = try Self.render(reference, dark: theme == "dark", width: width)
                let ours = NSBitmapImageRep(cgImage: rendered.cgImage!.cropping(to: CGRect(x: 0, y: top * 2, width: w, height: (bottom - top) * 2))!)
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [("all", 0, bottom - top)])
                let base = "\(reference).\(theme)"
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                let line = "\(base): \(String(format: "%.2f", total * 100))% differ"
                print("composer", line)
                lines.append(line)
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='composer/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        let html = "<!doctype html><meta charset=utf-8><title>Composer</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer.html"), atomically: true, encoding: .utf8)
    }
}
