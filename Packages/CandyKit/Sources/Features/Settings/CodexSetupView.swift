import AppKit
import DesignSystem
import T3Protocol

/// `ManagedCodexSetup` (CodexSetupSection.tsx:197-1000): a managed Codex instance's ChatGPT sign-in. It
/// installs Codex first when needed, starts the server's sign-in, opens ChatGPT's page and catches the
/// loopback callback on this computer (the desktop bridge), or for a remote environment signs in on the
/// primary and moves the profile across (`provider.chatgpt.*`). `presentation` picks the settings rows
/// or the Welcome card. The auth and install streams run only while the view is in a window.
public final class CodexSetupView: DSView, SettingsGroupRow {
    public enum Presentation: Sendable { case settings, onboarding }

    private let context: SettingsPageContext
    public let environment: String
    public let instance: String
    public let presentation: Presentation
    private let allowExistingCli: Bool
    private let displayName: String?
    public private(set) var state = CodexSetupState()
    private var error: String?

    public var onModeChange: ((String) -> Void)?
    public var onAutoStartConsumed: (() -> Void)?
    public var onSignInCancelled: (() -> Void)?
    public var onHeightChange: (() -> Void)?

    // The refs of T3's component.
    private var pendingFlag = false
    private var continueWithSignIn: String?
    private var openRequested = false
    private var openedFlow: String?
    private var importedAttempt: String?
    private var receivingCallback: String?
    private var watchedCallbackURL: String?
    private var refreshKey: String?
    private let handoffId = "codex-" + UUID().uuidString.prefix(8).lowercased()
    private var handoffSequence = 0
    private var handoffInput: (environment: String, input: JSONValue)?
    private var callbackHelpOpen = false
    private var callbackDraft = (flowId: "", value: "")
    private weak var pickerHost: ModalHost?

    private var authSubscription: Task<Void, Never>?
    private var installSubscription: Task<Void, Never>?
    private var handoffSubscription: Task<Void, Never>?

