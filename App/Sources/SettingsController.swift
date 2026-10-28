import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// Settings as pages inside the main window (T3's `/settings/*` routes): the settings nav replaces the
/// thread sidebar, the page replaces the thread panel, and Back or Escape returns. General, Appearance,
/// Keybindings (SettingsPages.swift) and Connections work. Cmd+, and the sidebar footer's Settings button open it.
@MainActor
final class SettingsController {
    weak var window: NSWindow?
    private weak var layout: SidebarLayoutView?
    private let threadSidebar: NSView
    private let threadPanel: NSView
    let environments: Environments
    let t3: T3ConnectController
    // Built on first open: an app that never opens Settings never pays for its views.
    lazy var nav = SettingsSidebarView()
    lazy var page = SettingsPageView()
    private lazy var connections = ConnectionsSettingsView()
    private var built = false
    private var sshAddTask: Task<Void, Never>?
    /// The open page; T3 opens `/settings` at General.
    var section: SettingsSection = .general
    /// `ThreadNotificationCoordinator.choose`, set by the app.
    var chooseNotificationMode: ((ThreadNotificationMode) async -> String?)?
    /// The project icon file picker (the palette's `ProjectFaviconPickerDialog`), set by the app.
    var chooseIconFile: ((String, String, String, Bool, @escaping (String) -> Void) -> Void)?
    // Pages and their shared context (SettingsPages.swift).
    let pageContext = SettingsPageContext()
    /// Server setting saves, one at a time (audit SU1).
    let settingsWrites = SettingsWriteQueue()
    var scopeSelection = SettingsScopeSelection()
    var general: ConcernSettingsView?
    var appearance: AppearanceSettingsView?
    var keybindingsPage: KeybindingsSettingsView?
    /// Project, Providers, Integrations, Source Control, Storage, Archive, Diagnostics and SnapShots (WP7.7b), built on first open.
    var extraPages: [SettingsSection: SettingsPageBase] = [:]
    /// Redesign's open section and its views; nil under other themes.
    var ditherSection: DitherSettingsSection?
    var ditherPages: [DitherSettingsSection: DitherSettingsSectionView] = [:]
    weak var composer: ComposerController?
    var clientObserver: Int?
    var themeObserver: NSObjectProtocol?
    isolated deinit {
        if let clientObserver { ClientSettingsStore.shared.removeObserver(clientObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }
    private(set) var isOpen = false { didSet { if isOpen != oldValue { navigationGeneration += 1 } } }
    private(set) var navigationGeneration = 0
    /// Settings opened, changed page or closed (route history).
    var onOnboardingReturn: (() -> Void)?
    var onRouteChange: (() -> Void)?
    /// The nav's brand link to "/".
    var onHome: () -> Void = {}
    /// The thread view is back in the window (focus goes to the composer).
    var onThreadViewReturn: () -> Void = {}
    /// The local environment's descriptor, read when the page opens (label, machine, version).
    var primaryDescriptor: EnvironmentDescriptor?
    var modal: ModalHost?
    /// Version skew and server updates, shared with the composer notice.
    var serverUpdates: ServerUpdates? {
        didSet { serverUpdates?.observe { [weak self] in self?.refresh() } }
    }

    // Host access (SettingsHostAccess.swift).
    var hosts: [String: HostInfo] = [:]
    var hostLoads: Set<String> = []
    /// Each project scope member's decoded t3.json by physical key, read once per Settings visit.
    var projectFiles: [String: T3ProjectFile?] = [:]
    var projectFileLoads: Set<String> = []
    var linkState: CloudLinkState?
    var linkLoading = false
    var linkBusy = false
    var linkError: String?
    var access = AuthAccessSnapshot()
    var accessLoaded = false
    var accessError: String?
    var accessTask: Task<Void, Never>?
    /// Credentials of pairing links created while the page is open, by link id. Memory only.
    var credentials: [String: String] = [:]
    var revokingLink: String?
    var revokingClient: String?
    var revokingOthers = false
    var ticker: Timer?
    /// Rereads the T3 Connect link state every 30 s while Connections shows a tunnel (`updateLinkPoll`).
    var linkPoll: Timer?
    /// Stops that poll while the window is hidden or covered, and restarts it when the window shows again.
    var linkPollVisibility: NSObjectProtocol?
    /// Linked environments by host environment id, read once per visit (SettingsLinkedEnvironments.swift).
    var peerLinks: [String: PeerLinkLoad] = [:]
    /// "host/peer" keys whose Forget is in flight.
    var forgettingLinks: Set<String> = []
    /// The open Add Environment form, for errors and the Adding state.
    private weak var form: AddEnvironmentFormView?

    init(window: NSWindow, layout: SidebarLayoutView, threadSidebar: NSView, threadPanel: NSView, environments: Environments,
         t3: T3ConnectController) {
        self.window = window
        self.layout = layout
        self.threadSidebar = threadSidebar
        self.threadPanel = threadPanel
        self.environments = environments
        self.t3 = t3
        environments.observe { [weak self] in self?.refresh() }
        environments.observeShell { [weak self] in self?.shellChanged() }
        t3.toast = { [weak self] title, message, kind in self?.toast(title, message, kind) }
        t3.observe { [weak self] in self?.refresh() }
    }

    private func buildViews() {
        guard !built else { return }
        built = true
        page.onEscape = { [weak self] in self?.escape() }
        nav.onSelect = { [weak self] section in self?.show(section) }
        nav.onSearchResult = { [weak self] item in self?.jump(to: item) }
        page.header.restore.action = { [weak self] in self?.confirmRestoreDefaults() }
        setUpPageContext()
        nav.onBack = { [weak self] in self?.close() }
        nav.onHome = { [weak self] in self?.onHome() }
        nav.onToggleSidebar = { [weak self] in self?.layout?.toggle() }
        connections.onHeightChange = { [weak self] in self?.page.needsLayout = true }
        var actions = ConnectionsActions()
        actions.addEnvironment = { [weak self] in self?.presentAdd(routeTarget: nil) }
        actions.addRoute = { [weak self] id in self?.presentAdd(routeTarget: id) }
        actions.retryNow = { [weak self] id in self?.environments.reconnect(id) }
        actions.setEnabled = { [weak self] id, on in self?.setEnabled(id, on) }
        actions.remove = { [weak self] id in self?.confirmRemove(id) }
        actions.removeRoute = { [weak self] id, route in self?.confirmRemoveRoute(id, route) }
        actions.copy = { [weak self] text, title, description in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast(title, description, .success)
        }
        actions.copySecret = { [weak self] text, title, description in
            ConnectionsActions.copySecret(text)
            self?.toast(title, description, .success)
        }
        actions.addCloud = { [weak t3] id in t3?.add(id) }
        actions.retryCloud = { [weak t3] in t3?.refreshMachines() }
        actions.setHostSwitch = { [weak self] id, on in self?.setHostSwitch(id, on) }
        actions.setIcon = { [weak self] id, kind in self?.setIcon(id, kind) }
        actions.reorderRoutes = { [weak self] id, routes in self?.reorderRoutes(id, routes) }
        actions.createPairingLink = { [weak self] in self?.presentCreateLink() }
        actions.revokePairingLink = { [weak self] id in self?.revokePairingLink(id) }
        actions.revokeClient = { [weak self] id in self?.revokeClient(id) }
        actions.revokeOtherClients = { [weak self] in self?.revokeOtherClients() }
        actions.setLoadBalancing = { [weak self] on in
            ClientSettingsStore.shared.update(["loadBalancingEnabled": .bool(on)])
            self?.refresh()
        }
        actions.setLoadPreference = { [weak self] id, weight in self?.setLoadPreference(id, weight) }
        actions.updateServer = { [weak self] id in
            guard let self else { return }
            let label = id == environments.primaryId ? connections.model.thisMachine?.label : environments.label(id)
            let serverLabel = label.map { "\($0) server" } ?? "server"
            if serverUpdates?.outdatedHost(id) != nil { serverUpdates?.updateOutdated(id, serverLabel: serverLabel) } else {
                serverUpdates?.request(id, serverLabel: serverLabel)
            }
        }
        actions.updateAll = { [weak self] in self?.serverUpdates?.updateAll() }
        actions.linkEnvironment = { [weak self] id in self?.presentLinkEnvironment(id) }
        actions.forgetLink = { [weak self] host, peer in self?.forgetPeerLink(host, peer) }
        connections.actions = actions
        nav.onSignIn = { [weak self] in
            guard let self, let window = self.window else { return }
            self.t3.presentSignIn(in: window)
        }
        pageContext.signInToConnect = nav.onSignIn
        nav.onAccount = { [weak self] trigger in
            guard let self, let window = self.window else { return }
            self.t3.showAccountMenu(from: trigger, window: window)
        }
    }

    // MARK: Open and close

    /// Opens on `target` (the provider banner's "Open provider setup" lands on Providers).
    func open(_ target: SettingsSection) {
        section = target
        if isOpen { show(target) } else { open() }
    }

    func open() {
        guard !isOpen, let layout else { return }
        buildViews()
        isOpen = true
        nav.windowedMac = (threadSidebar as? SidebarContentView)?.windowedMac ?? true
        layout.sidebar.content = nav
        threadPanel.removeFromSuperview()
        layout.mainContent = page
        show(section)
        window?.makeFirstResponder(page)
        startHostAccess()
        refresh()
        loadPrimaryDescriptor()
        // Connections refreshes the account's machines each time it opens (CloudEnvironmentConnectRows).
        t3.refreshMachines()
    }

    /// Escape (`useEscapeToGoBack`): T3 leaves Settings for the last main app screen from any page
    /// (routes/settings.tsx:115-116). Diagnostics and Open source licenses, reached from General, go back to
    /// General first, as the user asked. A held key does nothing more (`event.repeat`).
    func escape() {
        guard isOpen, NSApp.currentEvent?.isARepeat != true else { return }
        if isDither, ditherSection == nil, let parent = DitherSettingsSection.parent(of: section) {
            show(dither: parent)
            window?.makeFirstResponder(page)
        } else if let parent = section.parent {
            show(parent)
            window?.makeFirstResponder(page)
        } else {
            close()
        }
    }

    /// `record` false leaves the route history to the page that replaces Settings.
    func close(record: Bool = true) {
        guard isOpen, let layout else { return }
        modal?.close()
        stopHostAccess()
        isOpen = false
        updateScheduledTaskWatch()
        layout.sidebar.content = threadSidebar
        page.removeFromSuperview()
        // A closed Settings gives back its pages (T3 unmounts the route); the next open builds the one it shows.
        page.page = nil
        general = nil; appearance = nil; keybindingsPage = nil; extraPages = [:]; ditherPages = [:]; ditherSection = nil
        projectFiles = [:]; projectFileLoads = []
        layout.mainContent = threadPanel
        if record { onRouteChange?() }
        onThreadViewReturn()
        let returnToWelcome = onOnboardingReturn; onOnboardingReturn = nil; returnToWelcome?()
    }

    private func loadPrimaryDescriptor() {
        guard let id = environments.primaryId, let http = environments.session(id)?.http else { return }
        Task {
            primaryDescriptor = try? await http.descriptor()
            refresh()
        }
    }

    // MARK: Model

    func refreshPage() { refresh() }

    /// The 1 s tick: rebuilds only the access section and updates the page only when it changed.
    func refreshAccess() {
        guard isOpen, environments.primaryId != nil else { return }
        let access = accessModel()
        guard access != connections.model.access else { return }
        var model = connections.model
        model.access = access
        connections.set(model)
        page.pageChanged()
    }

    private func refresh() {
        guard isOpen else { return }
        nav.t3Connect = !t3.loaded ? .unavailable : t3.signedIn.map { .signedIn($0.identifier ?? "") } ?? .signedOut
        nav.avatar.image = t3.avatar
        nav.avatar.initials = t3.profile?.initials ?? t3.signedIn?.identifier?.first.map { String($0).uppercased() } ?? ""
        loadHosts()
        loadPeerLinks()
        connections.primaryId = environments.primaryId
        connections.set(model())
        refreshPages()
        page.pageChanged()
    }

    /// The Connections page view, for `show(_:)`.
    var connectionsPage: ConnectionsSettingsView { connections }

    private func model() -> ConnectionsPageModel {
        var m = ConnectionsPageModel()
        if let id = environments.primaryId {
            let d = primaryDescriptor?.environmentId == id ? primaryDescriptor : nil
            m.thisMachine = machineModel(id, descriptor: d)
            m.access = accessModel()
        }
        m.environments = environments.saved.map { r in
            let state = environments.state(r.environmentId)
            let status = EnvironmentRowStatus(enabled: r.enabled, state: state)
            let inUse = state?.status == .connected ? environments.routeInUse(r.environmentId) : nil
            // A relay session's origin follows the tunnel, so its saved relay route is the one in use.
            let relayInUse = state?.status == .connected && environments.session(r.environmentId)?.isRelay == true
            let routes = r.routes.map { url in
                // `connectionRouteAddress` is null for T3 Connect.
                ConnectionsPageModel.Route(url: url, label: r.routeLabel(url), address: r.isRelayRoute(url) ? "" : EnvironmentRowStatus.displayURL(url),
                                           inUse: relayInUse ? r.isRelayRoute(url) : inUse.map { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(url) } ?? false)
            }
            // `environmentMcpUrl`: the route in use, else the first, at `/mcp`.
            let mcpBase = inUse ?? r.httpBaseURL
            // The row's version note and update control (ConnectionsSettings.tsx:1548-1612, 1716-1741).
            let id = r.environmentId
            let update = serverUpdates?.state(id) ?? .idle
            let mismatch = serverUpdates?.mismatch(id)
            var resuming = false
            if case .running(.resuming, _, _) = update { resuming = true }
            // What failed on the way (`useConnectionDiagnosis`, ConnectionDiagnosisDetails.tsx:27-52). With a direct route as
            // well, the relay's health says nothing about the route in use.
            let diagnosis = r.enabled && !resuming && state?.status != .connected && state?.status != .unsupported
                ? state.flatMap { diagnosisInput(r, $0) }.flatMap(ConnectionDiagnosis.present) : nil
            // The headline below names the failure in full (SavedEnvironmentRows.tsx:210-218).
            let subtitle = [transport(r, inUse: inUse), diagnosis != nil ? nil : resuming ? "Restarting" : status.text, r.enabled ? mismatch?.server : nil]
                .compactMap { $0 }.joined(separator: " · ")
            var tooltip = EnvironmentRowStatus.tooltip(enabled: r.enabled, state: state)
            if let mismatch { tooltip += "\nUpdate available: \(mismatch.server) → \(mismatch.client)" }
            var updateAction: ConnectionsPageModel.UpdateAction?
            // A host too old to connect (ConnectionsSettings.tsx:1716-1726): "Update" in place of the icon.
            if state?.status == .unsupported, !update.isRunning, serverUpdates?.outdatedHost(id) != nil,
               environments.session(id)?.token.isEmpty == false {
                updateAction = .outdated(update.isFailed ? "Retry update" : "Update")
            }
            if r.enabled, state?.status == .connected, mismatch != nil, !update.isRunning, let updates = serverUpdates {
                switch updates.offer(id, serverLabel: "\(r.label) server") {
                case .update?: updateAction = .update(update.isFailed ? "Retry update" : "Update", enabled: updates.canUpdate(id))
                case .manual(let manual)?: updateAction = .copy(manual)
                case .desktopManual?: updateAction = .desktopManual
                case nil: break
                }
            }
            var row = ConnectionsPageModel.Environment(
                id: id, label: r.label, machine: environments.machine(id) ?? r.machine ?? "server",
                enabled: r.enabled, unsupported: state?.status == .unsupported,
                subtitle: subtitle,
                statusIsError: status.isError && !resuming && diagnosis == nil, tooltip: tooltip,
                routes: routes, mcpURL: EnvironmentRoute.origin(mcpBase) + "/mcp",
                removing: environments.removing.contains(id),
                permissions: permissions(id, routeContext: true), iconMenu: iconMenu(id))
            row.updateAction = updateAction
            row.updateProgress = update
            row.diagnosis = diagnosis
            row.attempt = state?.attempt ?? 0
            if state?.phase == .backoff, let at = state?.retryAt { row.retryAt = Date(timeIntervalSinceNow: Self.seconds(at - .now)) }
            row.relayOnly = r.isRelayOnly
            row.traceId = state?.failure?.traceId
            return row
        }
        m.canUpdateAll = !(serverUpdates?.updateAllTargets().isEmpty ?? true)
        m.cloudEnabled = true
        m.cloud = t3.cloudModel(primaryId: environments.primaryId)
        m.loadBalancing = loadBalancingModel(primaryLabel: m.thisMachine?.label)
        m.linkedEnvironments = linkedEnvironmentsModel()
        return m
    }

    /// `useConnectionDiagnosis`'s input from the supervisor's state and, for a machine reached only through T3 Connect,
    /// the relay's last health check.
    private func diagnosisInput(_ r: EnvironmentRegistration, _ state: ConnectionState) -> ConnectionDiagnosis.Input {
        let relay = r.isRelayOnly ? t3.machines?.first { $0.environmentId == r.environmentId }?.status : nil
        return ConnectionDiagnosis.Input(
            hostLabel: r.label, offline: state.phase == .offline, failure: state.failure, via: r.isRelayOnly ? .relay : .direct,
            relayStatus: relay.map { .init(status: $0.status, endpointFailure: $0.endpointFailure, endpointStatus: $0.endpointStatus.flatMap { Int(exactly: $0) },
                                           offlineReason: $0.offlineReason) },
            attempt: state.attempt, retryAt: state.retryAt.map { Date(timeIntervalSinceNow: Self.seconds($0 - .now)) },
            clientVersion: ServerVersionSkewLogic.clientVersion,
            serverVersion: serverUpdates?.descriptor(r.environmentId)?.serverVersion)
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// `LoadBalancingSettings` over `loadBalancingEnvironments`: this machine, then the switched-on saved ones; only
    /// with two or more.
    private func loadBalancingModel(primaryLabel: String?) -> ConnectionsPageModel.LoadBalancing? {
        var machines: [ConnectionsPageModel.LoadBalancing.Machine] = []
        if let id = environments.primaryId {
            machines.append(.init(id: id, label: primaryLabel ?? "This machine", machine: environments.machine(id) ?? "server", subtitle: "This machine"))
        }
        for r in environments.saved where r.enabled {
            let inUse = environments.state(r.environmentId)?.status == .connected ? environments.routeInUse(r.environmentId) : nil
            machines.append(.init(id: r.environmentId, label: r.label, machine: environments.machine(r.environmentId) ?? r.machine ?? "server",
                                  subtitle: transport(r, inUse: inUse)))
        }
        guard machines.count >= 2 else { return nil }
        let client = ClientSettingsStore.shared.current
        return .init(enabled: client.bool("loadBalancingEnabled"), machines: machines,
                     weights: LoadBalancingLogic.weights(client["loadBalancingWeights"]))
    }

    private func setLoadPreference(_ id: String, _ weight: Int) {
        var weights = ClientSettingsStore.shared.current["loadBalancingWeights"].objectValue ?? [:]
        weights[id] = .number(Double(weight))
        ClientSettingsStore.shared.update(["loadBalancingWeights": .object(weights)])
        refresh()
    }

    /// `environmentTransportLabel` with T3 Connect: `via <route>` or the first route's label with several
    /// routes, `T3 Connect` for a machine reached only through it, else the URL.
    private func transport(_ r: EnvironmentRegistration, inUse: URL?) -> String {
        guard r.routes.count > 1 else {
            if r.isRelayOnly { return "T3 Connect" }
            if let target = r.sshTarget { return "SSH \(target.display)" }
            return EnvironmentRowStatus.transport(routes: r.routes, inUse: inUse)
        }
        if let inUse, let active = r.routes.first(where: { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(inUse) }) {
            return "via \(r.routeLabel(active))"
        }
        return r.routeLabel(r.routes[0])
    }

    // MARK: Actions

    /// The toast stack while Settings shows, for toasts that aren't about Settings (thread notifications).
    var visibleToasts: ToastViewport? { isOpen ? page.toasts : nil }

    /// A pairing link opened with the app (`/pair#token=...`): Settings > Connections with the add dialog filled in.
    func openPairingLink(host: String, code: String) {
        open()
        show(.connections)
        presentAdd(routeTarget: nil)
        form?.prefill(host: host, code: code)
    }

    func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind) {
        // A queued save can fail after Settings closed; its error still shows, over the thread.
        let toasts = isOpen ? page.toasts : (threadPanel as? ThreadPanelView)?.toasts
        toasts?.show(ToastView(title: title, message: message, kind: kind))
    }

    func presentAdd(routeTarget: String?) {
        guard let window, modal == nil else { return }
        let targetLabel = routeTarget.flatMap { environments.label($0) }
        let (dialog, form) = AddEnvironmentDialog.make(routeTarget: targetLabel)
        form.splitPairingURL = { Pairing.splitPairingURL($0) }
        form.onSubmit = { [weak self, weak form] host, code in
            guard let self, let form else { return }
            self.add(host: host, code: code, routeTarget: routeTarget, targetLabel: targetLabel, form: form)
        }
        // `useDesktopSshHosts`: discovery reads ~/.ssh/config (and its includes) and known_hosts, and connects
        // nowhere. `--ssh-home <dir>` points it at fixture files for on-screen checks.
        form.onSSHMode = { [weak form] in
            let args = CommandLine.arguments
            let home = args.firstIndex(of: "--ssh-home").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser
            Task {
                do { form?.sshHosts.options = try await Task.detached { try SshEnvironmentDiscovery.discover(home: home) }.value }
                catch { form?.error = "Failed to discover SSH hosts." }
            }
        }
        // `handleSelectSshHostSuggestion` (ConnectionsSettings.tsx:2688-2709): resolve the alias, fill the fields, connect.
        form.sshHosts.onChange = { [weak self, weak form] index in
            guard let self, let form, !form.isAdding, form.sshHosts.options.indices.contains(index) else { return }
            let alias = form.sshHosts.options[index]
            self.connectSSH(form: form, routeTarget: routeTarget, targetLabel: targetLabel) {
                let resolved = try await self.environments.ssh.resolve(alias: alias)
                form.sshUsername.text = resolved.username ?? ""; form.sshPort.text = resolved.port.map(String.init) ?? ""
                return resolved
            }
        }
        // `handleAddSavedBackend` in SSH mode (ConnectionsSettings.tsx:2582-2597).
        form.onSubmitSSH = { [weak self, weak form] alias, user, port in
            guard let self, let form, !form.isAdding else { return }
            let target: SshEnvironmentTarget
            do { target = try SshEnvironmentTarget.manual(host: alias, username: user, port: port) }
            catch { form.error = String(describing: error); return }
            self.connectSSH(form: form, routeTarget: routeTarget, targetLabel: targetLabel) { target }
        }
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in
            self?.modal = nil
            self?.sshAddTask?.cancel(); self?.sshAddTask = nil
            let callback = self?.onOnboardingReturn; self?.onOnboardingReturn = nil; callback?()
        }
        modal = host
        self.form = form
        window.makeFirstResponder(form.host)
    }

    /// `connectSavedBackendSshTarget` (ConnectionsSettings.tsx:2546-2578): launch or reuse the host's server, pair,
    /// save, close and toast. A target no saved environment uses is disconnected again when this fails.
    private func connectSSH(form: AddEnvironmentFormView, routeTarget: String?, targetLabel: String?,
                            target makeTarget: @escaping @MainActor () async throws -> SshEnvironmentTarget) {
        form.isAdding = true; form.error = nil
        sshAddTask = Task { [weak self, weak form] in
            guard let self else { return }
            var started: SshEnvironmentTarget?
            do {
                let target = try await makeTarget()
                let bootstrap = try await self.environments.ssh.ensure(target)
                started = bootstrap.target
                try Task.checkCancellation()
                _ = try await self.environments.pairSSH(bootstrap, routeTarget: routeTarget)
                form?.isAdding = false
                self.modal?.close()
                if let targetLabel {
                    self.toast("Route added", "\(targetLabel) can now be reached over SSH \(target.alias).", .success)
                } else {
                    self.toast("Environment connected", "\(target.alias) is ready over an SSH-managed tunnel.", .success)
                }
            } catch {
                if let started, !self.environments.saved.contains(where: { $0.sshTarget?.stateKey == started.stateKey }) {
                    self.environments.ssh.disconnect(started)
                }
                form?.isAdding = false
                // `formatDesktopSshConnectionError`; an interrupted add (dialog closed) shows nothing.
                if !(error is CancellationError) { form?.error = String(describing: error) }
            }
        }
    }

    /// `handleAddSavedBackend` for Remote link.
    private func add(host: String, code: String, routeTarget: String?, targetLabel: String?, form: AddEnvironmentFormView) {
        form.isAdding = true
        form.error = nil
        Task {
            do {
                _ = try await environments.pair(host: host, code: code, routeTarget: routeTarget)
                form.isAdding = false
                modal?.close()
                if let targetLabel {
                    toast("Route added", "\(targetLabel) now has another way to connect.", .success)
                } else {
                    toast("Backend added", "The environment is saved and will reconnect on app startup.", .success)
                }
            } catch {
                let message = (error as? PairingError)?.message ?? "Failed to add backend."
                form.isAdding = false
                form.error = message
                toast("Could not add backend", message, .error)
            }
        }
    }

    private func setEnabled(_ id: String, _ on: Bool) {
        Task {
            do { try await environments.setEnabled(id, on) } catch {
                toast("Could not switch backend \(on ? "on" : "off")", "\(error)", .error)
                refresh()
            }
        }
    }

    /// `requestConfirmDialog` as `ConfirmDialogHost` draws it: the question line is the title, the rest
    /// the description, then Cancel and a destructive Confirm.
    func confirm(_ title: String, _ message: String, confirmTitle: String = "Confirm", then action: @escaping () -> Void) {
        guard let window, modal == nil else { return }
        let dialog = DialogView(kind: .alertDialog, title: title, message: message)
        let cancel = ButtonView("Cancel", variant: .outline)
        let ok = ButtonView(confirmTitle, variant: .destructive)
        dialog.footerButtons = [cancel, ok]
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        cancel.action = { [weak host] in host?.close() }
        ok.action = { [weak host] in host?.close(); action() }
    }

    private func confirmRemove(_ id: String) {
        let label = environments.label(id) ?? id
        let remove: () -> Void = { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.environments.removeSaved(id) } catch {
                    self.toast("Could not remove backend", "\(error)", .error)
                }
            }
        }
        // A T3 Connect machine stays on the account (RemoveT3ConnectEnvironmentDialog.tsx:46-72).
        // ponytail: "T3 Connect settings" is plain text here; T3 links it to the account page
        if environments.saved.first(where: { $0.environmentId == id })?.relay != nil {
            confirm("Remove \(label) from this device?",
                    "This forgets its pairing, credentials, and cached threads here.\n\nIt stays on your T3 Connect account and keeps its host space. Deregister it in T3 Connect settings to free it.",
                    confirmTitle: "Remove from this device", then: remove)
            return
        }
        confirm("Remove \(label) from this device?",
                "This forgets its pairing, credentials, and cached threads here. Switch it off instead to keep it saved.") { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.environments.removeSaved(id) } catch {
                    self.toast("Could not remove backend", "\(error)", .error)
                }
            }
        }
    }

    private func confirmRemoveRoute(_ id: String, _ route: ConnectionsPageModel.Route) {
        confirm("Remove \(route.label) route?", route.address) { [weak self] in
            guard let self else { return }
            Task {
                do { try await self.environments.removeRoute(route.url, environmentId: id) } catch {
                    self.toast("Could not remove route", "\(error)", .error)
                }
            }
        }
    }
}
