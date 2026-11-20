import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The Welcome page (WelcomePage.tsx:255-344 at Nightly 4928): one computer's agents, its projects to import
/// and, on the primary computer with T3 Connect, the phone. It fills the window; the App lays it over the shell.
@MainActor
public final class WelcomePageView: DSView {
    public let model: WelcomePageModel
    private let context: SettingsPageContext
    private let content: WelcomePageContent
    private let scroll: ScrollAreaView
    /// The window's title bar strip, kept clear (`WorkspacePageHeader electron`).
    public var topInset: CGFloat = 0 { didSet { needsLayout = true } }
    /// CandyWrapper's own name in the heading; the fidelity test passes T3's to compare the rest.
    public var heading: String {
        get { content.title.text }
        set { content.title.text = newValue }
    }

    public init(model: WelcomePageModel, context: SettingsPageContext) {
        self.model = model; self.context = context
        content = WelcomePageContent(model: model, context: context)
        scroll = ScrollAreaView(documentView: content)
        scroll.scrollsHorizontally = false
        super.init(frame: .zero)
        addSubview(scroll)
        setAccessibilityRole(.group); setAccessibilityLabel("Welcome")
        content.onHeightChange = { [weak self] in self?.needsLayout = true }
        model.observe { [weak self] in self?.content.rebuild() }
        content.rebuild()
    }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { layer?.backgroundColor = Themed.color(\.background).cgColor(in: self) }
    public override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        let width = scroll.contentWidth > 0 ? scroll.contentWidth : bounds.width
        content.minimumHeight = scroll.frame.height
        content.frame = NSRect(x: 0, y: 0, width: width, height: content.height(forWidth: width))
        content.layoutSubtreeIfNeeded()
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { content.tearDown() }
    }
}

/// The scrolling column: `mx-auto max-w-3xl px-6 pt-20 pb-8`, the heading, the bands and the footer.
@MainActor
final class WelcomePageContent: DSView {
    let model: WelcomePageModel
    let context: SettingsPageContext
    var onHeightChange: (() -> Void)?
    var minimumHeight: CGFloat = 0

    let title = LabelView("Welcome to CandyWrapper", font: DSFont.ui(24, weight: .semibold), color: Themed.color(\.foreground))
    private let subtitle = LabelView("", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private let topLine = WelcomeLine()
    private let agents: WelcomeSection
    private let projects: WelcomeSection
    private let phone: WelcomeSection
    private let startWithout = ButtonView("Start without an agent", variant: .ghostMuted)
    private let hint = LabelView("Set up one agent to start.", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let start = ButtonView("Start")
    private let notice = LabelView("T3 Code collects anonymous usage data to improve the app. To opt out, see the",
                                   font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))
    private let privacy = WelcomeLinkView("privacy policy")
    private let period = LabelView(".", font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))

    // View state that T3 keeps in the sections' React state.
    var moreOpen: Bool?
    var reviewing = false
    var phoneOpen = false
    var codexSetupId: String?
    var lastCodex: ServerProvider?
    var cliTerminalFor: String?
    var terminal: WelcomeInstallTerminalView?
    var codexCard: CodexSetupView?
    private let importList = OnboardingImportListView()
    private var phoneTimer: Task<Void, Never>?
    private var phoneLink: PhoneLink = .unknown

    enum PhoneLink: Equatable { case unknown, checking, failed, loaded(CloudLinkState) }

    init(model: WelcomePageModel, context: SettingsPageContext) {
        self.model = model; self.context = context
        agents = WelcomeSection("Agents")
        projects = WelcomeSection("Projects")
        phone = WelcomeSection("Phone")
        super.init(frame: .zero)
        title.lineHeight = 32
        title.tracking = -0.6
        subtitle.lineHeight = 20
        hint.lineHeight = 16
        notice.lineHeight = 17.875; period.lineHeight = 17.875
        [title, subtitle, topLine, agents, projects, phone, startWithout, hint, start, notice, privacy, period].forEach(addSubview)
        start.action = { [weak self] in self?.model.start() }
        startWithout.action = { [weak self] in self?.model.start() }
        privacy.action = { [weak self] in
            if let url = URL(string: "https://t3.codes/privacy-policy") { self?.context.openURL?(url) }
        }
        importList.onSelectionChange = { [weak self] keys in self?.model.setSelectedKeys(keys) }
        importList.onRetry = { [weak self] _ in self?.model.refreshScan() }
    }

    func tearDown() {
        phoneTimer?.cancel(); phoneTimer = nil
        terminal?.close()
    }

    // MARK: Building

    func rebuild() {
        let groups = model.groups
        subtitleRun.text = model.label
        _ = subtitleTail
        buildAgents(groups)
        buildProjects()
        phone.isHidden = !model.offersPhone
        if model.offersPhone { buildPhone() } else { phoneTimer?.cancel(); phoneTimer = nil }
        let ready = groups.readyCount > 0
        startWithout.isHidden = ready
        hint.isHidden = ready
        startWithout.isEnabled = !model.importing
        start.isEnabled = ready && !model.importing
        let picks = model.writable ? model.selected : []
        start.title = WelcomePageLogic.startTitle(importing: model.importing, selected: picks.count, new: picks.filter(model.isNew).count)
        needsLayout = true
        onHeightChange?()
    }

    /// "Setting up <label>." with the label in the foreground color.
    private lazy var subtitleRun: LabelView = {
        let l = LabelView("", font: DSFont.ui(14), color: Themed.color(\.foreground)); l.lineHeight = 20; addSubview(l); return l
    }()
    private lazy var subtitleTail: LabelView = {
        let l = LabelView(".", font: DSFont.ui(14), color: Themed.color(\.mutedForeground)); l.lineHeight = 20; addSubview(l); return l
    }()