    // Settings rows (`divide-y divide-border/50`).
    private let accountRow = SettingsRowView(title: "ChatGPT account")
    private let controls = SettingsControlGroup([], gap: 8)
    private let waitingButton = ButtonView("Open sign-in page", variant: .outline, size: .sm)
    private let cancelButton = ButtonView("Cancel", variant: .ghost, size: .sm)
    private let changeButton = ButtonView("Change account", variant: .outline, size: .sm)
    private let disconnectButton = ButtonView("Disconnect", variant: .ghost, size: .sm)
    private let connectButton = ChatGptButtons.connection(size: .sm)
    private let differentButton = ButtonView("Use a different account", variant: .ghost, size: .sm)
    private let existingButton = ButtonView("Use existing CLI", variant: .ghostMuted, size: .sm)
    private lazy var usageButton = ChatGptButtons.usage { [weak self] url in self?.context.openURL?(url) }
    private let notice = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.mutedForeground))
    private let errorText = TextBlockView("", font: DSFont.ui(12), lineHeight: 16, color: Themed.color(\.destructive))
    private let help = CallbackHelpView()
    private let signedIn = SignedInLineView()
    private var dividers: [CALayer] = []
    // The Welcome card (`CodexWelcomeCard`, CodexSetupSection.tsx:1115-1148).
    private let cardBox = BoxDecorationLayer()
    private let cardIcon = IconView(name: .brandOpenAI, size: 20, strokeColor: Themed.color(\.foreground))
    private let cardTitle = LabelView("", font: DSFont.ui(14, weight: .medium), color: Themed.color(\.foreground))
    private let cardDescription = TextBlockView("", font: DSFont.ui(12), lineHeight: 19.5, color: Themed.color(\.mutedForeground))
    private let readyLabel = ReadyLabel()
    private let descToggle = CallbackHelpView.Toggle("Complete sign-in in your browser.")

    public init(context: SettingsPageContext, environment: String, instance: String, provider: ServerProvider?, enabled: Bool, readOnly: Bool,
                presentation: Presentation = .settings, mode: String = "managed", autoStart: Bool = false, allowExistingCli: Bool = true,
                displayName: String? = nil) {
        self.context = context; self.environment = environment; self.instance = instance; self.presentation = presentation
        self.allowExistingCli = allowExistingCli; self.displayName = displayName; self.mode = mode
        super.init(frame: .zero)
        state.provider = provider; state.enabled = enabled; state.readOnly = readOnly; state.autoStart = autoStart
        state.desktopBridge = context.receiveProviderAuthCallback != nil
        state.local = CodexSetupLogic.isLoopback(context.httpBaseURL?(environment))
        for b in [waitingButton, cancelButton, changeButton, disconnectButton, connectButton, differentButton, existingButton] { b.isHidden = true }
        controls.views = presentation == .settings
            ? [waitingButton, cancelButton, changeButton, disconnectButton, connectButton, differentButton]
            : [existingButton, differentButton, cancelButton, waitingButton, connectButton]
        wireButtons()
        help.onToggle = { [weak self] in guard let self else { return }; self.callbackHelpOpen.toggle(); self.changed() }
        help.onSubmit = { [weak self] in self?.submitCallback() }
        help.onDraft = { [weak self] value in guard let self else { return }; self.callbackDraft = (self.state.flowId ?? "", value); self.render() }
        help.onBrowser = { [weak self] in if let url = self?.state.url.flatMap(URL.init(string:)) { self?.context.openURL?(url) } }
        if presentation == .settings {
            accountRow.control = controls
            for v in [accountRow, usageButton, notice, help, errorText] as [NSView] { addSubview(v) }
            setAccessibilityRole(.group)
            setAccessibilityLabel("Codex setup")
        } else {
            // The card's secondary buttons are `ghost-muted` (CodexSetupSection.tsx:838-877).
            cancelButton.variant = .ghostMuted
            differentButton.variant = .ghostMuted
            cardBox.host = self
            var s = BoxStyle()
            s.radius = 8
            s.border = Themed.color(\.border)
            s.fill = Themed.color(\.background)
            cardBox.boxStyle = s
            layer?.addSublayer(cardBox)
            cardTitle.lineHeight = 20
            descToggle.action = { [weak self] in guard let self else { return }; self.callbackHelpOpen.toggle(); self.changed() }
            for v in [cardIcon, cardTitle, cardDescription, signedIn, descToggle, readyLabel, controls, help, errorText] as [NSView] { addSubview(v) }
        }
        changed()
    }

    deinit {
        authSubscription?.cancel(); installSubscription?.cancel(); handoffSubscription?.cancel()
    }

    /// The parent's latest snapshot of the instance (a rebuild keeps this view and its flow).
    public func update(provider: ServerProvider?, enabled: Bool, readOnly: Bool, mode: String? = nil) {
        state.provider = provider; state.enabled = enabled; state.readOnly = readOnly
        if let mode { self.mode = mode }
        if window != nil { start() }
        changed()
    }

    /// `CodexSetupSection`'s `mode` (CodexSetupSection.tsx:60-158): "existing" shows the Welcome card for the
    /// Codex CLI already on the machine; "managed" runs the setup once the server reports `setup`.
    public private(set) var mode = "managed"
    /// `ManagedCodexSetup` is mounted: the instance is managed and the server reports how it can be set up.
    private var managedReady: Bool { mode == "managed" && state.provider?.setup != nil }

    // MARK: Streams

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start(); return }
        // A rebuild moves the view between parents in one pass; only a view that stays out lets go.
        DispatchQueue.main.async { [weak self] in if self?.window == nil { self?.stop() } }
    }

    private func start() {
        guard managedReady else { return }
        let payload = JSONValue.object(["instanceId": .string(instance)])
        if authSubscription == nil {
            authSubscription = context.subscribe?(environment, "provider.auth.subscribe", payload) { [weak self] value in
                self?.state.auth = value; self?.changed()
            }
        }
        if installSubscription == nil {
            installSubscription = context.subscribe?(environment, "provider.install.subscribe", payload) { [weak self] value in
                self?.state.install = value; self?.changed()
            }
        }
        if handoffSubscription == nil, let handoff = handoffInput { subscribeHandoff(handoff) }
    }

    /// Unmount: the streams end and the loopback listener for an open sign-in stops.
    public func stop() {
        authSubscription?.cancel(); authSubscription = nil
        installSubscription?.cancel(); installSubscription = nil
        handoffSubscription?.cancel(); handoffSubscription = nil
        if let url = watchedCallbackURL {
            if receivingCallback == url { receivingCallback = nil }
            context.cancelProviderAuthCallback?(url)
            watchedCallbackURL = nil
        }
        pickerHost?.close()
    }

    private func setHandoff(_ value: (environment: String, input: JSONValue)?) {
        handoffSubscription?.cancel(); handoffSubscription = nil
        handoffInput = value
        state.handoff = nil
        state.handoffActive = value != nil
        if let value, window != nil { subscribeHandoff(value) }
    }

    // ponytail: context streams drop their errors, so T3's "ChatGPT sign-in on the primary environment was interrupted"
    // line (CodexSetupSection.tsx:378-381) never shows; add it when `SettingsPageContext.subscribe` reports failures.
    private func subscribeHandoff(_ value: (environment: String, input: JSONValue)) {
        handoffSubscription = context.subscribe?(value.environment, "provider.chatgpt.handoff.subscribe", value.input) { [weak self] next in
            self?.state.handoff = next; self?.changed()
        }
    }

    // MARK: Commands

    private func message(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        let text = String(describing: error)
        return text.isEmpty ? "Codex setup failed. Try again." : text
    }

    /// `run` (CodexSetupSection.tsx:318-345): one command at a time, its failure in the error line.
    @discardableResult
    private func run(_ method: String, on env: String? = nil, _ payload: JSONValue, onSuccess: ((JSONValue) -> Void)? = nil) async -> Bool {
        guard !pendingFlag, let request = context.request else { return false }
        pendingFlag = true; state.pending = true; error = nil; changed()
        var succeeded = false
        do {
            let value = try await request(env ?? environment, method, payload)
            succeeded = true
            onSuccess?(value)
        } catch {
            if let text = message(error) { self.error = text }
        }
        pendingFlag = false; state.pending = false; changed()
        return succeeded
    }

    private var returnURL: String {
        CodexSetupLogic.returnURL(onboarding: presentation == .onboarding, environment: environment, instance: instance)
    }

    private var primaryAuthEnvironment: String? {
        let scope = context.scope
        let primary = scope.primaryId.flatMap { id in scope.environments.first { $0.id == id } }
        return CodexSetupLogic.primaryAuthEnvironment(local: state.local, primary: primary?.id, primaryConnected: primary?.connected == true,
                                                      primaryLocal: CodexSetupLogic.isLoopback(primary.flatMap { context.httpBaseURL?($0.id) }),
                                                      desktop: state.desktopBridge)
    }

    /// `signIn` (CodexSetupSection.tsx:388-449).
    private func signIn(_ methodId: String = "chatgpt") async {
        guard !pendingFlag else { return }
        openRequested = true
        state.transferFailed = false
        state.requestedMethodId = methodId
        let base: [String: JSONValue] = ["instanceId": .string(instance), "methodId": .string(methodId)]
        if let primary = primaryAuthEnvironment {
            handoffSequence += 1
            let attempt = "\(handoffId):\(handoffSequence)"
            let ok = await run("provider.chatgpt.reconnect-profile", .object(base)) { [weak self] profile in
                guard let self else { return }
                self.setHandoff((primary, .object(["instanceId": .string(self.instance), "environmentId": .string(self.environment),
                                                   "attemptId": .string(attempt), "returnUrl": .string(self.returnURL), "profile": profile])))
            }
            if !ok { openRequested = false }
            return
        }
        var input = base
        input["returnUrl"] = .string(returnURL)
        input["callbackMode"] = .string(state.clientCallback ? "client" : "server")
        let ok = await run("provider.auth.start", .object(input)) { [weak self] _ in self?.state.awaitingProvider = .signIn }
        if !ok { openRequested = false }
    }

    /// `setup` (CodexSetupSection.tsx:451-475): install or update first, then sign in.
    private func setup(_ methodId: String = "chatgpt") async {
        guard !state.unavailable, !state.busy else { return }
        if state.installed && !state.updateAvailable {
            await signIn(methodId)
        } else {
            continueWithSignIn = methodId
            if !(await run("provider.install.start", .object(["instanceId": .string(instance)]))) { continueWithSignIn = nil }
        }
    }

    /// `transferProfile` (CodexSetupSection.tsx:350-363): the primary's sign-in moves to this environment.
    private func transferProfile(_ profile: JSONValue) async {
        let ok = await run("provider.chatgpt.import-profile", .object(["instanceId": .string(instance), "profile": profile]))
        if ok { state.awaitingProvider = .handoff; setHandoff(nil) }
        state.transferFailed = !ok
        changed()
    }

    private func cancelSignIn() async {
        state.awaitingProvider = nil
        if handoffInput != nil { setHandoff(nil); changed(); return }
        guard let flow = state.flowId else { changed(); return }
        await run("provider.auth.cancel", .object(["instanceId": .string(instance), "flowId": .string(flow)]))
    }

    /// `openPage` (CodexSetupSection.tsx:522-548).
    private func openPage(_ url: String) async {
        guard let parsed = URL(string: url) else { return }
        if let receive = context.receiveProviderAuthCallback, state.clientCallback, let flow = state.flowId {
            if receivingCallback == url { context.openURL?(parsed); return }
            receivingCallback = url
            do {
                let callback = try await receive(url)
                guard receivingCallback == url else { return }
                receivingCallback = nil
                await run("provider.auth.complete", .object(["instanceId": .string(instance), "flowId": .string(flow), "callbackUrl": .string(callback)]))
            } catch {
                self.error = "Could not finish sign-in on this computer. Try again or paste the redirect URL below."
                changed()
            }
        } else {
            context.openURL?(parsed)
        }
    }

    private func submitCallback() {
        guard let flow = state.flowId else { return }
        let value = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.run("provider.auth.complete", .object(["instanceId": .string(self.instance), "flowId": .string(flow), "callbackUrl": .string(value)])) {
                self.callbackDraft = (flow, "")
                self.help.clear()
                self.changed()
            }
        }
    }

    private var callbackURL: String { callbackDraft.flowId == state.flowId ? callbackDraft.value : "" }

    private func openPicker() {
        guard let window, pickerHost == nil else { return }
        let methods = state.effectiveAuth?["methods"]?.arrayValue ?? []
        let picker = ChatGptAccountPickerDialog(methods: methods)
        let host = ModalHost.present(picker, in: window)
        picker.onSelect = { [weak self, weak host] id in
            host?.close()
            guard let self else { return }
            let method = CodexSetupLogic.pickedMethod(id, methods: self.state.effectiveAuth?["methods"]?.arrayValue ?? [])
            Task { await self.setup(method) }
        }
        pickerHost = host
    }

    private func wireButtons() {
        waitingButton.action = { [weak self] in
            guard let self else { return }
            if self.state.handoffFinished, let profile = self.state.handoff?["profile"] { Task { await self.transferProfile(profile) } }
            else if let url = self.state.url { Task { await self.openPage(url) } }
        }
        cancelButton.action = { [weak self] in self?.cancelPressed() }
        changeButton.action = { [weak self] in self?.openPicker() }
        disconnectButton.action = { [weak self] in
            guard let self else { return }
            Task { await self.run("provider.auth.logout", .object(["instanceId": .string(self.instance)])) }
        }
        connectButton.action = { [weak self] in
            guard let self else { return }
            if self.mode == "existing" {
                // The existing card's Continue with ChatGPT: switch to managed and start there.
                self.state.autoStart = true
                self.state.autoStartHandled = false
                self.onModeChange?("managed")
                return
            }
            if self.state.hasSavedAccount { self.openPicker() } else { Task { await self.setup() } }
        }
        differentButton.action = { [weak self] in Task { await self?.setup(CodexSetupLogic.changeAccountMethod) } }
        existingButton.action = { [weak self] in self?.onModeChange?("existing") }
    }

    private func cancelPressed() {
        let s = state
        if s.authActive {
            // Settings (CodexSetupSection.tsx:888-897) and the card (:840-855) both stop the sign-in.
            guard handoffInput != nil || s.flowId != nil || presentation == .onboarding else { return }
            openRequested = false
            if presentation == .onboarding { continueWithSignIn = nil }
            if handoffInput != nil || s.flowId != nil { Task { await cancelSignIn() } }
            if presentation == .settings { onSignInCancelled?() }
        } else if s.installActive, let operation = s.install?["operationId"]?.stringValue {
            continueWithSignIn = nil
            Task { await run("provider.install.cancel", .object(["instanceId": .string(instance), "operationId": .string(operation)])) }
        }
    }

    // MARK: Effects

    /// The component's effects, in T3's order, after every input change; then the views.
    private func changed() {
        guard managedReady else { render(); return }
        var s = state
        // :291-295
        if s.authenticated || s.phase == "failed" || s.phase == "cancelled" { s.awaitingProvider = nil }
        state = s
        // :296-300: a succeeded sign-in asks the server to probe the provider again.
        let key = "\(s.awaitingProvider?.rawValue ?? "")|\(s.phase ?? "")"
        if key != refreshKey {
            refreshKey = key
            if s.awaitingProvider != nil, s.phase == "succeeded", let request = context.request {
                let env = environment, payload = JSONValue.object(["instanceId": .string(instance)])
                Task { _ = try? await request(env, "server.refreshProviders", payload) }
            }
        }
        // :364-370: the primary finished; move its profile here once per attempt.
        if handoffInput != nil, s.handoffFinished, let attempt = handoffInput?.input["attemptId"]?.stringValue, importedAttempt != attempt,
           let profile = s.handoff?["profile"] {
            importedAttempt = attempt
            Task { await transferProfile(profile) }
        }
        // :371-385
        if handoffInput != nil, s.handoff?["phase"]?.stringValue == "auth", ["failed", "cancelled"].contains(s.handoff?["state"]?["phase"]?.stringValue ?? "") {
            error = s.handoff?["state"]?["message"]?.stringValue ?? "ChatGPT sign-in could not finish. Try again."
            setHandoff(nil)
        }
        // :477-498
        if state.autoStartReady {
            state.autoStartHandled = true
            onAutoStartConsumed?()
            Task { await setup() }
        }
        // :500-509: the install finished, so the sign-in it was for starts.
        if let method = continueWithSignIn, !state.pending, !state.installActive {
            if state.installPhase == "failed" || state.installPhase == "cancelled" { continueWithSignIn = nil }
            else if state.installed { continueWithSignIn = nil; Task { await signIn(method) } }
        }
        // :550-556: a new sign-in page releases the listener for the old one.
        let watched = state.clientCallback && context.cancelProviderAuthCallback != nil ? state.url : nil
        if watched != watchedCallbackURL {
            if let old = watchedCallbackURL {
                if receivingCallback == old { receivingCallback = nil }
                context.cancelProviderAuthCallback?(old)
            }
            watchedCallbackURL = watched
        }
        // :558-571: open the page once per flow the user asked for.
        if openRequested, state.phase == "waiting", let flow = state.flowId, let url = state.url, openedFlow != flow {
            openedFlow = flow
            openRequested = false
            if !state.remoteWeb { Task { await openPage(url) } }
        }
        render()
    }

    // MARK: Views

    private func show(_ b: ButtonView, _ title: String? = nil, enabled: Bool = true) {
        b.isHidden = false
        if let title, b.title != title { b.title = title }
        b.isEnabled = enabled
    }

    private func render() {
        let s = state
        for b in [waitingButton, cancelButton, changeButton, disconnectButton, connectButton, differentButton, existingButton] { b.isHidden = true }
        let onboarding = presentation == .onboarding
        let waiting = s.waitingControl(onboarding: onboarding)
        waitingButton.variant = s.remoteWeb ? .default : .outline
        let callback = s.showsCallbackCompletion
        if !managedReady {
            renderUnmanaged()
        } else if onboarding {
            if s.authenticated && !s.busy {
                readyLabel.configure(ready: true, text: "Ready")
            } else {
                readyLabel.isHidden = true
                if s.authActive { show(waitingButton, waiting.title, enabled: waiting.enabled) }
                else {
                    show(connectButton, s.onboardingConnectionTitle, enabled: !s.connectionDisabled)
                }
            }
            if (s.authActive && !s.finishingSignIn) || s.installActive { show(cancelButton, enabled: !(s.pending || s.readOnly)) }
            else if !s.authActive && !s.authenticated && s.hasSavedAccount { show(differentButton, enabled: !(s.unavailable || s.busy)) }
            else if !s.authActive && !s.authenticated && allowExistingCli { show(existingButton, enabled: !(s.readOnly || s.busy)) }
            cardTitle.text = displayName ?? s.provider?.displayName ?? "Codex"
            applyCardDescription(s.onboardingDescription)
            // The card's footer: the fallback itself on a remote browser, else `callbackHelpContent` while open.
            help.configure(toggle: false, rule: !s.remoteWeb, open: s.remoteWeb || callbackHelpOpen, remoteWeb: s.remoteWeb,
                           draft: callbackURL, enabled: !(s.pending || s.readOnly), showsCompletion: callback)
            help.isHidden = !(callback && (s.remoteWeb || callbackHelpOpen))
            if let e = s.onboardingError(error) { errorText.text = e; errorText.isHidden = false } else { errorText.isHidden = true }
        } else {
            readyLabel.isHidden = true
            if s.authActive {
                show(waitingButton, waiting.title, enabled: waiting.enabled)
                if !s.finishingSignIn { show(cancelButton, enabled: !(s.pending || s.readOnly)) }
            } else if s.installActive {
                show(cancelButton, enabled: !(s.pending || s.readOnly))
            } else if s.authenticated {
                show(changeButton, enabled: !(s.unavailable || s.busy))
                show(disconnectButton, enabled: !(s.unavailable || s.busy))
            } else {
                show(connectButton, s.connectionTitle, enabled: !s.connectionDisabled)
                if s.hasSavedAccount { show(differentButton, enabled: !(s.unavailable || s.busy)) }
            }
            switch s.accountDescription {
            case .signedIn(let email):
                signedIn.configure(email: email)
                accountRow.detail = " "
                accountRow.detailView = signedIn
            case .text(let t), .signInHelp(let t, _):
                accountRow.detailView = nil
                accountRow.detail = t
            }
            usageButton.isHidden = !s.authenticated
            notice.text = s.logoutWarning ?? ""
            notice.isHidden = s.logoutWarning == nil
            help.configure(toggle: !s.remoteWeb, rule: !s.remoteWeb, open: s.remoteWeb || callbackHelpOpen, remoteWeb: s.remoteWeb,
                           draft: callbackURL, enabled: !(s.pending || s.readOnly), showsCompletion: callback)
            help.isHidden = !callback
            if let e = s.errorLine(error) { errorText.text = e; errorText.isHidden = false } else { errorText.isHidden = true }
        }
        // Buttons came and went: the group and the row lay out again.
        controls.invalidateIntrinsicContentSize()
        controls.needsLayout = true
        accountRow.invalidateIntrinsicContentSize()
        accountRow.needsLayout = true
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    /// Before `ManagedCodexSetup` mounts (CodexSetupSection.tsx:64-156): the existing CLI's Welcome card, or the
    /// waiting card and row while the server prepares the managed instance.
    private func renderUnmanaged() {
        let s = state
        help.isHidden = true
        errorText.isHidden = true
        readyLabel.isHidden = true
        if presentation == .settings {
            accountRow.detailView = nil
            accountRow.detail = mode == "existing" ? nil : "Preparing sign-in."
            usageButton.isHidden = true
            notice.isHidden = true
            return
        }
        cardTitle.text = displayName ?? s.provider?.displayName ?? "Codex"
        guard mode == "existing" else {
            applyCardDescription(.signInHelp(label: "Complete sign-in in your browser.", toggle: false))
            // ponytail: T3 gives the card's sign-in button `min-w-44`; ButtonView has no minimum width, add one if the card is pixel-checked.
            show(waitingButton, "Open sign-in page", enabled: false)
            waitingButton.variant = .outline
            show(cancelButton, enabled: false)
            return
        }
        let readiness = OnboardingProviderReadiness.state(s.provider)
        let ready = s.enabled && readiness == .ready
        let checking = readiness == .checking
        let summary = ProvidersLogic.summary(s.provider).headline
        if ready { applyCardDescription(s.email.map(CodexSetupState.Description.signedIn) ?? .text("Connected with your Codex CLI.")) }
        else if checking { applyCardDescription(.text("Checking your Codex CLI...")) }
        else if s.provider?.installed == true { applyCardDescription(.text(summary)) }
        else { applyCardDescription(.text("Code with your ChatGPT subscription.")) }
        if ready { readyLabel.configure(ready: true, text: "Ready") }
        else if checking { readyLabel.configure(ready: false, text: "Checking...") }
        else if s.authenticated { readyLabel.configure(ready: false, text: summary) }
        else {
            show(connectButton, "Continue with ChatGPT", enabled: !s.readOnly)
            show(existingButton)
        }
    }

    private func applyCardDescription(_ d: CodexSetupState.Description) {
        signedIn.isHidden = true; cardDescription.isHidden = true; descToggle.isHidden = true
        switch d {
        case .signedIn(let email): signedIn.configure(email: email); signedIn.isHidden = false
        case .text(let t): cardDescription.text = t; cardDescription.isHidden = false
        case .signInHelp(let label, false): cardDescription.text = label; cardDescription.isHidden = false
        case .signInHelp(_, true): descToggle.expanded = callbackHelpOpen; descToggle.isHidden = false
        }
    }

    // MARK: Layout

    private struct Block { let view: NSView; let frame: NSRect }

    private func blocks(width: CGFloat) -> [Block] {
        var out: [Block] = []
        var y: CGFloat = 0
        func add(_ view: NSView, _ h: CGFloat, inset: CGFloat = 0, padY: CGFloat = 0, x: CGFloat = 0, w: CGFloat? = nil) {
            if !out.isEmpty { y += 1 }
            out.append(Block(view: view, frame: NSRect(x: x + inset, y: y + padY, width: w ?? width - 2 * inset, height: h)))
            y += h + 2 * padY
        }
        add(accountRow, accountRow.height(forWidth: width))
        if !usageButton.isHidden {
            let bw = usageButton.intrinsicContentSize.width
            add(usageButton, 28, padY: 4, x: width - 16 - bw, w: bw)
        }
        if !notice.isHidden { add(notice, notice.height(forWidth: width - 32), inset: 16, padY: 8) }
        if !help.isHidden { add(help, help.height(forWidth: width - 32), inset: 16, padY: 12) }
        if !errorText.isHidden { add(errorText, errorText.height(forWidth: width - 32), inset: 16, padY: 8) }
        return out
    }

    private func cardHeight(width: CGFloat) -> (row: CGFloat, text: CGFloat, controls: NSSize, footer: CGFloat, total: CGFloat) {
        let inner = width - 2 - 32
        let cs = controls.intrinsicContentSize
        let textWidth = max(1, inner - 20 - 12 - (cs.width > 0 ? cs.width + 12 : 0))
        let description = !cardDescription.isHidden ? cardDescription.height(forWidth: textWidth) : 19.5
        let text = 20 + 2 + description
        let row = max(text, readyLabel.isHidden ? cs.height : 16, 20)
        var footer: CGFloat = 0
        let footerWidth = max(1, inner - 32)
        if !help.isHidden { footer += help.height(forWidth: footerWidth) }
        if !errorText.isHidden { footer += (footer > 0 ? 8 : 0) + errorText.height(forWidth: footerWidth) }
        let total = 2 + 32 + row + (footer > 0 ? 8 + footer : 0)
        return (row, text, cs, footer, total)
    }

    public func height(forWidth width: CGFloat) -> CGFloat {
        if presentation == .onboarding { return cardHeight(width: width).total }
        guard let last = blocks(width: width).last else { return 0 }
        let pad: CGFloat = (last.view === accountRow) ? 0 : (last.view === usageButton ? 4 : last.view === help ? 12 : 8)
        return last.frame.maxY + pad
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: max(1, bounds.width))) }

    public override func layout() {
        super.layout()
        if presentation == .onboarding { layoutCard(); return }
        let laid = blocks(width: bounds.width)
        for b in laid { b.view.frame = b.frame }
        // Dividers sit in the 1pt gap above every block after the first.
        while dividers.count < max(0, laid.count - 1) {
            let l = CALayer()
            l.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(l)
            dividers.append(l)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, d) in dividers.enumerated() {
            d.isHidden = i >= laid.count - 1
            guard i < laid.count - 1 else { continue }
            let next = laid[i + 1]
            let top = next.view === usageButton ? next.frame.minY - 4 : next.view === help ? next.frame.minY - 12
                : next.view === accountRow ? next.frame.minY : next.frame.minY - 8
            d.frame = CGRect(x: 0, y: top - 1, width: bounds.width, height: 1)
            d.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
        }
        CATransaction.commit()
    }

    private func layoutCard() {
        let m = cardHeight(width: bounds.width)
        cardBox.layout(boxSize: bounds.size)
        let top: CGFloat = 17
        cardIcon.frame = NSRect(x: 17, y: top + (m.row - 20) / 2, width: 20, height: 20)
        let textX: CGFloat = 17 + 20 + 12
        let controlsW = readyLabel.isHidden ? m.controls.width : readyLabel.width
        let textW = max(1, bounds.width - 1 - 16 - textX - (controlsW > 0 ? controlsW + 12 : 0))
        let textY = top + (m.row - m.text) / 2
        cardTitle.frame = NSRect(x: textX, y: textY, width: textW, height: 20)
        cardDescription.frame = NSRect(x: textX, y: textY + 22, width: textW, height: cardDescription.height(forWidth: textW))
        signedIn.frame = NSRect(x: textX, y: textY + 22, width: textW, height: 19.5)
        descToggle.frame = NSRect(x: textX, y: textY + 22, width: min(textW, descToggle.width), height: 19.5)
        controls.frame = NSRect(x: bounds.width - 17 - m.controls.width, y: top + (m.row - m.controls.height) / 2,
                                width: m.controls.width, height: m.controls.height)
        readyLabel.frame = NSRect(x: bounds.width - 17 - readyLabel.width, y: top + (m.row - 16) / 2, width: readyLabel.width, height: 16)
        var y = top + m.row + 8
        let fx: CGFloat = 17 + 32, fw = max(1, bounds.width - 1 - 16 - 32 - 16)
        if !help.isHidden { let h = help.height(forWidth: fw); help.frame = NSRect(x: fx, y: y, width: fw, height: h); y += h + 8 }
        if !errorText.isHidden { errorText.frame = NSRect(x: fx, y: y, width: fw, height: errorText.height(forWidth: fw)) }
    }

    /// The card's status in place of buttons: "Ready" (`text-xs font-medium text-success-foreground` with the
    /// check), or a plain `text-xs text-muted-foreground` line such as "Checking...".
    final class ReadyLabel: DSView {
        private let icon = IconView(name: .check, size: 14, strokeColor: Themed.color(\.successForeground))
        private let label = LabelView("Ready", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.successForeground))
        private var ready = true
        var width: CGFloat { (ready ? 14 + 6 : 0) + ceil(label.textWidth) + 1 }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.lineHeight = 16
            addSubview(icon); addSubview(label)
            isHidden = true
        }
        func configure(ready: Bool, text: String) {
            self.ready = ready
            isHidden = false
            icon.isHidden = !ready
            label.text = text
            label.font = DSFont.ui(12, weight: ready ? .medium : .regular)
            label.color = ready ? Themed.color(\.successForeground) : Themed.color(\.mutedForeground)
            needsLayout = true
        }
        override func layout() {
            super.layout()
            icon.frame = NSRect(x: 0, y: 1, width: 14, height: 14)
            let x: CGFloat = ready ? 20 : 0
            label.frame = NSRect(x: x, y: 0, width: bounds.width - x, height: 16)
        }
    }
}

