import AppKit
import DesignSystem
import T3Protocol

/// "Use T3 Code in another app (MCP)" (components/mcp/UseInAnotherAppDialog.tsx at 4928, PR #33196): a
/// wizard that hands the environment's public MCP address to a cloud app. A gate comes first, since the app
/// reaches T3 Code's server through its T3 Connect tunnel; then App, Access and Connect. On a server with
/// `mcpHostedApproval` the level is picked on the sign-in page, so Access is skipped and no code is needed.
///
/// The presenter owns every server call: it feeds `gate`, answers `onMint` with `setCode`, and handles copies
/// and links. The MCP endpoint is T3 Code's server, so the copy names T3 Code; nothing here names this window.
@MainActor
public final class UseInAnotherAppDialog {
    public enum Code: Equatable {
        case none, pending
        case live(credential: String, expiresAt: Date)
        case failed
    }
    public typealias Gate = UseInAnotherApp.Gate

    public let dialog: DialogView
    public var onClose: (() -> Void)?
    public var onSignIn: (() -> Void)?
    public var onCheckAgain: (() -> Void)?
    /// "Check again" for a saved machine that is not connected: rereads T3 Connect's machine list.
    public var onRefreshList: (() -> Void)?
    public var onManageAccess: (() -> Void)?
    public var onMint: ((McpClientAccess) -> Void)?
    /// Copy a value; the string is the row's label, for the toast title.
    public var onCopy: ((String, String) -> Void)?
    public var onOpenLink: ((String) -> Void)?
    /// The primary action: copy first when it says so, then open the app.
    public var onHandOff: ((UseInAnotherApp.Action, UseInAnotherApp.App) -> Void)?

    public var gate: Gate = .checking { didSet { if gate != oldValue { rebuild() } } }
    public var code: Code = .none { didSet { if code != oldValue { rebuild() } } }
    public var linked: [(name: String, access: String, expired: Bool)] = [] { didSet { rebuild() } }
    public var blocked: [McpClientAccess: String] = [:] { didSet { rebuild() } }

    let environment: String
    let hostedApproval: Bool
    private(set) var step = 0
    private(set) var choice: Int?          // index into `shownApps`, or `other`
    private var picked: McpClientAccess?
    private var anotherWay = false
    private let steps: WizardStepsView
    let body = McpColumn()
    private var ticker: Timer?
    static let other = -1

    public init(environment: String, hostedApproval: Bool) {
        self.environment = environment
        self.hostedApproval = hostedApproval
        steps = WizardStepsView(steps: hostedApproval ? ["App", "Connect"] : ["App", "Access", "Connect"])
        dialog = DialogView(kind: .dialog, title: UseInAnotherApp.title(environment: environment))
        // `WizardPopup` is `max-w-xl` (ui/wizard.tsx:18).
        dialog.maxWidth = 576
        dialog.isWizardPanel = true
        dialog.footerVariant = .bare
        dialog.panelContent = [body]
        steps.onStepChange = { [weak self] index in
            guard let self, index <= self.shownStep else { return }
            self.step = self.hostedApproval && index == 1 ? 2 : index
            self.rebuild()
        }
        rebuild()
    }

    var access: McpClientAccess? { picked ?? UseInAnotherApp.defaultLevel(blocked: blocked) }
    private var shownStep: Int { hostedApproval && step == 2 ? 1 : step }
    private var app: UseInAnotherApp.App? {
        guard let choice, choice >= 0 else { return nil }
        return UseInAnotherApp.shownApps[choice]
    }

    // MARK: Build

    func rebuild() {
        var items: [NSView] = []
        let isOpen: Bool
        if case .open(let url) = gate {
            isOpen = true
            switch step {
            case 0: items = appStep()
            case 1: items = accessStep()
            default: items = connectStep(url)
            }
        } else {
            isOpen = false
            items = gateScreen()
        }
        dialog.headerContent = isOpen ? steps : nil
        steps.currentStep = shownStep
        for (i, v) in steps.stepViews.enumerated() { v.isEnabled = i <= shownStep }
        body.items = items
        dialog.panelContent = [body]
        dialog.footerButtons = isOpen ? footer() : []
        dialog.footerLeadingCount = isOpen && step == 2 ? 1 : 0
        updateTicker()
        dialog.needsLayout = true
        dialog.superview?.needsLayout = true
    }

