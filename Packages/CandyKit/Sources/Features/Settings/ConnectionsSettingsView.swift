import AppKit
import DesignSystem

/// What Settings > Connections shows. The app fills it from its environments; strings are final.
public struct ConnectionsPageModel: Equatable {
    /// "This machine": the local (primary) environment (ConnectionsSettings.tsx:3609-3734). Rows in T3
    /// desktop's order: Local environment, Version, Network access, Tailscale HTTPS, the T3 Connect rows,
    /// then the Permissions disclosure.
    public struct Machine: Equatable {
        public var label: String
        public var machine: String
        public var rows: [HostRow]
        public var permissions: Permissions?
        /// The header's ⋯ menu (`More actions for this machine`) with the Icon submenu.
        public var iconMenu: IconMenu?
        public init(label: String, machine: String, rows: [HostRow], permissions: Permissions? = nil, iconMenu: IconMenu? = nil) {
            self.label = label; self.machine = machine; self.rows = rows; self.permissions = permissions; self.iconMenu = iconMenu
        }
        /// Only the Version row (`<serverVersion> · <displayUrl>`, or "Loading…").
        public init(label: String, machine: String, versionLine: String, upToDate: Bool) {
            self.init(label: label, machine: machine, rows: [.version(versionLine, upToDate: upToDate)])
        }
    }

    public struct Route: Equatable {
        public var url: URL
        public var label: String
        public var address: String
        public var inUse: Bool
        public init(url: URL, label: String, address: String, inUse: Bool) {
            self.url = url; self.label = label; self.address = address; self.inUse = inUse
        }
    }

    /// One saved machine (`SavedBackendListRow`).
    public struct Environment: Equatable {
        public var id: String
        public var label: String
        public var machine: String
        public var enabled: Bool
        public var unsupported: Bool
        /// `<transport> · <status>`.
        public var subtitle: String
        public var statusIsError: Bool
        public var tooltip: String
        public var routes: [Route]
        public var traceId: String?
        public var mcpURL: String?
        public var removing: Bool
        /// The `Permissions` disclosure's panel (`SessionPermissions` with `routeContext`).
        public var permissions: Permissions
        public var iconMenu: IconMenu?
        public init(id: String, label: String, machine: String, enabled: Bool, unsupported: Bool = false, subtitle: String,
                    statusIsError: Bool, tooltip: String, routes: [Route], traceId: String? = nil, mcpURL: String? = nil, removing: Bool = false,
                    permissions: Permissions = Permissions(routeContext: true, grants: nil), iconMenu: IconMenu? = nil) {
            self.id = id; self.label = label; self.machine = machine; self.enabled = enabled; self.unsupported = unsupported
            self.subtitle = subtitle; self.statusIsError = statusIsError; self.tooltip = tooltip; self.routes = routes
            self.traceId = traceId; self.mcpURL = mcpURL; self.removing = removing; self.permissions = permissions; self.iconMenu = iconMenu
        }
    }

    /// One machine from the T3 Connect account that is not saved here (`CloudEnvironmentConnectRows`).
    public struct CloudMachine: Equatable {
        public enum Dot: Equatable { case success, warning, destructive, idle }
        public enum Action: Equatable {
            /// `Add`, or `Add route` for a machine saved over another route.
            case add(String)
            case adding
            /// Disabled `Add` with the reason as tooltip (client not supported).
            case unsupported(String)
        }
        public var id: String
        public var label: String
        public var machine: String
        /// `T3 Connect · Not added · Relay online`, or the offline reason.
        public var status: String
        public var statusIsError: Bool
        public var dot: Dot
        public var dotTooltip: String
        public var action: Action
        public init(id: String, label: String, machine: String, status: String, statusIsError: Bool, dot: Dot, dotTooltip: String, action: Action) {
            self.id = id; self.label = label; self.machine = machine; self.status = status; self.statusIsError = statusIsError
            self.dot = dot; self.dotTooltip = dotTooltip; self.action = action
        }
    }

    /// T3 Connect discovery for the signed-in account.
    public enum Cloud: Equatable {
        /// Signed out, or no cloud config: no rows.
        case idle
        case loading
        case machines([CloudMachine])
        /// `Could not load T3 Connect environments` with the reason.
        case failed(String)
    }

    public var thisMachine: Machine?
    /// "Authorized clients", shown with `access:read` or `access:write` on this machine.
    public var access: Access?
    public var environments: [Environment]
    /// T3 Connect configured: the empty state mentions connecting from it.
    public var cloudEnabled: Bool
    public var cloud: Cloud = .idle
    /// Load balancing, with two or more machines switched on.
    public var loadBalancing: LoadBalancing?

    public init(thisMachine: Machine? = nil, environments: [Environment] = [], cloudEnabled: Bool = true) {
        self.thisMachine = thisMachine; self.environments = environments; self.cloudEnabled = cloudEnabled
    }
}

