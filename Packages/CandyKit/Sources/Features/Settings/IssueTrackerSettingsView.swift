import AppKit
import DesignSystem
import T3Protocol

/// The pure parts of `IssueTrackerSettings.tsx` (T3 4928) and `issueTrackerSummary`
/// (client-runtime/src/state/issueTrackers.ts).
public enum IssueTrackerSettingsLogic {
    public typealias Connection = IssueTrackerConnectionList.Connection

    /// `usable` (IssueTrackerSettings.tsx:125): connected and the credential resolved to an account.
    public static func usable(_ t: Connection) -> Bool { t.connected && t.account != nil }

    /// `issueTrackerSummary` (issueTrackers.ts).
    public static func summary(_ t: Connection, bindings: [String: IssueTrackerConnectionList.Binding]) -> String {
        if !t.connected { return "Not connected. Add a \(t.credential.label.lowercased()) to list its issues." }
        guard let account = t.account else { return t.detail ?? "The saved credential was rejected." }
        let linked = bindings.values.filter { $0.tracker == t.tracker }.count
        if linked == 0 {
            return "Connected as \(account) · no projects linked yet. Pick a \(t.scopeNoun) for a project to list its issues."
        }
        return "Connected as \(account) · \(linked) project\(linked == 1 ? "" : "s") linked"
    }

    /// `issueTrackers.connect` (rpc.ts:1418): a null token disconnects.
    public static func connect(tracker: String, token: String?) -> JSONValue {
        .object(["tracker": .string(tracker), "token": token.map { .string($0) } ?? .null])
    }

    /// `issueTrackers.bindProject` (rpc.ts:1424): a nil scope unbinds the project.
    public static func bind(projectId: String, tracker: String, scope: String?) -> JSONValue {
        .object(["projectId": .string(projectId),
                 "binding": scope.map { .object(["tracker": .string(tracker), "scope": .string($0)]) } ?? .null])
    }

    /// The picker's selection (IssueTrackerSettings.tsx:276-277): a project bound to another tracker
    /// shows unbound here. Index 0 is "Not bound", then the tracker's scopes in order.
    public static func selectedIndex(_ t: Connection, binding: IssueTrackerConnectionList.Binding?) -> Int {
        guard let binding, binding.tracker == t.tracker else { return 0 }
        return (t.scopes.firstIndex { $0.key == binding.scope }).map { $0 + 1 } ?? 0
    }

    public static func options(_ t: Connection) -> [String] { ["Not bound"] + t.scopes.map { "\($0.name) (\($0.key))" } }
}

/// One tracker (`TrackerRow`, IssueTrackerSettings.tsx:96-218): the icon with its status dot, the name,
/// "Credential rejected", the summary and a chevron that opens the credential and project bindings.
/// The header matches `SourceControlDiscoveryRow`, whose markup it shares (px-4 py-3, hover:bg-muted/20).
final class IssueTrackerRow: DSView, SettingsGroupRow {
    let tracker: IssueTrackerConnectionList.Connection
    private let mark: NSView
    private let dot = CALayer()
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private var badge: BadgeView?
    private let summary = TextBlockView()
    private let toggle = ButtonView(nil, icon: .chevronDown, variant: .ghostMuted, size: .iconXs)
    let details: IssueTrackerDetailsView
    private let hoverFill = CALayer()
    private var hover: HoverGroup?
    var onToggle: (() -> Void)?
    var isExpanded = false {
        didSet { details.isHidden = !isExpanded; toggle.setIconRotation(isExpanded ? 180 : 0); toggle.setAccessibilityExpanded(isExpanded); needsLayout = true }
    }

    init(tracker: IssueTrackerConnectionList.Connection, summary text: String, details: IssueTrackerDetailsView) {
        self.tracker = tracker
        self.details = details
        // `TRACKER_ICONS` (:33-35): only Linear has art; others show the dot alone.
        mark = tracker.tracker == "linear" ? IconView(definition: IconName.brandLinear.definition, size: 18, color: Themed.color(\.foreground, 0.8)) : DSView()
        super.init(frame: .zero)
        hoverFill.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(hoverFill)
        hover = HoverGroup(self) { [weak self] _ in self?.restyleHover(transitioning: true) }
        addSubview(mark)
        dot.borderWidth = 2
        layer?.addSublayer(dot)
        label.text = tracker.displayName
        label.lineHeight = 20
        if tracker.connected && tracker.account == nil {
            let b = BadgeView("Credential rejected", variant: .destructive, size: .sm)
            badge = b
            addSubview(b)
        }
        summary.text = text
        summary.font = DSFont.ui(12)
        summary.lineHeight = 18
        summary.color = Themed.color(\.mutedForeground, 0.8)
        toggle.iconSize = 14
        toggle.setAccessibilityLabel("Toggle \(tracker.displayName) details")
        toggle.action = { [weak self] in self?.onToggle?() }
        for v in [label, summary, toggle, details] as [NSView] { addSubview(v) }
        details.isHidden = true
    }

    private func restyleHover(transitioning: Bool) {
        let color = hover?.hovered == true ? Themed.color(\.muted, 0.2).cgColor(in: self) : nil
        Motion.transitioning(transitioning ? .background : []) { Motion.setBackground(hoverFill, color) }
    }