    private func footer() -> [NSView] {
        var out: [NSView] = []
        if step == 2 {
            let manage = ButtonView("Manage access", variant: .ghost, size: .default)
            manage.action = { [weak self] in self?.onManageAccess?() }
            out.append(manage)
        }
        if step == 1 {
            let back = ButtonView("Back", variant: .outline, size: .default)
            back.action = { [weak self] in self?.step = 0; self?.rebuild() }
            out.append(back)
        }
        if step == 2 {
            let done = ButtonView("Done", size: .default)
            done.action = { [weak self] in self?.onClose?() }
            out.append(done)
        } else {
            let next = ButtonView("Next", size: .default)
            next.isEnabled = step == 0 ? choice != nil : access != nil
            next.action = { [weak self] in
                guard let self else { return }
                self.step = self.step == 0 ? (self.hostedApproval ? 2 : 1) : 2
                self.anotherWay = self.choice == Self.other
                self.rebuild()
            }
            out.append(next)
        }
        return out
    }

    private func gateScreen() -> [NSView] {
        let name = environment
        let offlineTitle = "\(name)'s T3 Connect is offline"
        let cannotCheck = "Can't check T3 Connect on \(name)"
        let checkAgain = { [weak self] in self?.button("Check again", .outline) { self?.onCheckAgain?() } ?? NSView() }
        switch gate {
        case .checking:
            return [McpStatusLine("Checking T3 Connect…")]
        case .signIn:
            return message("Sign in to T3 Connect", lines: [
                "Apps like Poke and Claude run in the cloud. They need a public address to reach \(name).",
                "T3 Connect gives \(name) that address. Each app still needs your approval.",
            ], [button("Sign in to T3 Connect", .default) { [weak self] in self?.onSignIn?() }])
        case .disconnected(let relay):
            guard let relay else { return message("Connect to \(name) first.") }
            return message(relay == .offline ? offlineTitle : cannotCheck, [button("Check again", .outline) { [weak self] in self?.onRefreshList?() }])
        case .update:
            return message("Update T3 Code on \(name)")
        case .noRelayRead:
            return message(cannotCheck, lines: ["This device needs the View relay permission on \(name)."])
        case .error(let text):
            return message(cannotCheck, lines: [text], [checkAgain()])
        case .offline(let reach):
            let lines = reach.map { [$0.reason ?? "", "Fix: \($0.fix ?? "")"] } ?? []
            return message(reach == nil ? cannotCheck : offlineTitle, lines: lines, [checkAgain()])
        case .turnOn:
            // CandyWrapper cannot link a backend to T3 Connect (`useT3ConnectTurnOn` reads `on-host` here),
            // so it shows the host command, as T3 does for a machine it does not run.
            let restart = McpText("Restart T3 Code on \(name).", size: 14)
            return message("Turn on T3 Connect for \(name)", lines: [
                "\(name) gets a public https address, with no router setup.",
                "Only apps you approve can use it. You can turn it off in Settings.",
            ], [McpCopyRow(command: "t3 connect link", onCopy: { [weak self] in self?.onCopy?($0, "Command") }), restart, checkAgain()], gap: 8)
        case .open:
            return []
        }
    }

    /// `GateMessage`: `text-base font-medium` title, muted `text-sm` lines `space-y-1`, then the actions, `space-y-3`.
    private func message(_ title: String, lines: [String] = [], _ actions: [NSView] = [], gap: CGFloat = 12) -> [NSView] {
        var out: [NSView] = [McpText(title, size: 16, weight: .medium)]
        if !lines.isEmpty { out.append(McpColumn(lines.map { McpText($0, size: 14, muted: true) }, gap: 4)) }
        if actions.count > 1 { out.append(McpColumn(actions, gap: gap)) } else { out += actions }
        return [McpColumn(out, gap: 12)]
    }

    private func button(_ title: String, _ variant: ButtonView.Variant, _ action: @escaping @MainActor @Sendable () -> Void) -> NSView {
        let b = ButtonView(title, variant: variant, size: .default)
        b.action = action
        return McpLeading(b)
    }