/// What the Connections page asks the app to do.
@MainActor
public struct ConnectionsActions {
    public var addEnvironment: () -> Void = {}
    public var addRoute: (String) -> Void = { _ in }
    public var setEnabled: (String, Bool) -> Void = { _, _ in }
    public var remove: (String) -> Void = { _ in }
    public var removeRoute: (String, ConnectionsPageModel.Route) -> Void = { _, _ in }
    /// Copies text and shows T3's toast: (text, toast title, toast description).
    public var copy: (String, String, String) -> Void = { _, _, _ in }
    /// The same for a pairing credential, which clipboard managers should skip.
    public var copySecret: (String, String, String) -> Void = { _, _, _ in }

    /// Puts `text` on the pasteboard with the nspasteboard.org concealed and transient markers, which
    /// clipboard managers read as "don't record this".
    @MainActor
    public static func copySecret(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.setString("", forType: .init("org.nspasteboard.TransientType"))
    }
    /// A T3 Connect row's `Add` or `Add route`.
    public var addCloud: (String) -> Void = { _ in }
    /// `Try again` after a failed discovery.
    public var retryCloud: () -> Void = {}
    /// A "This machine" switch changed: (row id, on).
    public var setHostSwitch: (String, Bool) -> Void = { _, _ in }
    /// The Icon submenu picked a kind: (environment id, kind).
    public var setIcon: (String, String) -> Void = { _, _ in }
    /// A route was dragged to a new place: (environment id, routes preferred first).
    public var reorderRoutes: (String, [URL]) -> Void = { _, _ in }
    public var createPairingLink: () -> Void = {}
    public var revokePairingLink: (String) -> Void = { _ in }
    public var revokeClient: (String) -> Void = { _ in }
    public var revokeOtherClients: () -> Void = {}
    /// Load balancing switched on or off, and one machine's preference weight.
    public var setLoadBalancing: (Bool) -> Void = { _ in }
    public var setLoadPreference: (String, Int) -> Void = { _, _ in }
    public init() {}
}

