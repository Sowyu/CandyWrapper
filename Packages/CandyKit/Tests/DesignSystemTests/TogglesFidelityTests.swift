import AppKit
import Testing
@testable import DesignSystem

/// Batch B fidelity: Toggle, ToggleGroup, Switch, Checkbox, Radio, Alert, Empty and
/// CollapsibleSectionHeader against T3's markup in Chromium (specs from scripts/gen-toggles-spec.py).
/// Writes /tmp/candywrapper-fidelity/report-<component>.html. Collapsible has no styling of its own.
@MainActor
struct TogglesFidelityTests {
    typealias Native = [String: String]

    @Test func toggle() throws {
        try run("toggle") { n in
            ToggleView(n["title"].flatMap { $0.isEmpty ? nil : $0 }, icon: n["icon"].flatMap(IconName.init(rawValue:)),
                       variant: ToggleView.Variant(rawValue: n["variant"]!)!, size: ToggleView.Size(rawValue: n["size"]!)!,
                       pressed: n["pressed"] == "true")
        }
    }

    @Test func toggleGroup() throws {
        try run("toggle-group") { n in
            let segmented = n["variant"] == "segmented"
            let items = n["items"]!.split(separator: ",").map { (title: Optional(String($0)), icon: segmented ? nil : Optional(IconName.plus)) }
            return ToggleGroupView(variant: segmented ? .segmented : .default, items: items, selected: 0)
        }
    }

    @Test func switchControl() throws {
        try run("switch") { n in
            let s = SwitchView(isOn: n["value"] == "on" || n["value"] == "mixed", size: SwitchView.Size(rawValue: n["size"]!)!)
            s.isMixed = n["value"] == "mixed"
            return s
        }
    }

    @Test func checkbox() throws {
        try run("checkbox") { n in
            let c = CheckboxView(value: n["value"] == "on" ? .on : n["value"] == "mixed" ? .mixed : .off)
            c.isInvalid = n["invalid"] == "true"
            return c
        }
    }

    @Test func radio() throws {
        try run("radio") { n in
            let r = RadioView(checked: n["value"] == "on")
            r.isInvalid = n["invalid"] == "true"
            return r
        }
    }

    @Test func alert() throws {
        try run("alert") { n in
            let alert = AlertView(n["title"], message: n["description"], icon: n["icon"].flatMap(IconName.init(rawValue:)),
                                  variant: AlertView.Variant(rawValue: n["variant"]!)!)
            if n["controlAlignment"] == "firstLine" { alert.controlAlignment = .firstLine }
            return alert
        }
    }

    @Test func empty() throws {
        try run("empty") { n in
            EmptyView(title: n["title"]!, message: n["description"], icon: n["icon"].flatMap(IconName.init(rawValue:)),
                      size: EmptyView.Size(rawValue: n["size"]!)!)
        }
    }

    @Test func collapsibleSectionHeader() throws {
        try run("collapsible-section-header") { n in
            CollapsibleSectionHeaderView(n["title"]!, tone: .init(rawValue: n["tone"]!)!, expanded: n["expanded"] == "true")
        }
    }

    // MARK: Runner

    func run(_ component: String, make: (Native) -> NSView) throws {
        let repo = FidelityTests.repo, out = FidelityTests.out
        let refDir = repo.appendingPathComponent("design/component-reference/\(component)")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/\(component).json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = out.appendingPathComponent(component)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var results: [FidelityTests.Result] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! Native
            let disabledCase = native["disabled"] == "true"
            for state in spec["states"] as! [String] {
                // Cases that carry `data-disabled` in their markup are compared at rest only.
                if disabledCase && state != "rest" { continue }
                for theme in spec["themes"] as! [String] {
                    let file = "\(name).\(state).\(theme).png"
                    guard let ref = NSBitmapImageRep(data: try Data(contentsOf: refDir.appendingPathComponent(file))) else { continue }
                    let view = make(native)
                    var controlState = FidelityTests.controlState(state)
                    if disabledCase { controlState.enabled = false }
                    let css = manifest[name]!
                    let ours = Self.render(view, state: controlState, width: css["width"]!, pixels: (ref.pixelsWide, ref.pixelsHigh), dark: theme == "dark")
                    let (stats, diff) = FidelityTests.compare(ref, ours)
                    let base = "\(name).\(state).\(theme)"
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    results.append(.init(name: base, differing: stats.0, maxDiff: stats.1, meanDiff: stats.2,
                                         refSize: String(format: "%.2fx%.0f", css["width"]!, css["height"]!),
                                         oursSize: String(format: "%.2fx%.0f", view.frame.width, view.frame.height),
                                         files: ("\(component)/\(base).ref.png", "\(component)/\(base).ours.png", "\(component)/\(base).diff.png")))
                }
            }
        }
        results.sort { $0.differing > $1.differing }
        try FidelityTests.writeReport(results, title: component)
        for r in results.prefix(8) {
            print(r.name.padding(toLength: 44, withPad: " ", startingAt: 0),
                  String(format: "%5.2f  %4d  %5.2f", r.differing * 100, r.maxDiff, r.meanDiff), " ", r.refSize, r.oursSize)
        }
        let mean = results.map(\.differing).reduce(0, +) / Double(max(1, results.count))
        print(String(format: "FIDELITY %@: %d cases, mean differing %.2f%%", component, results.count, mean * 100))
        #expect(!results.isEmpty)
    }

    /// Like FidelityTests.render, for any view: intrinsic size, or the reference width when the
    /// view has no intrinsic width (Alert, Empty, section header).
    static func render(_ view: NSView, state: ControlView.State, width: Double, pixels: (Int, Int), dark: Bool) -> NSBitmapImageRep {
        let canvas = FidelityTests.Canvas(frame: .zero)
        canvas.addSubview(view)
        view.setFrameSize(NSSize(width: width, height: 0)) // wrapped text measures its height at the width
        var size = view.intrinsicContentSize
        if size.width == NSView.noIntrinsicMetric { size.width = width }
        view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: size)
        (view as? ControlView)?.previewState(state)
        return Snapshot.image(of: canvas, size: NSSize(width: CGFloat(pixels.0) / 2, height: CGFloat(pixels.1) / 2), scale: 2, dark: dark)
    }
}
