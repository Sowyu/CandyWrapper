import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Source control > Issue trackers (4928) against T3's markup in Chromium (spec from
/// scripts/gen-settings-issue-trackers-spec.py, references in design/component-reference/settings-issue-trackers).
@MainActor @Suite(.fidelity)
struct SettingsIssueTrackersFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "settingsIssueTrackers": .init(0.02),
    ]
    static let out = Fidelity.root.appendingPathComponent("settings-issue-trackers")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        let patch: [String: JSONValue] = n["kind"] == "connected" ? [:] : ["connected": .bool(false), "account": .null]
        let t = try IssueTrackerSettingsTests.connection(patch)
        let details = IssueTrackerDetailsView(tracker: t, bindings: [:], projects: [], canEdit: true, busy: false, failure: nil, openURL: nil,
                                              submit: { _ in }, bind: { _, _ in })
        let row = IssueTrackerRow(tracker: t, summary: IssueTrackerSettingsLogic.summary(t, bindings: [:]), details: details)
        return SettingsPages2FidelityTests.sized(SettingsSectionView(title: "Issue trackers", rows: [row]), size)
    }

    @Test func settingsIssueTrackers() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-issue-trackers")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/settings-issue-trackers.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='settings-issue-trackers/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("settings-issue-trackers", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("settingsIssueTrackers", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY settings-issue-trackers: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Settings issue trackers</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-settings-issue-trackers.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
