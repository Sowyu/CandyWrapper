import AppKit
import DesignSystem
import T3Protocol

/// Settings > Devices > Device sources (DeviceSourcesSettings.tsx at 4928): every source the selected environments can open
/// devices from, one row each, in place of the old Device hosts rows. Local simulators, then SSH hosts grouped across
/// environments (deviceHostsSettings.logic.ts:21-56), then Expo hosts on servers that support them. A row shows the
/// source's kind, address, problems per environment with Refresh or Retry, a spinner while one starts, and the platforms
/// it offers. The Simlock pool is left out.
public enum DeviceSourcesLogic {
    public enum Tone: Equatable, Sendable { case pending, warning, error }
    public struct Status: Equatable, Sendable {
        public var tone: Tone
        public var label: String
        public var detail: String?
        /// `Refresh` (local) or `Retry` (a host the server can retry); the host id to retry, or nil for a refresh.
        public var action: (label: String, retryHostId: String?)?
        public static func == (a: Status, b: Status) -> Bool {
            a.tone == b.tone && a.label == b.label && a.detail == b.detail && a.action?.label == b.action?.label && a.action?.retryHostId == b.action?.retryHostId
        }
    }
    public struct Environment: Equatable, Sendable {
        public var environmentId: String
        public var label: String
        public var added: Bool
        public var status: Status?
        /// Unknown until the environment's hub reached the source.
        public var platforms: [DevicePanelHost.Platform]?
    }
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case local, ssh(JSONValue, holders: [String]), eas(JSONValue) }
        public var key: String
        public var title: String
        /// "SSH" or "Expo".
        public var badge: String?
        public var description: String
        public var environments: [Environment]
        /// One machine or account every environment reaches the same way, so one answer speaks for all.
        public var shared: Bool
        public var kind: Kind
        /// Every member environment's id for an SSH host, so a check stays pending on the row that remains after an
        /// environment drops out (#39328, DeviceSourcesSettings.tsx `testSsh` at 5258).
        public var hostIds: [String] = []
    }
    public struct Member: Sendable {
        public var environmentId: String
        public var label: String
        public var settings: ServerSettingsValues
        /// `subscribeDeviceState`, nil until it answers.
        public var state: DevicePanelState?
        public init(environmentId: String, label: String, settings: ServerSettingsValues, state: DevicePanelState?) {
            self.environmentId = environmentId; self.label = label; self.settings = settings; self.state = state
        }
    }

    /// `incompleteListings` (device/DeviceSetup.tsx:29-38): platforms whose listing on a ready host may miss devices.
    static func incomplete(_ status: DevicePanelHostStatus?) -> [String] {
        guard let status, status.status == "ready" else { return [] }
        return ["ios", "android"].filter { status.incompletePlatforms?.contains($0) == true || ($0 == "android" && status.androidDiscoveryIncomplete == true) }
    }

    /// `hostStatus` (:116-148): what a host does on one environment when it is not simply working.
    public static func hostStatus(_ state: DevicePanelState?, hostId: String) -> Status? {
        guard let state else { return Status(tone: .pending, label: "Loading") }
        let status = state.hostStatuses?[hostId]
        switch status?.status {
        case "ready":
            let missing = incomplete(status)
            guard !missing.isEmpty else { return nil }
            let label = missing.count > 1 ? "Device list may be incomplete" : missing[0] == "ios" ? "iOS list may be incomplete" : "Android list may be incomplete"
            return Status(tone: .warning, label: label, detail: status?.detail)
        case "installing", "starting": return Status(tone: .pending, label: "Starting", detail: status?.detail)
        case "failed": return Status(tone: .error, label: "Failed", detail: status?.detail)
        default: return nil
        }
    }

    /// `groupDeviceHosts` (deviceHostsSettings.logic.ts:21-56): only matching configurations combine; nil when any is ambiguous.
    public static func group(_ envs: [(environmentId: String, label: String, hosts: [JSONValue])]) -> [(host: JSONValue, members: [(environmentId: String, host: JSONValue)])]? {
        func s(_ v: JSONValue?) -> String { v?.stringValue ?? v?.doubleValue.map { String(Int($0)) } ?? "" }
        var order: [String] = [], groups: [String: (host: JSONValue, members: [(environmentId: String, host: JSONValue)])] = [:]
        var identities: [String: String] = [:], configurations: [String: String] = [:]
        for env in envs {
            var destinations: Set<String> = []
            for host in env.hosts {
                let destination = [s(host["target"]), s(host["port"]), s(host["identityFile"])].joined(separator: "\u{1}")
                let configuration = [s(host["label"]), destination].joined(separator: "\u{1}")
                let id = s(host["id"]), target = s(host["target"])
                if destinations.contains(destination) || identities[id].map({ $0 != configuration }) == true
                    || configurations[target].map({ $0 != configuration }) == true { return nil }
                destinations.insert(destination)
                identities[id] = configuration
                configurations[target] = configuration
                if groups[destination] == nil { order.append(destination); groups[destination] = (host, []) }
                groups[destination]!.members.append((env.environmentId, host))
            }
        }
        return order.map { groups[$0]! }
    }

    /// The rows (:380-560), for the members with devices on.
    public static func rows(_ members: [Member], supportsEas: Bool) -> [Row] {
        let active = members.filter { $0.settings["enableDeviceSupport"].boolValue == true }
        var rows: [Row] = []
        rows.append(Row(key: "local", title: "Local simulators", badge: nil,
                        description: members.count > 1 ? "Simulators and emulators installed on each environment's own machine."
                            : "Simulators and emulators installed on this environment's machine.",
                        environments: active.map { m in
                            let local = m.state?.hosts.first { $0.kind == "local" }
                            var status = hostStatus(m.state, hostId: local?.id ?? "")
                            if status?.tone == .error { status?.action = ("Refresh", nil) }
                            return Environment(environmentId: m.environmentId, label: m.label, added: true, status: status, platforms: local?.platforms)
                        }, shared: false, kind: .local))
        let byEnv = members.map { (environmentId: $0.environmentId, label: $0.label, hosts: $0.settings["deviceHosts"].arrayValue ?? []) }
        let groups = group(byEnv) ?? byEnv.flatMap { e in e.hosts.map { (host: $0, members: [(environmentId: e.environmentId, host: $0)]) } }
        for g in groups {
            let id = g.host["id"]?.stringValue ?? ""
            let holders = g.members.map(\.environmentId)
            rows.append(Row(key: "ssh:\(id):\(holders.joined(separator: ","))", title: g.host["label"]?.stringValue ?? id, badge: "SSH",
                            description: g.host["target"]?.stringValue ?? "",
                            environments: active.map { m in
                                guard let held = g.members.first(where: { $0.environmentId == m.environmentId }) else {
                                    return Environment(environmentId: m.environmentId, label: m.label, added: false)
                                }
                                let hostId = held.host["id"]?.stringValue ?? ""
                                var status = hostStatus(m.state, hostId: hostId)
                                if status?.tone == .error, m.state?.supportsHostRetry == true {
                                    status?.label = "Can't connect"
                                    status?.action = ("Retry", hostId)
                                }
                                return Environment(environmentId: m.environmentId, label: m.label, added: true, status: status,
                                                   platforms: m.state?.hosts.first { $0.id == hostId }?.platforms)
                            }, shared: true, kind: .ssh(g.host, holders: holders),
                            hostIds: g.members.compactMap { $0.host["id"]?.stringValue }))
        }
        guard supportsEas else { return rows }
        var seen: Set<String> = []
        for m in members {
            for host in m.settings["easDeviceHosts"].arrayValue ?? [] {
                guard let id = host["id"]?.stringValue, seen.insert(id).inserted else { continue }
                rows.append(Row(key: "eas:\(id)", title: host["label"]?.stringValue ?? "Expo", badge: "Expo", description: easLimits(host),
                                environments: active.map { a in
                                    let added = (a.settings["easDeviceHosts"].arrayValue ?? []).contains { $0["id"]?.stringValue == id }
                                    return Environment(environmentId: a.environmentId, label: a.label, added: added,
                                                       status: added ? hostStatus(a.state, hostId: id) : nil,
                                                       platforms: added ? a.state?.hosts.first { $0.id == id }?.platforms : nil)
                                }, shared: true, kind: .eas(host)))
            }
        }
        return rows
    }

    /// `easSessionLimits`: the session caps an Expo host holds.
    static func easLimits(_ host: JSONValue) -> String {
        let n = host["maxConcurrentSessions"]?.doubleValue.map { Int($0) }
        let minutes = host["maxSessionMinutes"]?.doubleValue.map { Int($0) }
        return [n.map { "Up to \($0) at once" }, minutes.map { "\($0) min sessions" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// `SourcePlatforms`: the platforms some environment reports for the source, with whether they are available.
    public static func platforms(_ row: Row) -> [(platform: String, label: String, available: Bool, partial: Bool, detail: String)] {
        let known = row.environments.filter { $0.added && $0.platforms != nil }
        return [("ios", "iOS"), ("android", "Android")].compactMap { platform, label in
            func entry(_ e: Environment) -> DevicePanelHost.Platform? { e.platforms?.first { $0.platform == platform } }
            guard known.contains(where: { entry($0) != nil }) else { return nil }
            let on = known.filter { entry($0)?.available == true }
            let available = !on.isEmpty
            let partial = available && on.count < known.count
            let several = row.environments.count > 1
            var lines = [available ? (partial ? "\(label) available on some" : "\(label) available") : "\(label) not available"]
            if several {
                lines += known.map { e in "\(e.label): " + (entry(e)?.available == true ? "Available" : entry(e)?.reason ?? "Not available") }
                let notAdded = row.environments.filter { !$0.added }.map(\.label)
                if !notAdded.isEmpty { lines.append("Not added: " + notAdded.joined(separator: ", ")) }
            } else if !available, let first = known.first {
                lines.append(entry(first)?.reason ?? "Not set up on this machine.")
            }
            return (platform, label, available, partial, lines.joined(separator: "\n"))
        }
    }
}

/// The section: rows, Add source and the SSH editor. The page feeds it each environment's settings and device state.
@MainActor
final class DeviceSourcesSection {
    let section = SettingsSectionView(title: "Device sources", rows: [])
    private let add = ButtonView("Add source", icon: .plus, variant: .outline, size: .sm).menuTrigger()
    private let context: SettingsPageContext
    private var editor: DeviceHostEditor?
    private var states: [String: DevicePanelState] = [:]
    private var subscriptions: [String: Task<Void, Never>] = [:]
    private var testing: Set<String> = []
    private var busy = false

    init(context: SettingsPageContext) {
        self.context = context
        add.trailingIcon = .chevronDown
        add.iconSize = 14
        section.headerAction = add
        add.action = { [weak self, weak add] in
            guard let self, let add else { return }
            var ssh = MenuItem("Machine over SSH")
            ssh.action = { [weak self] in self?.edit(nil) }
            MenuPopupView.show([ssh], from: add, placement: .dropdown)
        }
    }

    private var members: [DeviceSourcesLogic.Member] {
        context.scope.targets.map { DeviceSourcesLogic.Member(environmentId: $0.environmentId, label: $0.label, settings: $0.settings, state: states[$0.environmentId]) }
    }

    /// Follows `subscribeDeviceState` on each selected environment while the page shows; pushes only, no polling.
    func setVisible(_ visible: Bool) {
        let ids = visible ? Set(context.scope.targets.map(\.environmentId)) : []
        for (id, task) in subscriptions where !ids.contains(id) { task.cancel(); subscriptions[id] = nil; states[id] = nil }
        for id in ids where subscriptions[id] == nil {
            subscriptions[id] = context.subscribe?(id, "subscribeDeviceState", .object([:])) { [weak self] value in
                guard let self, let state = try? JSONValueDecoder().decode(DevicePanelState.self, from: value) else { return }
                self.states[id] = state
                self.refresh()
            }
        }
    }

    func refresh() {
        let disabled = context.scope.isProjectScope || busy || context.scope.targets.isEmpty || !context.scope.canWrite
        add.isEnabled = !disabled
        let supportsEas = states.values.contains { $0.supportsEasHosts == true }
        section.group.rows = DeviceSourcesLogic.rows(members, supportsEas: supportsEas).map { row in
            let view = DeviceSourceRowView(row: row, testing: testing)
            view.onAction = { [weak self] env, retry in self?.list(env, retryHostId: retry) }
            if !disabled, case .ssh(let host, let holders) = row.kind {
                view.actions(edit: { [weak self] in self?.edit(host) },
                             more: [("Test connection", { [weak self] in self?.test(host, ids: row.hostIds) }), ("Remove", { [weak self] in self?.remove(sshHost: host, holders: holders) })])
            } else if !disabled, case .eas(let host) = row.kind {
                view.actions(edit: nil, more: [("Remove", { [weak self] in self?.remove(easHost: host) })])
            }
            return view
        }
    }

    private func edit(_ host: JSONValue?) {
        editor = DeviceHostEditor(context: context, original: host)
        editor?.present()
    }

    /// `device.list` with `retryHostId`, or without to rescan.
    private func list(_ environmentId: String, retryHostId: String?) {
        guard let request = context.request else { return }
        Task { _ = try? await request(environmentId, "device.list", retryHostId.map { .object(["retryHostId": .string($0)]) } ?? .object([:])) }
    }

    /// `device.testHost` on every selected environment, then one toast.
    private func test(_ host: JSONValue, ids: [String]) {
        guard let request = context.request, let id = host["id"]?.stringValue else { return }
        let name = host["label"]?.stringValue ?? id
        let targets = context.scope.targets
        let ids = Set(ids + [id])
        testing.formUnion(ids)
        refresh()
        Task { [weak self] in
            var failed: [String] = []
            for t in targets {
                do { _ = try await request(t.environmentId, "device.testHost", host) } catch { failed.append("\(t.label): \(error)") }
            }
            guard let self else { return }
            self.testing.subtract(ids)
            self.refresh()
            if failed.isEmpty {
                self.context.toast?("\(name): connection checks passed", "Connected or already available locally on each selected environment.", .success)
            } else {
                self.context.toast?("\(name): \(failed.count) of \(targets.count) environments failed", failed.joined(separator: "\n"), .error)
            }
        }
    }

    private func write(_ patches: [(String, JSONValue)], failedTitle: String) {
        guard let request = context.request, !patches.isEmpty else { return }
        busy = true
        refresh()
        let labels = Dictionary(context.scope.targets.map { ($0.environmentId, $0.label) }, uniquingKeysWith: { a, _ in a })
        Task { [weak self] in
            var failed: [String] = []
            for (env, patch) in patches {
                do {
                    let result = try await request(env, "server.updateSettings", .object(["patch": patch]))
                    self?.context.applySettings?(env, result)
                } catch { failed.append("\(labels[env] ?? env): \(error)") }
            }
            guard let self else { return }
            self.busy = false
            self.refresh()
            if !failed.isEmpty { self.context.toast?(failedTitle, failed.joined(separator: "\n"), .error) }
        }
    }

    private func remove(sshHost host: JSONValue, holders: [String]) {
        let patches = context.scope.targets.filter { holders.contains($0.environmentId) }.compactMap { t -> (String, JSONValue)? in
            let current = t.settings["deviceHosts"].arrayValue ?? []
            guard let next = try? DeviceHostEditing.update(current, host: host, original: host, remove: true) else { return nil }
            return (t.environmentId, .object(["deviceHosts": .array(next)]))
        }
        write(patches, failedTitle: "Device host not removed everywhere")
    }

    private func remove(easHost host: JSONValue) {
        let id = host["id"]?.stringValue
        let patches = context.scope.targets.compactMap { t -> (String, JSONValue)? in
            let current = t.settings["easDeviceHosts"].arrayValue ?? []
            guard current.contains(where: { $0["id"]?.stringValue == id }) else { return nil }
            return (t.environmentId, .object(["easDeviceHosts": .array(current.filter { $0["id"]?.stringValue != id })]))
        }
        write(patches, failedTitle: "Expo host not removed everywhere")
    }
}

/// `DeviceSourceRow` (:804-876): title with its kind badge, the description, a line per environment with a problem, then
/// a spinner while one starts or the platform icons, then Edit and ⋯.
final class DeviceSourceRowView: DSView, SettingsGroupRow {
    var onAction: ((String, String?) -> Void)?
    private let title: LabelView
    private let badge: LabelView?
    private let detail: LabelView
    private var problemViews: [(McpText, NSView?)] = []
    private var trailing: [NSView] = []
    private var actionViews: [NSView] = []
    private let border = CALayer()
    var topBorder = false { didSet { border.isHidden = !topBorder } }

    init(row: DeviceSourcesLogic.Row, testing: Set<String>) {
        title = LabelView(row.title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        badge = row.badge.map { LabelView($0.uppercased(), font: DSFont.ui(10), color: Themed.color(\.mutedForeground)) }
        detail = LabelView(row.description, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        title.lineHeight = 20; detail.lineHeight = 16; badge?.lineHeight = 14; badge?.tracking = 0.25
        for v in [title, detail] as [NSView] { addSubview(v) }
        if let badge {
            badge.wantsLayer = true
            addSubview(badge)
        }
        border.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(border)
        let several = row.environments.count > 1
        var issues = row.environments.filter { $0.status != nil }
        if case .ssh(let host, _) = row.kind, let id = host["id"]?.stringValue, testing.contains(id) || row.hostIds.contains(where: testing.contains) {
            issues = issues.map { var e = $0; e.status = .init(tone: .pending, label: "Testing connection"); return e }
            if issues.isEmpty { issues = row.environments.filter(\.added).map { var e = $0; e.status = .init(tone: .pending, label: "Testing connection"); return e } }
        }
        for e in issues where e.status!.tone != .pending {
            let s = e.status!
            let text = (several ? "\(e.label): " : "") + (s.tone == .error && !several && s.detail != nil ? s.detail! : s.label)
            let line = McpText(text, size: 12, color: Themed.color(s.tone == .error ? \.destructive : \.warning))
            line.setAccessibilityRole(.staticText)
            var action: NSView?
            if let a = s.action {
                let env = e.environmentId
                let b = McpTextButton(a.label, size: 12) { [weak self] in self?.onAction?(env, a.retryHostId) }
                action = b
            }
            problemViews.append((line, action))
            addSubview(line); action.map(addSubview)
        }
        if let pending = issues.first(where: { $0.status?.tone == .pending }) {
            trailing = [McpStatusLine(pending.status!.label)]
        } else {
            trailing = DeviceSourcesLogic.platforms(row).map { p in
                let icon = IconView(name: p.platform == "ios" ? .brandApple : .brandAndroid, size: 14,
                                    strokeColor: p.available ? Themed.color(\.foreground) : Themed.color(\.mutedForeground, 0.45))
                let wrap = DSView()
                wrap.addSubview(icon)
                icon.frame = NSRect(x: 5, y: p.platform == "ios" ? 4 : 5, width: 14, height: 14)
                wrap.setAccessibilityElement(true)
                wrap.setAccessibilityRole(.image)
                wrap.setAccessibilityLabel("\(row.title): \(p.label) \(p.available ? "available" : "not available")")
                _ = TooltipController.attach(to: wrap, text: p.detail)
                if p.partial {
                    let dot = CALayer()
                    dot.backgroundColor = Themed.color(\.warning).cgColor(in: wrap)
                    dot.cornerRadius = 3
                    dot.frame = CGRect(x: 16, y: 2, width: 6, height: 6)
                    wrap.wantsLayer = true
                    wrap.layer?.addSublayer(dot)
                }
                return wrap
            }
        }
        trailing.forEach(addSubview)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func actions(edit: (@MainActor @Sendable () -> Void)?, more: [(String, @MainActor @Sendable () -> Void)]) {
        actionViews.forEach { $0.removeFromSuperview() }
        actionViews = []
        if let edit {
            let b = ButtonView("Edit", variant: .outline, size: .sm)
            b.action = edit
            actionViews.append(b)
        }
        let m = ButtonView(nil, icon: .moreVertical, variant: .ghostMuted, size: .iconSm).menuTrigger()
        m.setAccessibilityLabel("More")
        m.action = { [weak m] in
            guard let m else { return }
            let items = more.map { title, run -> MenuItem in
                var item = MenuItem(title)
                item.isDestructive = title == "Remove"
                item.action = run
                return item
            }
            MenuPopupView.show(items, from: m, placement: .dropdown)
        }
        actionViews.append(m)
        actionViews.forEach(addSubview)
        needsLayout = true
    }

    private var trailingWidth: CGFloat {
        let t = trailing.reduce(CGFloat(0)) { sum, v in sum + Self.width(v) } + CGFloat(max(0, trailing.count - 1)) * 2
        let a = actionViews.reduce(0) { $0 + $1.intrinsicContentSize.width } + CGFloat(max(0, actionViews.count - 1)) * 4
        return t + (a > 0 ? 12 + a : 0)
    }

    /// A platform button is `size-6`; the pending line is the spinner, `gap-1.5` and its label.
    private static func width(_ v: NSView) -> CGFloat {
        guard let line = v as? McpStatusLine else { return 24 }
        return 20 + line.labelWidth
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - 32 - trailingWidth - 12)
        let problems = problemViews.reduce(CGFloat(0)) { $0 + 4 + $1.0.height(forWidth: textWidth - ($1.1 == nil ? 0 : 60)) }
        return 24 + 20 + 16 + problems + (topBorder ? 1 : 0)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { border.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }

    override func layout() {
        super.layout()
        let top: CGFloat = topBorder ? 1 : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        CATransaction.commit()
        var x = bounds.width - 16
        for v in actionViews.reversed() {
            let s = v.intrinsicContentSize
            x -= s.width
            v.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x -= 4
        }
        if !actionViews.isEmpty { x -= 8 }
        for v in trailing.reversed() {
            let w = Self.width(v)
            x -= w
            v.frame = NSRect(x: x, y: (bounds.height - (v is McpStatusLine ? 20 : 24)) / 2, width: w, height: v is McpStatusLine ? 20 : 24)
            x -= 2
        }
        let textWidth = max(0, x - 12 - 16)
        let tw = min(ceil(title.textWidth) + 1, textWidth - (badge == nil ? 0 : 40))
        title.frame = NSRect(x: 16, y: top + 12, width: tw, height: 20)
        if let badge {
            let bw = ceil(badge.textWidth) + 10
            badge.frame = NSRect(x: 16 + tw + 6, y: top + 15, width: bw, height: 14)
            badge.alignment = .center
            badge.layer?.borderWidth = 1
            badge.layer?.cornerRadius = 4
            badge.layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        }
        detail.frame = NSRect(x: 16, y: top + 32, width: textWidth, height: 16)
        var y = top + 48
        for (line, action) in problemViews {
            let lw = textWidth - (action == nil ? 0 : 60)
            let h = line.height(forWidth: lw)
            y += 4
            line.frame = NSRect(x: 16, y: y, width: lw, height: h)
            if let action = action as? McpTextButton {
                action.frame = NSRect(x: 16 + min(lw, ceil(line.text.naturalWidth) + 1) + 6, y: y, width: action.naturalWidth, height: 16)
            }
            y += h
        }
    }
}
