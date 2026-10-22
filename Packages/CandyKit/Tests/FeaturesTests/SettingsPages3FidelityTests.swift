import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// WP7.14: Bitbucket credentials, a provider's Environment section and the provider version popover against T3's
/// markup in Chromium (spec from scripts/gen-settings-pages3-spec.py, references in design/component-reference/settings-pages3).
/// Writes ref, ours and diff PNGs plus report-settings-pages3.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct SettingsPages3FidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "settingsPages3": .init(0.11),
    ]
    static let out = Fidelity.root.appendingPathComponent("settings-pages3")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        let sized = SettingsPages2FidelityTests.sized
        switch n["kind"] {
        case "bitbucket-access", "bitbucket-api":
            let v = BitbucketCredentialsView(context: SettingsPages2FidelityTests.environmentContext(), environmentId: "a", onSaved: {})
            if n["kind"] == "bitbucket-api" { v.methodChoice = .apiToken }
            return sized(v, size)
        case "environment":
            let rows = [ProviderEnvironmentLogic.Draft(id: 1, .init(name: "OPENAI_BASE_URL", value: "http://localhost:8080", sensitive: false)),
                        ProviderEnvironmentLogic.Draft(id: 2, .init(name: "WP714_FAKE", value: "fakevalue", sensitive: true))]
            let list = ProviderEnvironmentVariablesView(rows: rows, enabled: true)
            let add = ButtonView("Add variable", icon: .plus, variant: .outline, size: .sm)
            add.iconSize = 12
            add.frame.size = add.intrinsicContentSize
            let row = SettingsRowView(title: "Variables", detail: "API keys, base URLs, and other per-instance CLI settings.", control: SettingsControlGroup([add]))
            row.footer = list
            return sized(SettingsSectionView(title: "Environment", rows: [row]), size)
        case "load-balancing":
            let v = LoadBalancingSectionView()
            v.configure(.init(enabled: true, machines: [.init(id: "a", label: "miniko", machine: "mac-mini", subtitle: "This machine"),
                                                        .init(id: "b", label: "Studio", machine: "server", subtitle: "192.168.1.20:3773")],
                              weights: ["b": 100]))
            v.isOpen = true
            return sized(v, size)
        default:
            let p = ProviderVersionAdvisoryLogic.Presentation(title: "Update available", detail: "Install the update now or review provider settings.",
                                                              updateCommand: "claude update", strong: false, targetVersion: nil, warning: false)
            let body = ProviderVersionAdvisoryPopover(p, updating: false, progress: nil, problem: nil, run: {}, copy: { _ in })
            let view = PopoverView(content: body, width: .md)
            view.frame.size = view.intrinsicContentSize
            view.layoutSubtreeIfNeeded()
            return view
        }
    }

    @Test func settingsPages3() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-pages3")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/settings-pages3.json"))) as! [String: Any]
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
                let view = try Self.make(native, size: size)
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='settings-pages3/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("settings-pages3", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("settingsPages3", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY settings-pages3: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Settings pages 3</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-settings-pages3.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