    private func appStep() -> [NSView] {
        let grid = McpAppGrid(apps: UseInAnotherApp.shownApps, selected: choice)
        grid.onSelect = { [weak self] i in self?.choice = i; self?.rebuild() }
        let other = McpChoiceButton(title: "Something else…", selected: choice == Self.other)
        other.action = { [weak self] in self?.choice = Self.other; self?.rebuild() }
        return [McpColumn([McpText("Which app?", size: 14, weight: .medium), grid, other], gap: 12)]
    }

    private func accessStep() -> [NSView] {
        let heading = app.map { "What can \($0.name) do?" } ?? "What can the app do?"
        let options = McpClientAccess.allCases.map { level -> NSView in
            let option = McpAccessOption(level: level, selected: level == access, disabledReason: blocked[level])
            option.action = { [weak self] in self?.picked = level; self?.rebuild() }
            return option
        }
        let group = McpColumn(options, gap: 12)
        group.setAccessibilityRole(.radioGroup)
        group.setAccessibilityLabel(heading)
        return [McpColumn([McpText(heading, size: 14, weight: .medium), group], gap: 12)]
    }

    private func connectStep(_ url: String) -> [NSView] {
        let level = hostedApproval ? nil : access
        let codeView: NSView = level.map(approvalCode) ?? McpText(
            app.map { "When \($0.name) opens the sign-in page, choose what it may do and approve with your T3 Connect account." }
                ?? "When the app opens the sign-in page, choose what it may do and approve with your T3 Connect account.",
            size: 14, muted: true)
        let linkedLine = UseInAnotherApp.linkedLine(linked, access: level).map { McpText($0, size: 12, muted: true) }
        let urlRow = McpCopyRow(label: "URL", value: url) { [weak self] in self?.onCopy?($0, "URL") }
        var items: [NSView] = []
        if anotherWay || app == nil {
            items.append(urlRow)
            if let message = UseInAnotherApp.message(app, mcpURL: url) {
                items.append(McpCopyRow(label: "Message", value: message) { [weak self] in self?.onCopy?($0, "Message") })
            }
            items.append(McpSteps(app?.steps ?? UseInAnotherApp.otherSteps))
            if let app {
                if let docs = app.docs { items.append(McpTextButton("\(app.name) help") { [weak self] in self?.onOpenLink?(docs) }) }
            } else {
                items.append(McpText("Apps that require their own client ID cannot connect.", size: 12, muted: true))
            }
            items.append(codeView)
            if let app {
                if case .commands = app.handoff {
                    items.append(McpTextButton("Back to commands") { [weak self] in self?.anotherWay = false; self?.rebuild() })
                } else {
                    items.append(McpTextButton("Back to one click") { [weak self] in self?.anotherWay = false; self?.rebuild() })
                }
            }
        } else if let app {
            items.append(primaryAction(app, url))
            items.append(urlRow)
            items.append(codeView)
            items.append(McpTextButton("Set up another way") { [weak self] in self?.anotherWay = true; self?.rebuild() })
        }
        if let linkedLine { items.append(linkedLine) }
        return [McpColumn(items, gap: 16)]
    }

    private func primaryAction(_ app: UseInAnotherApp.App, _ url: String) -> NSView {
        var items: [NSView] = []
        if let action = UseInAnotherApp.action(app, mcpURL: url) {
            let b = ButtonView(action.label, size: .default)
            b.action = { [weak self] in self?.onHandOff?(action, app) }
            items.append(McpFull(b))
        } else if case .commands(let commands) = app.handoff {
            items += commands(url).map { McpCopyRow(command: $0) { [weak self] in self?.onCopy?($0, "Command") } }
            items.append(McpText("Run these where \(app.name) runs.", size: 12, muted: true))
        }
        if let note = app.note { items.append(McpText(note, size: 12, muted: true)) }
        return McpColumn(items, gap: 8)
    }