/// Settings > Connections (ConnectionsSettings.tsx `ConnectionsSettings`): "This machine", then
/// "Environments" with one row per saved machine or the empty state.
public final class ConnectionsSettingsView: DSView, SettingsGroupRow {
    public var actions = ConnectionsActions()
    public private(set) var model = ConnectionsPageModel()
    private(set) var machineSection: SettingsSectionView?
    private var hostRows: [String: SettingsRowView] = [:]
    private lazy var machineMore: ButtonView = {
        let b = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs).menuTrigger()
        b.iconSize = 14
        b.setAccessibilityLabel("More actions for this machine")
        b.action = { [weak self, weak b] in
            guard let self, let b, let menu = self.model.thisMachine?.iconMenu, let id = self.primaryId else { return }
            let item = Self.iconMenuItem(menu) { [weak self] kind in self?.actions.setIcon(id, kind) }
            MenuPopupView.show([item], from: b, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4))
        }
        return b
    }()
    private lazy var machinePermissions: PermissionsDisclosureRow = {
        let row = PermissionsDisclosureRow()
        row.onHeightChange = { [weak self] in self?.relayout() }
        return row
    }()
    private(set) lazy var accessSection: AuthorizedClientsSectionView = {
        let section = AuthorizedClientsSectionView()
        section.onHeightChange = { [weak self] in self?.relayout() }
        return section
    }()
    private(set) lazy var loadBalancingSection: LoadBalancingSectionView = {
        let section = LoadBalancingSectionView()
        section.onHeightChange = { [weak self] in self?.relayout() }
        return section
    }()
    /// The primary environment's id, for the Icon submenu of This machine.
    public var primaryId: String?
    private var openPermissions: Set<String> = []
    private let environmentsSection: SettingsSectionView
    private let addButton = ButtonView("Add environment", icon: .plus, variant: .ghostMuted, size: .xs)
    private var rows: [String: EnvironmentRowView] = [:]
    private var openRoutes: Set<String> = []
    private var empty: (message: String, view: EmptyView)?
    private var cloudRows: [String: CloudMachineRowView] = [:]
    private lazy var cloudSkeleton = CloudSkeletonRowView()
    private lazy var cloudFailure = CloudFailureRowView()
    /// After a change of height, for the page to lay out again.
    public var onHeightChange: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        environmentsSection = SettingsSectionView(title: "Environments", rows: [])
        super.init(frame: frameRect)
        addButton.iconSize = 12
        addButton.setAccessibilityLabel("Add environment")
        let tip = TooltipController.attach(to: addButton, text: "Add environment")
        addButton.action = { [weak self, weak tip] in
            tip?.hide()
            self?.actions.addEnvironment()
        }
        environmentsSection.headerAction = addButton
        addSubview(environmentsSection)
        set(model)
    }

    public func set(_ model: ConnectionsPageModel) {
        self.model = model
        // This machine.
        if let m = model.thisMachine {
            let section = machineSection ?? SettingsSectionView(title: m.label, rows: [])
            if machineSection == nil {
                machineSection = section
                addSubview(section)
            }
            section.title = m.label
            let glyph = (section.icon as? EnvironmentMachineGlyphView) ?? EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            glyph.color = Themed.color(\.foreground, 0.7)
            glyph.kind = m.machine
            if section.icon !== glyph { section.icon = glyph }
            section.headerAction = m.iconMenu == nil ? nil : machineMore
            var next: [String: SettingsRowView] = [:]
            var rows: [any SettingsGroupRow] = []
            for r in m.rows {
                let row = hostRows[r.id] ?? SettingsRowView(title: r.title)
                configure(row, r)
                next[r.id] = row
                rows.append(row)
            }
            hostRows = next
            if let p = m.permissions {
                machinePermissions.panel.configure(p)
                rows.append(machinePermissions)
            }
            section.group.rows = rows
        } else {
            machineSection?.removeFromSuperview()
            machineSection = nil
        }
        // Authorized clients, between This machine and Environments.
        if let access = model.access {
            if accessSection.superview == nil { addSubview(accessSection) }
            accessSection.actions = actions
            accessSection.configure(access)
        } else if accessSection.superview != nil {
            accessSection.removeFromSuperview()
        }
        // Environments, in catalog order.
        var next: [String: EnvironmentRowView] = [:]
        var groupRows: [any SettingsGroupRow] = []
        for env in model.environments {
            let row = rows[env.id] ?? EnvironmentRowView()
            row.routesOpen = openRoutes.contains(env.id)
            row.permissionsOpen = openPermissions.contains(env.id)
            row.configure(env)
            wire(row, env)
            next[env.id] = row
            groupRows.append(row)
        }
        rows = next
        openRoutes = openRoutes.filter { next[$0] != nil }
        openPermissions = openPermissions.filter { next[$0] != nil }
        // The T3 Connect rows (`CloudRemoteEnvironmentRows`) follow the saved ones. With nothing saved
        // they stand alone: a skeleton while loading, the failure, or the empty state.
        var nextCloud: [String: CloudMachineRowView] = [:]
        let standalone = model.environments.isEmpty
        var machines: [ConnectionsPageModel.CloudMachine] = []
        if case .machines(let list) = model.cloud { machines = list }
        for machine in machines {
            let row = cloudRows[machine.id] ?? CloudMachineRowView()
            row.configure(machine)
            let id = machine.id
            row.onAdd = { [weak self] in self?.actions.addCloud(id) }
            nextCloud[id] = row
            groupRows.append(row)
        }
        cloudRows = nextCloud
        if standalone, machines.isEmpty, model.cloud == .loading {
            groupRows.append(cloudSkeleton)
        } else if standalone, machines.isEmpty, case .failed(let reason) = model.cloud {
            cloudFailure.reason = reason
            cloudFailure.onRetry = { [weak self] in self?.actions.retryCloud() }
            groupRows.append(cloudFailure)
        } else if standalone, machines.isEmpty {
            let message = model.cloudEnabled
                ? "Click “Add environment” to pair another environment, or connect one from T3 Connect."
                : "Click “Add environment” to pair another environment."
            if empty?.message != message {
                let view = EmptyView(title: "No saved remote environments", message: message, icon: .chevronsLeftRightEllipsis)
                view.minimumHeight = 208  // `min-h-52`
                empty = (message, view)
            }
            groupRows.append(empty!.view)
        }
        environmentsSection.group.rows = groupRows
        // Load balancing, under the environments list (ConnectionsSettings.tsx:4169).
        if let balancing = model.loadBalancing {
            if loadBalancingSection.superview == nil { addSubview(loadBalancingSection) }
            loadBalancingSection.onEnabled = { [weak self] on in self?.actions.setLoadBalancing(on) }
            loadBalancingSection.onPreference = { [weak self] id, weight in self?.actions.setLoadPreference(id, weight) }
            loadBalancingSection.configure(balancing)
        } else if loadBalancingSection.superview != nil {
            loadBalancingSection.removeFromSuperview()
        }
        needsLayout = true
        onHeightChange?()
    }

    private func configure(_ row: SettingsRowView, _ r: ConnectionsPageModel.HostRow) {
        row.title = r.title
        row.detail = r.detail
        row.status = r.status
        row.statusIsError = r.statusIsError
        switch r.control {
        case .none:
            row.control = nil
        case .text(let text):
            let label = (row.control as? LabelView) ?? LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            label.lineHeight = 16
            label.text = text
            label.frame.size = NSSize(width: ceil(label.textWidth) + 1, height: 16)
            if row.control !== label { row.control = label }
        case .copyCommand(let command):
            let button = ButtonView("Copy relaunch command", variant: .outline, size: .xs)
            button.action = { [weak self] in self?.actions.copy(command, "Relaunch command copied", "Stop t3 on that machine, then relaunch with the same subcommand and options.") }
            row.control = button
        case .toggle(let s):
            let view = (row.control as? HostSwitchView) ?? HostSwitchView()
            view.configure(s)
            let id = r.id
            view.onChange = { [weak self] on in self?.actions.setHostSwitch(id, on) }
            if row.control !== view { row.control = view }
        }
        row.needsLayout = true
    }

    private func relayout() {
        needsLayout = true
        onHeightChange?()
    }

    private func wire(_ row: EnvironmentRowView, _ env: ConnectionsPageModel.Environment) {
        let id = env.id
        row.onToggleRoutes = { [weak self] in self?.toggleRoutes(id) }
        row.onTogglePermissions = { [weak self] in self?.togglePermissions(id) }
        row.onReorder = { [weak self] urls in self?.actions.reorderRoutes(id, urls) }
        row.onSwitch = { [weak self] on in self?.actions.setEnabled(id, on) }
        row.onAddRoute = { [weak self] in self?.actions.addRoute(id) }
        row.onRemoveRoute = { [weak self] route in self?.actions.removeRoute(id, route) }
        row.menuItems = { [weak self] in
            guard let self, let env = self.model.environments.first(where: { $0.id == id }) else { return [] }
            var items: [MenuItem] = []
            if let menu = env.iconMenu {
                items.append(Self.iconMenuItem(menu) { [weak self] kind in self?.actions.setIcon(id, kind) })
            }
            items.append(MenuItem(self.openRoutes.contains(id) ? "Hide routes" : "Routes", icon: .route, action: { [weak row] in
                row?.onToggleRoutes?()
            }))
            if let url = env.mcpURL {
                items.append(MenuItem("Copy MCP URL", action: { [weak self] in
                    self?.actions.copy(url, "MCP URL copied", "Add it to an agent, e.g. claude mcp add --transport http t3 \(url)")
                }))
            }
            if let trace = env.traceId {
                items.append(MenuItem("Copy trace ID", action: { [weak self] in self?.actions.copy(trace, "Trace ID copied", trace) }))
            }
            items.append(.separator)
            items.append(MenuItem(env.removing ? "Removing…" : "Remove from this device…", destructive: true,
                                  action: { [weak self] in self?.actions.remove(id) }))
            return items
        }
    }

    func toggleRoutes(_ id: String) {
        if openRoutes.contains(id) { openRoutes.remove(id) } else { openRoutes.insert(id) }
        set(model)
    }

    func togglePermissions(_ id: String) {
        if openPermissions.contains(id) { openPermissions.remove(id) } else { openPermissions.insert(id) }
        set(model)
    }

    /// Opens the folded parts for a reference capture.
    func open(permissions: Bool = false, access: Bool = false) {
        if permissions { machinePermissions.isOpen = true }
        if access { accessSection.isOpen = true }
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if let machineSection { h += machineSection.height(forWidth: width) + 32 }
        if accessSection.superview != nil { h += accessSection.height(forWidth: width) + 32 }
        h += environmentsSection.height(forWidth: width)
        if loadBalancingSection.superview != nil { h += 32 + loadBalancingSection.height(forWidth: width) }
        return h
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let machineSection {
            let h = machineSection.height(forWidth: bounds.width)
            machineSection.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            machineSection.needsLayout = true
            machineSection.group.needsLayout = true
            y += h + 32
        }
        if accessSection.superview != nil {
            let h = accessSection.height(forWidth: bounds.width)
            accessSection.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 32
        }
        let eh = environmentsSection.height(forWidth: bounds.width)
        environmentsSection.frame = NSRect(x: 0, y: y, width: bounds.width, height: eh)
        if loadBalancingSection.superview != nil {
            loadBalancingSection.frame = NSRect(x: 0, y: y + eh + 32, width: bounds.width, height: loadBalancingSection.height(forWidth: bounds.width))
        }
    }
}

