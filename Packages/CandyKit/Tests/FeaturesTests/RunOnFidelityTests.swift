import AppKit
import Testing
import DesignSystem
@testable import Features

/// The draft composer's "Run on" control, its list and the context strip against T3's markup in Chromium
/// (spec from scripts/gen-run-on-spec.py, references in design/component-reference/run-on). Writes ref,
/// ours and diff PNGs plus report-run-on.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct RunOnFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "runOn": .init(0.055, except: [
            "strip.remote.hover.light": 0.15,
            "strip.remote.rest.light": 0.15,
        ]),
    ]
    static let out = Fidelity.root.appendingPathComponent("run-on")
    static let options = [RunOnOption(environmentId: "local", label: "This Mac", machine: "mac-mini"),
                          RunOnOption(environmentId: "env2", label: "sandbox-env2", machine: "server")]

    static func control(selected: String, locked: Bool = false) -> RunOnControl {
        let c = RunOnControl()
        c.options = options
        c.selectedId = selected
        c.locked = locked
        return c
    }

    @Test func runOn() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/run-on")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/run-on.json"))) as! [String: Any]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            for state in spec["states"] as! [String] {
                for theme in spec["themes"] as! [String] {
                    let base = "\(name).\(state).\(theme)"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                    let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                    let selected = native["selected"]!
                    switch native["kind"] {
                    case "trigger", "locked":
                        let v = Self.control(selected: selected, locked: native["kind"] == "locked")
                        v.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: v.intrinsicContentSize)
                        if state == "hover" { var s = v.state; s.hovered = true; v.previewState(s) }
                        canvas.addSubview(v)
                    case "popup":
                        let list = MenuPopupView(items: Self.control(selected: selected).listItems(), style: .select)
                        list.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: list.popupSize)
                        canvas.addSubview(list)
                    default:
                        // An empty 600x64 composer with the strip under it.
                        let composer = ComposerView(frame: NSRect(x: 8, y: 8, width: 600, height: 64))
                        composer.joinsContextStrip = true
                        composer.layoutSubtreeIfNeeded()
                        for v in [composer.placeholder, composer.attach, composer.primary] as [NSView] { v.alphaValue = 0 }
                        let strip = ComposerContextStripView(frame: NSRect(x: 8 + 22, y: 8 + 64 - 16, width: 556, height: ComposerContextStripView.height))
                        strip.runOn.options = Self.options
                        strip.runOn.selectedId = selected
                        canvas.addSubview(strip)
                        canvas.addSubview(composer)
                    }
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                    try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                    lines.append((base, total))
                    images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                        + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='run-on/\(base).\($0).png'>" }.joined() + "</p>"
                }
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("run-on", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("runOn", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY run-on: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Run on</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-run-on.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }

    /// One machine, or a locked draft: a static label with no list. A pick reports the new environment once.
    @Test func behaviour() {
        let c = Self.control(selected: "local")
        #expect(c.interactive)
        // 70bdbc30b2: the tooltip names the label and the `composer.host` chord.
        c.shortcutCommand = "composer.host"
        #expect(c.tooltipString == "This Mac · " + (ActiveKeymap.label(for: "composer.host") ?? ""))
        var picked: [String] = []
        c.onChange = { picked.append($0) }
        let items = c.listItems()
        #expect(items.count == 3 && items[0].title == "Run on")
        items[1].action?() // the current machine: no change
        items[2].action?()
        #expect(picked == ["env2"])
        c.options = [Self.options[0]]
        #expect(!c.interactive)
        c.options = Self.options
        c.locked = true
        #expect(!c.interactive && c.intrinsicContentSize.width < Self.control(selected: "local").intrinsicContentSize.width)
        // The hero's project name truncates at 256 (`max-w-64`), short names stay whole.
        #expect(DraftHeroView.truncated("demo-repo", kern: -0.75) == "demo-repo")
        #expect(DraftHeroView.truncated("candywrapper-sandbox/demo-repo", kern: -0.75).hasSuffix("…"))
    }
}