    // MARK: Agents (WelcomePage.tsx:445-773)

    private func buildAgents(_ groups: WelcomePageLogic.Groups) {
        let settings = model.settings
        if moreOpen == nil && !groups.checking && groups.found.isEmpty { moreOpen = true }
        let showMore = moreOpen ?? false
        // Codex's card, kept by instance while its status changes.
        let listed = codexSetupId.flatMap { id in model.providers?.first { $0.instanceId.rawValue == id } }
        if let listed { lastCodex = listed }
        let codexProvider = WelcomePageLogic.codexCardProvider(model.providers, instanceId: codexSetupId, last: lastCodex, settings: settings)
        if listed != nil && codexProvider == nil { codexSetupId = nil }
        // "Use existing CLI" opens the CLI's terminal once Codex has checked it.
        if let id = cliTerminalFor, let cli = model.providers?.first(where: { $0.instanceId.rawValue == id }) {
            let step = WelcomePageLogic.cliTerminalStep(cli, settings: settings)
            if step != .wait { cliTerminalFor = nil; if step == .open { openTerminal(cli) } }
        }

        var rows: [NSView] = groups.found.map { provider in
            let state = WelcomePageLogic.state(provider, settings: settings)
            return WelcomeAgentRow(provider: provider, state: state, compact: false, action: action(for: provider, state: state))
        }
        if groups.checking && groups.found.isEmpty {
            rows.append(WelcomeTextRow("Checking \(model.label)…", font: DSFont.ui(14), lineHeight: 40))
        }
        let all = groups.found + groups.available
        if !model.canOperateTerminal && all.contains(where: { WelcomePageLogic.needsTerminal($0, settings: settings) || WelcomePageLogic.codexNeedsSetup($0, settings: settings) }) {
            rows.append(WelcomeTextRow("This connection cannot control terminals.", font: DSFont.ui(12), lineHeight: 16, indent: 32))
        }
        if !model.canManageProviders {
            rows.append(WelcomeTextRow("This connection cannot manage agents.", font: DSFont.ui(12), lineHeight: 16, indent: 32))
        }
        let trigger = WelcomeMoreTrigger(title: groups.found.isEmpty ? "Set up an agent" : "Add more agents", emphasized: groups.found.isEmpty,
                                         open: showMore, logos: showMore ? [] : groups.available.prefix(6).map { ($0.driver, WelcomePageLogic.name($0)) },
                                         acp: true)
        trigger.action = { [weak self] in
            guard let self else { return }
            moreOpen = !(moreOpen ?? false); rebuild()
        }
        rows.append(trigger)
        if showMore {
            let grid = WelcomeAgentGrid(rows: groups.available.map { provider in
                let state = WelcomePageLogic.state(provider, settings: settings)
                return WelcomeAgentRow(provider: provider, state: state, compact: true, action: action(for: provider, state: state))
            })
            rows.append(grid)
            let browse = ButtonView("Browse", variant: .outline, size: .xs)
            browse.isEnabled = model.canManageProviders
            browse.action = { [weak self] in self?.model.openSettings?(.providers) }
            rows.append(WelcomeIconRow(icon: IconView(name: .brandACPRegistry, size: 16, strokeColor: Themed.color(\.mutedForeground)),
                                       text: "More agents in the ACP Registry", action: browse, height: 36))
        }
        if let codexProvider, let card = card(for: codexProvider) {
            rows.append(WelcomeInset(card, top: 8))
        } else {
            codexCard = nil
        }
        if let terminal { rows.append(WelcomeInset(terminal, top: 16)) }
        agents.rows = rows
    }

    /// One action per agent, the same in the list and in the grid (WelcomePage.tsx:546-614).
    private func action(for provider: ServerProvider, state: WelcomePageLogic.AgentState) -> NSView? {
        let settings = model.settings
        func button(_ title: String, icon: IconName? = nil, _ run: @escaping @MainActor @Sendable () -> Void) -> ButtonView {
            let b = ButtonView(title, icon: icon, variant: .outline, size: .xs)
            if icon != nil { b.iconSize = 14 }
            b.setAccessibilityLabel("\(title): \(WelcomePageLogic.name(provider))")
            b.action = run
            return b
        }
        let toSettings: @MainActor @Sendable () -> Void = { [weak self] in self?.model.openSettings?(.providers) }
        if state == .disabled {
            let b = button("Turn on") { [weak self] in self?.turnOn(provider) }
            b.isEnabled = model.canManageProviders && settings != nil
            return b
        }
        if WelcomePageLogic.brokenVersion(provider) { return button("Update", toSettings) }
        if settings != nil && WelcomePageLogic.codexNeedsSetup(provider, settings: settings) {
            let id = provider.instanceId.rawValue
            let b = button("Set up") { [weak self] in
                guard let self else { return }
                codexSetupId = codexSetupId == id ? nil : id
                rebuild()
            }
            b.setAccessibilityExpanded(codexSetupId == id)
            return b
        }
        if WelcomePageLogic.needsTerminal(provider, settings: settings) {
            let b = button(state == .signIn ? "Sign in" : "Install", icon: .terminal) { [weak self] in self?.openTerminal(provider) }
            b.isEnabled = terminal?.instanceId != provider.instanceId.rawValue && settings != nil && model.canOperateTerminal
            return b
        }
        return button(state == .signIn ? "Sign in" : state == .attention ? "Details" : "Set up", toSettings)
    }

