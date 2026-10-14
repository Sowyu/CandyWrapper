import AppKit
import DesignSystem
import T3Protocol

// "This machine" rows, the session Permissions panel, the environment Icon submenu and "Authorized
// clients" of Settings > Connections (ConnectionsSettings.tsx:3609-3776, SessionPermissions.tsx,
// EnvironmentIconPicker.tsx). The app fills the model; strings are final.

extension ConnectionsPageModel {
    /// A switch in a host row. Disabled switches carry the reason as a tooltip (`CloudLinkSwitch`).
    public struct HostSwitch: Equatable {
        public var isOn: Bool
        public var isEnabled: Bool
        public var tooltip: String?
        public var label: String
        public init(isOn: Bool, isEnabled: Bool, tooltip: String? = nil, label: String) {
            self.isOn = isOn; self.isEnabled = isEnabled; self.tooltip = tooltip; self.label = label
        }
    }

    /// One `SettingsRow` of "This machine".
    public struct HostRow: Equatable {
        public enum Control: Equatable {
            case none
            case toggle(HostSwitch)
            /// Muted `text-xs`, like `Up to date`.
            case text(String)
            /// The manual update: copy the command, then T3's toast.
            case copyCommand(ServerUpdateCopy.Manual)
            /// `ServerUpdateAction size="sm"`: "Update to <version>" or "Retry update".
            case update(String, enabled: Bool)
        }
        public var id: String
        public var title: String
        public var detail: String?
        public var status: String?
        public var statusIsError: Bool
        public var control: Control
        /// `ServerUpdateProgress` in place of the description while an update runs or after it failed.
        public var progress: ServerUpdateState?
        public init(id: String, title: String, detail: String? = nil, status: String? = nil, statusIsError: Bool = false, control: Control = .none,
                    progress: ServerUpdateState? = nil) {
            self.id = id; self.title = title; self.detail = detail; self.status = status; self.statusIsError = statusIsError; self.control = control
            self.progress = progress
        }

        /// The `Version` row: `<version> · <url>` and `Up to date`.
        public static func version(_ line: String, upToDate: Bool) -> HostRow {
            HostRow(id: "version", title: "Version", detail: line, control: upToDate ? .text("Up to date") : .none)
        }
    }

    /// `SessionPermissions`: what this client's session may do there, or nil grants before it is read.
    public struct Permissions: Equatable {
        public struct Grant: Equatable {
            public var title: String
            public var allowed: Bool
            public init(title: String, allowed: Bool) { self.title = title; self.allowed = allowed }
        }
        /// Saved machines say "your active route"; This machine says "this client’s current connection".
        public var routeContext: Bool
        public var grants: [Grant]?
        public init(routeContext: Bool, grants: [Grant]?) { self.routeContext = routeContext; self.grants = grants }
    }

    /// `EnvironmentIconMenu`: the resolved kind, the server's own detection, and why it can't change.
    public struct IconMenu: Equatable {
        public var resolved: String
        public var detected: String
        /// `detected` when the server reported a machine, else `default`.
        public var detectedTag: String
        public var lock: String?
        public init(resolved: String, detected: String, detectedTag: String, lock: String?) {
            self.resolved = resolved; self.detected = detected; self.detectedTag = detectedTag; self.lock = lock
        }
    }

    /// "Authorized clients" (`FoldedSettingsSection` with `PairingClientsList`).
    public struct Access: Equatable {
        public struct PairingLink: Equatable {
            public var id: String
            public var label: String
            public var createdTooltip: String
            public var expires: String
            public var expiresAbsolute: String
            public var scopes: [String]
            /// Only links this client created have their secret.
            public var credential: String?
            /// `<origin>/pair#token=<credential>` for the route in use.
            public var shareURL: String?
            /// False for a loopback URL: no QR code (a scanning device would dial itself).
            public var qrShareable: Bool
            public var revoking: Bool
            public init(id: String, label: String, createdTooltip: String, expires: String, expiresAbsolute: String, scopes: [String],
                        credential: String? = nil, shareURL: String? = nil, qrShareable: Bool = false, revoking: Bool = false) {
                self.id = id; self.label = label; self.createdTooltip = createdTooltip; self.expires = expires
                self.expiresAbsolute = expiresAbsolute; self.scopes = scopes; self.credential = credential; self.shareURL = shareURL
                self.qrShareable = qrShareable; self.revoking = revoking
            }
        }
        public struct Client: Equatable {
            public var id: String
            public var label: String
            public var live: Bool
            public var statusTooltip: String
            public var current: Bool
            /// `Desktop · macOS · Chrome · 127.0.0.1`, or nil.
            public var info: String?
            public var scopes: [String]
            public var revoking: Bool
            public init(id: String, label: String, live: Bool, statusTooltip: String, current: Bool, info: String?, scopes: [String], revoking: Bool = false) {
                self.id = id; self.label = label; self.live = live; self.statusTooltip = statusTooltip; self.current = current
                self.info = info; self.scopes = scopes; self.revoking = revoking
            }
        }
        public var summary: String
        public var canRead: Bool
        public var canWrite: Bool
        public var loading: Bool
        public var error: String?
        public var links: [PairingLink]
        public var clients: [Client]
        public var revokingOthers: Bool
        /// `canRevokeOtherClients`: unknown lists allow it, known ones need another session.
        public var canRevokeOthers: Bool
        public init(summary: String, canRead: Bool, canWrite: Bool, loading: Bool = false, error: String? = nil, links: [PairingLink] = [],
                    clients: [Client] = [], revokingOthers: Bool = false, canRevokeOthers: Bool = true) {
            self.summary = summary; self.canRead = canRead; self.canWrite = canWrite; self.loading = loading; self.error = error
            self.links = links; self.clients = clients; self.revokingOthers = revokingOthers; self.canRevokeOthers = canRevokeOthers
        }

