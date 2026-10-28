import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The composer against design/reference-3824: 03a (at rest over the markdown thread), 01 (running,
/// Stop), 04 and 04n (the new-thread page). Compared at 2x in the main panel's coordinates.
/// Writes ref, ours and diff PNGs plus report-composer.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct ComposerFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "composer": .init(0.115, except: ["03a-kitchen-sink-top.light": 0.14]),
    ]
    static let out = Fidelity.root.appendingPathComponent("composer")
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
        let savedEffort = ClientSettingsStore.shared.current["effortDisplay"]
        defer { ClientSettingsStore.shared.update(["effortDisplay": savedEffort]) }
        ClientSettingsStore.shared.update(["effortDisplay": .string(reference == "54-composer-effort-bars" ? "bars" : "label")])
        let panel = panel(width: width, dark: dark)
        let draft = reference.hasPrefix("04")
        let pickers = try Screen3824Fixtures.pickers(draft: draft)
        panel.composer.footerControls = [pickers.controlsView]
        if reference == "54-composer-effort-bars" {
            let glyph = try #require(pickers.traitsButton.icon as? ComposerEffortGlyphView)
            #expect(glyph.effort.count == 4 && glyph.effort.filled == 2 && pickers.traitsButton.title.isEmpty)
            #expect(!glyph.wantsUpdateLayer) // Its four bars come from draw(_:), not updateLayer().
        }
        switch reference {
        case "03a-kitchen-sink-top", "54-composer-effort-bars":
            let projection = try Screen3824Fixtures.markdown()
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
        case "01-running-turn":
            // Only the composer band is compared; scrolled to the end, nothing sits behind it.
            let projection = try Screen3824Fixtures.markdown()
            panel.setProjection(projection, projectTitle: "demo-repo", workspaceRoot: nil)
            panel.composer.runState = ComposerLogic.RunState(activeRunId: RunId("run"), running: true)
        default:
            panel.setDraft(projectTitle: "demo-repo")
            panel.composer.placeholderInput.disconnected = true
            Screen3824Fixtures.contextStrip(panel.contextStrip)
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
            ("54-composer-effort-bars", 844, 600, 780),
        ]
        var lines: [String] = [], diffs: [(String, Double)] = [], images = ""
        for (reference, width, top, bottom) in cases {
            for theme in ["light", "dark"] {
                let full = try #require(NSBitmapImageRep(data: Data(contentsOf: SidebarFidelityTests.repo.appendingPathComponent(
                    "design/reference-3824/\(reference).\(theme).png"))))
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
                diffs.append((base, total))
                images += "<p>\(line)<br>" + ["ref", "ours", "diff"].map { "<img style='zoom:.4' src='composer/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        Self.ceilings.check("composer", diffs)
        let html = "<!doctype html><meta charset=utf-8><title>Composer</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer.html"), atomically: true, encoding: .utf8)
    }
}