    private func turnOn(_ provider: ServerProvider) {
        let id = provider.instanceId.rawValue
        let instance = model.settings?["providerInstances"]?[id] ?? .object(["driver": .string(provider.driver)])
        let env = model.environmentId
        let payload = JSONValue.object(["patch": .object([:]), "providerInstanceMutation": .object([
            "operation": .string("upsert"), "instanceId": .string(id), "instance": WelcomePageLogic.turnedOn(instance)])])
        Task { [weak self] in
            guard let self, let request = context.request else { return }
            do {
                context.applySettings?(env, try await request(env, "server.updateSettings", payload))
                model.refreshProviders?(id)
                if ["claudeAgent", "codex", "pi"].contains(provider.driver) { model.refreshScan() }
            } catch {
                context.toast?("Could not turn on \(WelcomePageLogic.name(provider))", (error as? LocalizedError)?.errorDescription ?? "\(error)", .error)
            }
        }
    }

    private func card(for provider: ServerProvider) -> CodexSetupView? {
        let id = provider.instanceId.rawValue
        let instance = model.settings?["providerInstances"]?[id]
        let mode = CodexSetupLogic.setupMode(instance?["config"])
        if let codexCard, codexCard.instance == id {
            codexCard.update(provider: provider, enabled: provider.enabled, readOnly: !model.canManageProviders, mode: mode)
            return codexCard
        }
        let card = CodexSetupView(context: context, environment: model.environmentId, instance: id, provider: provider, enabled: provider.enabled,
                                  readOnly: !model.canManageProviders, presentation: .onboarding, mode: mode,
                                  allowExistingCli: model.canOperateTerminal, displayName: WelcomePageLogic.name(provider))
        card.onModeChange = { [weak self] mode in self?.changeCodexMode(provider, mode: mode) }
        card.onHeightChange = { [weak self] in self?.needsLayout = true; self?.onHeightChange?() }
        codexCard = card
        return card
    }

    /// `OnboardingCodexSetup.changeMode`: "Use existing CLI" also asks for the CLI's terminal.
    private func changeCodexMode(_ provider: ServerProvider, mode: String) {
        let id = provider.instanceId.rawValue
        cliTerminalFor = mode == "existing" ? id : nil
        let stored = model.settings?["providerInstances"]?[id]?.objectValue ?? ["driver": .string(provider.driver), "config": .object([:])]
        if CodexSetupLogic.setupMode(stored["config"]) == mode && provider.enabled { rebuild(); return }
        guard model.canManageProviders else { return }
        var next = stored
        var config = next["config"]?.objectValue ?? [:]
        config["enabled"] = .bool(true); config["setupMode"] = .string(mode)
        next["enabled"] = .bool(true); next["config"] = .object(config)
        let env = model.environmentId
        let payload = JSONValue.object(["patch": .object([:]), "providerInstanceMutation": .object([
            "operation": .string("upsert"), "instanceId": .string(id), "instance": .object(next)])])
        Task { [weak self] in
            guard let self, let request = context.request else { return }
            do { context.applySettings?(env, try await request(env, "server.updateSettings", payload)) }
            catch {
                cliTerminalFor = nil
                context.toast?("Could not save Codex setup", (error as? LocalizedError)?.errorDescription ?? "\(error)", .error)
            }
        }
    }

    private func openTerminal(_ provider: ServerProvider) {
        guard WelcomePageLogic.isInstallable(provider.driver), model.settings != nil, model.canOperateTerminal, let cwd = model.cwd else { return }
        let command = provider.installed
            ? WelcomePageLogic.loginCommand(provider, settings: model.settings, platform: model.platform)
            : WelcomePageLogic.installCommand(driver: provider.driver, platform: model.platform)
        terminal?.close()
        let id = provider.instanceId.rawValue
        let view = WelcomeInstallTerminalView(context: context, environmentId: model.environmentId, driver: provider.driver, instanceId: id,
                                              cwd: cwd, command: command)
        view.onCommandFinished = { [weak self] in self?.model.refreshProviders?(id) }
        view.onClose = { [weak self, weak view] in
            guard let self, terminal === view else { return }
            terminal?.close(); terminal = nil
            model.refreshProviders?(nil)
            rebuild()
        }
        terminal = view
        view.start()
        rebuild()
        DispatchQueue.main.async { [weak self, weak view] in
            guard let view else { return }
            self?.scrollToVisible(view.frame.insetBy(dx: 0, dy: -8).offsetBy(dx: 0, dy: view.superview?.frame.minY ?? 0))
        }
    }

    // MARK: Projects (WelcomePage.tsx:798-979)

