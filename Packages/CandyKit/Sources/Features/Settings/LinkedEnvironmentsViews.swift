import AppKit
import DesignSystem
import T3Protocol

extension ConnectionsPageModel {
    /// One "Linked environments" section (LinkedEnvironmentsSettings.tsx at 3814): the links of one connected environment
    /// that offers them (`usePeerLinkHosts`). With more than one such environment, each title names its environment.
    public struct LinkedEnvironments: Equatable {
        public enum Dot: Equatable { case success, warning, destructive, idle }
        public struct Link: Equatable {
            public var id, label, line, urls, status: String
            public var dot: Dot
            public var canForget, forgetting: Bool
            public init(id: String, label: String, line: String, urls: String, status: String, dot: Dot, canForget: Bool, forgetting: Bool = false) {
                self.id = id; self.label = label; self.line = line; self.urls = urls; self.status = status; self.dot = dot
                self.canForget = canForget; self.forgetting = forgetting
            }
        }
        public enum State: Equatable {
            case loading
            case failed(String)
            case links([Link])
        }
        public var hostId: String
        public var title: String
        /// The session there may link (`peerLinkEnvironment.link.permissionAtom`): shows the Link button.
        public var canLink: Bool
        public var state: State
        public init(hostId: String, title: String, canLink: Bool, state: State) {
            self.hostId = hostId; self.title = title; self.canLink = canLink; self.state = state
        }

        /// A listed link as its row shows it (LinkedEnvironmentsSettings.tsx:92-171).
        public static func link(_ l: PeerLinkSummary, now: Date, canForget: Bool, forgetting: Bool) -> Link {
            let health = PeerLinkHealth(l, now: now)
            let dot: Dot = switch health {
            case .reachable(nil): .success
            case .reachable: .warning
            case .expired, .failing: .destructive
            case .unreachable: .idle
            }
            return Link(id: l.environmentId, label: l.label, line: "\(LinkAccess.label(l.access)) · \(health.text)",
                        urls: l.urls.joined(separator: ", "), status: health.text, dot: dot, canForget: canForget, forgetting: forgetting)
        }
    }
}

/// `accessConfig` (auth/ConnectAgentSurface.tsx:27-37 at 3814): Read only, then the runtime modes.
public enum LinkAccess {
    public static let all: [(value: String, label: String, description: String, icon: IconName)] = [
        ("read-only", "Read only", "Read projects and threads. Cannot start, message or change anything.", .eye),
        ("approval-required", "Supervised", "Ask before commands and file changes.", .lock),
        ("auto-accept-edits", "Auto-accept edits", "Auto-approve edits, ask before other actions.", .penLine),
        ("auto", "Auto", "Supported providers approve routine actions; others still ask.", .sparkles),
        ("full-access", "Full access", "Allow commands and edits without prompts.", .lockOpen),
    ]
    public static func label(_ access: String) -> String { all.first { $0.value == access }?.label ?? access }
    /// `LinkAccessPicker`'s note under the select.
    static func note(_ access: String) -> String {
        let description = all.first { $0.value == access }?.description ?? ""
        return "\(description) An agent never gets more access there than its own mode here. Below full access, it can change only threads this link started, not that machine's own threads, projects or settings."
    }
}

