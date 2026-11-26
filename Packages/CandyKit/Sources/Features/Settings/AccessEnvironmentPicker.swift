import AppKit
import DesignSystem

/// The environments Sharing & access can show and the one it shows (5258 useAccessEnvironment.ts,
/// ConnectionsSettings.logic.ts:494-510).
public enum AccessEnvironment {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var label: String
        public var machine: String
        public var connected: Bool
        public init(id: String, label: String, machine: String, connected: Bool) {
            self.id = id; self.label = label; self.machine = machine; self.connected = connected
        }
    }

    /// `resolveAccessEnvironmentId`: the selection while it is listed, else the primary, else the first
    /// connected candidate, else the first.
    public static func resolve(primary: String?, candidates: [Candidate], selected: String?) -> String? {
        let listed = { (id: String?) in id.map { id in candidates.contains { $0.id == id } } ?? false }
        if listed(selected) { return selected }
        if listed(primary) { return primary }
        return (candidates.first(where: \.connected) ?? candidates.first)?.id
    }
}

/// The Access page's environment picker (ConnectionsSettings.tsx:201-247): "Showing access for" and an
/// `sm` select, shown when more than one environment can be managed. `px-4 gap-1.5 text-sm text-muted-foreground`.
final class AccessEnvironmentPickerView: DSView, SettingsGroupRow {
    private let lead = LabelView("Showing access for", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    let select = SelectView(options: [], size: .sm)
    private(set) var candidates: [AccessEnvironment.Candidate] = []
    var onPick: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        lead.lineHeight = 20
        select.alignItemWithTrigger = false
        select.hidesIndicator = true
        select.fitsContent = true
        select.ditherSettings = true
        select.setAccessibilityLabel("Environment")
        select.onChange = { [weak self] index in
            guard let self, self.candidates.indices.contains(index) else { return }
            self.onPick?(self.candidates[index].id)
        }
        addSubview(lead)
        addSubview(select)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ picker: ConnectionsPageModel.AccessPicker) {
        candidates = picker.candidates
        // `settingsScopeEnvironmentLabel`: a label two environments share gets its address.
        select.options = picker.candidates.map(\.label)
        select.optionGlyphs = picker.candidates.map { EnvironmentMachineIcon.definition($0.machine) }
        select.optionTrailingDetails = picker.candidates.map { $0.connected ? nil : "Offline" }
        select.selectedIndex = picker.candidates.firstIndex { $0.id == picker.selected }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 28 }

    override func layout() {
        super.layout()
        let pad: CGFloat = DesignGeometry.usesClassic(self) ? 16 : 0
        let leadWidth = ceil(lead.intrinsicContentSize.width)
        lead.frame = NSRect(x: pad, y: 4, width: leadWidth, height: 20)
        // `w-auto max-w-72`.
        let w = min(288, select.intrinsicContentSize.width, max(0, bounds.width - pad * 2 - leadWidth - 6))
        select.frame = NSRect(x: pad + leadWidth + 6, y: 0, width: w, height: 28)
    }
}