    private func buildProjects() {
        let scan = model.scan
        let candidates = model.candidates
        let sources = WelcomePageLogic.importSourcesLabel
        if scan.pending && candidates.isEmpty && scan.candidates == nil {
            projects.isHidden = false
            projects.rows = [WelcomeTextRow("Looking for projects in your \(sources) history…", font: DSFont.ui(14), lineHeight: 40)]
            return
        }
        let retry = ButtonView("Retry", variant: .ghost, size: .sm)
        retry.action = { [weak self] in self?.model.refreshScan() }
        if let error = scan.error, candidates.isEmpty {
            projects.isHidden = false
            projects.rows = [WelcomeTextRow("Could not check projects. \(error)", font: DSFont.ui(14), lineHeight: 40, trailing: retry)]
            return
        }
        if candidates.isEmpty {
            projects.isHidden = !scan.truncated
            projects.rows = scan.truncated ? [WelcomeTextRow(OnboardingProjectImport.scanLimitMessage, font: DSFont.ui(12), lineHeight: 40)] : []
            return
        }
        projects.isHidden = false
        let canWrite = model.writable
        let selected = model.selected
        let keys = model.selectedKeys
        let defaults = model.defaultKeys
        let partial = !selected.isEmpty && selected.count < candidates.count
            && !(selected.count == defaults.count && defaults.allSatisfy(keys.contains))
        let row = WelcomeImportRow(title: canWrite && !selected.isEmpty
                                   ? "Import \(selected.count) \(selected.count == 1 ? "project" : "projects") and their threads"
                                   : "Import projects and their threads",
                                   detail: "From your \(sources) history",
                                   value: canWrite && partial ? .mixed : canWrite && !selected.isEmpty ? .on : .off)
        row.checkbox.isEnabled = !model.importing && canWrite
        row.checkbox.onChange = { [weak self] value in
            guard let self else { return }
            let on = value != .off
            model.setSelectedKeys(on ? Set(model.defaultKeys) : [], optedOut: !on)
        }
        if canWrite {
            let review = ButtonView(reviewing ? "Hide" : "Review all \(candidates.count)", variant: .ghostMuted, size: .xs)
            review.trailingIcon = reviewing ? .chevronUp : .chevronDown
            review.iconSize = 14
            review.setAccessibilityExpanded(reviewing)
            review.action = { [weak self] in guard let self else { return }; reviewing.toggle(); rebuild() }
            row.trailing = review
        }
        var rows: [NSView] = [row]
        if reviewing && canWrite {
            importList.update(scans: [.init(environmentId: model.environmentId, label: model.label, pending: false, error: nil,
                                            truncated: false, candidates: candidates)],
                              selected: keys, importing: model.importing, error: nil)
            rows.append(WelcomeInset(importList, top: 4, horizontal: -6))
        }
        if scan.truncated { rows.append(WelcomeTextRow(OnboardingProjectImport.scanLimitMessage, font: DSFont.ui(12), lineHeight: 16, indent: 32)) }
        if let error = scan.error {
            rows.append(WelcomeTextRow("Could not check projects again. \(error)", font: DSFont.ui(14), lineHeight: 20, indent: 32, trailing: retry))
        }
        if let error = model.importError {
            rows.append(WelcomeTextRow(error, font: DSFont.ui(14), lineHeight: 20, indent: 32, color: Themed.color(\.destructive), top: 4))
        }
        projects.rows = rows
    }

    // MARK: Phone (WelcomePage.tsx:981-1127)

    private func buildPhone() {
        let toggle = ButtonView(phoneOpen ? "Hide" : "Set up", variant: .ghostMuted, size: .xs)
        toggle.trailingIcon = phoneOpen ? .chevronUp : .chevronDown
        toggle.iconSize = 14
        toggle.action = { [weak self] in
            guard let self else { return }
            phoneOpen.toggle()
            if phoneOpen { refreshPhoneLink(); armPhoneTimer() } else { phoneTimer?.cancel(); phoneTimer = nil }
            rebuild()
        }
        var rows: [NSView] = [WelcomeIconRow(icon: IconView(name: .smartphone, size: 16, strokeColor: Themed.color(\.mutedForeground)),
                                             text: "Use T3 Code on your phone", action: toggle, height: 40, medium: true)]
        if phoneOpen { rows.append(WelcomePhonePanel(step2: phoneStep())) }
        phone.rows = rows
    }