        /// `summarizeAuthorizedClients`.
        public static func summary(clients: Int, links: Int) -> String {
            var parts = ["\(clients) \(clients == 1 ? "client" : "clients")"]
            if links > 0 { parts.append("\(links) \(links == 1 ? "pairing link" : "pairing links")") }
            return parts.joined(separator: " · ")
        }
    }

    /// `ENVIRONMENT_MACHINE_KINDS` with `ENVIRONMENT_MACHINE_KIND_LABELS`, in T3's order.
    public static let machineKinds: [(kind: String, label: String)] = [
        ("server", "Server"), ("cloud", "Cloud VM"), ("linux", "Linux/WSL"), ("desktop", "Desktop"),
        ("laptop", "Laptop"), ("mac-mini", "Mini PC"), ("mac-studio", "Workstation"),
    ]
}

extension ConnectionsSettingsView {
    /// The row menu's `Icon` submenu (`EnvironmentIconMenu`): the lock reason as a disabled item, then one
    /// radio item per kind with the detected one marked. Picking the detected kind clears the override.
    static func iconMenuItem(_ menu: ConnectionsPageModel.IconMenu, pick: @escaping @MainActor (String) -> Void) -> MenuItem {
        var items: [MenuItem] = []
        if let lock = menu.lock {
            items.append(MenuItem(lock, disabled: true))
            items.append(.separator)
        }
        for (kind, label) in ConnectionsPageModel.machineKinds {
            var item = MenuItem.radio(label, checked: kind == menu.resolved) { _ in pick(kind) }
            item.glyph = EnvironmentMachineIcon.definition(kind)
            item.isDisabled = menu.lock != nil
            // ponytail: the `detected` note uses the shortcut slot's style (muted xs); fine unless a reference shows otherwise
            if kind == menu.detected { item.shortcut = menu.detectedTag }
            items.append(item)
        }
        var sub = MenuItem.submenu("Icon", items)
        sub.glyph = EnvironmentMachineIcon.definition(menu.resolved)
        return sub
    }
}

/// A switch in a `span` that carries the tooltip, so a disabled switch still explains itself.
final class HostSwitchView: DSView {
    let toggle = SwitchView()
    private var tip: TooltipController?
    var onChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(toggle)
        toggle.onChange = { [weak self] on in self?.onChange?(on) }
    }

    func configure(_ s: ConnectionsPageModel.HostSwitch) {
        toggle.isOn = s.isOn
        toggle.isEnabled = s.isEnabled
        toggle.setAccessibilityLabel(s.label)
        if let text = s.tooltip {
            if let tip { tip.text = text } else { tip = TooltipController.attach(to: self, text: text, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4)) }
            setAccessibilityHelp(text)
        } else {
            tip?.text = ""
        }
    }

    override var intrinsicContentSize: NSSize { toggle.intrinsicContentSize }
    override func layout() { super.layout(); toggle.frame = bounds }
}

/// `SessionPermissions`: a note and a two-column list of permissions with `Allowed` or `Not granted`,
/// or "Permissions not checked" while there is no connected, authenticated session. `py-3 text-xs`.
final class SessionPermissionsView: DSView {
    private let note = TextBlockView()
    private var titles: [LabelView] = []
    private var values: [LabelView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        note.font = DSFont.ui(12)
        note.lineHeight = 16
        note.color = Themed.color(\.mutedForeground)
        addSubview(note)
    }

    func configure(_ p: ConnectionsPageModel.Permissions) {
        (titles + values).forEach { $0.removeFromSuperview() }
        titles = []; values = []
        guard let grants = p.grants else {
            note.text = "Permissions not checked. Connect to this environment to view this session’s permissions."
            needsLayout = true
            return
        }
        note.text = p.routeContext
            ? "These permissions apply to your active route. Other routes may have different permissions."
            : "These permissions apply to this client’s current connection."
        for g in grants {
            let t = LabelView(g.title, font: DSFont.ui(12), color: Themed.color(\.foreground))
            let v = LabelView(g.allowed ? "Allowed" : "Not granted", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            t.lineHeight = 16; v.lineHeight = 16; t.truncates = true
            addSubview(t); addSubview(v)
            titles.append(t); values.append(v)
        }
        needsLayout = true
    }

    /// `space-y-3 py-3`; the list is `grid gap-x-6 gap-y-2 sm:grid-cols-2`.
    func height(forWidth width: CGFloat) -> CGFloat {
        var h = 12 + note.height(forWidth: width) + 12
        if !titles.isEmpty {
            let rows = (titles.count + 1) / 2
            h += 12 + CGFloat(rows) * 16 + CGFloat(rows - 1) * 8
        }
        return h
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let nh = note.height(forWidth: w)
        note.frame = NSRect(x: 0, y: 12, width: w, height: nh)
        let colW = (w - 24) / 2
        for (i, (t, v)) in zip(titles, values).enumerated() {
            let x = CGFloat(i % 2) * (colW + 24)
            let y = 12 + nh + 12 + CGFloat(i / 2) * 24
            let vw = ceil(v.textWidth) + 1
            v.frame = NSRect(x: x + colW - vw, y: y, width: vw, height: 16)
            t.frame = NSRect(x: x, y: y, width: max(0, colW - vw - 12), height: 16)
        }
    }
}

/// This machine's `<details>` Permissions row: `px-3 sm:px-4`, a `min-h-11` summary with a `size-3`
/// chevron, then `SessionPermissions`.
final class PermissionsDisclosureRow: DSView, SettingsGroupRow {
    private let summary = DisclosureSummary()
    let panel = SessionPermissionsView()
    var isOpen = false { didSet { panel.isHidden = !isOpen; summary.isOpen = isOpen; onHeightChange?() } }
    var onHeightChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        panel.isHidden = true
        addSubview(summary)
        addSubview(panel)
        summary.action = { [weak self] in guard let self else { return }; self.isOpen.toggle() }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 44 + (isOpen ? panel.height(forWidth: width - 32) : 0) }