extension EmptyView: SettingsGroupRow {}

/// A T3 Connect machine that is not saved (CloudEnvironmentConnectList.tsx:420-470): status dot, glyph and
/// name, the status line, and `Add` on the right. `px-4 py-3`.
// ponytail: the dot doesn't ping while checking; add the `animate-status-ping` ring if users miss it
final class CloudMachineRowView: DSView, SettingsGroupRow {
    private let dot = CALayer()
    private let dotHit = DSView()
    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let add = ButtonView("Add", variant: .default, size: .sm)
    private var dotTip: TooltipController?
    private var addTip: TooltipController?
    private var dotKind: ConnectionsPageModel.CloudMachine.Dot = .idle
    var onAdd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        dot.cornerRadius = 4
        layer?.addSublayer(dot)
        glyph.color = Themed.color(\.mutedForeground)
        title.lineHeight = 20
        title.truncates = true
        status.lineHeight = 16
        status.truncates = true
        for v in [dotHit, glyph, title, status, add] as [NSView] { addSubview(v) }
        add.action = { [weak self] in self?.onAdd?() }
        dotTip = TooltipController.attach(to: dotHit, text: "")
    }

    func configure(_ m: ConnectionsPageModel.CloudMachine) {
        glyph.kind = m.machine
        title.text = m.label
        status.text = m.status
        status.color = m.statusIsError ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        dotTip?.text = m.dotTooltip
        dotHit.setAccessibilityLabel(m.dotTooltip)
        dotKind = m.dot
        switch m.action {
        case .add(let title):
            add.title = title
            add.isEnabled = true
        case .adding:
            add.title = "Adding…"
            add.isEnabled = false
        case .unsupported(let reason):
            add.title = "Add"
            add.isEnabled = false
            if addTip == nil { addTip = TooltipController.attach(to: add, text: reason) } else { addTip?.text = reason }
        }
        needsDisplay = true
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat { 12 + 20 + 4 + 16 + 12 }

    override func updateLayer() {
        let color: NSColor = switch dotKind {
        case .success: Themed.color(\.success)
        case .warning: Themed.color(\.warning)
        case .destructive: Themed.color(\.destructive)
        case .idle: Themed.color(\.mutedForeground, 0.35)
        }
        dot.backgroundColor = color.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let s = add.intrinsicContentSize
        add.frame = NSRect(x: w - 16 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let right = add.frame.minX - 12
        // `flex items-center gap-2`: the `size-3` dot box, the glyph, the name.
        dotHit.frame = NSRect(x: 16, y: 12 + 4, width: 12, height: 12)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 18, y: 12 + 6, width: 8, height: 8)
        CATransaction.commit()
        glyph.frame = NSRect(x: 36, y: 12 + 2, width: 16, height: 16)
        title.frame = NSRect(x: 60, y: 12, width: max(0, right - 60), height: 20)
        status.frame = NSRect(x: 16, y: 36, width: max(0, right - 16), height: 16)
    }
}