    /// The server rechecks the tunnel every 30 s; read its latest result while the panel is open.
    private func armPhoneTimer() {
        phoneTimer?.cancel()
        phoneTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                refreshPhoneLink()
            }
        }
    }

    private func refreshPhoneLink() {
        guard let load = model.cloudLinkState else { return }
        if case .unknown = phoneLink { phoneLink = .checking }
        Task { [weak self] in
            let next: PhoneLink
            do { next = .loaded(try await load()) } catch { next = .failed }
            guard let self, phoneOpen else { return }
            phoneLink = next
            rebuild()
        }
    }

    /// `PhoneConnectLink`.
    private func phoneStep() -> [NSView] {
        func text(_ s: String) -> NSView { WelcomeWrappedText(s, font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.foreground)) }
        func settingsLink(_ title: String) -> NSView {
            let b = ButtonView(title, variant: .outline, size: .xs)
            b.action = { [weak self] in self?.model.openSettings?(.connections) }
            return b
        }
        if model.connectSignedOut || model.cloudLinkState == nil {
            let b = ButtonView("Sign in to T3 Connect", variant: .outline, size: .xs)
            b.action = { [weak self] in self?.model.signInToConnect?() }
            return [text("Sign in to T3 Connect here, then in the app with the same account."), b]
        }
        switch phoneLink {
        case .unknown, .checking:
            return [WelcomeWrappedText("Checking T3 Connect…", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.mutedForeground))]
        case .failed:
            return [text("Could not check T3 Connect."), settingsLink("Check T3 Connect")]
        case .loaded(let link):
            let shared = link.linked && link.tunnelActive
            let reachability = shared ? link.reachability?.status : nil
            if reachability == "reachable" {
                return [WelcomeWrappedText("Your phone can reach this computer. Sign in to the app with the same account.", font: DSFont.ui(14),
                                           lineHeight: 20, color: Themed.color(\.foreground), check: true)]
            }
            if shared && reachability == nil {
                return [text("T3 Connect is on for this computer. Sign in to the app with the same account.")]
            }
            return [text(shared ? "T3 Connect is on, but the app cannot reach this computer." : "Signed in. Share this computer so the app can reach it."),
                    settingsLink(shared ? "Check T3 Connect" : "Set up T3 Connect")]
        }
    }

    // MARK: Layout

    private struct Column { var x: CGFloat; var width: CGFloat; var top: CGFloat }
    private func column(_ width: CGFloat) -> Column {
        let inner = min(width, 768) - 48
        return Column(x: max(0, (width - min(width, 768)) / 2) + 24, width: max(0, inner), top: width >= 640 ? 80 : 48)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let c = column(width)
        var y = c.top + 32 + 6 + 20 + 40 + 1
        for section in [agents, projects, phone] where !section.isHidden { y += section.height(forWidth: c.width) }
        y += 24 + 32
        let natural = y + 48 + 17.875 + 32
        return max(minimumHeight, natural)
    }

    override func layout() {
        super.layout()
        let c = column(bounds.width)
        var y = c.top
        title.frame = NSRect(x: c.x, y: y, width: c.width, height: 32)
        y += 32 + 6
        let prefix = "Setting up "
        subtitle.text = prefix
        let pw = subtitle.textWidth
        subtitle.frame = NSRect(x: c.x, y: y, width: pw + 1, height: 20)
        let lw = min(subtitleRun.textWidth, max(0, c.width - pw - 6))
        subtitleRun.frame = NSRect(x: c.x + pw, y: y, width: lw, height: 20)
        subtitleTail.frame = NSRect(x: c.x + pw + lw, y: y, width: 6, height: 20)
        y += 20 + 40
        topLine.frame = NSRect(x: c.x, y: y, width: c.width, height: 1)
        y += 1
        for section in [agents, projects, phone] where !section.isHidden {
            let h = section.height(forWidth: c.width)
            section.frame = NSRect(x: c.x, y: y, width: c.width, height: h)
            y += h
        }
        y += 24
        let sw = start.intrinsicContentSize.width
        start.frame = NSRect(x: c.x + c.width - sw, y: y, width: sw, height: 32)
        if !hint.isHidden {
            let hw = hint.textWidth
            hint.frame = NSRect(x: start.frame.minX - 12 - hw, y: y + 8, width: hw, height: 16)
            startWithout.frame = NSRect(origin: NSPoint(x: c.x, y: y), size: startWithout.intrinsicContentSize)
        }
        y += 32
        let lineH: CGFloat = 17.875
        let ny = max(y + 48, bounds.height - 32 - lineH)
        let nw = notice.textWidth
        notice.frame = NSRect(x: c.x, y: ny, width: min(nw, c.width), height: lineH)
        privacy.label.text = "privacy policy"
        let rw = privacy.label.textWidth
        privacy.frame = NSRect(x: c.x + nw + notice.font.spaceWidth, y: ny, width: rw, height: lineH)
        period.frame = NSRect(x: privacy.frame.maxX, y: ny, width: 4, height: lineH)
    }
}

private extension NSFont {
    var spaceWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: self]).width }
}

// MARK: - Pieces

/// A `border-border/60` hairline.
final class WelcomeLine: DSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Themed.color(\.border, 0.6).cgColor(in: self) }
}

/// `WelcomeSection`: the label on the left (`6rem`), the rows on the right, `gap-x-10 py-4 border-b`.
final class WelcomeSection: DSView {
    private let label: LabelView
    private let line = WelcomeLine()
    var rows: [NSView] = [] {
        didSet {
            for old in oldValue where !rows.contains(where: { $0 === old }) { old.removeFromSuperview() }
            for row in rows where row.superview !== self { addSubview(row) }
            needsLayout = true
        }
    }
    init(_ title: String) {
        label = LabelView(title, font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 40
        addSubview(label); addSubview(line)
    }
    private func rowsWidth(_ width: CGFloat) -> CGFloat { max(0, width - 136) }
    func height(forWidth width: CGFloat) -> CGFloat {
        let w = rowsWidth(width)
        return 16 + max(40, rows.reduce(0) { $0 + WelcomeSection.height(of: $1, width: w) }) + 16 + 1
    }
    static func height(of view: NSView, width: CGFloat) -> CGFloat {
        if let row = view as? WelcomeRowSizing { return row.height(forWidth: width) }
        return view.intrinsicContentSize.height
    }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 16, width: 96, height: 40)
        let w = rowsWidth(bounds.width)
        var y: CGFloat = 16
        for row in rows {
            let h = WelcomeSection.height(of: row, width: w)
            row.frame = NSRect(x: 136, y: y, width: w, height: h)
            y += h
        }
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

@MainActor protocol WelcomeRowSizing { func height(forWidth width: CGFloat) -> CGFloat }

/// `RowIcon`: a 20pt box that lines names, checkboxes and steps up down the page.
private func placeIcon(_ icon: NSView, size: CGFloat, centerY: CGFloat) {
    icon.frame = NSRect(x: (20 - size) / 2, y: centerY - size / 2, width: size, height: size)
}

/// `AgentRow` (WelcomePage.tsx:1220-1287).
final class WelcomeAgentRow: DSView, WelcomeRowSizing {
    private let icon: NSView
    private let name: LabelView
    private let detail: TextBlockView?
    private let trailing: NSView?
    private let compact: Bool
    init(provider: ServerProvider, state: WelcomePageLogic.AgentState, compact: Bool, action: NSView?) {
        self.compact = compact
        let title = WelcomePageLogic.name(provider)
        icon = ProviderIcon.make(driver: provider.driver, displayName: title, size: compact ? 16 : 18, color: Themed.color(\.foreground))
        name = LabelView(title, font: DSFont.ui(14, weight: compact ? .regular : .medium), color: Themed.color(\.foreground))
        name.lineHeight = 20
        let text = WelcomePageLogic.detail(provider, state: state, compact: compact, headline: provider.message)
        detail = text.map {
            let block = TextBlockView($0, font: DSFont.ui(12), lineHeight: 19.5, color: Themed.color(\.mutedForeground))
            block.maxLines = 2
            return block
        }
        switch state {
        case .ready: trailing = WelcomeReadyLabel()
        case .checking:
            let l = LabelView("Checking…", font: DSFont.ui(12), color: Themed.color(\.mutedForeground)); l.lineHeight = 16
            trailing = l
        default: trailing = action
        }
        super.init(frame: .zero)
        [icon, name].forEach(addSubview)
        if let detail { addSubview(detail) }
        if let trailing { addSubview(trailing) }
    }
    private var trailingSize: NSSize {
        guard let trailing else { return .zero }
        if let l = trailing as? LabelView { return NSSize(width: ceil(l.textWidth), height: 16) }
        return trailing.intrinsicContentSize
    }
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 32 - (trailing == nil ? 0 : trailingSize.width + 12)) }
    private func textHeight(_ width: CGFloat) -> CGFloat { 20 + (detail?.height(forWidth: textWidth(width)) ?? 0) }
    func height(forWidth width: CGFloat) -> CGFloat { compact ? max(36, textHeight(width)) : max(40, textHeight(width) + 8) }
    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        placeIcon(icon, size: compact ? 16 : 18, centerY: mid)
        let tw = textWidth(bounds.width)
        let th = textHeight(bounds.width)
        var y = mid - th / 2
        name.frame = NSRect(x: 32, y: y, width: tw, height: 20)
        y += 20
        detail?.frame = NSRect(x: 32, y: y, width: tw, height: th - 20)
        if let trailing {
            let s = trailingSize
            // The status sits on the baseline of the block T3 wraps it in, 1.5pt above center (27-welcome).
            let lift: CGFloat = trailing is ButtonView ? 0 : 1.5
            trailing.frame = NSRect(x: bounds.width - s.width, y: mid - s.height / 2 - lift, width: s.width, height: s.height)
        }
    }
}