    override func layout() {
        super.layout()
        summary.frame = NSRect(x: 16, y: 0, width: bounds.width - 32, height: 44)
        if isOpen { panel.frame = NSRect(x: 16, y: 44, width: bounds.width - 32, height: panel.height(forWidth: bounds.width - 32)) }
    }

    /// `text-sm font-medium` "Permissions" and a muted chevron that turns down when open.
    final class DisclosureSummary: ControlView {
        private let label = LabelView("Permissions", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let chevron = IconView(name: .chevronRight, size: 12)
        var isOpen = false { didSet { chevron.frameCenterRotation = isOpen ? 90 : 0; setAccessibilityExpanded(isOpen) } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            label.lineHeight = 20
            chevron.strokeColor = Themed.color(\.mutedForeground)
            addSubview(label)
            addSubview(chevron)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Permissions")
        }

        override func layout() {
            super.layout()
            let lw = ceil(label.textWidth)
            label.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: lw + 1, height: 20)
            // A rotated view's frame is in rotated space: place it unrotated, then turn it.
            chevron.frameCenterRotation = 0
            chevron.frame = NSRect(x: lw + 8, y: (bounds.height - 12) / 2, width: 12, height: 12)
            chevron.frameCenterRotation = isOpen ? 90 : 0
        }
    }
}

/// `ConnectionStatusDot`: a `size-2` dot in a `size-3` box with a tooltip. With `pings` a halo in the
/// tone at 60% bursts from 75% to 200% and fades in eight steps over the first 40% of every 2s
/// (`animate-status-ping`, index.css:317-330), only while the dot is on screen.
final class StatusDotView: DSView {
    enum Tone { case success, warning, idle, destructive, off }
    var tone: Tone = .idle { didSet { needsDisplay = true } }
    var pings = false {
        didSet {
            guard pings != oldValue else { return }
            halo.isHidden = !pings
            if pings { ping.windowChanged() } else { halo.removeAnimation(forKey: "ping") }
        }
    }
    private let dot = CALayer()
    private let halo = CALayer()
    private lazy var ping = LoopingAnimation(view: self, key: "ping", layer: { [weak self] in self?.pings == true ? self?.halo : nil }) {
        // steps(8) from 0% to 40%, then held at the end: discrete values at each eighth.
        let steps = 8
        let fractions = (0...steps).map { CGFloat($0) / CGFloat(steps) }
        let times = (0...steps).map { NSNumber(value: 0.4 * Double($0) / Double(steps)) } + [1]
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = fractions.map { 0.9 * (1 - $0) }
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = fractions.map { 0.75 + 1.25 * $0 }
        for a in [opacity, scale] { a.keyTimes = times; a.calculationMode = .discrete }
        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = 2
        group.repeatCount = .infinity
        return group
    }
    private var tip: TooltipController?
    var tooltip = "" {
        didSet {
            setAccessibilityLabel(tooltip)
            if let tip { tip.text = tooltip } else { tip = TooltipController.attach(to: self, text: tooltip, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4)) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        dot.cornerRadius = 4
        halo.actions = dot.actions
        halo.isHidden = true
        halo.opacity = 0 // between bursts, and whenever the loop is off
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        setAccessibilityRole(.button)
    }

    override func updateLayer() {
        let (color, ring): (NSColor, NSColor) = switch tone {
        case .success: (Themed.color(\.success), Themed.color(\.success, 0.6))
        case .warning: (Themed.color(\.warning), Themed.color(\.warning, 0.6))
        case .idle: (Themed.color(\.mutedForeground, 0.3), Themed.color(\.mutedForeground, 0.18))
        case .destructive: (Themed.color(\.destructive), Themed.color(\.destructive, 0.6))
        case .off: (Themed.color(\.mutedForeground, 0.4), Themed.color(\.mutedForeground, 0.24))
        }
        dot.backgroundColor = color.cgColor(in: self)
        halo.backgroundColor = ring.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: (bounds.width - 8) / 2, y: (bounds.height - 8) / 2, width: 8, height: 8)
        // `absolute h-full w-full rounded-full`: the size-3 box.
        let side = min(bounds.width, bounds.height)
        halo.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        halo.cornerRadius = side / 2
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if pings { ping.windowChanged() } }
    override func viewDidHide() { super.viewDidHide(); if pings { ping.update() } }
    override func viewDidUnhide() { super.viewDidUnhide(); if pings { ping.update() } }
}

/// `AccessScopeSummary`: `<n> scopes`, underlined, with the granted scopes on hover.
final class ScopeSummaryLabel: DSView {
    private let label = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let underline = CALayer()
    private var tip: TooltipController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(label)
        underline.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(underline)
    }

    // ponytail: the scope list shows as a plain tooltip; T3 uses a hover popover with monospaced scopes
    func configure(scopes: [String], label prefix: String) {
        let count = "\(scopes.count) \(scopes.count == 1 ? "scope" : "scopes")"
        label.text = count
        setAccessibilityLabel("\(prefix): show \(count)")
        let text = (["Granted scopes"] + scopes).joined(separator: "\n")
        if let tip { tip.text = text } else { tip = TooltipController.attach(to: self, text: text, placement: PopupPlacement(side: .top, align: .start, sideOffset: 4)) }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 1, height: 16) }

    override func updateLayer() { underline.backgroundColor = Themed.color(\.border).cgColor(in: self) }

    override func layout() {
        super.layout()
        label.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        underline.frame = CGRect(x: 0, y: 15, width: bounds.width, height: 1)
        CATransaction.commit()
    }
}