    /// `ApprovalCode`: Get code mints on click; the code is never copied or sent anywhere by itself.
    private func approvalCode(_ level: McpClientAccess) -> NSView {
        let levelName = UseInAnotherApp.label(level)
        let label = LabelView("Code to approve \(levelName)", font: DSFont.ui(14), color: Themed.color(\.foreground))
        label.lineHeight = 20
        label.emphasizedSuffix = levelName
        var row: [NSView] = [label]
        var below: [NSView] = []
        let live: (String, Date)? = { if case .live(let c, let e) = code, e > Date() { return (c, e) }; return nil }()
        if live == nil {
            let pending = code == .pending
            let b = ButtonView(pending ? "Getting code…" : hadCode ? "New code" : "Get code", variant: .outline, size: .sm)
            b.isEnabled = !pending
            b.action = { [weak self] in self?.onMint?(level) }
            row.append(b)
        }
        if let live {
            below.append(McpCopyRow(label: "Code", value: live.0) { [weak self] in self?.onCopy?($0, "Code") })
            below.append(McpText(UseInAnotherApp.expiry(secondsLeft: Int(live.1.timeIntervalSinceNow.rounded(.down))), size: 12, muted: true))
        } else if hadCode, code != .pending {
            below.append(McpText("The code expired.", size: 12, muted: true))
        }
        if code == .failed {
            below.append(McpText("Could not get a code from \(environment). Try again.", size: 12, color: Themed.color(\.destructiveForeground)))
        }
        return McpColumn([McpSpread(row)] + below, gap: 6)
    }
    /// Whether a code was minted before, so the button reads New code.
    private var hadCode = false

    /// `useNowSecond`: the expiry counts down once a second while a live code shows; nothing ticks otherwise.
    private func updateTicker() {
        if case .live(_, let expires) = code {
            hadCode = true
            if expires > Date() {
                guard ticker == nil else { return }
                ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.dialog.window == nil { self.stop(); return }
                        self.rebuild()
                    }
                }
                ticker?.tolerance = 0.2
                return
            }
        }
        stop()
    }

    public func stop() { ticker?.invalidate(); ticker = nil }
}

// MARK: Pieces

/// Something that knows its height at a width.
@MainActor protocol McpSized: NSView { func height(forWidth width: CGFloat) -> CGFloat }

@MainActor func mcpHeight(_ view: NSView, _ width: CGFloat) -> CGFloat {
    (view as? McpSized)?.height(forWidth: width) ?? view.intrinsicContentSize.height
}

/// `space-y-*`: children top to bottom at the full width.
final class McpColumn: DSView, McpSized {
    var gap: CGFloat
    var items: [NSView] = [] { didSet { attach(oldValue) } }
    init(_ items: [NSView] = [], gap: CGFloat = 16) {
        self.gap = gap
        self.items = items
        super.init(frame: .zero)
        attach([])
    }
    private func attach(_ old: [NSView]) {
        for v in old where !items.contains(where: { $0 === v }) { v.removeFromSuperview() }
        for v in items where v.superview !== self { addSubview(v) }
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat {
        let shown = items.filter { !$0.isHidden }
        return shown.reduce(0) { $0 + mcpHeight($1, width) } + CGFloat(max(0, shown.count - 1)) * gap
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width)) }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for v in items where !v.isHidden {
            let h = mcpHeight(v, bounds.width)
            v.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
            y += h + gap
        }
    }
}

/// A wrapped text block at T3's size: `text-xs` 12/16, `text-sm` 14/20, `text-base` 16/24.
final class McpText: DSView, McpSized {
    let text = TextBlockView()
    init(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false, color: NSColor? = nil) {
        super.init(frame: .zero)
        text.font = DSFont.ui(size, weight: weight)
        text.lineHeight = size == 12 ? 16 : size == 14 ? 20 : 24
        text.color = color ?? Themed.color(muted ? \.mutedForeground : \.foreground)
        text.text = string
        addSubview(text)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(string)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.naturalWidth) + 1, height: height(forWidth: bounds.width)) }
    override func layout() { super.layout(); text.frame = bounds }
}

/// Keeps a control at its own width at the start of the row.
final class McpLeading: DSView, McpSized {
    let control: NSView
    init(_ control: NSView) { self.control = control; super.init(frame: .zero); addSubview(control) }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { control.intrinsicContentSize.height }
    override func layout() { super.layout(); control.frame = NSRect(origin: .zero, size: control.intrinsicContentSize) }
}