/// "Ready": `text-xs font-medium text-success-foreground` after a 14pt check, `gap-1.5`.
final class WelcomeReadyLabel: DSView {
    private let check = IconView(name: .check, size: 14, strokeColor: Themed.color(\.successForeground))
    private let label = LabelView("Ready", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.successForeground))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineHeight = 16
        addSubview(check); addSubview(label)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 14 + 6 + ceil(label.textWidth), height: 16) }
    override func layout() {
        super.layout()
        check.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 20, y: (bounds.height - 16) / 2, width: bounds.width - 20, height: 16)
    }
}

/// The two-column grid of agents to add (`grid-cols-1 gap-x-8 sm:grid-cols-2`).
final class WelcomeAgentGrid: DSView, WelcomeRowSizing {
    private let rows: [WelcomeAgentRow]
    init(rows: [WelcomeAgentRow]) {
        self.rows = rows
        super.init(frame: .zero)
        rows.forEach(addSubview)
    }
    private func columns(_ width: CGFloat) -> Int { width >= 400 ? 2 : 1 }
    private func cellWidth(_ width: CGFloat) -> CGFloat { columns(width) == 2 ? (width - 32) / 2 : width }
    private func rowHeights(_ width: CGFloat) -> [CGFloat] {
        let n = columns(width), w = cellWidth(width)
        return stride(from: 0, to: rows.count, by: n).map { start in
            rows[start..<min(rows.count, start + n)].map { $0.height(forWidth: w) }.max() ?? 0
        }
    }
    func height(forWidth width: CGFloat) -> CGFloat { rowHeights(width).reduce(0, +) }
    override func layout() {
        super.layout()
        let n = columns(bounds.width), w = cellWidth(bounds.width)
        var y: CGFloat = 0
        for (line, h) in rowHeights(bounds.width).enumerated() {
            for col in 0..<n {
                let i = line * n + col
                guard i < rows.count else { break }
                rows[i].frame = NSRect(x: CGFloat(col) * (w + 32), y: y, width: w, height: h)
            }
            y += h
        }
    }
}

/// The "Add more agents" trigger: plus, label, the grayscale logo stack and a chevron (WelcomePage.tsx:695-711).
final class WelcomeMoreTrigger: ControlView, WelcomeRowSizing {
    private let plus = IconView(name: .plus, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private let label: LabelView
    private let chevron = IconView(name: .chevronDown, size: 16, strokeColor: Themed.color(\.mutedForeground))
    private let logos: [NSView]
    private let emphasized: Bool
    init(title: String, emphasized: Bool, open: Bool, logos: [(String, String)], acp: Bool) {
        self.emphasized = emphasized
        label = LabelView(title, font: DSFont.ui(14), color: Themed.color(emphasized ? \.foreground : \.mutedForeground))
        label.lineHeight = 20
        var views = logos.map { ProviderIcon.make(driver: $0.0, displayName: $0.1, size: 14, color: Themed.color(\.foreground)) }
        if acp && !open { views.append(IconView(name: .brandACPRegistry, size: 14, strokeColor: Themed.color(\.foreground))) }
        self.logos = views
        super.init(frame: .zero)
        [plus, label, chevron].forEach(addSubview)
        // `opacity-60 grayscale`: each logo drawn once into a gray image.
        for _ in views {
            let image = NSImageView()
            image.alphaValue = 0.6
            images.append(image)
            addSubview(image)
        }
        if open { chevron.frameCenterRotation = 180 }
        setAccessibilityRole(.button); setAccessibilityLabel(title); setAccessibilityExpanded(open)
    }
    private var images: [NSImageView] = []
    private var renderedAppearance: NSAppearance.Name?
    /// Renders the logos in this view's appearance and takes their color out.
    private func renderLogos() {
        let name = effectiveAppearance.name
        guard renderedAppearance != name else { return }
        renderedAppearance = name
        for (logo, image) in zip(logos, images) {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
            host.appearance = effectiveAppearance
            logo.frame = host.bounds
            host.addSubview(logo)
            image.image = Self.grayscale(host)
            logo.removeFromSuperview()
        }
    }
    static func grayscale(_ view: NSView) -> NSImage? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let input = CIImage(bitmapImageRep: rep),
              let filter = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: input, kCIInputSaturationKey: 0]),
              let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }
    func height(forWidth width: CGFloat) -> CGFloat { 40 }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = Themed.color(state.hovered || emphasized ? \.foreground : \.mutedForeground)
    }
    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        placeIcon(plus, size: 16, centerY: mid)
        let lw = ceil(label.textWidth)
        label.frame = NSRect(x: 32, y: mid - 10, width: lw, height: 20)
        var x = 32 + lw + 12
        renderLogos()
        for image in images {
            image.frame = NSRect(x: x, y: mid - 7, width: 14, height: 14)
            x += 14 + 8
        }
        chevron.frame = NSRect(x: bounds.width - 16, y: mid - 8, width: 16, height: 16)
    }
}