/// "Authorized clients": a `SettingsGroup` that starts closed (`FoldedSettingsSection`, inside header).
/// The header has the chevron, title and summary, and `Revoke others` and `Create link` on the right.
final class AuthorizedClientsSectionView: BoxView, SettingsGroupRow {
    private let header = FoldHeader()
    private let revokeOthers = ButtonView("Revoke others", variant: .destructiveOutline, size: .xs)
    private let createLink = ButtonView("Create link", icon: .plus, variant: .default, size: .xs)
    private let rule = CALayer()
    private var rows: [NSView & SettingsGroupRow] = []
    private var dividers: [CALayer] = []
    private var linkRows: [String: PairingLinkRowView] = [:]
    private var clientRows: [String: ClientSessionRowView] = [:]
    private lazy var note = AccessNoteRow()
    private lazy var errorRow = AccessNoteRow()
    var isOpen = false { didSet { header.isOpen = isOpen; rows.forEach { $0.isHidden = !isOpen }; onHeightChange?() } }
    var onHeightChange: (() -> Void)?
    var actions = ConnectionsActions()
    private var sharing: Set<String> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var box = BoxStyle()
        box.radius = 14
        box.border = Themed.color(\.contrastBorder, 0.6)
        box.fill = Themed.color(\.card, 0.4)
        box.shadows = [BoxShadow(y: 1, blur: 2, color: Themed.black(0.05))]
        boxStyle = box
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(rule)
        createLink.iconSize = 12
        for v in [header, revokeOthers, createLink] as [NSView] { addSubview(v) }
        // `FoldedSettingsSection`'s `CollapsiblePanel` (FoldedSettingsSection.tsx:90): rows slide open over 200 ms.
        header.action = { [weak self] in guard let self else { return }; CollapseMotion.run(in: self) { self.isOpen.toggle() } }
        revokeOthers.action = { [weak self] in self?.actions.revokeOtherClients() }
        createLink.action = { [weak self] in self?.actions.createPairingLink() }
    }

    func configure(_ a: ConnectionsPageModel.Access) {
        header.summary = a.summary
        revokeOthers.isHidden = !a.canWrite
        createLink.isHidden = !a.canWrite
        revokeOthers.title = a.revokingOthers ? "Revoking…" : "Revoke others"
        revokeOthers.isEnabled = !a.revokingOthers && a.canRevokeOthers
        var next: [NSView & SettingsGroupRow] = []
        if let error = a.error {
            errorRow.configure(error, error: true)
            next.append(errorRow)
        }
        if !a.canRead {
            note.configure("This connection can create access links but cannot view authorized clients.", error: false)
            next.append(note)
        } else {
            var nextLinks: [String: PairingLinkRowView] = [:]
            for link in a.links {
                let row = linkRows[link.id] ?? PairingLinkRowView()
                let id = link.id
                row.sharing = sharing.contains(id)
                row.configure(link, canRevoke: a.canWrite)
                row.onRevoke = { [weak self] in self?.actions.revokePairingLink(id) }
                row.onShare = { [weak self] in self?.toggleShare(id) }
                row.onCopy = { [weak self] text, title, description in self?.actions.copySecret(text, title, description) }
                nextLinks[id] = row
                next.append(row)
            }
            linkRows = nextLinks
            sharing = sharing.filter { nextLinks[$0] != nil }
            var nextClients: [String: ClientSessionRowView] = [:]
            for client in a.clients {
                let row = clientRows[client.id] ?? ClientSessionRowView()
                let id = client.id
                row.configure(client, canRevoke: a.canWrite)
                row.onRevoke = { [weak self] in self?.actions.revokeClient(id) }
                nextClients[id] = row
                next.append(row)
            }
            clientRows = nextClients
            if a.links.isEmpty, a.clients.isEmpty, !a.loading {
                note.configure("No pairing links or client sessions.", error: false, faint: true)
                next.append(note)
            }
        }
        for r in rows where !next.contains(where: { $0 === r }) { r.removeFromSuperview() }
        rows = next
        for r in rows {
            if r.superview !== self { addSubview(r) }
            r.isHidden = !isOpen
        }
        while dividers.count < max(0, rows.count - 1) {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
            dividers.append(l)
        }
        needsLayout = true
        needsDisplay = true
    }

    private func toggleShare(_ id: String) {
        if sharing.contains(id) { sharing.remove(id) } else { sharing.insert(id) }
        linkRows[id]?.sharing = sharing.contains(id)
        onHeightChange?()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 2 + 44
        if isOpen {
            h += 1 + rows.reduce(0) { $0 + $1.height(forWidth: width - 2) } + CGFloat(max(0, rows.count - 1))
        }
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
        // `flex items-center gap-4 px-3 sm:px-4`; the control is `flex shrink-0 items-center` with `gap-2`.
        var x = w - 1 - 16
        for b in [createLink, revokeOthers] where !b.isHidden {
            let s = b.intrinsicContentSize
            x -= s.width
            b.frame = NSRect(x: x, y: 1 + (44 - s.height) / 2, width: s.width, height: s.height)
            x -= 8
        }
        let controlLeft = createLink.isHidden ? w - 1 - 16 : x + 8 - 16
        header.frame = NSRect(x: 1 + 16, y: 1, width: max(0, controlLeft - 17), height: 44)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rule.isHidden = !isOpen
        rule.frame = CGRect(x: 1, y: 45, width: w - 2, height: 1)
        var y: CGFloat = 46
        for (i, r) in rows.enumerated() {
            if i > 0 {
                dividers[i - 1].isHidden = !isOpen
                dividers[i - 1].frame = CGRect(x: 1, y: y, width: w - 2, height: 1)
                y += 1
            }
            let h = r.height(forWidth: w - 2)
            r.frame = NSRect(x: 1, y: y, width: w - 2, height: h)
            y += h
        }
        for d in dividers.dropFirst(max(0, rows.count - 1)) { d.isHidden = true }
        CATransaction.commit()
    }

    /// The `CollapsibleTrigger`: `size-4` muted chevron, `text-sm font-medium` title, `text-xs` muted summary.
    final class FoldHeader: ControlView {
        private let chevron = IconView(name: .chevronRight, size: 16)
        private let title = LabelView("Authorized clients", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        private let summaryLabel = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        var summary: String { get { summaryLabel.text } set { summaryLabel.text = newValue; needsLayout = true } }
        /// The section title (`FoldedSettingsSection title`); Load balancing reuses this header.
        var heading: String { get { title.text } set { title.text = newValue; setAccessibilityLabel(newValue); needsLayout = true } }
        /// `transition-transform duration-150`, `rotate-90` when open (FoldedSettingsSection.tsx:76-81).
        var isOpen = false { didSet { chevron.setRotation(isOpen ? 90 : 0); setAccessibilityExpanded(isOpen) } }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            title.lineHeight = 20
            summaryLabel.lineHeight = 16
            summaryLabel.truncates = true
            chevron.strokeColor = Themed.color(\.mutedForeground)
            for v in [chevron, title, summaryLabel] as [NSView] { addSubview(v) }
            setAccessibilityRole(.button)
            setAccessibilityLabel("Authorized clients")
        }

        override func layout() {
            super.layout()
            let h = bounds.height
            chevron.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
            let tw = ceil(title.textWidth) + 1
            title.frame = NSRect(x: 24, y: (h - 20) / 2, width: tw, height: 20)
            let sx = 24 + ceil(title.textWidth) + 7
            summaryLabel.frame = NSRect(x: sx, y: (h - 16) / 2, width: max(0, bounds.width - sx), height: 16)
        }
    }
}

