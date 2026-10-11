import AppKit
import Testing
import DesignSystem
@testable import Features

/// Settings > Appearance's Themes heading and cards, and the theme editor, against T3's markup in Chromium (spec
/// from scripts/gen-theme-settings-spec.py, references in design/component-reference/theme-settings). Writes ref,
/// ours and diff PNGs plus report-theme-settings.html to /tmp/candywrapper-fidelity.
@MainActor
struct ThemeSettingsFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/theme-settings")

    static func make(_ kind: String, size: NSSize) -> NSView {
        switch kind {
        case "header":
            let h = SettingsSubheadingView("Themes")
            h.minHeight = 24
            h.topPadding = 8
            h.trailing = ThemeHeaderButtonsView()
            h.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: h.height(forWidth: size.width)))
            h.layoutSubtreeIfNeeded()
            return h
        case "cards":
            let none = ThemeLibraryCardView.Actions(use: {}, useMode: { _ in }, duplicate: {})
            let grid = ThemeCardGridView()
            grid.cards = [ThemeLibraryCardView(card: .standard, picked: [.light, .dark], actions: none)]
                + ThemeDefinition.builtIns.prefix(2).map { ThemeLibraryCardView(card: ThemeCardDefinition($0), picked: [], actions: none) }
            grid.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: grid.height(forWidth: size.width)))
            grid.layoutSubtreeIfNeeded()
            return grid
        default:
            let c = ThemeEditorController(library: ThemeLibrary(defaults: UserDefaults(suiteName: "candy.theme-fidelity")!))
            c.name = "Aurora"
            c.active = .dark
            c.colors = [.dark: [.canvas: "#0a0a0a", .accent: "#346bf1"], .light: [:]]
            let panel = ThemeEditorPanelView(controller: c)
            panel.placesInHost = false
            panel.frame = NSRect(origin: .zero, size: size)
            panel.update(structure: true)
            panel.layoutSubtreeIfNeeded()
            return panel
        }
    }

    @Test func themeSettings() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/theme-settings")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/theme-settings.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let view = Self.make(native["kind"]!, size: size)
                canvas.addSubview(view)
                // The editor places itself in its host when added; the reference shows it in a static box.
                view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: native["kind"] == "editor" ? size : view.frame.size)
                view.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='theme-settings/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("theme-settings", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY theme-settings: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Theme settings</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-theme-settings.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
