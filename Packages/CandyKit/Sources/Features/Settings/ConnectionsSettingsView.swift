import AppKit
import DesignSystem

/// What Settings > Connections shows. The app fills it from its environments; strings are final.
public struct ConnectionsPageModel: Equatable {
    /// "This machine": the local (primary) environment (ConnectionsSettings.tsx:3609-3713).
    public struct Machine: Equatable {
        public var label: String
        public var machine: String
        /// `<serverVersion> · <displayUrl>`, or "Loading…".
        public var versionLine: String
        public var upToDate: Bool
        public init(label: String, machine: String, versionLine: String, upToDate: Bool) {
            self.label = label; self.machine = machine; self.versionLine = versionLine; self.upToDate = upToDate
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
        public init(id: String, label: String, machine: String, enabled: Bool, unsupported: Bool = false, subtitle: String,
                    statusIsError: Bool, tooltip: String, routes: [Route], traceId: String? = nil, mcpURL: String? = nil, removing: Bool = false) {
            self.id = id; self.label = label; self.machine = machine; self.enabled = enabled; self.unsupported = unsupported
            self.subtitle = subtitle; self.statusIsError = statusIsError; self.tooltip = tooltip; self.routes = routes
            self.traceId = traceId; self.mcpURL = mcpURL; self.removing = removing
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
    public var environments: [Environment]
    /// T3 Connect configured: the empty state mentions connecting from it.
    public var cloudEnabled: Bool
    public var cloud: Cloud = .idle

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
    /// A T3 Connect row's `Add` or `Add route`.
    public var addCloud: (String) -> Void = { _ in }
    /// `Try again` after a failed discovery.
    public var retryCloud: () -> Void = {}
    public init() {}
}

/// Settings > Connections (ConnectionsSettings.tsx `ConnectionsSettings`): "This machine", then
/// "Environments" with one row per saved machine or the empty state.
public final class ConnectionsSettingsView: DSView, SettingsGroupRow {
    public var actions = ConnectionsActions()
    public private(set) var model = ConnectionsPageModel()
    private(set) var machineSection: SettingsSectionView?
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
            let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            glyph.color = Themed.color(\.foreground, 0.7)
            glyph.kind = m.machine
            section.icon = glyph
            // ponytail: the row menu (environment icon picker), Network access, Publish agent activity,
            // Permissions and Authorized clients manage the host itself; they come with milestone 7
            let upToDate = LabelView(m.upToDate ? "Up to date" : "", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            upToDate.lineHeight = 16
            upToDate.frame.size = NSSize(width: ceil(upToDate.textWidth) + 1, height: 16)
            section.group.rows = [SettingsRowView(title: "Version", detail: m.versionLine, control: m.upToDate ? upToDate : nil)]
        } else {
            machineSection?.removeFromSuperview()
            machineSection = nil
        }
        // Environments, in catalog order.
        var next: [String: EnvironmentRowView] = [:]
        var groupRows: [any SettingsGroupRow] = []
        for env in model.environments {
            let row = rows[env.id] ?? EnvironmentRowView()
            row.routesOpen = openRoutes.contains(env.id)
            row.configure(env)
            wire(row, env)
            next[env.id] = row
            groupRows.append(row)
        }
        rows = next
        openRoutes = openRoutes.filter { next[$0] != nil }
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
        needsLayout = true
        onHeightChange?()
    }

    private func wire(_ row: EnvironmentRowView, _ env: ConnectionsPageModel.Environment) {
        let id = env.id
        row.onToggleRoutes = { [weak self] in self?.toggleRoutes(id) }
        row.onSwitch = { [weak self] on in self?.actions.setEnabled(id, on) }
        row.onAddRoute = { [weak self] in self?.actions.addRoute(id) }
        row.onRemoveRoute = { [weak self] route in self?.actions.removeRoute(id, route) }
        row.menuItems = { [weak self] in
            guard let self, let env = self.model.environments.first(where: { $0.id == id }) else { return [] }
            var items: [MenuItem] = []
            // ponytail: the environment icon submenu (EnvironmentIconMenu) is not built; it comes with the
            // `environmentIcon` setting in milestone 7
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

    public func height(forWidth width: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        if let machineSection { h += machineSection.height(forWidth: width) + 32 }
        return h + environmentsSection.height(forWidth: width)
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        if let machineSection {
            let h = machineSection.height(forWidth: bounds.width)
            machineSection.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + 32
        }
        environmentsSection.frame = NSRect(x: 0, y: y, width: bounds.width, height: environmentsSection.height(forWidth: bounds.width))
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
/// (`<transport> · <status> · Routes`), the on/off switch and the row menu; the route list opens below.
final class EnvironmentRowView: DSView, SettingsGroupRow {
    private let glyph = EnvironmentMachineGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let status = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let dot = LabelView("·", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    let routesButton = InlineDisclosureButton()
    let toggle = SwitchView(size: .sm)
    let more = ButtonView(nil, icon: .ellipsis, variant: .ghostMuted, size: .iconXs)
    private let routesList = EnvironmentRoutesListView()
    private var statusTip: TooltipController?
    private var switchTip: TooltipController?
    private var isError = false

    var routesOpen = false { didSet { routesList.isHidden = !routesOpen; routesButton.isOpen = routesOpen; needsLayout = true } }
    var onToggleRoutes: (() -> Void)?
    var onSwitch: ((Bool) -> Void)?
    var onAddRoute: (() -> Void)? { didSet { routesList.onAddRoute = onAddRoute } }
    var onRemoveRoute: ((ConnectionsPageModel.Route) -> Void)? { didSet { routesList.onRemove = onRemoveRoute } }
    var menuItems: (() -> [MenuItem])?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.color = Themed.color(\.mutedForeground)
        title.lineHeight = 20
        status.lineHeight = 16
        dot.lineHeight = 16
        for v in [glyph, title, status, dot, routesButton, toggle, more, routesList] as [NSView] { addSubview(v) }
        routesList.isHidden = true
        more.iconSize = 14
        routesButton.action = { [weak self] in self?.onToggleRoutes?() }
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
        // `opacity-60` on the whole row while switched off.
        alphaValue = env.enabled && !env.unsupported ? 1 : 0.6
        needsLayout = true
    }

    /// `px-4 py-2.5`, the 36pt text column; the routes list spans the text and control columns.
    func height(forWidth width: CGFloat) -> CGFloat {
        10 + 36 + (routesOpen ? routesList.height(forWidth: max(0, width - 44 - 16)) : 0) + 10
    }

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
        // `flex items-center gap-1`: the status truncates; the dot and Routes keep their size.
        let routesW = routesButton.intrinsicContentSize.width
        let dotW = ceil(dot.textWidth)
        let statusW = max(0, min(ceil(status.textWidth) + 1, textWidth - routesW - dotW - 8))
        status.frame = NSRect(x: textX, y: 30, width: statusW, height: 16)
        dot.frame = NSRect(x: textX + statusW + 4, y: 30, width: dotW, height: 16)
        routesButton.frame = NSRect(x: dot.frame.maxX + 4, y: 30, width: routesW, height: 16)
        if routesOpen {
            let lw = max(0, w - textX - 16)
            routesList.frame = NSRect(x: textX, y: 46, width: lw, height: routesList.height(forWidth: lw))
        }
    }
}

/// The subtitle's "Routes" toggle: muted text with a `size-3` chevron that turns down when open.
final class InlineDisclosureButton: ControlView {
    private let label = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let chevron = IconView(name: .chevronRight, size: 12)
    var title: String { get { label.text } set { label.text = newValue; invalidateIntrinsicContentSize() } }
    /// `rotate-90` when open; in the flipped parent a positive angle turns clockwise.
    var isOpen = false { didSet { chevron.frameCenterRotation = isOpen ? 90 : 0; setAccessibilityExpanded(isOpen) } }

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
final class EnvironmentRoutesListView: DSView {
    private var routes: [ConnectionsPageModel.Route] = []
    private var rowViews: [RouteRow] = []
    private let border = CALayer()
    private let add = ButtonView("Add route", icon: .plus, variant: .ghostMuted, size: .xs)
    var onAddRoute: (() -> Void)?
    var onRemove: ((ConnectionsPageModel.Route) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        border.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(border)
        add.iconSize = 12
        add.action = { [weak self] in self?.onAddRoute?() }
        addSubview(add)
    }

    func set(_ routes: [ConnectionsPageModel.Route], label: String) {
        self.routes = routes
        rowViews.forEach { $0.removeFromSuperview() }
        // The last route goes with the machine ("Remove from this device"), so it has no remove button.
        // ponytail: no drag handle; routes keep the order they were added in, add reordering if users ask
        rowViews = routes.map { route in
            let row = RouteRow(route, removable: routes.count > 1)
            row.remove.action = { [weak self] in self?.onRemove?(route) }
            addSubview(row)
            return row
        }
        setAccessibilityLabel("Routes to \(label), preferred first")
        needsLayout = true
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
        var y: CGFloat = 17
        for row in rowViews {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: RouteRow.height)
            y += RouteRow.height
        }
        let s = add.intrinsicContentSize
        add.frame = NSRect(x: -6, y: y + 4, width: s.width, height: s.height)
    }

    override func updateLayer() { border.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self) }

    final class RouteRow: DSView {
        static let height: CGFloat = 8 + 16 + 16.5 + 8
        private let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
        private let chip = InUseChip()
        private let address = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
        let remove = ButtonView(nil, icon: .x, variant: .ghostMuted, size: .iconXs)

        init(_ route: ConnectionsPageModel.Route, removable: Bool) {
            super.init(frame: .zero)
            label.text = route.label
            label.lineHeight = 16
            address.text = route.address
            address.lineHeight = 16.5
            chip.isHidden = !route.inUse
            remove.iconSize = 12
            remove.isHidden = !removable
            remove.setAccessibilityLabel("Remove \(route.label) route")
            TooltipController.attach(to: remove, text: "Remove route")
            for v in [label, chip, address, remove] as [NSView] { addSubview(v) }
        }

        override func layout() {
            super.layout()
            let right = remove.isHidden ? bounds.width : bounds.width - 24 - 8
            let lw = min(ceil(label.textWidth) + 1, right)
            label.frame = NSRect(x: 0, y: 8, width: lw, height: 16)
            let cs = chip.intrinsicContentSize
            chip.frame = NSRect(x: lw + 6, y: 8 + (16 - cs.height) / 2, width: cs.width, height: cs.height)
            address.frame = NSRect(x: 0, y: 24, width: max(0, right), height: 16.5)
            remove.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
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