/// A one-line note row (`px-4 py-3 text-xs`): the access error, the read-only note, or the empty state.
final class AccessNoteRow: DSView, SettingsGroupRow {
    private let text = TextBlockView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.font = DSFont.ui(12)
        text.lineHeight = 16
        addSubview(text)
    }
    func configure(_ s: String, error: Bool, faint: Bool = false) {
        text.text = s
        text.color = error ? Themed.color(\.destructive) : Themed.color(\.mutedForeground, faint ? 0.6 : 1)
        needsLayout = true
    }
    func height(forWidth width: CGFloat) -> CGFloat { 24 + text.height(forWidth: width - 32) }
    override func layout() { super.layout(); text.frame = NSRect(x: 16, y: 12, width: bounds.width - 32, height: text.height(forWidth: bounds.width - 32)) }
}

/// `PairingLinkListRow`: warning dot, label, `Expires in …` · scopes, a note when the secret is not
/// here, and `Share`, `Copy code` and `Revoke`. `Share` opens the panel with the link and its QR code.
final class PairingLinkRowView: DSView, SettingsGroupRow {
    private let dot = StatusDotView()
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let expires = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let separator = LabelView(" · ", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let scopes = ScopeSummaryLabel()
    private let note = TextBlockView()
    private let share = ButtonView("Share", icon: .qrCode, variant: .outline, size: .xs)
    private let copyCode = ButtonView("Copy code", variant: .outline, size: .xs)
    private let revoke = ButtonView("Revoke", variant: .destructiveOutline, size: .xs)
    private let panel = SharePanel()
    private let panelRule = CALayer()
    private var expiresTip: TooltipController?
    private var link: ConnectionsPageModel.Access.PairingLink?
    var sharing = false { didSet { panel.isHidden = !sharing; share.setAccessibilityExpanded(sharing); needsLayout = true } }
    var onRevoke: (() -> Void)?
    var onShare: (() -> Void)?
    var onCopy: ((String, String, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 20
        title.truncates = true
        expires.lineHeight = 16
        separator.lineHeight = 16
        note.font = DSFont.ui(11)
        note.lineHeight = 16
        note.color = Themed.color(\.mutedForeground, 0.7)
        share.iconSize = 14
        panel.isHidden = true
        panelRule.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(panelRule)
        for v in [dot, title, expires, separator, scopes, note, share, copyCode, revoke, panel] as [NSView] { addSubview(v) }
        dot.tone = .warning
        share.action = { [weak self] in self?.onShare?() }
        revoke.action = { [weak self] in self?.onRevoke?() }
        copyCode.action = { [weak self] in self?.copyCodeNow() }
        panel.onCopyLink = { [weak self] in
            guard let url = self?.link?.shareURL else { return }
            self?.onCopy?(url, "Pairing URL copied", "Open it in the client you want to pair to this environment.")
        }
        panel.onCopyCode = { [weak self] in self?.copyCodeNow() }
    }

    private func copyCodeNow() {
        guard let code = link?.credential else { return }
        onCopy?(code, "Pairing code copied", "Paste it into another client to finish pairing.")
    }

    func configure(_ l: ConnectionsPageModel.Access.PairingLink, canRevoke: Bool) {
        link = l
        dot.tooltip = l.createdTooltip
        title.text = l.label
        expires.text = l.expires
        if let expiresTip { expiresTip.text = l.expiresAbsolute } else {
            expiresTip = TooltipController.attach(to: expires, text: l.expiresAbsolute, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        }
        scopes.configure(scopes: l.scopes, label: "Pairing link scopes")
        if l.credential == nil {
            note.text = "Create a new link to share from this client."
            note.isHidden = false
        } else if l.shareURL == nil {
            note.text = "Copy the token and pair from another client using this backend's reachable host."
            note.isHidden = false
        } else {
            note.isHidden = true
        }
        share.isHidden = l.shareURL == nil
        copyCode.isHidden = l.credential == nil || l.shareURL != nil
        revoke.title = l.revoking ? "Revoking…" : "Revoke"
        revoke.isEnabled = canRevoke && !l.revoking
        if let url = l.shareURL { panel.configure(url: url, qr: l.qrShareable) }
        needsLayout = true
    }

    private var textHeight: CGFloat { 20 + 4 + 16 + (note.isHidden ? 0 : 4 + 16) }

    func height(forWidth width: CGFloat) -> CGFloat {
        12 + max(textHeight, 24) + (sharing ? 12 + 1 + 12 + panel.height(forWidth: width - 32) : 0) + 12
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let top: CGFloat = 12
        let rowH = max(textHeight, 24)
        var x = w - 16
        for b in [revoke, copyCode, share] where !b.isHidden {
            let s = b.intrinsicContentSize
            x -= s.width
            b.frame = NSRect(x: x, y: top + (rowH - s.height) / 2, width: s.width, height: s.height)
            x -= 8
        }
        let textW = max(0, x - 12 - 16)
        let ty = top + (rowH - textHeight) / 2
        dot.frame = NSRect(x: 16, y: ty + 4, width: 12, height: 12)
        title.frame = NSRect(x: 16 + 12 + 6, y: ty, width: max(0, textW - 18), height: 20)
        let ew = ceil(expires.textWidth) + 1
        expires.frame = NSRect(x: 16, y: ty + 24, width: ew, height: 16)
        let sw = ceil(separator.textWidth)
        separator.frame = NSRect(x: 16 + ew, y: ty + 24, width: sw, height: 16)
        scopes.frame = NSRect(x: 16 + ew + sw, y: ty + 24, width: scopes.intrinsicContentSize.width, height: 16)
        note.frame = NSRect(x: 16, y: ty + 44, width: textW, height: 16)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panelRule.isHidden = !sharing
        panelRule.frame = CGRect(x: 16, y: top + rowH + 12, width: w - 32, height: 1)
        CATransaction.commit()
        if sharing {
            panel.frame = NSRect(x: 16, y: top + rowH + 12 + 1 + 12, width: w - 32, height: panel.height(forWidth: w - 32))
        }
    }

    override func updateLayer() { panelRule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }

    /// The expanded share view: the URL with `Copy link`, `Copy code only`, and a 168pt QR code on white,
    /// or the loopback note in a 192pt box.
    final class SharePanel: DSView {
        private let urlBox = DSView()
        private let url = LabelView("", font: DSFont.mono(11), color: Themed.color(\.mutedForeground))
        private let copyLink = ButtonView("Copy link", variant: .ghost, size: .xs)
        private let copyCode = ButtonView("Copy code only", variant: .ghost, size: .xs)
        private let qrBox = DSView()
        private var qr: QRCodeView?
        private let loopback = TextBlockView()
        private var showsQR = false
        private var urlTip: TooltipController?
        var onCopyLink: (() -> Void)?
        var onCopyCode: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            url.lineHeight = 16
            url.truncates = true
            urlBox.layer?.cornerRadius = 8
            urlBox.layer?.borderWidth = 1
            urlBox.addSubview(url)
            urlBox.addSubview(copyLink)
            qrBox.layer?.cornerRadius = 12
            loopback.font = DSFont.ui(11)
            loopback.lineHeight = 16
            loopback.alignment = .center
            loopback.color = Themed.color(\.mutedForeground, 0.7)
            loopback.text = "No QR for this endpoint. Another device scanning a loopback link would dial itself; copy the URL for use on this machine instead."
            qrBox.addSubview(loopback)
            for v in [urlBox, copyCode, qrBox] as [NSView] { addSubview(v) }
            copyLink.action = { [weak self] in self?.onCopyLink?() }
            copyCode.action = { [weak self] in self?.onCopyCode?() }
        }

        func configure(url text: String, qr shareable: Bool) {
            url.text = text
            if let urlTip { urlTip.text = text } else { urlTip = TooltipController.attach(to: url, text: text, placement: PopupPlacement(side: .top, align: .center, sideOffset: 4)) }
            showsQR = shareable
            if shareable {
                if let qr { qr.value = text } else {
                    let v = QRCodeView(value: text, size: 168, level: .medium, marginSize: 1, title: "Pairing link — scan to open on another device")
                    qrBox.addSubview(v)
                    qr = v
                }
            } else {
                qr?.removeFromSuperview()
                qr = nil
            }
            loopback.isHidden = shareable
            needsDisplay = true
            needsLayout = true
        }

        func height(forWidth width: CGFloat) -> CGFloat { 192 }

        override func updateLayer() {
            urlBox.layer?.borderColor = Themed.color(\.border, 0.6).cgColor(in: self)
            urlBox.layer?.backgroundColor = Themed.color(\.muted, 0.3).cgColor(in: self)
            qrBox.layer?.backgroundColor = showsQR ? NSColor.white.cgColor : nil
            qrBox.layer?.borderWidth = showsQR ? 0 : 1
            qrBox.layer?.borderColor = Themed.color(\.border, 0.5).cgColor(in: self)
        }

        override func layout() {
            super.layout()
            let w = bounds.width
            // `sm:flex-row sm:justify-between gap-4`: the copy column, then the QR box.
            qrBox.frame = NSRect(x: w - 192, y: 0, width: 192, height: 192)
            qr?.frame = NSRect(x: 12, y: 12, width: 168, height: 168)
            let lh = loopback.height(forWidth: 160)
            loopback.frame = NSRect(x: 16, y: (192 - lh) / 2, width: 160, height: lh)
            let colW = max(0, w - 192 - 16)
            let cs = copyLink.intrinsicContentSize
            urlBox.frame = NSRect(x: 0, y: 0, width: colW, height: 6 + max(16, cs.height) + 6)
            copyLink.frame = NSRect(x: colW - 10 - cs.width, y: (urlBox.frame.height - cs.height) / 2, width: cs.width, height: cs.height)
            url.frame = NSRect(x: 10, y: (urlBox.frame.height - 16) / 2, width: max(0, colW - 20 - cs.width - 8), height: 16)
            let cc = copyCode.intrinsicContentSize
            copyCode.frame = NSRect(x: 0, y: urlBox.frame.maxY + 12, width: cc.width, height: cc.height)
        }
    }
}

/// `ConnectedClientListRow`: live or idle dot, label, `This device` chip, device info · scopes, `Revoke`.
final class ClientSessionRowView: DSView, SettingsGroupRow {
    private let dot = StatusDotView()
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let chip = ThisDeviceChip()
    private let info = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let scopes = ScopeSummaryLabel()
    private let revoke = ButtonView("Revoke", variant: .destructiveOutline, size: .xs)
    var onRevoke: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 20
        title.truncates = true
        info.lineHeight = 16
        info.truncates = true
        for v in [dot, title, chip, info, scopes, revoke] as [NSView] { addSubview(v) }
        revoke.action = { [weak self] in self?.onRevoke?() }
    }

    func configure(_ c: ConnectionsPageModel.Access.Client, canRevoke: Bool) {
        dot.tone = c.live ? .success : .idle
        dot.pings = c.live // ConnectionsSettings.tsx:987-991
        dot.tooltip = c.statusTooltip
        title.text = c.label
        chip.isHidden = !c.current
        info.text = c.info.map { $0 + " · " } ?? ""
        scopes.configure(scopes: c.scopes, label: "Client scopes")
        revoke.isHidden = c.current
        revoke.title = c.revoking ? "Revoking…" : "Revoke"
        revoke.isEnabled = canRevoke && !c.revoking
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 12 + 40 + 12 }

    override func layout() {
        super.layout()
        let w = bounds.width
        var right = w - 16
        if !revoke.isHidden {
            let s = revoke.intrinsicContentSize
            revoke.frame = NSRect(x: w - 16 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            right = revoke.frame.minX - 12
        }
        dot.frame = NSRect(x: 16, y: 12 + 4, width: 12, height: 12)
        let tw = min(ceil(title.textWidth) + 1, max(0, right - 34 - (chip.isHidden ? 0 : chip.intrinsicContentSize.width + 6)))
        title.frame = NSRect(x: 34, y: 12, width: tw, height: 20)
        let cs = chip.intrinsicContentSize
        chip.frame = NSRect(x: title.frame.maxX + 6, y: 12 + (20 - cs.height) / 2, width: cs.width, height: cs.height)
        let iw = min(ceil(info.textWidth) + 1, max(0, right - 16 - scopes.intrinsicContentSize.width))
        info.frame = NSRect(x: 16, y: 36, width: iw, height: 16)
        scopes.frame = NSRect(x: 16 + iw, y: 36, width: scopes.intrinsicContentSize.width, height: 16)
    }

    /// `text-3xs text-muted-foreground/80 rounded-md border border-border/50 bg-muted/50 px-1 py-0.5`.
    final class ThisDeviceChip: DSView {
        private let text = LabelView("This device", font: DSFont.ui(10), color: Themed.color(\.mutedForeground, 0.8))
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            text.lineHeight = 14
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            addSubview(text)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.textWidth) + 8 + 2, height: 14 + 4 + 2) }
        override func updateLayer() {
            layer?.borderColor = Themed.color(\.border, 0.5).cgColor(in: self)
            layer?.backgroundColor = Themed.color(\.muted, 0.5).cgColor(in: self)
        }
        override func layout() { super.layout(); text.frame = NSRect(x: 5, y: 3, width: bounds.width - 10, height: 14) }
    }
}