    private func headerHeight(_ width: CGFloat) -> CGFloat { 12 + 20 + 4 + summary.height(forWidth: width - 32 - 32 - 12) + 12 }

    func height(forWidth width: CGFloat) -> CGFloat {
        let top = headerHeight(width)
        guard isExpanded else { return top }
        return top + 4 + details.height(forWidth: width - 32) + 16
    }

    override func layout() {
        super.layout()
        let rows = (superview as? SettingsGroupView)?.rows ?? []
        var corners: CACornerMask = []
        if rows.first === self { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if rows.last === self { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        let w = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverFill.frame = bounds
        hoverFill.cornerRadius = corners.isEmpty ? 0 : 12
        hoverFill.maskedCorners = corners
        // `-left-0.5 -top-0.5 size-2 ring-2 ring-background` on the 20pt icon box.
        dot.frame = CGRect(x: 16 - 2 - 2, y: 12 - 2 - 2, width: 12, height: 12)
        dot.cornerRadius = 6
        CATransaction.commit()
        let headerH = headerHeight(w)
        mark.frame = NSRect(x: 17, y: 13, width: 18, height: 18)
        var x: CGFloat = 16 + 20 + 8
        let lw = ceil(label.textWidth) + 1
        label.frame = NSRect(x: x, y: 12, width: lw, height: 20)
        x += lw + 8
        if let badge {
            let s = badge.intrinsicContentSize
            badge.frame = NSRect(x: x, y: 12 + (20 - s.height) / 2, width: s.width, height: s.height)
        }
        let tw = w - 32 - 32 - 12
        summary.frame = NSRect(x: 16, y: 36, width: tw, height: summary.height(forWidth: tw))
        toggle.frame = NSRect(x: w - 16 - 24, y: (headerH - 24) / 2, width: 24, height: 24)
        if isExpanded { details.frame = NSRect(x: 16, y: headerH + 4, width: w - 32, height: details.height(forWidth: w - 32)) }
    }

    override func updateLayer() {
        super.updateLayer()
        restyleHover(transitioning: false)
        dot.backgroundColor = (IssueTrackerSettingsLogic.usable(tracker) ? Themed.color(\.success) : Themed.color(\.mutedForeground, 0.35)).cgColor(in: self)
        dot.borderColor = Themed.color(\.background).cgColor(in: self)
    }
}

/// The open part of a tracker row: the credential row, then "Projects" and one scope picker per project.
final class IssueTrackerDetailsView: DSView, SettingsGroupRow {
    let credential: SettingsRowView
    let secret: SecretFieldControl
    private(set) var projectRows: [SettingsRowView] = []
    private(set) var pickers: [SelectView] = []

    struct Project { var id: String; var title: String }

    init(tracker t: IssueTrackerConnectionList.Connection, bindings: [String: IssueTrackerConnectionList.Binding], projects: [Project],
         canEdit: Bool, busy: Bool, failure: String?, openURL: ((URL) -> Void)?,
         submit: @escaping @MainActor (String?) -> Void, bind: @escaping @MainActor (String, String?) -> Void) {
        secret = SecretFieldControl(label: t.credential.label, saved: t.connected, enabled: canEdit && !busy)
        credential = SettingsRowView(title: t.credential.label, detail: "Stored on the server.", control: secret)
        super.init(frame: .zero)
        // `SecretInput configured={connected} value=""`: a saved credential never comes back.
        secret.input.placeholder = t.connected ? "Stored secret, enter a new value to replace" : "Not set"
        secret.input.onSubmit = { [weak secret] in
            guard let secret else { return }
            let next = secret.input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty { submit(next) }
        }
        secret.input.onCommit = { text in
            let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty { submit(next) }
        }
        secret.clear.setAccessibilityLabel("Disconnect \(t.displayName)")
        secret.clear.action = { submit(nil) }
        if let help = t.credential.helpUrl.flatMap(URL.init(string:)), let openURL {
            credential.detailLink = (title: "Create one", action: { openURL(help) })
        }
        if let failure { credential.status = failure; credential.statusIsError = true }
        addSubview(credential)
        guard IssueTrackerSettingsLogic.usable(t), !projects.isEmpty, !t.scopes.isEmpty else { return }
        let heading = SettingsRowView(title: "Projects",
                                      detail: "Pick the \(t.displayName) \(t.scopeNoun) whose issues each project lists beside its repository's own.")
        projectRows.append(heading)
        for p in projects {
            let picker = SelectView(options: IssueTrackerSettingsLogic.options(t),
                                    selected: IssueTrackerSettingsLogic.selectedIndex(t, binding: bindings[p.id]), size: .sm)
            picker.setAccessibilityLabel("\(t.displayName) \(t.scopeNoun) for \(p.title)")
            picker.isEnabled = canEdit && !busy
            picker.onChange = { i in bind(p.id, i == 0 ? nil : t.scopes[i - 1].key) }
            pickers.append(picker)
            projectRows.append(SettingsRowView(title: p.title, control: picker))
        }
        projectRows.forEach(addSubview)
    }

    private var rows: [SettingsRowView] { [credential] + projectRows }

    func height(forWidth width: CGFloat) -> CGFloat { rows.reduce(0) { $0 + $1.height(forWidth: width) } }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for r in rows {
            let h = r.height(forWidth: bounds.width)
            r.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h
        }
    }
}