/// A row of muted text (`text-sm leading-10` or a `pl-8 text-xs` note), with an optional trailing button.
final class WelcomeTextRow: DSView, WelcomeRowSizing {
    private let text: TextBlockView
    private let indent: CGFloat
    private let trailing: NSView?
    private let top: CGFloat
    private let lineHeight: CGFloat
    init(_ string: String, font: NSFont, lineHeight: CGFloat, indent: CGFloat = 0, trailing: NSView? = nil,
         color: NSColor = Themed.color(\.mutedForeground), top: CGFloat = 0) {
        text = TextBlockView(string, font: font, lineHeight: lineHeight, color: color)
        self.indent = indent; self.trailing = trailing; self.top = top; self.lineHeight = lineHeight
        super.init(frame: .zero)
        addSubview(text)
        if let trailing { addSubview(trailing) }
    }
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - indent - (trailing.map { $0.intrinsicContentSize.width + 12 } ?? 0)) }
    func height(forWidth width: CGFloat) -> CGFloat {
        top + max(trailing == nil ? 0 : 40, text.height(forWidth: textWidth(width)))
    }
    override func layout() {
        super.layout()
        let th = text.height(forWidth: textWidth(bounds.width))
        let area = bounds.height - top
        text.frame = NSRect(x: indent, y: top + (area - th) / 2, width: textWidth(bounds.width), height: th)
        if let trailing {
            let s = trailing.intrinsicContentSize
            trailing.frame = NSRect(x: bounds.width - s.width, y: top + (area - s.height) / 2, width: s.width, height: s.height)
        }
    }
}

/// A wrapped line of text for the phone steps, optionally after a success check.
final class WelcomeWrappedText: DSView, WelcomeRowSizing {
    private let text: TextBlockView
    private let check: IconView?
    init(_ string: String, font: NSFont, lineHeight: CGFloat, color: NSColor, check: Bool = false) {
        text = TextBlockView(string, font: font, lineHeight: lineHeight, color: color)
        self.check = check ? IconView(name: .check, size: 16, strokeColor: Themed.color(\.successForeground)) : nil
        super.init(frame: .zero)
        addSubview(text)
        if let c = self.check { addSubview(c) }
    }
    private var inset: CGFloat { check == nil ? 0 : 22 }
    func height(forWidth width: CGFloat) -> CGFloat { text.height(forWidth: max(0, width - inset)) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    override func layout() {
        super.layout()
        check?.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
        text.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: bounds.height)
    }
}

/// An icon, a label and a trailing control (the ACP Registry row and the phone row).
final class WelcomeIconRow: DSView, WelcomeRowSizing {
    private let icon: NSView
    private let label: LabelView
    private let action: NSView
    private let rowHeight: CGFloat
    init(icon: NSView, text: String, action: NSView, height: CGFloat, medium: Bool = false) {
        self.icon = icon; self.action = action; rowHeight = height
        label = LabelView(text, font: DSFont.ui(14, weight: medium ? .medium : .regular),
                          color: Themed.color(medium ? \.foreground : \.mutedForeground))
        label.lineHeight = 20
        super.init(frame: .zero)
        [icon, label, action].forEach(addSubview)
    }
    func height(forWidth width: CGFloat) -> CGFloat { rowHeight }
    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        placeIcon(icon, size: 16, centerY: mid)
        let s = action.intrinsicContentSize
        action.frame = NSRect(x: bounds.width - s.width, y: mid - s.height / 2, width: s.width, height: s.height)
        label.frame = NSRect(x: 32, y: mid - 10, width: max(0, bounds.width - 32 - s.width - 12), height: 20)
    }
}

