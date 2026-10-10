import AppKit
import Testing
import DesignSystem
@testable import Features

/// The settings shell, Settings > Connections and the Add Environment dialog against T3's markup in
/// Chromium (spec from scripts/gen-connections-spec.py, references in design/component-reference/connections).
/// Writes ref, ours and diff PNGs plus report-connections.html to /tmp/candywrapper-fidelity.
@MainActor
struct ConnectionsFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/connections")

    final class Canvas: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    }

    final class SidebarBox: DSView {
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.sidebar, sidebar: true).cgColor(in: self) }
    }

    static func env(_ id: String, _ label: String, _ machine: String, _ subtitle: String, error: Bool = false, enabled: Bool = true,
                    routes: [ConnectionsPageModel.Route]? = nil) -> ConnectionsPageModel.Environment {
        let r = routes ?? [.init(url: URL(string: "http://127.0.0.1:47391/")!, label: "This device", address: "http://127.0.0.1:47391/", inUse: true)]
        return .init(id: id, label: label, machine: machine, enabled: enabled, subtitle: subtitle, statusIsError: error,
                     tooltip: "", routes: r)
    }

    static func make(_ n: [String: String], size: NSSize) -> NSView {
        switch n["kind"] {
        case "nav", "back":
            // The nav without its brand row: search, rows and the footer, as in the reference box.
            let nav = SettingsSidebarView()
            nav.stage = .none
            let box = SidebarBox(frame: NSRect(origin: .zero, size: size))
            nav.frame = NSRect(x: 0, y: n["kind"] == "nav" ? -52 : -(800 - 40), width: size.width, height: 800)
            box.clipsToBounds = true
            box.addSubview(nav)
            nav.layoutSubtreeIfNeeded()
            return box
        case "header":
            let header = SettingsHeaderView(frame: NSRect(x: 0, y: 0, width: size.width, height: 52))
            let box = DSView(frame: NSRect(origin: .zero, size: size))
            box.clipsToBounds = true
            box.addSubview(header)
            header.layoutSubtreeIfNeeded()
            return box
        case "dialog":
            let (dialog, form) = AddEnvironmentDialog.make(routeTarget: n["route"])
            form.error = n["error"]
            dialog.frame = NSRect(x: 0, y: 0, width: size.width, height: 10)
            dialog.layoutSubtreeIfNeeded()
            dialog.frame.size.height = dialog.height(forWidth: size.width)
            dialog.layoutSubtreeIfNeeded()
            return dialog
        default:
            let view = ConnectionsSettingsView()
            var model = ConnectionsPageModel(cloudEnabled: false)
            switch n["kind"] {
            case "this-machine":
                model.thisMachine = .init(label: "miniko", machine: "mac-mini",
                                          versionLine: "0.0.46-nightly.20261009.2861 · http://127.0.0.1:47391/", upToDate: true)
            case "rows":
                model.environments = [
                    env("a", "Sandbox", "mac-mini", "http://127.0.0.1:47391/ · Connected"),
                    env("b", "Studio", "server", "LAN · Reconnecting: The environment credential is invalid.", error: true),
                    env("c", "Old laptop", "laptop", "box.example.com · Off", enabled: false),
                ]
            case "routes":
                model.environments = [env("a", "Studio", "mac-mini", "via LAN · Connected", routes: [
                    .init(url: URL(string: "http://192.168.1.4:3773/")!, label: "LAN", address: "http://192.168.1.4:3773/", inUse: true),
                    .init(url: URL(string: "https://studio.tail1234.ts.net/")!, label: "Tailscale", address: "https://studio.tail1234.ts.net/", inUse: false),
                ])]
            default: break
            }
            view.set(model)
            if n["kind"] == "routes" { view.toggleRoutes("a") }
            if n["kind"] == "this-machine", let section = view.machineSection {
                // Only the machine section: the reference has no Environments section under it.
                section.frame = NSRect(x: 0, y: 0, width: size.width, height: section.height(forWidth: size.width))
                section.layoutSubtreeIfNeeded()
                return section
            }
            view.frame = NSRect(x: 0, y: 0, width: size.width, height: view.height(forWidth: size.width))
            view.layoutSubtreeIfNeeded()
            return view
        }
    }

    @Test func connections() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/connections")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/connections.json"))) as! [String: Any]
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
                let canvas = Canvas(frame: .zero)
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='connections/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("connections", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY connections: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Connections</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-connections.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
