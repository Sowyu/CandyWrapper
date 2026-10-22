import AppKit
import Testing
@testable import DesignSystem

/// Popup family fidelity: Menu, Select (trigger and popup), Combobox and Autocomplete popups, Popover
/// and Tooltip against T3's markup rendered statically open in Chromium (scripts/gen-popups-spec.py).
/// Writes report-<component>.html.
@MainActor @Suite(.fidelity)
struct PopupsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "autocomplete-popup": .init(0.05),
        "combobox-popup": .init(0.05),
        "menu": .init(0.05),
        "popover": .init(0.065),
        "select-popup": .init(0.05),
        "select-trigger": .init(0.05),
        "tooltip": .init(0.07),
    ]

    typealias Native = [String: String]

    static func menuPreset(_ name: String) -> [MenuItem] {
        switch name {
        case "actions":
            return [MenuItem("New thread", icon: .squarePen, shortcut: "⌘N"), MenuItem("Copy path", icon: .copy, shortcut: "⇧⌘C"),
                    MenuItem("Rename", icon: .pencil), .separator, .submenu("Move to", icon: .folder, []),
                    MenuItem("Archive", icon: .archive, disabled: true), .separator, MenuItem("Delete", icon: .trash2, destructive: true)]
        default:
            return [.label("Appearance"), .radio("System", checked: true), .radio("Light", checked: false), .radio("Dark", checked: false),
                    .separator, .label("View"), .checkbox("Show sidebar", checked: true), .checkbox("Wrap lines", checked: false)]
        }
    }

    static let options = ["Claude Haiku", "Claude Sonnet", "Claude Opus", "GPT Astra"]

    static func list(_ style: MenuPopupView.Style, _ n: Native) -> MenuPopupView {
        let selected = Int(n["selected"]!)!
        let v = MenuPopupView(items: options.enumerated().map { MenuItem($1, kind: .radio($0 == selected)) }, style: style)
        v.minimumWidth = CGFloat(Double(n["anchor"]!)!)
        let h = Int(n["highlight"]!)!
        v.highlightedIndex = h >= 0 ? h : nil
        return v
    }

    @Test func menu() throws {
        try run("menu") { n in
            let v = MenuPopupView(items: Self.menuPreset(n["preset"]!))
            let h = Int(n["highlight"]!)!
            v.highlightedIndex = h >= 0 ? h : nil
            return v
        }
    }

    @Test func selectTrigger() throws {
        try run("select-trigger") { n in
            let value = n["value"]!
            let s = SelectView(options: Self.options, selected: value.isEmpty ? nil : 0, placeholder: "Choose a model",
                               variant: .init(rawValue: n["variant"]!)!, size: .init(rawValue: n["size"]!)!)
            s.isPopupOpen = n["open"] == "true"
            return s
        }
    }

    @Test func selectPopup() throws { try run("select-popup") { Self.list(.select, $0) } }
    @Test func comboboxPopup() throws { try run("combobox-popup") { Self.list(.combobox, $0) } }
    @Test func autocompletePopup() throws { try run("autocomplete-popup") { Self.list(.autocomplete, $0) } }

    @Test func popover() throws {
        try run("popover") { n in
            PopoverView(content: popoverTitle("Share thread"), padding: n["padding"] == "compact" ? .compact : .default,
                        width: n["width"] == "md" ? .md : .auto)
        }
    }

    @Test func tooltip() throws {
        try run("tooltip") { n in
            TooltipView(n["text"]!, variant: n["variant"] == "glass" ? .glass : n["variant"] == "code" ? .code : .default)
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
            for state in spec["states"] as! [String] {
                for theme in spec["themes"] as! [String] {
                    let file = "\(name).\(state).\(theme).png"
                    let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                    let view = make(c["native"] as! Native)
                    let css = manifest[name]!
                    let ours = TogglesFidelityTests.render(view, state: Self.state(state, of: view), width: css["width"]!,
                                                           pixels: (ref.pixelsWide, ref.pixelsHigh), dark: theme == "dark")
                    let (stats, diff) = FidelityTests.compare(ref, ours)
                    let base = "\(name).\(state).\(theme)"
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                    try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                    try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                    try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                    results.append(.init(name: base, differing: stats.0, maxDiff: stats.1, meanDiff: stats.2,
                                         refSize: String(format: "%.2fx%.2f", css["width"]!, css["height"]!),
                                         oursSize: String(format: "%.2fx%.2f", view.frame.width, view.frame.height),
                                         files: ("\(component)/\(base).ref.png", "\(component)/\(base).ours.png", "\(component)/\(base).diff.png")))
                }
            }
        }
        results.sort { $0.differing > $1.differing }
        try FidelityTests.writeReport(results, title: component)
        for r in results.prefix(6) {
            print(r.name.padding(toLength: 44, withPad: " ", startingAt: 0),
                  String(format: "%5.2f  %4d  %5.2f", r.differing * 100, r.maxDiff, r.meanDiff), " ", r.refSize, r.oursSize)
        }
        let mean = results.map(\.differing).reduce(0, +) / Double(max(1, results.count))
        print(String(format: "FIDELITY %@: %d cases, mean differing %.2f%%", component, results.count, mean * 100))
        Self.ceilings.check(component, results.map { ($0.name, $0.differing) })
    }

    /// Forced pseudo state, keeping `data-pressed` set by the case.
    static func state(_ name: String, of view: NSView) -> ControlView.State {
        var s = FidelityTests.controlState(name)
        if let c = view as? ControlView { s.popupOpen = c.state.popupOpen }
        return s
    }
}
