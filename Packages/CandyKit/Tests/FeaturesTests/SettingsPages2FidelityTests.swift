import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Project (overview, Actions), Source Control (Repositories, Version Control) and the Providers list
/// against T3's markup in Chromium (spec from scripts/gen-settings-pages2-spec.py, references in
/// design/component-reference/settings-pages2). Writes ref, ours and diff PNGs plus report-settings-pages2.html
/// to /tmp/candywrapper-fidelity.
@MainActor
struct SettingsPages2FidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/settings-pages2")

    static func json(_ text: String) -> JSONValue { try! JSONValue(parsing: Data(text.utf8)) }

    /// One environment with git-demo picked in the scope, its Lint action set up and bound to ⇧⌘L.
    static func context() -> SettingsPageContext {
        let c = SettingsPageContext()
        let settings = ServerSettingsValues(json(#"""
        {"projectSettingsFolded": true, "projectSettingsOverrides": {"p": {"defaultProjectScripts": [
          {"id": "lint", "name": "Lint", "command": "bun run lint", "icon": "lint", "runOnWorktreeCreate": true}]}}}
        """#))
        let env = SettingsScopeEnvironment(id: "a", label: "host", settings: settings, capabilities: ["projectSettingsOverrides"])
        let member = SettingsScopeProject.Member(environmentId: "a", projectId: "p", title: "git-demo", workspaceRoot: "/repo")
        c.scope = SettingsScopeState(selection: SettingsScopeSelection(project: "repo"), environments: [env], primaryId: "a",
                                     projects: [SettingsScopeProject(key: "repo", displayName: "git-demo", members: [member])])
        let rules = Keymap.decodeRules(json(#"[{"command": "script.lint.run", "shortcut": {"key": "l", "modKey": true, "metaKey": false, "ctrlKey": false, "altKey": false, "shiftKey": true}}]"#))
        c.configs = ["a": ServerProviderConfig(providers: [], keybindings: rules)]
        return c
    }

    static func environmentContext() -> SettingsPageContext {
        let c = SettingsPageContext()
        c.scope = SettingsScopeState(environments: [SettingsScopeEnvironment(id: "a", label: "host", settings: ServerSettingsValues(.object([:])))],
                                     primaryId: "a")
        return c
    }

    static func sized(_ v: NSView & SettingsGroupRow, _ size: NSSize) -> NSView {
        v.removeFromSuperview()
        v.frame = NSRect(x: 0, y: 0, width: size.width, height: v.height(forWidth: size.width))
        v.layoutSubtreeIfNeeded()
        return v
    }

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        switch n["kind"] {
        case "overview":
            let page = ProjectSettingsView(context: context())
            page.refresh()
            let group = try #require(page.anchor("project-overview") as? SettingsGroupView)
            // The favicon is left out of both sides (T3 draws ProjectFavicon from the project's files).
            if let row = group.rows.compactMap({ $0 as? SettingsRowView }).first(where: { $0.title == "Project icon" }),
               let controls = row.control as? SettingsControlGroup {
                controls.views[0].isHidden = true
                controls.invalidateIntrinsicContentSize()
                row.control = controls
            }
            return sized(group, size)
        case "actions":
            let page = ProjectSettingsView(context: context())
            page.refresh()
            return sized(try #require(page.anchor("project-actions") as? SettingsSectionView), size)
        case "repositories":
            let page = SourceControlSettingsView(context: environmentContext())
            return sized(try #require(page.anchor("source-control-defaults") as? SettingsSectionView), size)
        case "vcs":
            let result = json(#"""
            {"versionControlSystems": [
              {"kind": "git", "label": "Git", "executable": "git", "status": "available", "implemented": true, "installHint": "",
               "version": {"_tag": "Some", "value": "git version 2.54.0 (Apple Git-157)"}, "detail": {"_tag": "None"}},
              {"kind": "jj", "label": "Jujutsu", "executable": "jj", "status": "missing", "implemented": false, "installHint": "", "version": {"_tag": "None"}}],
             "sourceControlProviders": []}
            """#)
            let (vcs, _) = SourceControlDiscoveryItem.list(result)
            let section = SettingsSectionView(title: "Version Control", rows: [
                SourceControlDiscoveryRow(item: vcs[0], details: SettingsGroupNote("")), SourceControlDiscoveryRow(item: vcs[1], details: nil),
            ])
            let scan = ButtonView(nil, icon: .refreshCw, variant: .ghostMuted, size: .iconXs)
            scan.iconSize = 14
            section.headerAction = scan
            return sized(section, size)
        default:
            let providers = try json(#"""
            [{"instanceId": "codex", "driver": "codex", "enabled": true, "installed": false, "status": "error",
              "message": "Could not start Codex CLI (`codex`). Check Settings → Providers → Codex → Binary path on the server.", "models": []},
             {"instanceId": "claudeAgent", "driver": "claudeAgent", "enabled": true, "installed": true, "status": "ready", "version": "2.1.295",
              "auth": {"status": "authenticated", "label": "Claude Max Subscription"}, "models": []}]
            """#).decode(as: [ServerProvider].self)
            let rows = ProvidersLogic.rows(settings: ServerSettingsValues(.object([:])), providers: providers)
            let box = ListBox(frame: NSRect(origin: .zero, size: size))
            var y: CGFloat = 0
            for (i, row) in rows.enumerated() {
                let v = ProviderListRow(row: row, provider: providers[i])
                v.isSelected = row.instanceId == "claudeAgent"
                let h = v.height(forWidth: size.width)
                v.frame = NSRect(x: 0, y: y, width: size.width, height: h)
                box.addSubview(v)
                y += h
                box.dividers.append(y)
                y += 1
            }
            let add = ProvidersSectionView.SidebarStyleAddRow()
            add.frame = NSRect(x: 0, y: y, width: size.width, height: 44)
            box.addSubview(add)
            box.dividers.append(y + 44)
            box.layoutSubtreeIfNeeded()
            return box
        }
    }

    /// The list column: `bg-muted/10`, rows divided by `border/50`, the column's `border-b border/60`.
    final class ListBox: DSView {
        var dividers: [CGFloat] = []
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            Themed.color(\.muted, 0.1).setFill()
            bounds.fill()
            Themed.color(\.border, 0.5).setFill()
            for y in dividers.dropLast() { NSRect(x: 0, y: y, width: bounds.width, height: 1).fill() }
            Themed.color(\.border, 0.6).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    @Test func settingsPages2() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-pages2")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/settings-pages2.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='settings-pages2/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("settings-pages2", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY settings-pages2: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Settings pages 2</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-settings-pages2.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