/// The import row: the main checkbox, its title and source line, and Review all (WelcomePage.tsx:873-918).
final class WelcomeImportRow: DSView, WelcomeRowSizing {
    let checkbox = CheckboxView()
    private let title: LabelView
    private let detail: LabelView
    var trailing: NSView? { didSet { oldValue?.removeFromSuperview(); if let trailing { addSubview(trailing) }; needsLayout = true } }
    init(title: String, detail: String, value: CheckboxView.Value) {
        self.title = LabelView(title, font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
        self.detail = LabelView(detail, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        self.title.lineHeight = 20; self.detail.lineHeight = 16
        checkbox.value = value
        checkbox.setAccessibilityLabel(title)
        [checkbox, self.title, self.detail].forEach(addSubview)
    }
    func height(forWidth width: CGFloat) -> CGFloat { max(40, 36 + 8) }
    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        placeIcon(checkbox, size: 16, centerY: mid)
        let tw = trailing?.intrinsicContentSize.width ?? 0
        let w = max(0, bounds.width - 32 - (tw > 0 ? tw + 12 : 0))
        title.frame = NSRect(x: 32, y: mid - 18, width: w, height: 20)
        detail.frame = NSRect(x: 32, y: mid + 2, width: w, height: 16)
        if let trailing {
            let s = trailing.intrinsicContentSize
            trailing.frame = NSRect(x: bounds.width - s.width, y: mid - s.height / 2, width: s.width, height: s.height)
        }
    }
    override func mouseDown(with event: NSEvent) {
        // The row is a `<label>`: a click on the text toggles the box.
        let p = convert(event.locationInWindow, from: nil)
        if p.x < bounds.width - (trailing?.frame.width ?? 0) - 12, checkbox.isEnabled { checkbox.performAction() } else { super.mouseDown(with: event) }
    }
}

/// A child view placed with a top margin and an optional horizontal outset (`mt-2`, `-mx-1.5 mt-1`).
final class WelcomeInset: DSView, WelcomeRowSizing {
    private let child: NSView
    private let top: CGFloat
    private let horizontal: CGFloat
    init(_ child: NSView, top: CGFloat, horizontal: CGFloat = 0) {
        self.child = child; self.top = top; self.horizontal = horizontal
        super.init(frame: .zero)
        child.removeFromSuperview()
        addSubview(child)
    }
    func height(forWidth width: CGFloat) -> CGFloat {
        let w = width - 2 * horizontal
        if let sized = child as? CodexSetupView { return top + sized.height(forWidth: w) }
        if let sized = child as? WelcomeRowSizing { return top + sized.height(forWidth: w) }
        return top + child.intrinsicContentSize.height
    }
    override func layout() {
        super.layout()
        child.frame = NSRect(x: horizontal, y: top, width: bounds.width - 2 * horizontal, height: bounds.height - top)
    }
}

/// The phone panel: two numbered steps and the app's QR code (`pl-8 pt-2 pb-3 gap-8`).
final class WelcomePhonePanel: DSView, WelcomeRowSizing {
    private let one = LabelView("1", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private let two = LabelView("2", font: DSFont.ui(14), color: Themed.color(\.mutedForeground))
    private let scan = WelcomeWrappedText("Scan with your phone to get the app.", font: DSFont.ui(14), lineHeight: 20, color: Themed.color(\.foreground))
    private let step2: [NSView]
    private let qrBox = WelcomeWhiteBox()
    private let qr = QRCodeView(value: "https://t3.codes/mobile", size: 124, level: .medium, marginSize: 2,
                                title: "T3 Code app for iPhone and Android")
    init(step2: [NSView]) {
        self.step2 = step2
        super.init(frame: .zero)
        one.lineHeight = 20; two.lineHeight = 20
        [one, two, scan, qrBox].forEach(addSubview)
        qrBox.addSubview(qr)
        step2.forEach(addSubview)
    }
    private func textWidth(_ width: CGFloat) -> CGFloat { max(0, width - 32 - 24 - 32 - 136) }
    private func stepsHeight(_ width: CGFloat) -> CGFloat {
        let w = textWidth(width)
        let second = step2.enumerated().reduce(CGFloat(0)) { sum, item in
            sum + (item.offset > 0 ? 8 : 0) + WelcomeSection.height(of: item.element, width: w)
        }
        return scan.height(forWidth: w) + 20 + second
    }
    func height(forWidth width: CGFloat) -> CGFloat { 8 + max(136, stepsHeight(width)) + 12 }
    override func layout() {
        super.layout()
        let w = textWidth(bounds.width)
        let inner = bounds.height - 20
        let stepsTop = 8 + (inner - stepsHeight(bounds.width)) / 2
        var y = stepsTop
        one.frame = NSRect(x: 32, y: y, width: 12, height: 20)
        let sh = scan.height(forWidth: w)
        scan.frame = NSRect(x: 56, y: y, width: w, height: sh)
        y += sh + 20
        two.frame = NSRect(x: 32, y: y, width: 12, height: 20)
        for (i, view) in step2.enumerated() {
            if i > 0 { y += 8 }
            let h = WelcomeSection.height(of: view, width: w)
            let vw = view is ButtonView ? view.intrinsicContentSize.width : w
            view.frame = NSRect(x: 56, y: y, width: vw, height: h)
            y += h
        }
        qrBox.frame = NSRect(x: bounds.width - 136, y: 8 + (inner - 136) / 2, width: 136, height: 136)
        qr.frame = NSRect(x: 6, y: 6, width: 124, height: 124)
    }
}

final class WelcomeWhiteBox: DSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.white.cgColor; layer?.cornerRadius = 8 }
}

/// The privacy policy link: underlined at 40% of its color, muted on hover.
final class WelcomeLinkView: ControlView {
    let label: LabelView
    init(_ text: String) {
        label = LabelView(text, font: DSFont.ui(11), color: Themed.color(\.mutedForeground, 0.7))
        super.init(frame: .zero)
        label.lineHeight = 17.875
        label.isUnderlined = true
        addSubview(label)
        setAccessibilityRole(.link); setAccessibilityLabel(text)
    }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        label.color = Themed.color(\.mutedForeground, state.hovered ? 1 : 0.7)
    }
    override func layout() { super.layout(); label.frame = bounds }
}