/// `RemoteEnvironmentRowsSkeleton`: two pills and a button-sized block while discovery runs.
final class CloudSkeletonRowView: DSView, SettingsGroupRow {
    private let name = SkeletonView(shape: .pill)
    private let line = SkeletonView(shape: .pill)
    private let button = SkeletonView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [name, line, button] { addSubview(v) }
    }

    func height(forWidth width: CGFloat) -> CGFloat { 12 + 16 + 8 + 12 + 12 }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: 16, y: 12, width: 128, height: 16)
        line.frame = NSRect(x: 16, y: 36, width: 80, height: 12)
        button.frame = NSRect(x: bounds.width - 16 - 64, y: (bounds.height - 28) / 2, width: 64, height: 28)
    }
}

/// A failed discovery (CloudEnvironmentConnectList.tsx:293-312), never shown as "no environments".
final class CloudFailureRowView: DSView, SettingsGroupRow {
    private let title = LabelView("Could not load T3 Connect environments", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.destructive))
    private let detail = TextBlockView()
    private let retry = ButtonView("Try again", variant: .outline, size: .sm)
    var onRetry: (() -> Void)?
    var reason = "" { didSet { detail.text = reason; needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineHeight = 20
        detail.font = DSFont.ui(12)
        detail.lineHeight = 16
        detail.color = Themed.color(\.mutedForeground)
        for v in [title, detail, retry] as [NSView] { addSubview(v) }
        retry.action = { [weak self] in self?.onRetry?() }
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        12 + 20 + 4 + detail.height(forWidth: max(0, width - 32)) + 12 + retry.intrinsicContentSize.height + 12
    }

    override func layout() {
        super.layout()
        let tw = max(0, bounds.width - 32)
        title.frame = NSRect(x: 16, y: 12, width: tw, height: 20)
        let dh = detail.height(forWidth: tw)
        detail.frame = NSRect(x: 16, y: 36, width: tw, height: dh)
        let s = retry.intrinsicContentSize
        retry.frame = NSRect(x: 16, y: 36 + dh + 12, width: s.width, height: s.height)
    }
}

