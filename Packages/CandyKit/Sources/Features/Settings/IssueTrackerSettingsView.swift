import AppKit
import DesignSystem
import T3Protocol

/// The pure parts of `IssueTrackerSettings.tsx` and `client-runtime/src/state/issueTrackers.ts` (T3 5258).
public enum IssueTrackerSettingsLogic {
    public typealias Connection = IssueTrackerConnectionList.Connection
    public typealias Binding = IssueTrackerConnectionList.Binding

    /// `MAX_ISSUE_TRACKER_ADDITIONAL_SCOPES` (issue.ts).
    public static let maxAdditionalScopes = 250

    /// `usable` (IssueTrackerSettings.tsx:162): connected and the credential resolved to an account.
    public static func usable(_ t: Connection) -> Bool { t.connected && t.account != nil }

    /// A row's identity: the tracker and which of its accounts.
    public static func key(_ t: Connection) -> String { "\(t.tracker)-\(t.accountId ?? "")" }

    /// Each tracker's first account, then the accounts added beside it (IssueTrackerSettings.tsx:89-104).
    public static func rows(_ list: IssueTrackerConnectionList) -> [Connection] {
        list.trackers.flatMap { t in [t] + (list.accounts ?? []).filter { $0.tracker == t.tracker } }
    }

    /// The "Another account" row shows on a first account's row while any account of it is connected,
    /// and only on servers with `issueTrackerAccounts` (IssueTrackerSettings.tsx:57-59, :91-92).
    public static func canAddAccount(_ t: Connection, list: IssueTrackerConnectionList, capable: Bool) -> Bool {
        guard capable, t.accountId == nil else { return false }
        return t.connected || (list.accounts ?? []).contains { $0.tracker == t.tracker }
    }

    /// `issueTrackerBindings` (issueTrackers.ts): every project's binding, whichever account made it.
    public static func bindings(_ list: IssueTrackerConnectionList) -> [String: Binding] {
        list.bindings.merging(list.accountBindings ?? [:]) { _, added in added }
    }

    /// `issueTrackerBindingIsFor` (issueTrackers.ts).
    static func binding(_ b: Binding, isFor t: Connection) -> Bool { b.tracker == t.tracker && b.accountId == t.accountId }

    /// `issueTrackerSummary` (issueTrackers.ts).
    public static func summary(_ t: Connection, bindings: [String: Binding]) -> String {
        if !t.connected { return "Not connected. Add a \(t.credential.label.lowercased()) to list its issues." }
        guard let account = t.account else { return t.detail ?? "The saved credential was rejected." }
        let linked = bindings.values.filter { binding($0, isFor: t) }.count
        if linked == 0 {
            return "Connected as \(account) · no projects linked yet. Pick a \(t.scopeNoun) for a project to list its issues."
        }
        return "Connected as \(account) · \(linked) project\(linked == 1 ? "" : "s") linked"
    }

    /// `issueTrackers.connect` (IssueTrackerSettings.tsx:136-141): a null token disconnects, and `addAccount`
    /// saves the credential as a new account instead of replacing this one.
    public static func connect(_ t: Connection, token: String?, addAccount: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["tracker": .string(t.tracker), "token": token.map { .string($0) } ?? .null]
        if addAccount { o["addAccount"] = .bool(true) } else if let id = t.accountId { o["accountId"] = .string(id) }
        return .object(o)
    }

    /// `boundIssueTrackerScopes` (issueTrackers.ts): a project bound to another tracker or account shows unbound.
    public static func boundScopes(_ t: Connection, binding: Binding?) -> [String] {
        guard let binding, self.binding(binding, isFor: t) else { return [] }
        return binding.scopes
    }

    /// `issueTrackerBindingFor` (issueTrackers.ts): the scopes kept from before stay first, so the filing
    /// scope only changes when it is removed. No scopes unbinds.
    public static func binding(for t: Connection, current: [String], scopes: [String]) -> Binding? {
        let kept = current.filter { scopes.contains($0) }
        let ordered = kept + scopes.filter { !kept.contains($0) }
        guard let scope = ordered.first else { return nil }
        let rest = Array(ordered.dropFirst())
        return Binding(tracker: t.tracker, accountId: t.accountId, scope: scope, additionalScopes: rest.isEmpty ? nil : rest)
    }

    /// `issueTrackers.bindProject` with `issueTrackerBindInput` (issueTrackers.ts): an unbind names the account.
    public static func bind(projectId: String, tracker t: Connection, binding: Binding?) -> JSONValue {
        var o: [String: JSONValue] = ["projectId": .string(projectId), "binding": .null]
        if let binding {
            var b: [String: JSONValue] = ["tracker": .string(binding.tracker), "scope": .string(binding.scope)]
            if let id = binding.accountId { b["accountId"] = .string(id) }
            if let more = binding.additionalScopes { b["additionalScopes"] = .array(more.map { .string($0) }) }
            o["binding"] = .object(b)
        } else if let id = t.accountId {
            o["accountId"] = .string(id)
        }
        return .object(o)
    }

    public struct ScopeOption: Equatable { public var key: String; public var name: String; public var addable: Bool }

    /// `issueTrackerScopeOptions` (issueTrackers.ts): the tracker's scopes, then bound keys it no longer offers.
    public static func scopeOptions(_ t: Connection, bound: [String]) -> [ScopeOption] {
        let offered = Set(t.scopes.map(\.key))
        let full = bound.count > maxAdditionalScopes
        return (t.scopes.map { ($0.key, $0.name) } + bound.filter { !offered.contains($0) }.map { ($0, $0) })
            .map { ScopeOption(key: $0.0, name: $0.1, addable: !full || bound.contains($0.0)) }
    }

