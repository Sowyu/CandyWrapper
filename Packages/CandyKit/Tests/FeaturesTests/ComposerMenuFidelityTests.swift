import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The `/`, `@`, `$` and `#` menu and the editor's inline chips against T3's markup in Chromium
/// (spec from scripts/gen-composer-menu-spec.py, references in design/component-reference/composer-menu).
/// Writes ref, ours and diff PNGs plus report-composer-menu.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct ComposerMenuFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "composerMenu": .init(0.045, except: [
            "chips.rest.dark": 0.18,
            "chips.rest.light": 0.175,
        ]),
    ]
    static let out = Fidelity.root.appendingPathComponent("composer-menu")

    static func item(_ id: String, _ kind: ComposerMenuItem.Kind, _ label: String, _ description: String) -> ComposerMenuItem {
        ComposerMenuItem(id: id, kind: kind, label: label, description: description)
    }

    static func pr(_ n: Int, _ title: String, _ state: String) -> PullRequestReference {
        PullRequestReference(number: n, title: title, url: "", headBranch: "h", baseBranch: "main", state: state, isDraft: false)
    }

    static func menu(_ name: String) -> ComposerCommandMenuView {
        let menu = ComposerCommandMenuView()
        switch name {
        case "slash":
            menu.items = [
                item("m", .builtIn("model"), "/model", "Switch response model for this thread"),
                item("c", .providerCommand("compact"), "/compact", "Summarize the conversation to free context"),
                item("r", .providerCommand("review"), "/review", "Review the current changes"),
                item("s", .skill(name: "pdf-tools", sourceKind: .personal, viaSlash: true), "/skill:pdf-tools", "Read and fill PDF forms"),
            ]
        case "mention":
            menu.items = [
                item("t", .thread(id: "a", title: "Fix login"), "Fix login", "Thread"),
                item("f", .path(path: "src/server/api.ts", isDirectory: false), "api.ts", "src/server"),
                item("d", .path(path: "README.md", isDirectory: false), "README.md", ""),
                item("o", .path(path: "src/components", isDirectory: true), "components", "src"),
            ]
        case "skill":
            menu.items = [
                item("p", .skill(name: "pdf-tools", sourceKind: .personal, viaSlash: false), "Pdf Tools", "Read and fill PDF forms"),
                item("c", .skill(name: "commit", sourceKind: .repo, viaSlash: false), "Commit", "Write a commit message"),
            ]
        case "pull-request":
            menu.items = [
                item("42", .pullRequest(pr(42, "Fix the login redirect", "open")), "#42", "Fix the login redirect"),
                item("7", .pullRequest(pr(7, "Add the settings page", "merged")), "#7", "Add the settings page"),
            ]
        default:
            menu.emptyText = "No matching files or folders."
        }
        menu.activeItemId = menu.items.first?.id
        return menu
    }

    static func chips() -> NSView {
        let editor = ComposerEditor()
        editor.chipLook = { token in
            switch token.kind {
            case .context(_, let id, _) where id == "thread_a": ComposerChipLook(kind: .thread, label: "Fix login")
            case .context: ComposerChipLook(kind: .pullRequest(state: "open"), label: "#42")
            default: ComposerChipLook.look(for: token, skillLabel: { _ in "Pdf Tools" }, record: { _ in nil })
            }
        }
        editor.frame = NSRect(x: 8, y: 8, width: 560, height: ComposerEditor.lineHeight)
        editor.textContainerInset = NSSize(width: 0, height: editor.lineTop)
        let pr = ComposerContext.pullRequestReference(pr(42, "Fix", "open"))
        editor.setText("Use $pdf-tools on [api.ts](src/api.ts) and [Fix login](t3-context://v1/thread/thread_a) \(ComposerContext.reference(pr)) ")
        return editor
    }

    @Test func composerMenu() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/composer-menu")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-menu.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                if name == "chips" {
                    canvas.addSubview(Self.chips())
                } else {
                    let menu = Self.menu(name)
                    #expect(menu.preferredHeight == CGFloat(css["height"]!), "\(name) height")
                    menu.frame = NSRect(x: 8, y: 8, width: CGFloat(css["width"]!), height: menu.preferredHeight)
                    canvas.addSubview(menu)
                }
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='composer-menu/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("composer-menu", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("composerMenu", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY composer-menu: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Composer menu</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer-menu.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