/// A link's row: the status dot and name, "Access · status", the addresses, and Forget.
final class LinkedEnvironmentRowView: DSView, SettingsGroupRow {
    private let dot = CALayer()
    private let dotHit = DSView()
    private let title = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let line = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let urls = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground, 0.8))
    private let forget = ButtonView("Forget", variant: .destructiveOutline, size: .xs)
    private var dotTip: TooltipController?
    private var dotKind: ConnectionsPageModel.LinkedEnvironments.Dot = .idle
    var onForget: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        dot.cornerRadius = 4
        layer?.addSublayer(dot)
        for l in [title, line, urls] { l.truncates = true }
        title.lineHeight = 20
        line.lineHeight = 16
        urls.lineHeight = 16
        for v in [dotHit, title, line, urls, forget] as [NSView] { addSubview(v) }
        forget.action = { [weak self] in self?.onForget?() }
        dotTip = TooltipController.attach(to: dotHit, text: "")
    }

    func configure(_ l: ConnectionsPageModel.LinkedEnvironments.Link) {
        title.text = l.label
        line.text = l.line
        urls.text = l.urls
        dotTip?.text = l.status
        dotHit.setAccessibilityLabel(l.status)
        dotKind = l.dot
        forget.isHidden = !l.canForget
        forget.title = l.forgetting ? "Forgetting…" : "Forget"
        forget.isEnabled = !l.forgetting
        forget.setAccessibilityLabel("Forget \(l.label)")
        needsDisplay = true
        needsLayout = true
    }

    /// `px-4 py-3`, `space-y-1`: the 20pt name line, then two 16pt lines.
    func height(forWidth width: CGFloat) -> CGFloat { 12 + 20 + 4 + 16 + 4 + 16 + 12 }

    override func updateLayer() {
        let color: NSColor = switch dotKind {
        case .success: Themed.color(\.success)
        case .warning: Themed.color(\.warning)
        case .destructive: Themed.color(\.destructive)
        case .idle: Themed.color(\.mutedForeground, 0.3)
        }
        dot.backgroundColor = color.cgColor(in: self)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var right = w - 16
        if !forget.isHidden {
            let s = forget.intrinsicContentSize
            forget.frame = NSRect(x: w - 16 - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            right = forget.frame.minX - 16
        }
        dotHit.frame = NSRect(x: 16, y: 12 + 4, width: 12, height: 12)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 18, y: 12 + 6, width: 8, height: 8)
        CATransaction.commit()
        title.frame = NSRect(x: 34, y: 12, width: max(0, right - 34), height: 20)
        line.frame = NSRect(x: 16, y: 36, width: max(0, right - 16), height: 16)
        urls.frame = NSRect(x: 16, y: 56, width: max(0, right - 16), height: 16)
    }
}

/// A machine the Link dialog offers (client-runtime/src/linkRequest.ts `LinkableMachine` at 3814).
public struct LinkableMachine: Equatable {
    public var environmentId, label: String
    public var connected, linked: Bool
    /// Where the client knows it answers, most preferred first. Empty when no other machine could reach it.
    public var urls: [String]
    /// Connected with a session there that may create pairing codes, so the dialog mints one itself.
    public var canMint: Bool
    /// What to turn on so other machines reach it, shown when `urls` is empty. Nil keeps T3's generic line.
    public var noAddressHint: String?
    public init(environmentId: String, label: String, connected: Bool, linked: Bool, urls: [String], canMint: Bool, noAddressHint: String? = nil) {
        self.environmentId = environmentId; self.label = label; self.connected = connected; self.linked = linked
        self.urls = urls; self.canMint = canMint; self.noAddressHint = noAddressHint
    }
}

/// A machine this app can link without a pasted code because another of its environments links there at full access,
/// so that one gets the pairing code (`LinkThroughRoute`, client-runtime state/peerLinks.ts:169-211 at 5258, #40036).
public struct LinkThroughRoute: Equatable, Sendable {
    public var viaEnvironmentId, viaLabel, environmentId, label: String
    public var urls: [String]
    public init(viaEnvironmentId: String, viaLabel: String, environmentId: String, label: String, urls: [String]) {
        self.viaEnvironmentId = viaEnvironmentId; self.viaLabel = viaLabel; self.environmentId = environmentId
        self.label = label; self.urls = urls
    }

    /// `linkThroughRoutes`: the machines `source` can link to through a host's full-access link that answers, the first
    /// host winning. `hosts` are environments this app is connected to and manages access on, the only ones it may ask.
    public static func routes(source: String, hosts: [(environmentId: String, label: String, links: [PeerLinkSummary])],
                              now: Date) -> [LinkThroughRoute] {
        var routes: [LinkThroughRoute] = []
        for host in hosts where host.environmentId != source {
            for link in host.links where link.environmentId != source && link.access == "full-access"
                && !routes.contains(where: { $0.environmentId == link.environmentId }) {
                guard case .reachable = PeerLinkHealth(link, now: now) else { continue }
                routes.append(LinkThroughRoute(viaEnvironmentId: host.environmentId, viaLabel: host.label,
                                               environmentId: link.environmentId, label: link.label, urls: link.urls))
            }
        }
        return routes
    }
}