/// `w-full`: a control stretched across the row.
final class McpFull: DSView, McpSized {
    let control: NSView
    init(_ control: NSView) { self.control = control; super.init(frame: .zero); addSubview(control) }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { control.intrinsicContentSize.height }
    override func layout() { super.layout(); control.frame = bounds }
}

/// `flex flex-wrap items-center justify-between gap-2`: the first view at the start, the rest at the end.
final class McpSpread: DSView, McpSized {
    let views: [NSView]
    init(_ views: [NSView]) { self.views = views; super.init(frame: .zero); views.forEach(addSubview) }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { views.map { mcpHeight($0, width) }.max() ?? 0 }
    override func layout() {
        super.layout()
        let h = bounds.height
        var x = bounds.width
        for v in views.dropFirst().reversed() {
            let s = v.intrinsicContentSize
            x -= s.width
            v.frame = NSRect(x: x, y: (h - s.height) / 2, width: s.width, height: s.height)
            x -= 8
        }
        if let first = views.first {
            let fh = mcpHeight(first, x)
            first.frame = NSRect(x: 0, y: (h - fh) / 2, width: max(0, x), height: fh)
        }
    }
}

/// `role="status"`: the small muted spinner and "Checking T3 Connect…".
final class McpStatusLine: DSView, McpSized {
    private let spinner = SpinnerView(size: .sm, tone: .muted)
    private let label: McpText
    init(_ text: String) {
        label = McpText(text, size: 14, muted: true)
        super.init(frame: .zero)
        addSubview(spinner); addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 20 }
    override func layout() {
        super.layout()
        spinner.frame = NSRect(x: 0, y: 3, width: 14, height: 14)
        label.frame = NSRect(x: 22, y: 0, width: max(0, bounds.width - 22), height: 20)
    }
}

/// `CopyRow` and `CommandBlock`: a muted rounded box with the label or `$`, the mono value, and a copy button
/// that shows a check for 1.5 s.
final class McpCopyRow: DSView, McpSized {
    private let label: LabelView
    private let value: LabelView
    private let copy = ButtonView(nil, icon: .copy, variant: .ghost, size: .iconXs)
    private let command: Bool
    private var reset: DispatchWorkItem?

    init(label text: String, value string: String, onCopy: @escaping (String) -> Void) {
        command = false
        label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        value = LabelView(string, font: DSFont.mono(14), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        setUp(string, accessibility: "Copy \(text)", onCopy)
    }
    init(command string: String, onCopy: @escaping (String) -> Void) {
        command = true
        label = LabelView("$", font: DSFont.mono(14), color: Themed.color(\.mutedForeground))
        value = LabelView(string, font: DSFont.mono(14), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        setUp(string, accessibility: "Copy command", onCopy)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setUp(_ string: String, accessibility: String, _ onCopy: @escaping (String) -> Void) {
        label.lineHeight = command ? 20 : 16; value.lineHeight = 20; value.truncates = true
        for v in [label, value, copy] as [NSView] { addSubview(v) }
        copy.iconSize = 14
        copy.setAccessibilityLabel(accessibility)
        copy.action = { [weak self] in
            onCopy(string)
            guard let self else { return }
            self.copy.icon = .check
            self.reset?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.copy.icon = .copy }
            self.reset = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    /// `py-2` around the 24 px button, or `py-2.5` for a command.
    func height(forWidth width: CGFloat) -> CGFloat { command ? 46 : 42 }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(\.border).cgColor(in: self)
        layer?.backgroundColor = Themed.color(\.muted, 0.5).cgColor(in: self)
    }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        let h = bounds.height, pad: CGFloat = 12
        let lw = ceil(label.textWidth)
        let bs = copy.intrinsicContentSize
        copy.frame = NSRect(x: bounds.width - pad - bs.width, y: (h - bs.height) / 2, width: bs.width, height: bs.height)
        label.frame = NSRect(x: pad, y: (h - (command ? 20 : 16)) / 2, width: lw + 1, height: command ? 20 : 16)
        let vx = pad + lw + (command ? 8 : 8)
        value.frame = NSRect(x: vx, y: (h - 20) / 2, width: max(0, copy.frame.minX - 8 - vx), height: 20)
    }
}

/// `list-decimal space-y-1 ps-5 text-sm`.
final class McpSteps: DSView, McpSized {
    private var rows: [(LabelView, TextBlockView)] = []
    init(_ steps: [String]) {
        super.init(frame: .zero)
        for (i, s) in steps.enumerated() {
            let n = LabelView("\(i + 1).", font: DSFont.ui(14), color: Themed.color(\.foreground))
            n.alignment = .right
            let t = TextBlockView()
            t.font = DSFont.ui(14); t.lineHeight = 20; t.text = s
            addSubview(n); addSubview(t)
            rows.append((n, t))
        }
        setAccessibilityElement(true); setAccessibilityRole(.list)
        setAccessibilityLabel(steps.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: " "))
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat {
        rows.reduce(0) { $0 + $1.1.height(forWidth: width - 20) } + CGFloat(max(0, rows.count - 1)) * 4
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (n, t) in rows {
            let h = t.height(forWidth: bounds.width - 20)
            n.frame = NSRect(x: 0, y: y, width: 16, height: 20)
            t.frame = NSRect(x: 20, y: y, width: bounds.width - 20, height: h)
            y += h + 4
        }
    }
}

/// `TextButton`: `text-sm font-medium`, underlined on hover and keyboard focus.
final class McpTextButton: ControlView, McpSized {
    private let label: LabelView
    init(_ title: String, action: @escaping @MainActor @Sendable () -> Void) {
        label = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        label.lineHeight = 20
        addSubview(label)
        self.action = action
        scalesWhenPressed = false
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 20 }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.isUnderlined = state.hovered || state.focusVisible
        label.underlineDecoration = (4, 1)
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 0, width: ceil(label.textWidth) + 1, height: 20)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return p.x <= ceil(label.textWidth) + 1 && bounds.contains(p) ? self : nil
    }
}