/// "Signed in as <email>." with `RedactedSensitiveText` (RedactedSensitiveText.tsx): the email stays blurred
/// until it is clicked.
final class SignedInLineView: DSView {
    private let lead = LabelView("Signed in as ", font: DSFont.ui(12), color: Themed.color(\.contrastMutedForeground, 0.8))
    private let tail = LabelView(".", font: DSFont.ui(12), color: Themed.color(\.contrastMutedForeground, 0.8))
    private var email: UsageRedactedTextView?
    private var value = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 18))
        lead.lineHeight = 18; tail.lineHeight = 18
        addSubview(lead); addSubview(tail)
    }

    func configure(email value: String) {
        guard value != self.value else { return }
        self.value = value
        email?.removeFromSuperview()
        let e = UsageRedactedTextView(value)
        e.setAccessibilityLabel("Toggle account email visibility")
        addSubview(e)
        email = e
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let lw = ceil(lead.textWidth) + 1
        lead.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: lw, height: 18)
        let ew = min(email?.intrinsicContentSize.width ?? 0, max(0, bounds.width - lw - 8))
        email?.frame = NSRect(x: lw, y: (bounds.height - 16) / 2, width: ew, height: 16)
        tail.frame = NSRect(x: lw + ew, y: (bounds.height - 18) / 2, width: 8, height: 18)
    }
}