/// One saved machine (`EnvironmentRow` in `SavedBackendListRow`): machine glyph, name, one subtitle line
/// (`<transport> · <status> · Routes · Permissions`), the on/off switch and the row menu; the route list
/// and the session's permissions open below.
final class EnvironmentRowView: DSView, SettingsGroupRow {
    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let dot = LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let dot2 = LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let routesButton = InlineDisclosureButton()
    let permissionsButton = InlineDisclosureButton()
    let toggle = SwitchView(size: .sm)
    let more = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs).menuTrigger()
    private let routesList = EnvironmentRoutesListView()
    private let permissionsRule = CALayer()
    private let permissions = SessionPermissionsView()
    private var statusTip: TooltipController?
    private var switchTip: TooltipController?
    private var isError = false

    var routesOpen = false { didSet { routesList.isHidden = !routesOpen; routesButton.isOpen = routesOpen; needsLayout = true } }
    var permissionsOpen = false {
        didSet { permissions.isHidden = !permissionsOpen; permissionsRule.isHidden = !permissionsOpen; permissionsButton.isOpen = permissionsOpen; needsLayout = true }
    }
    var onToggleRoutes: (() -> Void)?
    var onTogglePermissions: (() -> Void)?
    var onSwitch: ((Bool) -> Void)?
    var onAddRoute: (() -> Void)? { didSet { routesList.onAddRoute = onAddRoute } }
    var onRemoveRoute: ((ConnectionsPageModel.Route) -> Void)? { didSet { routesList.onRemove = onRemoveRoute } }
    var onReorder: (([URL]) -> Void)? { didSet { routesList.onReorder = onReorder } }
    var menuItems: (() -> [MenuItem])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.color = Themed.color(\.mutedForeground)
        title.lineHeight = 20
        status.lineHeight = 16
        dot.lineHeight = 16
        dot2.lineHeight = 16
        permissionsButton.title = "Permissions"
        for v in [glyph, title, status, dot, routesButton, dot2, permissionsButton, toggle, more, routesList, permissions] as [NSView] { addSubview(v) }
        permissionsRule.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(permissionsRule)
        routesList.isHidden = true
        permissions.isHidden = true
        permissionsRule.isHidden = true
        more.iconSize = 14
        routesButton.action = { [weak self] in self?.onToggleRoutes?() }
        permissionsButton.action = { [weak self] in self?.onTogglePermissions?() }
        toggle.onChange = { [weak self] on in self?.onSwitch?(on) }
        more.action = { [weak self] in
            guard let self, let items = self.menuItems?() else { return }
            MenuPopupView.show(items, from: self.more, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 4))
        }
        statusTip = TooltipController.attach(to: status, text: "", placement: PopupPlacement(side: .top, align: .center, sideOffset: 4))
        switchTip = TooltipController.attach(to: toggle, text: "")
    }

    func configure(_ env: ConnectionsPageModel.Environment) {
        glyph.kind = env.machine
        title.text = env.label
        status.text = env.subtitle
        isError = env.enabled && env.statusIsError
        status.color = isError ? Themed.color(\.destructive) : Themed.color(\.mutedForeground)
        statusTip?.text = env.tooltip
        routesButton.title = env.routes.count == 1 ? "Routes" : "\(env.routes.count) routes"
        toggle.isOn = env.enabled && !env.unsupported
        toggle.isEnabled = !env.removing && !env.unsupported
        toggle.setAccessibilityLabel("\(toggle.isOn ? "Switch off" : "Switch on") \(env.label)")
        switchTip?.text = env.unsupported ? "Client not supported" : toggle.isOn ? "Switch off" : "Switch on"
        more.isEnabled = !env.removing
        more.setAccessibilityLabel("More actions for \(env.label)")
        routesList.set(env.routes, label: env.label)
        permissions.configure(env.permissions)
        // `opacity-60` on the whole row while switched off.
        alphaValue = env.enabled && !env.unsupported ? 1 : 0.6
        needsLayout = true
    }

    /// The detail column (`col-span-2 col-start-2`): the text column plus the controls.
    private func detailWidth(_ width: CGFloat) -> CGFloat { max(0, width - 44 - 16) }

    /// `mt-2 border-t border-border/50` above `SessionPermissions`.
    private func permissionsHeight(_ width: CGFloat) -> CGFloat { permissionsOpen ? 8 + 1 + permissions.height(forWidth: detailWidth(width)) : 0 }

    /// `px-4 py-2.5`, the 36pt text column; the routes list spans the text and control columns.
    func height(forWidth width: CGFloat) -> CGFloat {
        10 + 36 + (routesOpen ? routesList.height(forWidth: detailWidth(width)) : 0) + permissionsHeight(width) + 10
    }

    override func updateLayer() { permissionsRule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }

    override func layout() {
        super.layout()
        let w = bounds.width
        let ts = toggle.intrinsicContentSize
        var x = w - 16 - 24
        more.frame = NSRect(x: x, y: 10 + (36 - 24) / 2, width: 24, height: 24)
        x -= 4 + ts.width
        toggle.frame = NSRect(x: x, y: 10 + (36 - ts.height) / 2, width: ts.width, height: ts.height)
        let textRight = x - 12
        glyph.frame = NSRect(x: 16, y: 10 + 10, width: 16, height: 16)
        let textX: CGFloat = 44
        let textWidth = max(0, textRight - textX)
        title.frame = NSRect(x: textX, y: 10, width: textWidth, height: 20)
        // `flex items-center gap-1`: the status truncates; the dots and both disclosures keep their size.
        let routesW = routesButton.intrinsicContentSize.width
        let permW = permissionsButton.intrinsicContentSize.width
        let dotW = ceil(dot.textWidth)
        let statusW = max(0, min(ceil(status.textWidth) + 1, textWidth - routesW - permW - 2 * dotW - 16))
        status.frame = NSRect(x: textX, y: 30, width: statusW, height: 16)
        dot.frame = NSRect(x: textX + statusW + 4, y: 30, width: dotW, height: 16)
        routesButton.frame = NSRect(x: dot.frame.maxX + 4, y: 30, width: routesW, height: 16)
        dot2.frame = NSRect(x: routesButton.frame.maxX + 4, y: 30, width: dotW, height: 16)
        permissionsButton.frame = NSRect(x: dot2.frame.maxX + 4, y: 30, width: permW, height: 16)
        let lw = detailWidth(w)
        var y: CGFloat = 46
        if routesOpen {
            let h = routesList.height(forWidth: lw)
            routesList.frame = NSRect(x: textX, y: y, width: lw, height: h)
            y += h
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        permissionsRule.frame = CGRect(x: textX, y: y + 8, width: lw, height: 1)
        CATransaction.commit()
        if permissionsOpen {
            permissions.frame = NSRect(x: textX, y: y + 9, width: lw, height: permissions.height(forWidth: lw))
        }
    }
}