/// The app tiles: `grid grid-cols-4 gap-2` of `rounded-lg px-1 py-3` buttons with a 40 px logo and the name.
final class McpAppGrid: DSView, McpSized {
    var onSelect: ((Int) -> Void)?
    private var tiles: [McpAppTile] = []
    init(apps: [UseInAnotherApp.App], selected: Int?) {
        super.init(frame: .zero)
        for (i, app) in apps.enumerated() {
            let tile = McpAppTile(app: app, selected: i == selected)
            tile.action = { [weak self] in self?.onSelect?(i) }
            tiles.append(tile); addSubview(tile)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat {
        let rows = CGFloat((tiles.count + 3) / 4)
        return rows * 90 + max(0, rows - 1) * 8
    }
    override func layout() {
        super.layout()
        let w = (bounds.width - 24) / 4
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: CGFloat(i % 4) * (w + 8), y: CGFloat(i / 4) * 98, width: w, height: 90)
        }
    }
}

final class McpAppTile: ControlView {
    private let logo = CALayer()
    private let ring = CALayer()
    private let name: LabelView
    private let selected: Bool
    init(app: UseInAnotherApp.App, selected: Bool) {
        self.selected = selected
        name = LabelView(app.name, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        name.lineHeight = 16; name.alignment = .center
        logo.contents = Self.image(app.logo)
        logo.contentsGravity = .resizeAspectFill
        logo.cornerRadius = 8; logo.masksToBounds = true
        ring.cornerRadius = 9; ring.borderWidth = 1
        for l in [logo, ring] { l.actions = ["position": NSNull(), "bounds": NSNull()]; layer?.addSublayer(l) }
        addSubview(name)
        setAccessibilityRole(.button); setAccessibilityLabel(app.name)
        setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    static func image(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "mcp-logos"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = (selected ? Themed.color(\.primary) : NSColor.clear).cgColor(in: self)
        layer?.backgroundColor = (selected ? Themed.color(\.primary, 0.08) : state.hovered ? Themed.color(\.accent) : NSColor.clear).cgColor(in: self)
        ring.borderColor = (effectiveAppearance.isDark ? Themed.white(0.12) : Themed.black(0.1)).cgColor(in: self)
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() {
        super.layout()
        let x = (bounds.width - 40) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        logo.frame = CGRect(x: x, y: 13, width: 40, height: 40)
        ring.frame = logo.frame.insetBy(dx: -1, dy: -1)
        CATransaction.commit()
        name.frame = NSRect(x: 5, y: 61, width: bounds.width - 10, height: 16)
    }
}

/// "Something else…": `w-full rounded-lg border px-3 py-2.5 text-sm font-medium`.
final class McpChoiceButton: ControlView, McpSized {
    private let label: LabelView
    private let selected: Bool
    init(title: String, selected: Bool) {
        self.selected = selected
        label = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        label.lineHeight = 20; label.alignment = .center
        addSubview(label)
        setAccessibilityRole(.button); setAccessibilityLabel(title); setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 42 }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Themed.color(selected ? \.primary : \.border).cgColor(in: self)
        layer?.backgroundColor = (selected ? Themed.color(\.primary, 0.08) : state.hovered ? Themed.color(\.accent) : NSColor.clear).cgColor(in: self)
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() { super.layout(); label.frame = NSRect(x: 12, y: 11, width: bounds.width - 24, height: 20) }
}

/// `AccessOption` (auth/ConnectAgentSurface.tsx:453-496): a radio card with the level's icon, label and line.
final class McpAccessOption: ControlView, McpSized {
    private let icon: IconView
    private let title: LabelView
    private let detail = TextBlockView()
    private let ring = CALayer()
    private let selected: Bool
    init(level: McpClientAccess, selected: Bool, disabledReason: String?) {
        self.selected = selected
        let name: IconName = switch level {
        case .readOnly: .eye
        case .approvalRequired: .lock
        case .autoAcceptEdits: .penLine
        case .auto: .shieldCheck
        case .fullAccess: .shieldOff
        }
        icon = IconView(name: name, size: 16)
        title = LabelView(UseInAnotherApp.label(level), font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        super.init(frame: .zero)
        scalesWhenPressed = false
        icon.strokeColor = Themed.color(selected ? \.primary : \.mutedForeground)
        title.lineHeight = 20
        detail.font = DSFont.ui(12); detail.lineHeight = 16; detail.color = Themed.color(\.mutedForeground)
        detail.text = disabledReason ?? UseInAnotherApp.description(level)
        for v in [icon, title, detail] as [NSView] { addSubview(v) }
        ring.actions = ["position": NSNull(), "bounds": NSNull()]
        ring.isHidden = !selected
        layer?.addSublayer(ring)
        isEnabled = disabledReason == nil
        alphaValue = disabledReason == nil ? 1 : 0.64
        setAccessibilityRole(.radioButton); setAccessibilityLabel(title.text)
        setAccessibilityValue(selected ? 1 : 0); setAccessibilityHelp(detail.text)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(forWidth width: CGFloat) -> CGFloat { 10 + 20 + detail.height(forWidth: width - 26 - 28) + 10 + 2 }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        layer?.cornerRadius = 8
        if selected {
            // `ring-2 ring-inset ring-primary/25` inside the border, `ring-1 ring-primary/30` on a clear one in dark.
            layer?.borderWidth = 1
            layer?.borderColor = (dark ? NSColor.clear : Themed.color(\.primary)).cgColor(in: self)
            layer?.backgroundColor = (dark ? Themed.color(\.primary, 0.1) : Themed.color(\.background)).cgColor(in: self)
            ring.borderWidth = dark ? 1 : 2
            ring.borderColor = Themed.color(\.primary, dark ? 0.3 : 0.25).cgColor(in: self)
            ring.cornerRadius = 7
        } else {
            layer?.borderWidth = dark ? 0 : 1
            layer?.borderColor = Themed.color(\.border).cgColor(in: self)
            layer?.backgroundColor = (state.hovered ? (dark ? Themed.color(\.accent) : Themed.color(\.muted, 0.5)) : dark ? Themed.white(0.035) : Themed.color(\.background)).cgColor(in: self)
        }
    }
    override func stateDidChange(from old: State) { super.stateDidChange(from: old); needsDisplay = true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
        icon.frame = NSRect(x: 13, y: 13, width: 16, height: 16)
        title.frame = NSRect(x: 41, y: 11, width: bounds.width - 54, height: 20)
        detail.frame = NSRect(x: 41, y: 31, width: bounds.width - 54, height: detail.height(forWidth: bounds.width - 54))
    }
}
