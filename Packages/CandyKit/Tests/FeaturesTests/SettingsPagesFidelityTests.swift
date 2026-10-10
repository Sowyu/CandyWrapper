import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The settings nav with search results, a General section and a Keybindings section against T3's markup in
/// Chromium (spec from scripts/gen-settings-spec.py, references in design/component-reference/settings-pages).
/// Writes ref, ours and diff PNGs plus report-settings-pages.html to /tmp/candywrapper-fidelity.
@MainActor
struct SettingsPagesFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/settings-pages")

    static func context() -> SettingsPageContext {
        let c = SettingsPageContext()
        c.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "host", settings: ServerSettingsValues(.object([:])),
                                                                            capabilities: ["threadAutoSettlement", "threadRestartContinuation"])],
                                     primaryId: "a")
        return c
    }

    static func make(_ n: [String: String], size: NSSize) -> NSView {
        switch n["kind"] {
        case "nav-search":
            let nav = SettingsSidebarView()
            nav.stage = .none
            nav.setQuery("time")
            let box = ConnectionsFidelityTests.SidebarBox(frame: NSRect(origin: .zero, size: size))
            nav.frame = NSRect(x: 0, y: -52, width: size.width, height: 800)
            box.clipsToBounds = true
            box.addSubview(nav)
            nav.layoutSubtreeIfNeeded()
            return box
        case "behavior":
            let page = GeneralSettingsView(context: context())
            let section = page.anchor("behavior") as! SettingsSectionView
            section.group.rows = Array(section.group.rows.prefix(5))
            section.removeFromSuperview()
            section.frame = NSRect(x: 0, y: 0, width: size.width, height: section.height(forWidth: size.width))
            section.layoutSubtreeIfNeeded()
            return section
        default:
            let page = KeybindingsSettingsView(context: context())
            let section = page.anchor("keybindings-navigation") as! SettingsSectionView
            let keep = ["commandPalette.toggle", "editor.openFavorite", "projectSearch.toggle"]
            section.group.rows = section.group.rows.filter { ($0 as? KeybindingRowView).map { keep.contains($0.row.command) } ?? false }
            section.removeFromSuperview()
            section.frame = NSRect(x: 0, y: 0, width: size.width, height: section.height(forWidth: size.width))
            section.layoutSubtreeIfNeeded()
            return section
        }
    }

    @Test func settingsPages() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-pages")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/settings-pages.json"))) as! [String: Any]
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
                let view = Self.make(native, size: size)
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='settings-pages/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("settings-pages", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY settings-pages: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Settings pages</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-settings-pages.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
