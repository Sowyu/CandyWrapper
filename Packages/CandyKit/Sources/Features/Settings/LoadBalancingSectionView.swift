import AppKit
import DesignSystem
import T3Protocol

/// Settings > Connections > Load balancing (LoadBalancingSettings.tsx): how often each switched-on machine should
/// receive new threads in shared projects. Stored per client (`loadBalancingEnabled`, `loadBalancingWeights`).
public enum LoadBalancingLogic {
    /// The four preferences, Prefer first (`preferences`).
    public static let preferences: [(weight: Int, label: String)] = [(100, "Prefer"), (50, "Normal"), (25, "Less often"), (0, "Manual only")]

    /// `loadPreferenceForWeight`: older builds stored a slider value; snap it onto the four preferences.
    public static func preference(forWeight weight: Int?) -> Int {
        guard let weight, weight != 50 else { return 50 }
        if weight == 0 { return 0 }
        return weight < 50 ? 25 : 100
    }

    static func label(_ preference: Int) -> String { preferences.first { $0.weight == preference }?.label ?? "Normal" }

    /// `summarizeLoadPreferences`: the machines not at Normal, in list order, or nil when all are.
    public static func summary(_ machines: [(id: String, label: String)], weights: [String: Int]) -> String? {
        let parts = machines.compactMap { m -> String? in
            let p = preference(forWeight: weights[m.id])
            return p == 50 ? nil : "\(m.label) \(label(p).lowercased())"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The stored weights; entries that are not whole numbers in 0...100 drop, like `LoadBalancingWeights`.
    public static func weights(_ json: JSONValue) -> [String: Int] {
        (json.objectValue ?? [:]).compactMapValues { v in v.intValue.flatMap { (0...100).contains($0) ? $0 : nil } }
    }
}

extension ConnectionsPageModel {
    /// The Load balancing section: shown when two or more machines are switched on (this machine leads).
    public struct LoadBalancing: Equatable {
        public struct Machine: Equatable {
            public var id, label, machine, subtitle: String
            public init(id: String, label: String, machine: String, subtitle: String) {
                self.id = id; self.label = label; self.machine = machine; self.subtitle = subtitle
            }
        }
        public var enabled: Bool
        public var machines: [Machine]
        public var weights: [String: Int]
        public init(enabled: Bool, machines: [Machine], weights: [String: Int]) {
            self.enabled = enabled; self.machines = machines; self.weights = weights
        }
        /// The closed header's summary: `Off`, the machines not at Normal, or nothing.
        public var summary: String? {
            enabled ? LoadBalancingLogic.summary(machines.map { ($0.id, $0.label) }, weights: weights) : "Off"
        }
    }
}

/// `FoldedSettingsSection` with the section switch: the header (chevron, title, summary, switch), then the note and one
/// `EnvironmentRow` per machine with its preference select (`xs`, `w-32`).
final class LoadBalancingSectionView: BoxView, SettingsGroupRow {
    private let header = AuthorizedClientsSectionView.FoldHeader()
    private let toggle = SwitchView()
    private let rule = CALayer()
    private let note = TextBlockView("New threads in shared projects start on the machine with the most free CPU and memory, weighted by each machine's preference.",
                                     font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private var rows: [MachineRow] = []
    private var dividers: [CALayer] = []
    var isOpen = false { didSet { header.isOpen = isOpen; applyOpen(); onHeightChange?() } }
    var onHeightChange: (() -> Void)?
    var onEnabled: ((Bool) -> Void)?
    var onPreference: ((String, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var box = BoxStyle()
        box.radius = 14
        box.border = Themed.color(\.contrastBorder, 0.6)
        box.fill = Themed.color(\.card, 0.4)
        box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        boxStyle = box
        header.heading = "Load balancing"
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(rule)
        toggle.setAccessibilityLabel("Automatically balance load")
        toggle.onChange = { [weak self] on in self?.onEnabled?(on) }
        // `FoldedSettingsSection`'s `CollapsiblePanel` (FoldedSettingsSection.tsx:90): rows slide open over 200 ms.
        header.action = { [weak self] in guard let self else { return }; CollapseMotion.run(in: self) { self.isOpen.toggle() } }
        for v in [header, toggle, note] as [NSView] { addSubview(v) }
        applyOpen()
    }

    func configure(_ m: ConnectionsPageModel.LoadBalancing) {
        header.summary = m.summary ?? ""
        toggle.isOn = m.enabled
        rows.forEach { $0.removeFromSuperview() }
        rows = m.machines.map { machine in
            let r = MachineRow(machine)
            r.select.selectedIndex = LoadBalancingLogic.preferences.firstIndex { $0.weight == LoadBalancingLogic.preference(forWeight: m.weights[machine.id]) }
            r.select.isEnabled = m.enabled
            r.select.onChange = { [weak self] i in self?.onPreference?(machine.id, LoadBalancingLogic.preferences[i].weight) }
            addSubview(r)
            return r
        }
        while dividers.count < rows.count {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
            dividers.append(l)
        }
        applyOpen()
        needsLayout = true
    }

    private func applyOpen() {
        note.isHidden = !isOpen
        rows.forEach { $0.isHidden = !isOpen }
        rule.isHidden = !isOpen
        for (i, d) in dividers.enumerated() { d.isHidden = !isOpen || i >= rows.count }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 2 + 44
        if isOpen { h += 1 + 20 + note.height(forWidth: width - 2 - 32) + CGFloat(rows.count) * (1 + 56) }
        return h
    }

    override func updateLayer() {
        super.updateLayer()
        let c = Themed.color(\.contrastBorder, 0.5).cgColor(in: self)
        rule.backgroundColor = c
        dividers.forEach { $0.backgroundColor = c }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ts = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: w - 1 - 16 - ts.width, y: 1 + (44 - ts.height) / 2, width: ts.width, height: ts.height)
        header.frame = NSRect(x: 1 + 16, y: 1, width: max(0, toggle.frame.minX - 16 - 17), height: 44)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rule.frame = CGRect(x: 1, y: 45, width: w - 2, height: 1)
        var y: CGFloat = 46
        let nh = note.height(forWidth: w - 2 - 32)
        note.frame = NSRect(x: 1 + 16, y: y + 10, width: w - 2 - 32, height: nh)
        y += 20 + nh
        for (i, r) in rows.enumerated() {
            dividers[i].frame = CGRect(x: 1, y: y, width: w - 2, height: 1)
            y += 1
            r.frame = NSRect(x: 1, y: y, width: w - 2, height: 56)
            y += 56
        }
        CATransaction.commit()
    }

    /// `EnvironmentRow` (`px-4 py-2.5`, `gap-x-3`): the machine glyph, name and transport, the select on the right.
    final class MachineRow: DSView {
        private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let subtitle = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        let select = SelectView(options: LoadBalancingLogic.preferences.map(\.label), size: .xs)

        init(_ m: ConnectionsPageModel.LoadBalancing.Machine) {
            super.init(frame: .zero)
            glyph.kind = m.machine
            glyph.color = Themed.color(\.mutedForeground)
            title.text = m.label
            title.lineHeight = 20
            title.truncates = true
            subtitle.text = m.subtitle
            subtitle.lineHeight = 16
            subtitle.truncates = true
            select.popupAlign = .end
            select.alignItemWithTrigger = false
            select.setAccessibilityLabel("\(m.label) load preference")
            for v in [glyph, title, subtitle, select] as [NSView] { addSubview(v) }
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            select.frame = NSRect(x: w - 16 - 128, y: (bounds.height - 24) / 2, width: 128, height: 24)
            glyph.frame = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
            let tw = max(0, select.frame.minX - 4 - 44)
            title.frame = NSRect(x: 44, y: 10, width: tw, height: 20)
            subtitle.frame = NSRect(x: 44, y: 30, width: tw, height: 16)
        }
    }
}
