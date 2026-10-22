import AppKit
import Testing
@testable import DesignSystem

/// Batch A fidelity: Input, Textarea, InputGroup, Label, Kbd, Badge, Separator, Skeleton, Spinner
/// against T3's markup in Chromium. Specs come from scripts/gen-forms-spec.py.
/// Reports: report-<component>.html under `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct FormsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "badge": .init(0.095),
        "input": .init(0.045, except: [
            "invalid.value.focus-visible.light": 0.055,
            "mono.value.disabled.dark": 0.06,
            "mono.value.disabled.light": 0.06,
            "mono.value.focus-visible.dark": 0.065,
            "mono.value.focus-visible.light": 0.065,
            "mono.value.rest.dark": 0.065,
            "mono.value.rest.light": 0.065,
        ]),
        "input-group": .init(0.035),
        "input-group-hover": .init(0.03),
        "kbd": .init(0.05),
        "label": .init(0.1),
        "separator": .init(0.02),
        "skeleton": .init(0.02),
        "spinner": .init(0.04),
        "textarea": .init(0.045),
    ]

    typealias Make = (_ native: [String: String], _ state: String, _ css: CGSize) -> NSView

    /// Runs one component spec. `make` builds our view in the given state; it is placed at 8,8 with
    /// its intrinsic size, or the reference's CSS size where it has no intrinsic metric.
    @discardableResult
    static func run(_ component: String, title: String, ceilings: FidelityCeilings = Self.ceilings, make: Make) throws -> Double {
        let repo = FidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/\(component)")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/\(component).json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = FidelityTests.out.appendingPathComponent(component)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var results: [FidelityTests.Result] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: String]
            let css = manifest[name].map { CGSize(width: $0["width"]!, height: $0["height"]!) } ?? .zero
            for state in spec["states"] as! [String] {
                for theme in spec["themes"] as! [String] {
                    let file = "\(name).\(state).\(theme).png"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                    let view = make(native, state, css)
                    var size = view.intrinsicContentSize
                    if size.width == NSView.noIntrinsicMetric { size.width = css.width }
                    if size.height == NSView.noIntrinsicMetric { size.height = css.height }
                    let canvas = FidelityTests.Canvas(frame: .zero)
                    canvas.addSubview(view)
                    view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: size)
                    let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                              scale: 2, dark: theme == "dark")
                    let (stats, diff) = FidelityTests.compare(ref, ours)
                    let base = "\(name).\(state).\(theme)"
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    results.append(.init(name: base, differing: stats.0, maxDiff: stats.1, meanDiff: stats.2,
                                         refSize: String(format: "%.2fx%.0f", css.width, css.height),
                                         oursSize: String(format: "%.2fx%.0f", size.width, size.height),
                                         files: ("\(component)/\(base).ref.png", "\(component)/\(base).ours.png", "\(component)/\(base).diff.png")))
                }
            }
        }
        results.sort { $0.differing > $1.differing }
        try FidelityTests.writeReport(results, title: title)
        for r in results.prefix(6) {
            print(r.name.padding(toLength: 44, withPad: " ", startingAt: 0),
                  String(format: "%5.2f  %4d  %5.2f", r.differing * 100, r.maxDiff, r.meanDiff), " ", r.refSize, r.oursSize)
        }
        let mean = results.map(\.differing).reduce(0, +) / Double(max(1, results.count))
        print(String(format: "FIDELITY %@: %d cases, mean differing %.2f%%", title, results.count, mean * 100))
        ceilings.check(component, results.map { ($0.name, $0.differing) })
        return mean
    }

    static func fieldState(_ name: String, invalid: Bool) -> FieldView.State {
        var s = FieldView.State()
        s.invalid = invalid
        switch name {
        case "focus-visible": s.focused = true
        case "disabled": s.enabled = false
        case "hover": s.hovered = true
        default: break
        }
        return s
    }

    @Test func input() throws {
        try Self.run("input", title: "Input") { n, state, _ in
            let v = InputView(placeholder: n["placeholder"] ?? "", text: n["value"] ?? "",
                              size: InputView.Size(rawValue: n["size"]!)!, font: n["font"] == "mono" ? .mono : .default)
            v.previewState(Self.fieldState(state, invalid: n["invalid"] == "true"))
            return v
        }
    }

    @Test func textarea() throws {
        try Self.run("textarea", title: "Textarea") { n, state, css in
            let v = TextareaView(placeholder: n["placeholder"] ?? "", text: n["value"] ?? "", size: TextareaView.Size(rawValue: n["size"]!)!)
            v.frame.size.width = css.width
            v.previewState(Self.fieldState(state, invalid: n["invalid"] == "true"))
            return v
        }
    }

    static func group(_ n: [String: String], _ state: String) -> NSView {
        let v = InputGroupView(placeholder: "Search", variant: InputGroupView.Variant(rawValue: n["variant"]!)!,
                               size: n["size"] == "lg" ? .lg : .default,
                               leading: n["start"].flatMap(IconName.init(rawValue:)).map { .icon($0) },
                               trailing: n["kbd"].map { .kbd($0) })
        v.previewState(Self.fieldState(state, invalid: false))
        return v
    }

    @Test func inputGroup() throws {
        try Self.run("input-group", title: "InputGroup") { n, state, _ in Self.group(n, state) }
        try Self.run("input-group-hover", title: "InputGroup hover") { n, state, _ in Self.group(n, state) }
    }

    @Test func label() throws {
        try Self.run("label", title: "Label") { n, _, _ in FormLabel.make(n["text"]!) }
    }

    @Test func kbd() throws {
        try Self.run("kbd", title: "Kbd") { n, _, _ in
            if let group = n["group"] { return KbdGroupView(keys: group.split(separator: ",").map(String.init)) }
            return KbdView(n["keys"] ?? "", icon: n["icon"].flatMap(IconName.init(rawValue:)))
        }
    }

    @Test func badge() throws {
        try Self.run("badge", title: "Badge") { n, _, _ in
            BadgeView(n["text"]!, variant: BadgeView.Variant(rawValue: n["variant"]!)!, size: BadgeView.Size(rawValue: n["size"]!)!)
        }
    }

    @Test func separator() throws {
        try Self.run("separator", title: "Separator") { n, _, css in
            let v = SeparatorView(n["orientation"] == "vertical" ? .vertical : .horizontal)
            v.frame.size = css
            return v
        }
    }

    @Test func skeleton() throws {
        try Self.run("skeleton", title: "Skeleton") { n, _, css in
            let v = SkeletonView(shape: SkeletonView.Shape(rawValue: n["shape"]!)!)
            v.frame.size = css
            return v
        }
    }

    @Test func spinner() throws {
        try Self.run("spinner", title: "Spinner") { n, _, _ in
            SpinnerView(size: SpinnerView.Size(rawValue: n["size"]!)!, tone: SpinnerView.Tone(rawValue: n["tone"]!)!)
        }
    }
}
