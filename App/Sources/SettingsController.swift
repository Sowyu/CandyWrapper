import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// Settings as pages inside the main window (T3's `/settings/*` routes): the settings nav replaces the
/// thread sidebar, the page replaces the thread panel, and Back or Escape returns. Only Connections
/// works for now (WP6.3). Cmd+, and the sidebar footer's Settings button open it.
@MainActor
final class SettingsController {
    private weak var window: NSWindow?
    private weak var layout: SidebarLayoutView?
    private let threadSidebar: NSView
    private let threadPanel: NSView
    private let environments: Environments
    private let t3: T3ConnectController
    private let nav = SettingsSidebarView()
    private let page = SettingsPageView()
    private let connections = ConnectionsSettingsView()
    private(set) var isOpen = false
    /// The local environment's descriptor, read when the page opens (label, machine, version).
    private var primaryDescriptor: EnvironmentDescriptor?
    private var modal: ModalHost?
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
        page.page = connections
        page.header.section = .connections
        page.onEscape = { [weak self] in self?.close() }
        nav.onBack = { [weak self] in self?.close() }
        nav.onToggleSidebar = { [weak layout] in layout?.toggle() }
        connections.onHeightChange = { [weak self] in self?.page.needsLayout = true }
        var actions = ConnectionsActions()
        actions.addEnvironment = { [weak self] in self?.presentAdd(routeTarget: nil) }
        actions.addRoute = { [weak self] id in self?.presentAdd(routeTarget: id) }
        actions.setEnabled = { [weak self] id, on in self?.setEnabled(id, on) }
        actions.remove = { [weak self] id in self?.confirmRemove(id) }
        actions.removeRoute = { [weak self] id, route in self?.confirmRemoveRoute(id, route) }
        actions.copy = { [weak self] text, title, description in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.toast(title, description, .success)
        }
        actions.addCloud = { [weak t3] id in t3?.add(id) }
        actions.retryCloud = { [weak t3] in t3?.refreshMachines() }
        connections.actions = actions
        environments.observe { [weak self] in self?.refresh() }
        nav.onSignIn = { [weak self] in
            guard let self, let window = self.window else { return }
            self.t3.presentSignIn(in: window)
        }
        nav.onAccount = { [weak self] trigger in
            guard let self, let window = self.window else { return }
            self.t3.showAccountMenu(from: trigger, window: window)
        }
        t3.toast = { [weak self] title, message, kind in self?.toast(title, message, kind) }
        t3.observe { [weak self] in self?.refresh() }
    }

    // MARK: Open and close

    func open() {
        guard !isOpen, let layout else { return }
        isOpen = true
        nav.windowedMac = (threadSidebar as? SidebarContentView)?.windowedMac ?? true
        layout.sidebar.content = nav
        threadPanel.removeFromSuperview()
        layout.main.addSubview(page)
        layout.needsLayout = true
        window?.makeFirstResponder(page)
        refresh()
        loadPrimaryDescriptor()
        // Connections refreshes the account's machines each time it opens (CloudEnvironmentConnectRows).
        t3.refreshMachines()
    }

    func close() {
        guard isOpen, let layout else { return }
        modal?.close()
        isOpen = false
        layout.sidebar.content = threadSidebar
        page.removeFromSuperview()
        layout.main.addSubview(threadPanel)
        layout.needsLayout = true
    }

    private func loadPrimaryDescriptor() {
        guard let id = environments.primaryId, let http = environments.session(id)?.http else { return }
        Task {
            primaryDescriptor = try? await http.descriptor()
            refresh()
        }
    }

    // MARK: Model

    private func refresh() {
        guard isOpen else { return }
        nav.t3Connect = !t3.loaded ? .unavailable : t3.signedIn.map { .signedIn($0.identifier ?? "") } ?? .signedOut
        connections.set(model())
        page.pageChanged()
    }

    private func model() -> ConnectionsPageModel {
        var m = ConnectionsPageModel()
        if let id = environments.primaryId {
            let d = primaryDescriptor?.environmentId == id ? primaryDescriptor : nil
            let url = environments.routeInUse(id).map(EnvironmentRowStatus.displayURL)
            let line = [d?.serverVersion, url].compactMap { $0 }.joined(separator: " · ")
            m.thisMachine = .init(label: d?.label ?? environments.label(id) ?? "This machine",
                                  machine: d?.platform?.machine ?? environments.machine(id) ?? "desktop",
                                  versionLine: line.isEmpty ? "Loading…" : line,
                                  // ponytail: "Up to date" whenever the version is known; T3 compares with its own app version and offers updates (M9)
                                  upToDate: d != nil)
        }
        m.environments = environments.saved.map { r in
            let state = environments.state(r.environmentId)
            let status = EnvironmentRowStatus(enabled: r.enabled, state: state)
            let inUse = state?.status == .connected ? environments.routeInUse(r.environmentId) : nil
            let routes = r.routes.map { url in
                // `connectionRouteAddress` is null for T3 Connect.
                ConnectionsPageModel.Route(url: url, label: r.routeLabel(url), address: r.isRelayRoute(url) ? "" : EnvironmentRowStatus.displayURL(url),
                                           inUse: inUse.map { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(url) } ?? false)
            }
            // `environmentMcpUrl`: the route in use, else the first, at `/mcp`.
            let mcpBase = inUse ?? r.httpBaseURL
            return ConnectionsPageModel.Environment(
                id: r.environmentId, label: r.label, machine: environments.machine(r.environmentId) ?? r.machine ?? "server",
                enabled: r.enabled, unsupported: state?.status == .unsupported,
                subtitle: transport(r, inUse: inUse) + " · " + status.text,
                statusIsError: status.isError, tooltip: EnvironmentRowStatus.tooltip(enabled: r.enabled, state: state),
                routes: routes, mcpURL: EnvironmentRoute.origin(mcpBase) + "/mcp",
                removing: environments.removing.contains(r.environmentId))
        }
        m.cloudEnabled = true
        m.cloud = t3.cloudModel(primaryId: environments.primaryId)
        return m
    }

    /// `environmentTransportLabel` with T3 Connect: `via <route>` or the first route's label with several
    /// routes, `T3 Connect` for a machine reached only through it, else the URL.
    private func transport(_ r: EnvironmentRegistration, inUse: URL?) -> String {
        guard r.routes.count > 1 else { return r.isRelayOnly ? "T3 Connect" : EnvironmentRowStatus.transport(routes: r.routes, inUse: inUse) }
        if let inUse, let active = r.routes.first(where: { EnvironmentRoute.origin($0) == EnvironmentRoute.origin(inUse) }) {
            return "via \(r.routeLabel(active))"
        }
        return r.routeLabel(r.routes[0])
    }

    // MARK: Actions

    private func toast(_ title: String, _ message: String?, _ kind: ToastQueue.Kind) {
        page.toasts.show(ToastView(title: title, message: message, kind: kind))
    }

    private func presentAdd(routeTarget: String?) {
        guard let window, modal == nil else { return }
        let targetLabel = routeTarget.flatMap { environments.label($0) }
        let (dialog, form) = AddEnvironmentDialog.make(routeTarget: targetLabel)
        form.splitPairingURL = { Pairing.splitPairingURL($0) }
        form.onSubmit = { [weak self, weak form] host, code in
            guard let self, let form else { return }
            self.add(host: host, code: code, routeTarget: routeTarget, targetLabel: targetLabel, form: form)
        }
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        self.form = form
        window.makeFirstResponder(form.host)
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
    private func confirm(_ title: String, _ message: String, confirmTitle: String = "Confirm", then action: @escaping () -> Void) {
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