/// "Link an environment" (LinkedEnvironmentsSettings.tsx:174-357 at 3814): a machine or an address, a pairing code
/// unless this app can mint one there, and what agents here may do there.
public final class LinkEnvironmentFormView: DSView {
    public static let anotherAddress = "another-address"

    public let machines: [LinkableMachine]
    private let machineTitle = LabelView("Machine", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let machineSelect: SelectView
    private let linkedNote = TextBlockView()
    private let throughNote = TextBlockView()
    /// Machines reachable through another environment's full-access link (#40036).
    public let throughRoutes: [LinkThroughRoute]
    /// The map's drop on a machine known only through a link: linked through `prefilledThrough` while the address
    /// stays the one the dialog opened with (LinkedEnvironmentsSettings.tsx:306-311 at 5258).
    private var prefilledThrough: LinkThroughRoute?
    private var prefilledAddress = ""
    /// Machines that would not give a code through a link, so the form asks for one instead.
    public var throughFailed: Set<String> = [] { didSet { apply() } }
    /// Whether this app's session on the route's environment may ask it for a code at `access` (#41742): handing out
    /// access takes holding it, so a route this session can't use is not offered.
    public var mayPairThrough: (LinkThroughRoute, String) -> Bool = { _, _ in true }
    private let addressTitle = LabelView("Address", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    public let addressInput = InputView(placeholder: "https://box.example.ts.net")
    private let addressHint = TextBlockView()
    private let codeTitle = LabelView("Pairing code", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    public let codeInput = InputView(placeholder: "Paste the code")
    private let codeHint = TextBlockView()
    private let accessTitle = LabelView("What agents here may do there", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
    private let accessSelect: SelectView
    private let accessNote = TextBlockView()

    /// Null until the user picks; with no other machines known, only an address is left.
    public private(set) var choice: String?
    public private(set) var access = "approval-required"
    /// Machines whose minting already failed, so the form asks for a code instead.
    public var mintFailed: Set<String> = [] { didSet { apply() } }
    public var isBusy = false { didSet { apply() } }
    /// Answering an agent's link request: a machine linked already is answered as it is (`use-existing`).
    public var answersRequest = false { didSet { apply() } }
    var onChange: (() -> Void)?
    public var onHeightChange: (() -> Void)?

    public init(machines saved: [LinkableMachine], throughRoutes: [LinkThroughRoute] = []) {
        // Machines this app has no entry for are still pickable when one of its environments links to them at full
        // access (:264-277 at 5258).
        let machines = saved + throughRoutes.filter { route in !saved.contains { $0.environmentId == route.environmentId } }.map {
            LinkableMachine(environmentId: $0.environmentId, label: $0.label, connected: false, linked: false, urls: $0.urls, canMint: false)
        }
        self.machines = machines
        self.throughRoutes = throughRoutes
        machineSelect = SelectView(options: machines.map(\.label) + ["Another address…"], placeholder: "Choose a machine")
        accessSelect = SelectView(options: LinkAccess.all.map(\.label), selected: 1)
        super.init(frame: .zero)
        machineSelect.optionTrailingDetails = machines.map { $0.linked ? "Linked" : $0.connected ? nil : "Not connected" } + [nil]
        machineSelect.setAccessibilityLabel("Machine")
        machineSelect.onChange = { [weak self] i in
            guard let self else { return }
            self.choice = i < self.machines.count ? self.machines[i].environmentId : Self.anotherAddress
            self.apply()
        }
        accessSelect.optionDetails = LinkAccess.all.map(\.description)
        accessSelect.optionGlyphs = LinkAccess.all.map { $0.icon.definition }
        accessSelect.alignItemWithTrigger = false
        accessSelect.setAccessibilityLabel("What agents here may do there")
        accessSelect.onChange = { [weak self] i in
            self?.access = LinkAccess.all[i].value
            self?.apply()
        }
        for t in [linkedNote, throughNote, addressHint, codeHint, accessNote] {
            t.font = DSFont.ui(12)
            t.lineHeight = 16
            t.color = Themed.color(\.mutedForeground)
        }
        linkedNote.text = "Already linked. Linking again renews it with the access you pick."
        for l in [machineTitle, addressTitle, codeTitle, accessTitle] { l.lineHeight = 16 }
        addressInput.onChange = { [weak self] _ in
            guard let self else { return }
            // Machines found after typing began must not hide the address being typed.
            if self.choice == nil { self.choice = Self.anotherAddress }
            self.apply()
        }
        codeInput.onChange = { [weak self] _ in self?.onChange?() }
        for v in [machineTitle, machineSelect, linkedNote, throughNote, addressTitle, addressInput, addressHint, codeTitle, codeInput, codeHint,
                  accessTitle, accessSelect, accessNote] as [NSView] { addSubview(v) }
        apply()
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    /// A link request card opens on the machine the agent named or hinted at, with the access it suggested; a named
    /// machine can't be changed (LinkRequestCard.tsx `resolveTarget`).
    public func preset(choice: String?, access: String?, lockMachine: Bool, address: String? = nil, through: LinkThroughRoute? = nil) {
        if let choice { self.choice = choice }
        if let address { addressInput.text = address; prefilledAddress = address }
        if let through, address != nil { prefilledThrough = through; self.choice = Self.anotherAddress }
        if let access, let i = LinkAccess.all.firstIndex(where: { $0.value == access }) {
            self.access = access
            accessSelect.selectedIndex = i
        }
        machineLocked = lockMachine
        apply()
    }
    private var machineLocked = false

    public var selected: String? { choice ?? (machines.isEmpty ? Self.anotherAddress : nil) }
    public var machine: LinkableMachine? { machines.first { $0.environmentId == selected } }
    public var addressHintText: String { addressHint.text }
    public var needsAddress: Bool { selected == Self.anotherAddress || machine?.urls.isEmpty == true }
    /// This client mints the code there (`canMint`), unless that already failed.
    public var mints: Bool { machine.map { $0.canMint && !mintFailed.contains($0.environmentId) } ?? false }
    public var address: String { addressInput.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var pairingCode: String { codeInput.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The request's machine is linked already, so the agent uses that link and nothing else is asked
    /// (LinkRequestCard.tsx:245-277 at 3814).
    public var usesExisting: Bool { answersRequest && machine?.linked == true }
    /// The link goes through another environment, which gets the pairing code: no address or code is asked. Minting
    /// with this app's own session there comes first, since it needs no third machine (:325-347 at 5258).
    public var through: LinkThroughRoute? {
        let candidate: LinkThroughRoute?
        if let p = prefilledThrough, selected == Self.anotherAddress, addressInput.text == prefilledAddress { candidate = p }
        else if let m = machine, !mints, !answersRequest { candidate = throughRoutes.first { $0.environmentId == m.environmentId } }
        else { candidate = nil }
        guard let candidate, !throughFailed.contains(candidate.environmentId), mayPairThrough(candidate, access) else { return nil }
        return candidate
    }

    /// `DialogTitle` (:491-501 at 5258): names the source, because from the map nothing else on screen does.
    public func title(source: String?) -> String {
        guard let source else { return "Link an environment" }
        if let through { return "Link \(source) to \(through.label)" }
        guard let machine, selected != Self.anotherAddress else { return "Link \(source) to another machine" }
        return "Link \(source) to \(machine.label)"
    }

    public var ready: Bool {
        if usesExisting || through != nil { return true }
        return selected != nil && (!needsAddress || !address.isEmpty) && (mints || !pairingCode.isEmpty)
    }
    /// `[url, ...alternateUrls]`: the typed address, else the machine's.
    public var urls: [String] { machine == nil || needsAddress ? [address] : machine!.urls }

    private func apply() {
        let m = machine
        let through = through
        // The machine the map dropped on stays fixed; picking another one shows the select again (:519).
        let hideSelect = machines.isEmpty || (through != nil && through == prefilledThrough)
        machineTitle.isHidden = hideSelect
        machineSelect.isHidden = hideSelect
        throughNote.isHidden = through == nil
        throughNote.text = through.map { "\($0.viaLabel) links to \($0.label) at full access, so it gets the pairing code. No code to paste." } ?? ""
        machineSelect.isEnabled = !isBusy && !machineLocked
        if let i = machines.firstIndex(where: { $0.environmentId == selected }) { machineSelect.selectedIndex = i }
        else if selected == Self.anotherAddress, !machines.isEmpty { machineSelect.selectedIndex = machines.count }
        linkedNote.isHidden = m?.linked != true
        linkedNote.text = usesExisting
            ? "This environment is already linked to \(m?.label ?? "it"). The agent can use that link as it is; change its access in Settings → Environments."
            : "Already linked. Linking again renews it with the access you pick."
        let address = needsAddress && !usesExisting && through == nil
        addressTitle.isHidden = !address
        addressInput.isHidden = !address
        addressInput.isEnabled = !isBusy
        addressHint.text = m.map { $0.noAddressHint ?? "This app has no address for \($0.label) that another machine can reach. Enter its https or Tailscale address." } ?? ""
        addressHint.isHidden = !address || m == nil
        let code = selected != nil && !mints && !usesExisting && through == nil
        codeTitle.isHidden = !code
        codeInput.isHidden = !code
        codeInput.isEnabled = !isBusy
        codeInput.placeholder = m == nil ? "From Sharing & access there, or t3 pair" : "Paste the code"
        codeHint.text = m.map { "Create a link on \($0.label): Settings → Sharing & access → Authorized clients → Create link, then paste its code here." } ?? ""
        codeHint.isHidden = !code || m == nil
        accessSelect.isEnabled = !isBusy
        accessTitle.isHidden = usesExisting
        accessSelect.isHidden = usesExisting
        accessNote.isHidden = usesExisting
        accessNote.text = LinkAccess.note(access)
        needsLayout = true
        invalidateIntrinsicContentSize()
        onChange?()
        onHeightChange?()
    }

    /// `space-y-4` between fields, `space-y-1.5` inside one.
    private func blocks(_ width: CGFloat) -> [(view: NSView, height: CGFloat, gapBefore: CGFloat)] {
        var b: [(NSView, CGFloat, CGFloat)] = []
        func field(_ views: [(NSView, CGFloat)]) {
            for (i, v) in views.enumerated() where !v.0.isHidden { b.append((v.0, v.1, b.isEmpty ? 0 : (i == 0 ? 16 : 6))) }
        }
        field([(machineTitle, 16), (machineSelect, 32)])
        field([(linkedNote, linkedNote.height(forWidth: width))])
        field([(throughNote, throughNote.height(forWidth: width))])
        field([(addressTitle, 16), (addressInput, 32), (addressHint, addressHint.height(forWidth: width))])
        field([(codeTitle, 16), (codeInput, 32), (codeHint, codeHint.height(forWidth: width))])
        field([(accessTitle, 16), (accessSelect, 32), (accessNote, accessNote.height(forWidth: width))])
        return b
    }

    public func height(forWidth width: CGFloat) -> CGFloat { blocks(width).reduce(0) { $0 + $1.gapBefore + $1.height } }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: bounds.width > 0 ? height(forWidth: bounds.width) : NSView.noIntrinsicMetric)
    }

    public override func layout() {
        super.layout()
        var y: CGFloat = 0
        for b in blocks(bounds.width) {
            y += b.gapBefore
            b.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: b.height)
            y += b.height
        }
    }
}

public enum LinkEnvironmentDialog {
    @MainActor
    public static func make(machines: [LinkableMachine], throughRoutes: [LinkThroughRoute] = [], sourceLabel: String? = nil)
        -> (dialog: DialogView, form: LinkEnvironmentFormView, cancel: ButtonView, link: ButtonView) {
        let dialog = DialogView(title: "Link an environment",
                                message: "Agents here can then launch, message and wait on threads there. It appears under Authorized clients in that environment's Sharing & access, where it can be revoked.")
        dialog.maxWidth = 448
        let form = LinkEnvironmentFormView(machines: machines, throughRoutes: throughRoutes)
        dialog.panelContent = [form]
        let cancel = ButtonView("Cancel", variant: .outline)
        let link = ButtonView("Link", variant: .default)
        // The footer lays out once, so "Linking…" would spill out of a button sized for "Link".
        link.reservedTitles = ["Linking…"]
        dialog.footerButtons = [cancel, link]
        dialog.footerVariant = .bare
        form.onChange = { [weak link, weak cancel, weak form, weak dialog] in
            guard let form else { return }
            if let sourceLabel { dialog?.title = form.title(source: sourceLabel) }
            link?.isEnabled = !form.isBusy && form.ready
            link?.title = form.isBusy ? "Linking…" : "Link"
            cancel?.isEnabled = !form.isBusy
        }
        form.onChange?()
        return (dialog, form, cancel, link)
    }
}
