import AppKit
import Testing
import DesignSystem
@testable import Features

/// The composer footer's narrow states and the "..." overflow menu against T3's markup in Chromium
/// (spec from scripts/gen-composer-footer-spec.py, references in design/component-reference/composer-footer).
/// The cluster cases start at the model trigger, which carries the effort as its suffix at 4928. Writes ref, ours and diff PNGs plus
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
        v.hidesPermissions = false // Exercise the non-default permissions chip, including its overflow.
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
                    // 4928 has one resting block, the permissions chip (ComposerControlsBar.tsx:168-183), so the spec's
                    // 3824 fit names map to it: one icon-only step, then the overflow trigger.
                    let hidden = min(1, Int(native["hidden"]!)!), iconOnly = min(1, Int(native["iconOnly"]!)!)
                    if native["bars"] == "true" {
                        p.modelButton.adornment = ComposerModelSuffixView(ComposerModelSuffix(p.current.descriptors, ultrathink: false, bars: true))
                    }
                    let v = Self.fitted(p, iconOnly: iconOnly, hidden: hidden)
                    #expect(v.fit == ComposerFooterLayout.Fit(hiddenCount: hidden, iconOnlyCount: iconOnly))
                    if let width = native["modelWidth"].flatMap(Double.init) {
                        // A narrower host shrinks the model trigger once the chip is in the overflow menu.
                        v.frame.size.width -= v.model.frame.width - CGFloat(width)
                        v.layoutSubtreeIfNeeded()
                    }
                    // The reference starts at the model trigger (ComposerControlsBar.tsx:186-247).
                    v.frame.origin = NSPoint(x: 8 - v.model.frame.minX, y: 8)
                    canvas.addSubview(v)
                } else if native["kind"] == "files" {
                    let list = ComposerFileListView(frame: NSRect(x: 8, y: 8, width: 360, height: 104))
                    list.rows = [ComposerFileRow(id: "1", name: "notes.txt", sizeBytes: 3 * 1024 - 100, status: .ready),
                                 ComposerFileRow(id: "2", name: "screenshot-2026-10-10-with-a-long-name.png", sizeBytes: 900_000, status: .uploading(0.457)),
                                 ComposerFileRow(id: "3", name: "report.pdf", sizeBytes: 1_468_006, status: .failed("Upload failed"))]
                    list.hidesIconsForTests = true
                    canvas.addSubview(list)
                } else {
                    let popup = PickerPopupView(p.optionsMenu(includingTraits: native["traits"] == "true"))
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

    /// 4928 composerFooterLayout.ts:76-115 with one resting block, the permissions chip (ComposerControlsBar.tsx:168-183).
    /// The overflow trigger is 2px wider than the icon-only chip (`px-2` against `ps-1.5`), so below the icon-only
    /// width the chip moves straight into the overflow menu and the model trigger shrinks to make room.
    @Test func overflowSkipsPermissionsOnlyState() throws {
        for dark in [false, true] {
            let p = try PickersFidelityTests.pickers()
            let v = p.controlsView
            v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            v.hidesPermissions = false
            let m = v.measurement
            #expect(m.blockWidths.count == 1)
            let iconOnly = ComposerFooterLayout.width(m, hidden: 0, fixed: m.naturalFixedWidth, iconOnly: 1)
            let overflow = ComposerFooterLayout.width(m, hidden: 1, fixed: m.naturalFixedWidth, iconOnly: 1)
            #expect(overflow == iconOnly + 2)
            v.frame = NSRect(x: 0, y: 0, width: iconOnly - 0.5, height: 28)
            v.layoutSubtreeIfNeeded()
            #expect(v.fit == ComposerFooterLayout.Fit(hiddenCount: 1, iconOnlyCount: 1))
            #expect(v.model.frame.width < v.model.naturalWidth)
            print("composer-overflow", dark ? "dark" : "light", "icon-only", iconOnly, "overflow", overflow, "host", v.frame.width)
        }
    }

    /// 3824 closes the grouped menu after either a permission or effort pick.
    @Test func overflowMenuBehaviour() throws {
        let p = try PickersFidelityTests.pickers()
        var closed = false
        let permissions = p.optionsMenu(includingTraits: false)
        permissions.onClose = { closed = true }
        permissions.permissions.onPick?(.approvalRequired)
        #expect(closed && p.current.runtimeMode == .approvalRequired)
        closed = false
        let combined = p.optionsMenu(includingTraits: true)
        combined.onClose = { closed = true }
        let traits = try #require(combined.traits)
        #expect(traits.selectableIndices.count == 6)
        traits.highlightedIndex = traits.selectableIndices[2]
        #expect(combined.handleKey(.enter))
        #expect(closed && p.traitsButton.title == "High")
    }
}
