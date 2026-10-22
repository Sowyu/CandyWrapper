import AppKit
import Testing
@testable import Features
import DesignSystem

@MainActor @Suite(.fidelity)
struct SettingsSweepFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "settingsSweepStates": .init(0.075),
    ]
    @Test func settingsSweepStates() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-sweep")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let out = Fidelity.root.appendingPathComponent("settings-sweep")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var differences: [(String, Double)] = []
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        for name in manifest.keys.sorted() {
            for theme in ["light", "dark"] {
                var runtime = ThemeRuntimeInput(); runtime.blueOrangeDiff = name == "diff-blue-orange"
                ThemeRuntime.apply(runtime)
                let size = NSSize(width: manifest[name]!["width"]!, height: manifest[name]!["height"]!)
                let view: NSView
                if name == "invalid-project" {
                    view = SettingsRowView(title: "t3.json is invalid", detail: "A t3.json exists in this checkout but fails to parse, so every action and icon it declares is ignored. Check the JSON syntax and icon values.")
                } else if name == "motion-preview" {
                    view = SettingsPanelAnimationPreview(frame: .zero)
                } else {
                    view = SettingsSweepDiffSwatches(frame: .zero)
                }
                view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: size)
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero); canvas.addSubview(view)
                let base = "\(name).rest.\(theme)"
                let reference = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(base + ".png"))))
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(reference.pixelsWide) / 2, height: CGFloat(reference.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(reference, ours, bands: [])
                differences.append((base, difference))
                try Snapshot.writePNG(ours, to: out.appendingPathComponent(base + ".ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent(base + ".diff.png"))
                print(String(format: "settings-sweep %@ %.2f%%", base, difference * 100))
                #expect(difference < 0.09)
            }
        }
        print(String(format: "FIDELITY settings-sweep: %d cases, mean differing %.2f%%", differences.count, differences.map(\.1).reduce(0, +) / Double(differences.count) * 100))
        Self.ceilings.check("settingsSweepStates", differences)
    }
}

private final class SettingsSweepDiffSwatches: DSView {
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        Themed.color(\.diffAddition).setFill(); NSRect(x: 0, y: 0, width: 80, height: 32).fill()
        Themed.color(\.diffDeletion).setFill(); NSRect(x: 80, y: 0, width: 80, height: 32).fill()
    }
}
