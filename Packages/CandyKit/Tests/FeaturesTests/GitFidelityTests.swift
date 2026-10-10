import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The branch toolbar under the draft composer, the thread details card, the git actions menu and the commit
/// dialog against T3's markup in Chromium (spec from scripts/gen-git-spec.py, references in
/// design/component-reference/git). Writes ref, ours and diff PNGs plus report-git.html to /tmp/candywrapper-fidelity.
@MainActor
struct GitFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/git")

    static func icon(_ name: String) -> IconDefinition { IconName(rawValue: name)!.definition }

    /// The view for a case, placed at the reference's 8pt padding.
    static func view(_ n: [String: String], size: CGSize) -> [NSView] {
        let origin = NSPoint(x: 8, y: 8)
        switch n["kind"] {
        case "strip":
            let composer = ComposerView(frame: NSRect(x: 8, y: 8, width: 600, height: 64))
            composer.joinsContextStrip = true
            composer.layoutSubtreeIfNeeded()
            for v in [composer.placeholder, composer.attach, composer.primary] as [NSView] { v.alphaValue = 0 }
            let strip = ComposerContextStripView(frame: NSRect(x: 8 + 22, y: 8 + 64 - 16, width: 556, height: ComposerContextStripView.height))
            strip.showsGitControls = true
            strip.runContext.glyphs = [icon(n["folder"]!)]
            strip.runContext.text = n["workspace"]!
            strip.branch.text = n["branch"]!
            strip.layoutSubtreeIfNeeded()
            return [strip, composer]
        case "card":
            let card = ThreadDetailsCardView(frame: NSRect(origin: origin, size: size))
            card.runContext.icons = [EnvironmentMachineIcon.definition("mac-mini"), IconName.folder.definition]
            card.runContext.text = n["env"]!
            card.branch.text = n["branch"]!
            card.gitActions.primary.icon = icon(n["icon"]!)
            card.gitActions.primary.text = n["quick"]!
            card.totals.insertions = Int(n["plus"]!)!
            card.totals.deletions = Int(n["minus"]!)!
            card.layoutSubtreeIfNeeded()
            return [card]
        case "menu":
            var commit = MenuItem("Commit", icon: .gitCommitHorizontal)
            var second = MenuItem("Publish repository...", icon: .cloudUpload)
            if n["variant"] == "remote" {
                commit.isDisabled = true
                second = MenuItem("Push", icon: .cloudUpload)
            }
            let menu = MenuPopupView(items: [commit, second])
            menu.minimumWidth = 248
            menu.frame = NSRect(origin: origin, size: menu.popupSize)
            return [menu]
        default:
            let files = [VcsStatus.File(path: "Sources/App/main.swift", insertions: 4, deletions: 0),
                         VcsStatus.File(path: "README.md", insertions: 12, deletions: 3)]
            let d = CommitDialog(branch: n["branch"], isDefaultRef: n["default"] == "true", files: files, canChangeBranch: true, canWrite: true)
            d.dialog.frame = NSRect(x: 8, y: 8, width: 512, height: 0)
            d.dialog.frame.size.height = d.dialog.height(forWidth: 512)
            d.dialog.layoutSubtreeIfNeeded()
            return [d.dialog]
        }
    }

    @Test func git() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/git")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/git.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                for v in Self.view(native, size: CGSize(width: css["width"]!, height: css["height"]!)) { canvas.addSubview(v) }
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='git/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("git", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY git: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Git</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-git.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }

    /// The commit dialog's selection drives its buttons; the card swaps git rows for Initialize Git outside a repo.
    @Test func behaviour() {
        let d = CommitDialog(branch: "main", isDefaultRef: false, files: [.init(path: "a", insertions: 1, deletions: 0)], canChangeBranch: false, canWrite: true)
        #expect(d.commit.isEnabled && !d.commitOnNewBranch.isEnabled)
        d.summary.list.onToggle?("a")
        #expect(!d.commit.isEnabled && d.selection.noneSelected)
        let card = ThreadDetailsCardView()
        #expect(card.initGit.isHidden)
        card.isRepo = false
        #expect(!card.initGit.isHidden && card.branch.isHidden && card.gitActions.isHidden)
        #expect(abs(card.preferredHeight - 103) < 0.01) // 2 + 8 + 32 + 10, then 1 + 8 + 10 + 32
    }
}