/// "Create pairing link" (`AuthorizedClientsHeaderAction`): optional label, the permission presets and
/// checkboxes limited to what this session may delegate, the warnings, then Cancel and Create link.
public enum CreatePairingLinkDialog {
    @MainActor
    public static func make(delegatable: [String]) -> (dialog: DialogView, form: CreatePairingLinkFormView, cancel: ButtonView, create: ButtonView) {
        let dialog = DialogView(title: "Create pairing link",
                                message: "Generate a one-time link that another device can use to pair with this backend as an authorized client.")
        dialog.maxWidth = 448
        let form = CreatePairingLinkFormView(delegatable: delegatable)
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        let create = ButtonView("Create link", variant: .default)
        dialog.footerButtons = [cancel, create]
        dialog.footerVariant = .bare
        form.onChange = { [weak create, weak form] in
            guard let form else { return }
            create?.isEnabled = !form.isCreating && !form.selected.isEmpty
            create?.title = form.isCreating ? "Creating…" : "Create link"
            cancel.isEnabled = !form.isCreating
        }
        return (dialog, form, cancel, create)
    }
}

public final class CreatePairingLinkFormView: DSView {
    public let labelInput = InputView(placeholder: "e.g. Living room iPad")
    private let labelTitle = LabelView("Client label (optional)", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let permTitle = LabelView("Permissions", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let permDetail = LabelView("Limit what the paired client can do.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let readOnly = ButtonView("Read only", variant: .outline, size: .xs)
    private let standard = ButtonView("Standard", variant: .outline, size: .xs)
    private let list = BoxView()
    private var rows: [(scope: String, box: CheckboxView, title: LabelView, detail: TextBlockView, hit: ControlView)] = []
    private var dividers: [CALayer] = []
    private let warning = TextBlockView()
    private let delegatable: [String]
    public private(set) var selection: [String]
    /// The checked scopes this session may delegate (`selectedScopes`).
    public var selected: [String] { selection.filter { delegatable.contains($0) } }
    public var isCreating = false { didSet { apply() } }
    var onChange: (() -> Void)?
    public var onHeightChange: (() -> Void)?

    init(delegatable: [String]) {
        self.delegatable = delegatable
        selection = AuthScopes.standard
        super.init(frame: .zero)
        labelTitle.lineHeight = 16
        permTitle.lineHeight = 16
        permDetail.lineHeight = 16
        var box = BoxStyle()
        box.radius = 8
        box.border = Themed.color(\.input)
        box.fill = Themed.color(\.muted, 0.25)
        list.boxStyle = box
        warning.font = DSFont.ui(12)
        warning.lineHeight = 16
        for v in [labelTitle, labelInput, permTitle, permDetail, readOnly, standard, list, warning] as [NSView] { addSubview(v) }
        for option in AuthScopes.options where delegatable.contains(option.scope) {
            let cb = CheckboxView()
            let t = LabelView(option.title, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
            t.lineHeight = 16
            let d = TextBlockView()
            d.text = option.description
            d.font = DSFont.ui(12)
            d.lineHeight = 16.5
            d.color = Themed.color(\.mutedForeground)
            let hit = HoverFillControl(fill: Themed.color(\.muted, 0.4)) // hover:bg-muted/40 (ConnectionsSettings.tsx:1186)
            let scope = option.scope
            hit.action = { [weak self] in self?.toggle(scope) }
            cb.onChange = { [weak self] _ in self?.toggle(scope) }
            for v in [hit, cb, t, d] as [NSView] { list.addSubview(v) }
            rows.append((scope, cb, t, d, hit))
        }
        while dividers.count < max(0, rows.count - 1) {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull()]
            list.layer?.addSublayer(l)
            dividers.append(l)
        }
        readOnly.action = { [weak self] in self?.setSelection(AuthScopes.readOnly) }
        standard.action = { [weak self] in self?.setSelection(AuthScopes.standard) }
        apply()
    }

    private func toggle(_ scope: String) {
        guard !isCreating else { return }
        selection = AuthScopes.toggle(selection, scope, !selection.contains(scope))
        apply()
    }

    private func setSelection(_ scopes: [String]) {
        selection = scopes.filter { delegatable.contains($0) }
        apply()
    }

    private func apply() {
        for r in rows { r.box.value = selection.contains(r.scope) ? .on : .off; r.box.isEnabled = !isCreating }
        labelInput.isEnabled = !isCreating
        readOnly.isEnabled = !isCreating
        standard.isEnabled = !isCreating
        if selected.isEmpty {
            warning.text = "Select at least one permission."
            warning.color = Themed.color(\.destructive)
            warning.isHidden = false
        } else if selected.contains(AuthScopes.accessWrite) {
            warning.text = "This client can create or revoke access for other devices."
            warning.color = Themed.color(\.warning)
            warning.isHidden = false
        } else {
            warning.isHidden = true
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
        onChange?()
        onHeightChange?()
    }

    public override func updateLayer() {
        let c = Themed.color(\.border, 0.6).cgColor(in: self)
        dividers.forEach { $0.backgroundColor = c }
    }

    private func rowHeight(_ r: (scope: String, box: CheckboxView, title: LabelView, detail: TextBlockView, hit: ControlView), width: CGFloat) -> CGFloat {
        10 + 16 + r.detail.height(forWidth: width - 54) + 10
    }

    private func listHeight(_ width: CGFloat) -> CGFloat {
        2 + rows.reduce(0) { $0 + rowHeight($1, width: width) } + CGFloat(max(0, rows.count - 1))
    }

    /// `block` label then input, `space-y-4`, the Permissions section `space-y-3`.
    public func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 16 + 6 + 32 + 16
        h += 32 + 12 + listHeight(width)
        if !warning.isHidden { h += 12 + warning.height(forWidth: width) }
        return h
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width
        labelTitle.frame = NSRect(x: 0, y: 0, width: w, height: 16)
        labelInput.frame = NSRect(x: 0, y: 22, width: w, height: 32)
        var y: CGFloat = 22 + 32 + 16
        // `flex items-center justify-between gap-3`: title and detail, then the two presets.
        let so = standard.intrinsicContentSize, ro = readOnly.intrinsicContentSize
        standard.frame = NSRect(x: w - so.width, y: y + (32 - so.height) / 2, width: so.width, height: so.height)
        readOnly.frame = NSRect(x: standard.frame.minX - 4 - ro.width, y: y + (32 - ro.height) / 2, width: ro.width, height: ro.height)
        permTitle.frame = NSRect(x: 0, y: y, width: readOnly.frame.minX - 12, height: 16)
        permDetail.frame = NSRect(x: 0, y: y + 16, width: readOnly.frame.minX - 12, height: 16)
        y += 32 + 12
        let lh = listHeight(w)
        list.frame = NSRect(x: 0, y: y, width: w, height: lh)
        var ry: CGFloat = 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, r) in rows.enumerated() {
            if i > 0 { dividers[i - 1].frame = CGRect(x: 1, y: ry, width: w - 2, height: 1); ry += 1 }
            let h = rowHeight(r, width: w)
            r.hit.frame = NSRect(x: 1, y: ry, width: w - 2, height: h)
            r.box.frame = NSRect(x: 13, y: ry + 10 + 2, width: 16, height: 16)
            r.title.frame = NSRect(x: 41, y: ry + 10, width: w - 54, height: 16)
            r.detail.frame = NSRect(x: 41, y: ry + 26, width: w - 54, height: r.detail.height(forWidth: w - 54))
            ry += h
        }
        CATransaction.commit()
        y += lh
        if !warning.isHidden { warning.frame = NSRect(x: 0, y: y + 12, width: w, height: warning.height(forWidth: w)) }
    }
}
