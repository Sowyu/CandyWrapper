import AppKit
import Testing
import DesignSystem
@testable import Features

/// The composer footer's narrow states and the "..." overflow menu against T3's markup in Chromium
/// (spec from scripts/gen-composer-footer-spec.py, references in design/component-reference/composer-footer).
/// The cluster cases start at the traits separator. Writes ref, ours and diff PNGs plus
/// report-composer-footer.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct ComposerFooterFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "composerFooter": .init(0.06),
    ]
    static let out = Fidelity.root.appendingPathComponent("composer-footer")

    /// Lays the cluster out at the widest width that gives the wanted fit.
    static func fitted(_ p: ComposerPickers, iconOnly: Int, hidden: Int) -> PickerControlsView {
        let v = p.controlsView
        var w = v.intrinsicContentSize.width + 2
        repeat {
            v.frame = NSRect(x: 0, y: 0, width: w, height: 28)
            v.layoutSubtreeIfNeeded()
            w -= 0.5
        } while (v.fit.iconOnlyCount != iconOnly || v.fit.hiddenCount != hidden) && w > 0
        return v
    }

    @Test func composerFooter() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/composer-footer")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-footer.json"))) as! [String: Any]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let p = try PickersFidelityTests.pickers()
                if native["kind"] == "cluster" {
                    let iconOnly = Int(native["iconOnly"]!)!, hidden = Int(native["hidden"]!)!
                    let v = Self.fitted(p, iconOnly: iconOnly, hidden: hidden)
                    #expect(v.fit == ComposerFooterLayout.Fit(hiddenCount: hidden, iconOnlyCount: iconOnly))
                    // The reference starts at the first block's separator, one gap after the model.
                    let start = v.model.frame.maxX + 4
                    v.frame.origin = NSPoint(x: 8 - start, y: 8)
                    canvas.addSubview(v)
                } else if native["kind"] == "files" {
                    let list = ComposerFileListView(frame: NSRect(x: 8, y: 8, width: 360, height: 104))
                    list.rows = [ComposerFileRow(id: "1", name: "notes.txt", sizeBytes: 3 * 1024 - 100, status: .ready),
                                 ComposerFileRow(id: "2", name: "screenshot-2026-10-10-with-a-long-name.png", sizeBytes: 900_000, status: .uploading(0.457)),
                                 ComposerFileRow(id: "3", name: "report.pdf", sizeBytes: 1_468_006, status: .failed("Upload failed"))]
                    list.hidesIconsForTests = true
                    canvas.addSubview(list)
                } else {
                    _ = Self.fitted(p, iconOnly: 2, hidden: native["traits"] == "true" ? 2 : 1)
                    let popup = PickerPopupView(PickerMenuView(entries: p.overflowEntries(), style: .menu, minimumWidth: 158))
                    popup.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: popup.popupSize)
                    canvas.addSubview(popup)
                }
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='composer-footer/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("composer-footer", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("composerFooter", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY composer-footer: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Composer footer</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer-footer.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }

    /// Picking access in the overflow menu keeps it open and moves the check; a trait pick closes it.
    @Test func overflowMenuBehaviour() throws {
        let p = try PickersFidelityTests.pickers()
        _ = Self.fitted(p, iconOnly: 2, hidden: 1)
        #expect(p.controlsView.accessInOverflow && !p.controlsView.traitsInOverflow)
        #expect(p.accessButton.isHidden && !p.traitsButton.isHidden && !p.controlsView.overflow.isHidden && !p.traitsButton.showsLabel)
        var closed = false
        let menu = PickerMenuView(entries: p.overflowEntries(), style: .menu, minimumWidth: 158)
        menu.refreshEntries = { p.overflowEntries() }
        menu.onClose = { closed = true }
        #expect(menu.selectableIndices.count == 4)
        menu.pick(menu.selectableIndices[0])
        #expect(!closed && p.current.runtimeMode == .approvalRequired && menu.entry(menu.selectableIndices[0]).checked)
        _ = Self.fitted(p, iconOnly: 2, hidden: 2)
        let both = PickerMenuView(entries: p.overflowEntries(), style: .menu, minimumWidth: 158)
        both.onClose = { closed = true }
        #expect(both.selectableIndices.count == 10)
        both.pick(both.selectableIndices[2]) // High closes the menu
        #expect(closed && p.traitsButton.title == "High")
    }
}