    /// `hasIssueTrackerTeams` (issueTrackers.ts).
    public static func hasTeams(_ t: Connection, bindings: [String: Binding]) -> Bool {
        !t.scopes.isEmpty || bindings.values.contains { binding($0, isFor: t) }
    }

    /// The trigger text (IssueTrackerSettings.tsx:334-341): "Not bound", or the picked names joined.
    public static func value(_ t: Connection, bound: [String]) -> String {
        bound.isEmpty ? "Not bound" : bound.map { k in t.scopes.first { $0.key == k }?.name ?? k }.joined(separator: ", ")
    }
}

/// One tracker (`TrackerRow`, IssueTrackerSettings.tsx:96-218): the icon with its status dot, the name,
/// "Credential rejected", the summary and a chevron that opens the credential and project bindings.
/// The header matches `SourceControlDiscoveryRow`, whose markup it shares (px-4 py-3, hover:bg-muted/20).
final class IssueTrackerRow: DSView, SettingsGroupRow {
    let tracker: IssueTrackerConnectionList.Connection
    private let mark: NSView
    private let dot = CALayer()
    private let label = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    /// The account's workspace (`truncate text-xs text-muted-foreground`, IssueTrackerSettings.tsx:180-182, 5258).
    private var workspace: LabelView?
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
        if let name = tracker.workspace, !name.isEmpty {
            let w = LabelView(name, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            w.lineHeight = 16
            workspace = w
            addSubview(w)
        }
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
        let room = w - 16 - 24 - 12 - x
        let badgeW = badge.map { $0.intrinsicContentSize.width + 8 } ?? 0
        let lw = min(ceil(label.textWidth) + 1, max(0, room - badgeW))
        label.frame = NSRect(x: x, y: 12, width: lw, height: 20)
        x += lw + 8
        if let workspace {
            let ww = min(ceil(workspace.textWidth) + 1, max(0, room - badgeW - lw - 8))
            workspace.frame = NSRect(x: x, y: 12 + 2, width: ww, height: 16)
            x += ww + 8
        }
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

/// The open part of a tracker row: the credential row, then "Projects" and one multi-pick per project, then
/// "Another account" on a first account that can add one (IssueTrackerSettings.tsx:200-266, T3 5258).
final class IssueTrackerDetailsView: DSView, SettingsGroupRow {
    let credential: SettingsRowView
    let secret: SecretFieldControl
    private(set) var projectRows: [SettingsRowView] = []
    private(set) var pickers: [SelectView] = []
    private(set) var accountRow: SettingsRowView?

    struct Project { var id: String; var title: String }

    /// `adding` shows the new account's credential field instead of the "Add account" button.
    struct AddAccount { var adding: Bool; var start: @MainActor () -> Void; var submit: @MainActor (String) -> Void }

    init(tracker t: IssueTrackerConnectionList.Connection, bindings: [String: IssueTrackerConnectionList.Binding], projects: [Project],
         canEdit: Bool, busy: Bool, failure: String?, openURL: ((URL) -> Void)?, addAccount: AddAccount? = nil,
         submit: @escaping @MainActor (String?) -> Void, bind: @escaping @MainActor (String, [String]) -> Void) {
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
        if IssueTrackerSettingsLogic.usable(t), !projects.isEmpty, IssueTrackerSettingsLogic.hasTeams(t, bindings: bindings) {
            let heading = SettingsRowView(title: "Projects",
                                          detail: "Pick one or more \(t.displayName) \(t.scopeNoun)s for each project. Their issues list beside the repository's own, and agents file new issues in the first one unless asked for another.")
            projectRows.append(heading)
            for p in projects {
                let bound = IssueTrackerSettingsLogic.boundScopes(t, binding: bindings[p.id])
                let options = IssueTrackerSettingsLogic.scopeOptions(t, bound: bound)
                let picker = SelectView(options: options.map { "\($0.name) (\($0.key))" }, selected: nil,
                                        placeholder: IssueTrackerSettingsLogic.value(t, bound: bound), size: .sm)
                picker.selectedIndices = Set(options.indices.filter { bound.contains(options[$0].key) })
                picker.disabledOptions = Set(options.indices.filter { !options[$0].addable })
                picker.setAccessibilityLabel("\(t.displayName) \(t.scopeNoun) for \(p.title)")
                picker.isEnabled = canEdit && !busy
                picker.onChangeMany = { [weak picker] picked in
                    let keys = options.indices.filter { picked.contains($0) }.map { options[$0].key }
                    picker?.placeholder = IssueTrackerSettingsLogic.value(t, bound: keys)
                    bind(p.id, keys)
                }
                pickers.append(picker)
                projectRows.append(SettingsRowView(title: p.title, control: picker))
            }
        }
        if let addAccount {
            // `AddAccountRow` (IssueTrackerSettings.tsx:395-432).
            let row: SettingsRowView
            if addAccount.adding {
                let field = SecretFieldControl(label: t.credential.label, saved: false, enabled: canEdit && !busy)
                field.input.placeholder = "Not set"
                field.input.onCommit = { text in
                    let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !next.isEmpty { addAccount.submit(next) }
                }
                field.input.onSubmit = { [weak field] in
                    let next = field?.input.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !next.isEmpty { addAccount.submit(next) }
                }
                row = SettingsRowView(title: t.credential.label, detail: "For the new \(t.displayName) account.", control: field)
            } else {
                let add = ButtonView("Add account", icon: .plus, variant: .outline, size: .xs)
                add.isEnabled = canEdit && !busy
                add.action = { addAccount.start() }
                row = SettingsRowView(title: "Another account", detail: "Connect a second \(t.displayName) workspace or user.", control: add)
            }
            accountRow = row
            projectRows.append(row)
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