/// The subtitle's "Routes" and "Permissions" toggles: muted text with a `size-3` chevron that turns down when open.
final class InlineDisclosureButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let chevron = IconView(name: .chevronRight, size: 12)
    var title: String { get { label.text } set { label.text = newValue; invalidateIntrinsicContentSize() } }
    /// `rotate-90` when open, `transition-transform duration-150` (ConnectionsSettings.tsx:1656-1681).
    var isOpen = false { didSet { chevron.setRotation(isOpen ? 90 : 0); setAccessibilityExpanded(isOpen) } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        label.lineHeight = 16
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.button)
        restyle()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.textWidth) + 2 + 12, height: 16) }

    override func stateDidChange(from old: State) { super.stateDidChange(from: old); restyle() }

    private func restyle() {
        let color = state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        label.color = color
        chevron.strokeColor = color
    }

    override func layout() {
        super.layout()
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: 0, y: 0, width: lw, height: 16)
        chevron.frame = NSRect(x: lw + 2, y: 2, width: 12, height: 12)
    }
}

/// `EnvironmentRoutesList`: the ways this client reaches one machine, preferred first, then "Add route".
/// Drag a row by its grip to reorder; the new order shows until the catalog matches it.
final class EnvironmentRoutesListView: DSView {
    private var routes: [ConnectionsPageModel.Route] = []
    private var rowViews: [RouteRow] = []
    private let border = CALayer()
    private let add = ButtonView("Add route", icon: .plus, variant: .ghostMuted, size: .xs)
    private var drag: (index: Int, offset: CGFloat)?
    /// The dropped order, kept until `set` brings the same order (`pending` in EnvironmentRoutesList.tsx).
    private var pending: [URL]?
    var onAddRoute: (() -> Void)?
    var onRemove: ((ConnectionsPageModel.Route) -> Void)?
    var onReorder: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        border.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(border)
        add.iconSize = 12
        add.action = { [weak self] in self?.onAddRoute?() }
        addSubview(add)
    }

    func set(_ saved: [ConnectionsPageModel.Route], label: String) {
        guard drag == nil else { return }
        var ordered = saved
        if let pending, pending.count == saved.count, pending != saved.map(\.url) {
            ordered = pending.compactMap { url in saved.first { $0.url == url } }
            if ordered.count != saved.count { ordered = saved; self.pending = nil }
        } else {
            pending = nil
        }
        routes = ordered
        rowViews.forEach { $0.removeFromSuperview() }
        // The last route goes with the machine ("Remove from this device"), so it has no remove button.
        rowViews = ordered.enumerated().map { i, route in
            let row = RouteRow(route, removable: ordered.count > 1, position: i + 1)
            row.remove.action = { [weak self] in self?.onRemove?(route) }
            row.grip.onDrag = { [weak self] phase, dy in self?.dragRow(i, phase, dy) }
            addSubview(row)
            return row
        }
        setAccessibilityLabel("Routes to \(label), preferred first")
        needsLayout = true
    }

    private func dragRow(_ index: Int, _ phase: GripHandle.Phase, _ dy: CGFloat) {
        switch phase {
        case .began:
            drag = (index, 0)
            rowViews[index].isDragging = true
        case .moved:
            // `restrictToVerticalAxis, restrictToParentElement`.
            let minY = -CGFloat(index) * RouteRow.height
            let maxY = CGFloat(rowViews.count - 1 - index) * RouteRow.height
            drag = (index, min(max(dy, minY), maxY))
        case .ended:
            let target = targetIndex()
            rowViews[index].isDragging = false
            drag = nil
            if target != index {
                var urls = routes.map(\.url)
                let moved = urls.remove(at: index)
                urls.insert(moved, at: target)
                pending = urls
                onReorder?(urls)
                set(routes, label: accessibilityLabel()?.replacingOccurrences(of: "Routes to ", with: "").replacingOccurrences(of: ", preferred first", with: "") ?? "")
            }
        }
        needsLayout = true
    }

    /// `closestCenter`: the slot nearest the dragged row's middle.
    private func targetIndex() -> Int {
        guard let drag else { return 0 }
        let center = CGFloat(drag.index) * RouteRow.height + drag.offset + RouteRow.height / 2
        return min(max(Int(center / RouteRow.height), 0), rowViews.count - 1)
    }

    /// `mt-2 border-t py-2`, rows of `py-2` text (16 + 16.5), then the `pt-1` button.
    func height(forWidth width: CGFloat) -> CGFloat {
        8 + 1 + 8 + CGFloat(routes.count) * RouteRow.height + 4 + 24 + 8
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: 8, width: bounds.width, height: 1)
        CATransaction.commit()
        let target = drag.map { _ in targetIndex() }
        for (i, row) in rowViews.enumerated() {
            var slot = CGFloat(i)
            if let drag, let target, i != drag.index {
                // Rows between the origin and the target shift by one (`verticalListSortingStrategy`).
                if drag.index < i, i <= target { slot -= 1 }
                if target <= i, i < drag.index { slot += 1 }
            }
            var y = 17 + slot * RouteRow.height
            if let drag, i == drag.index { y = 17 + CGFloat(i) * RouteRow.height + drag.offset }
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: RouteRow.height)
        }
        if let drag { addSubview(rowViews[drag.index], positioned: .above, relativeTo: nil) }
        let s = add.intrinsicContentSize
        add.frame = NSRect(x: -6, y: 17 + CGFloat(rowViews.count) * RouteRow.height + 4, width: s.width, height: s.height)
    }

    override func updateLayer() { border.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }

    /// The `GripVerticalIcon` button: `size-6`, `text-muted-foreground/70`, `cursor-grab`.
    final class GripHandle: ControlView {
        enum Phase { case began, moved, ended }
        private let icon = IconView(name: .gripVertical, size: 14)
        private var start: NSPoint?
        var onDrag: ((Phase, CGFloat) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            icon.strokeColor = Themed.color(\.mutedForeground, 0.7)
            addSubview(icon)
            setAccessibilityRole(.button)
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func stateDidChange(from old: State) {
            super.stateDidChange(from: old)
            icon.strokeColor = state.hovered ? Themed.color(\.foreground) : Themed.color(\.mutedForeground, 0.7)
        }
        override func layout() { super.layout(); icon.frame = NSRect(x: 5, y: 5, width: 14, height: 14) }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            NSCursor.closedHand.push()
            onDrag?(.began, 0)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            // Window coordinates grow upward; the list is flipped.
            onDrag?(.moved, start.y - event.locationInWindow.y)
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            NSCursor.pop()
            onDrag?(.ended, 0)
        }
    }

    final class RouteRow: DSView {
        static let height: CGFloat = 8 + 16 + 16.5 + 8
        private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
        private let chip = InUseChip()
        private let address = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
        let grip = GripHandle()
        let remove = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconXs)
        var isDragging = false {
            didSet {
                layer?.backgroundColor = isDragging ? Themed.color(\.background).cgColor(in: self) : nil
                layer?.cornerRadius = 6
                layer?.shadowOpacity = isDragging ? 0.12 : 0
                layer?.shadowRadius = 6
                layer?.shadowOffset = CGSize(width: 0, height: -2)
            }
        }

        init(_ route: ConnectionsPageModel.Route, removable: Bool, position: Int) {
            super.init(frame: .zero)
            label.text = route.label
            label.lineHeight = 16
            address.text = route.address
            address.lineHeight = 16.5
            address.truncates = true
            chip.isHidden = !route.inUse
            remove.iconSize = 12
            remove.isHidden = !removable
            remove.setAccessibilityLabel("Remove \(route.label) route")
            grip.setAccessibilityLabel("Reorder \(route.label), position \(position)")
            TooltipController.attach(to: remove, text: "Remove route")
            for v in [label, chip, address, grip, remove] as [NSView] { addSubview(v) }
        }

        override func layout() {
            super.layout()
            // `flex items-center gap-2`: text, the grip, the remove button.
            var right = bounds.width
            if !remove.isHidden {
                remove.frame = NSRect(x: right - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
                right -= 24 + 8
            }
            grip.frame = NSRect(x: right - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
            right -= 24 + 8
            let lw = min(ceil(label.textWidth) + 1, right)
            label.frame = NSRect(x: 0, y: 8, width: lw, height: 16)
            let cs = chip.intrinsicContentSize
            chip.frame = NSRect(x: lw + 6, y: 8 + (16 - cs.height) / 2, width: cs.width, height: cs.height)
            address.frame = NSRect(x: 0, y: 24, width: max(0, right), height: 16.5)
        }
    }

    /// `rounded-sm bg-success/12 px-1 text-2xs text-success-foreground`.
    final class InUseChip: DSView {
        private let text = LabelView("In use", font: DSFont.ui(11), color: Themed.color(\.successForeground))
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            text.lineHeight = 16.5
            layer?.cornerRadius = 4
            addSubview(text)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.textWidth) + 8, height: 16.5) }
        override func layout() { super.layout(); text.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: 16.5) }
        override func updateLayer() { layer?.backgroundColor = Themed.color(\.success, 0.12).cgColor(in: self) }
    }
}