/// The redirect URL fallback (CodexSetupSection.tsx:655-728, 1088-1113): "Having trouble signing in?" opens
/// the paste field, Connect, and "Try sign-in in your browser". A remote browser shows it open, without the toggle.
final class CallbackHelpView: DSView {
    var onToggle: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onDraft: ((String) -> Void)?
    var onBrowser: (() -> Void)?
    private let toggle = Toggle("Having trouble signing in?")
    private let rule = CALayer()
    private let intro = TextBlockView("If sign-in doesn't return to T3 Code, paste the URL from the final localhost page.",
                                      font: DSFont.ui(12), lineHeight: 19.5, color: Themed.color(\.mutedForeground))
    private let input = SecureInputView(placeholder: "Paste the URL from the sign-in tab")
    private let connect = ButtonView("Connect", variant: .outline)
    private let browser = ButtonView("Try sign-in in your browser", variant: .ghostMuted, size: .xs)
    private var showsToggle = true, showsRule = true, open = false, remoteWeb = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(rule)
        input.setAccessibilityLabel("ChatGPT sign-in redirect URL")
        input.onChange = { [weak self] v in self?.onDraft?(String(v.prefix(16_384))) }
        input.onSubmit = { [weak self] in self?.onSubmit?() }
        connect.action = { [weak self] in self?.onSubmit?() }
        browser.trailingIcon = .externalLink
        browser.iconSize = 14
        browser.action = { [weak self] in self?.onBrowser?() }
        toggle.action = { [weak self] in self?.onToggle?() }
        for v in [toggle, intro, input, connect, browser] as [NSView] { addSubview(v) }
    }

    func clear() { input.text = "" }

    /// `toggle`: the settings fallback's own toggle line. `rule`: the `border-t pt-3` of `callbackHelpContent`.
    func configure(toggle shows: Bool, rule withRule: Bool, open: Bool, remoteWeb: Bool, draft: String, enabled: Bool, showsCompletion: Bool) {
        showsToggle = shows; showsRule = withRule; self.open = open; self.remoteWeb = remoteWeb
        toggle.isHidden = !shows
        toggle.expanded = open
        if input.text != draft { input.text = draft }
        input.isEnabled = enabled
        connect.isEnabled = enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let content = open && showsCompletion
        for v in [intro, input, connect] as [NSView] { v.isHidden = !content }
        browser.isHidden = !content || remoteWeb
        rule.isHidden = !(content && withRule)
        needsLayout = true
    }

    private var contentShown: Bool { !intro.isHidden }

    func height(forWidth w: CGFloat) -> CGFloat {
        var h: CGFloat = showsToggle ? 20 : 0
        if contentShown {
            if showsToggle { h += 12 }
            if showsRule { h += 1 + 12 }
            h += intro.height(forWidth: w) + 12 + 32
            if !browser.isHidden { h += 12 + 24 }
        }
        return h
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        if showsToggle {
            toggle.frame = NSRect(x: 0, y: 0, width: min(w, toggle.width), height: 20)
            y = 20
        }
        guard contentShown else { return }
        if showsToggle { y += 12 }
        if showsRule {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rule.frame = CGRect(x: 0, y: y, width: w, height: 1)
            rule.backgroundColor = Themed.color(\.border, 0.5).cgColor(in: self)
            CATransaction.commit()
            y += 13
        }
        let ih = intro.height(forWidth: w)
        intro.frame = NSRect(x: 0, y: y, width: w, height: ih)
        y += ih + 12
        let cw = connect.intrinsicContentSize.width
        input.frame = NSRect(x: 0, y: y, width: max(1, w - cw - 8), height: 32)
        connect.frame = NSRect(x: w - cw, y: y, width: cw, height: 32)
        y += 32
        if !browser.isHidden {
            browser.frame = NSRect(x: 0, y: y + 12, width: browser.intrinsicContentSize.width, height: 24)
        }
    }

    /// `CodexSignInDescription` with `onToggle`: the label and a `size-3` chevron that turns when expanded.
    final class Toggle: ControlView {
        let label: LabelView
        private let chevron = IconView(name: .chevronRight, size: 12, strokeColor: Themed.color(\.mutedForeground))
        var expanded = false { didSet { if expanded != oldValue { chevron.setRotation(expanded ? 90 : 0, motion: .none) }; setAccessibilityExpanded(expanded) } }
        var width: CGFloat { ceil(label.textWidth) + 1 + 6 + 12 }
        init(_ text: String) {
            label = LabelView(text, font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
            super.init(frame: .zero)
            scalesWhenPressed = false
            label.lineHeight = 19.5
            addSubview(label); addSubview(chevron)
            setAccessibilityRole(.button)
            // T3 labels both toggles "Having trouble signing in?".
            setAccessibilityLabel("Having trouble signing in?")
        }
        override func layout() {
            super.layout()
            let lw = ceil(label.textWidth) + 1
            label.frame = NSRect(x: 0, y: (bounds.height - 19.5) / 2, width: lw, height: 19.5)
            chevron.frame = NSRect(x: lw + 6, y: (bounds.height - 12) / 2, width: 12, height: 12)
        }
    }
}
