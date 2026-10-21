import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// What Settings > Connections reads from each environment it shows: the descriptor (machine,
/// capabilities) and this client's session there (`GET /api/auth/session`, the permission list).
struct HostInfo {
    var descriptor: EnvironmentDescriptor?
    var session: AuthSessionState?
}

/// The host side of Settings > Connections: "This machine" rows, the T3 Connect preferences, the Icon
/// submenu, the Permissions panels and "Authorized clients" (ConnectionsSettings.tsx:2034-3776).
///
/// CandyWrapper never restarts or reconfigures the T3 server process. Rows that T3 Code's desktop app
/// changes through its bridge (Local environment, Network access, Tailscale HTTPS, the T3 Connect link
/// switch) show their state and stay disabled with `bridgeTooltip`. Changes the server applies itself
/// go through its own API: `server.updateSettings` for the icon, `/api/connect/preferences`, and the
/// `/api/auth/*` pairing and revoke routes.
extension SettingsController {
    // ponytail: one tooltip for every bridge-only control; split it per row if users ask what each needs
    static let bridgeTooltip = "Only the T3 Code app can change this. It restarts the server."
    static let linkTooltip = "Only the T3 Code app can link this environment to T3 Connect."

    // MARK: Loading

    /// Page opened: read every connected environment's descriptor and session, the primary's T3 Connect
    /// link, and follow its pairing links and client sessions.
    func startHostAccess() {
        hosts = [:]
        hostLoads = []
        linkState = nil
        linkError = nil
        accessLoaded = false
        accessError = nil
        access = AuthAccessSnapshot()
        loadHosts()
    }

    /// `useRelativeTimeTick(1_000)`: expiry and connected-for labels count down. Only the access
    /// section has them, so only it is rebuilt, and the page updates only when a label changed.
    /// The tick runs only while there is a link or session to count; nothing runs otherwise.
    private func updateAccessTicker() {
        let live = isOpen && (!access.pairingLinks.isEmpty || !access.clientSessions.isEmpty)
        if live, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccess() }
            }
            ticker?.tolerance = 0.2
        } else if !live {
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// Page closed: the stream stops and created credentials are forgotten (T3 keeps them only while the
    /// page is open).
    func stopHostAccess() {
        accessTask?.cancel()
        accessTask = nil
        ticker?.invalidate()
        ticker = nil
        linkPoll?.invalidate()
        linkPoll = nil
        credentials = [:]
    }

    /// Reads hosts that are connected and not read yet. Called on each refresh, so a machine that
    /// connects while the page is open gets its permissions.
    func loadHosts() {
        guard isOpen else { return }
        let ids = ([environments.primaryId].compactMap { $0 } + environments.saved.map(\.environmentId))
        for id in ids where hosts[id]?.session == nil && !hostLoads.contains(id) && environments.state(id)?.status == .connected {
            guard let shell = environments.session(id) else { continue }
            hostLoads.insert(id)
            let http = shell.http, token = shell.token
            Task {
                async let d = try? http.descriptor()
                async let s = try? http.session(token: token)
                let info = HostInfo(descriptor: await d, session: await s)
                hostLoads.remove(id)
                guard isOpen else { return }
                hosts[id] = info
                if id == environments.primaryId {
                    if let machine = info.descriptor?.platform?.machine { environments.setDetectedMachine(id, machine) }
                    hostReady()
                }
                refreshPage()
            }
        }
    }

    /// The primary's session is known: read the link state and subscribe to access changes as its
    /// permissions allow.
    private func hostReady() {
        guard let id = environments.primaryId, let session = hosts[id]?.session else { return }
        if session.grants(AuthScopes.relayRead), t3.loaded { loadLinkState() }
        if session.grants(AuthScopes.accessRead), accessTask == nil, let shell = environments.session(id) {
            let env = id
            accessTask = shell.supervisor.subscribe("subscribeAuthAccess", payload: { .object([:]) }, handler: { [weak self] event in
                guard case .value(let json) = event else { return }
                await MainActor.run {
                    guard let self, self.environments.primaryId == env else { return }
                    do {
                        try self.access.apply(json)
                        self.accessLoaded = true
                        self.updateAccessTicker()
                    } catch {
                        self.accessError = "Could not read authorized clients."
                    }
                    self.refreshPage()
                }
            })
        }
    }

    func loadLinkState() {
        guard let id = environments.primaryId, let shell = environments.session(id), !linkLoading else { return }
        linkLoading = true
        let http = shell.http, token = shell.token
        Task {
            do {
                linkState = try await http.cloudLinkState(token: token)
                linkError = nil
            } catch {
                linkError = Self.message(error, fallback: "Could not read T3 Connect link state.")
            }
            linkLoading = false
            updateLinkPoll()
            refreshPage()
        }
    }

    /// The server rechecks reachability when the tunnel's readiness changes, so T3 rereads the link state
    /// every 30 s while the row is mounted (SavedEnvironmentRows.tsx:489-494). Here the timer runs only
    /// while the Connections page shows an active tunnel, the only time the reachability line shows.
    func updateLinkPoll() {
        let live = isOpen && section == .connections && linkState?.tunnelActive == true
        if live, linkPoll == nil {
            linkPoll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadLinkState() }
            }
            linkPoll?.tolerance = 3
        } else if !live {
            linkPoll?.invalidate()
            linkPoll = nil
        }
    }

    // MARK: Model

    private func session(_ id: String) -> AuthSessionState? { hosts[id]?.session }
    private func grants(_ id: String?, _ scope: String) -> Bool { id.flatMap { session($0)?.grants(scope) } ?? false }

    /// "This machine" in T3 desktop's order (ConnectionsSettings.tsx:3613-3734).
    func machineModel(_ id: String, descriptor d: EnvironmentDescriptor?) -> ConnectionsPageModel.Machine {
        let url = environments.routeInUse(id).map(EnvironmentRowStatus.displayURL)
        // The welcome's descriptor follows a restart; the HTTP one is read when Settings opens.
        let version = serverUpdates?.descriptor(id)?.serverVersion ?? d?.serverVersion
        let line = [version, url].compactMap { $0 }.joined(separator: " · ")
        let canMaintain = grants(id, AuthScopes.environmentMaintain)
        let canReadRelay = grants(id, AuthScopes.relayRead)
        let canManageRelay = grants(id, AuthScopes.relayWrite)
        var rows: [ConnectionsPageModel.HostRow] = []
        // `LocalEnvironmentSetting`: CandyWrapper is talking to the local server, so it is on.
        rows.append(.init(id: "local-environment", title: "Local environment",
                          detail: "Run agents on this computer. Turn off to use T3 Code only with remote environments.",
                          control: .toggle(.init(isOn: true, isEnabled: false, tooltip: Self.bridgeTooltip, label: "Local environment"))))
        if canMaintain {
            rows.append(versionRow(id, line: line, known: version != nil, label: d?.label ?? environments.label(id)))
            rows.append(networkAccessRow(id))
            rows.append(tailscaleRow())
            if canReadRelay || canManageRelay { rows += cloudRows(canReadRelay: canReadRelay, canManageRelay: canManageRelay) }
        }
        return ConnectionsPageModel.Machine(label: d?.label ?? environments.label(id) ?? "This machine",
                                            machine: environments.machine(id) ?? d?.platform?.machine ?? "desktop",
                                            rows: rows, permissions: permissions(id, routeContext: false), iconMenu: iconMenu(id))
    }

    /// The `Version` row (ConnectionsSettings.tsx:3655-3700): the update's progress in place of the version
    /// line, then "Update to <version>", "Retry update", the manual path, or "Up to date".
    private func versionRow(_ id: String, line: String, known: Bool, label: String?) -> ConnectionsPageModel.HostRow {
        let state = serverUpdates?.state(id) ?? .idle
        if let runtime = serverUpdates?.ownRuntimeState(id) {
            let look = DesktopUpdateLogic.settingsButton(runtime)
            return .init(id: "version", title: "Version", detail: "\(line)\n\(DesktopUpdateLogic.buttonTooltip(runtime))",
                control: .update(look.label, enabled: !look.disabled && serverUpdates?.canUpdate(id) == true))
        }
        let serverLabel = label.map { "\($0) server" } ?? "server"
        var control: ConnectionsPageModel.HostRow.Control = .none
        if let updates = serverUpdates, let mismatch = updates.mismatch(id), !state.isRunning {
            switch updates.offer(id, serverLabel: serverLabel) {
            case .update?: control = .update(state.isFailed ? "Retry update" : "Update to \(mismatch.client)", enabled: updates.canUpdate(id))
            case .manual(let manual)?: control = .copyCommand(manual)
            case .desktopManual?: control = .text(ServerUpdateCopy.desktopManual)
            case nil: break
            }
        } else if state == .idle, known {
            control = .text("Up to date")
        }
        return .init(id: "version", title: "Version", detail: line.isEmpty ? "Loading…" : line, control: control,
                     progress: state == .idle ? nil : state)
    }

    /// `Network access` from the server's auth policy: `remote-reachable` is on (the desktop bridge's
    /// `network-accessible`), anything else is this machine only.
    // ponytail: on reads "Exposed on all interfaces." without the bridge's advertised endpoints; list the LAN address if users miss it
    private func networkAccessRow(_ id: String) -> ConnectionsPageModel.HostRow {
        let policy = session(id)?.auth.policy
        let on = policy == "remote-reachable"
        return .init(id: "network-access", title: "Network access",
                     detail: policy == nil ? "Loading…" : on ? "Exposed on all interfaces." : "Limited to this machine.",
                     control: .toggle(.init(isOn: on, isEnabled: false, tooltip: Self.bridgeTooltip, label: "Enable network access")))
    }

    /// `Tailscale HTTPS`. Without Tailscale T3 shows only the hint; with it, the switch.
    // ponytail: checks that Tailscale is installed, not `tailscale status`; the switch shows off until the Serve state is read
    private func tailscaleRow() -> ConnectionsPageModel.HostRow {
        let paths = ["/Applications/Tailscale.app", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .init(id: "tailscale-https", title: "Tailscale HTTPS", detail: "Start Tailscale to set up HTTPS access through MagicDNS.")
        }
        return .init(id: "tailscale-https", title: "Tailscale HTTPS",
                     detail: "Use Tailscale Serve to expose this backend through a MagicDNS HTTPS URL.",
                     control: .toggle(.init(isOn: false, isEnabled: false, tooltip: Self.bridgeTooltip, label: "Enable Tailscale HTTPS")))
    }

    /// `CloudLinkRow` and `ConfiguredCloudLinkRow` (ConnectionsSettings.tsx:1826-1996).
    private func cloudRows(canReadRelay: Bool, canManageRelay: Bool) -> [ConnectionsPageModel.HostRow] {
        guard canReadRelay else {
            return [.init(id: "t3-connect", title: "T3 Connect",
                          detail: "To edit these settings, pair this connection with both View relay and Manage relay permissions.")]
        }
        let signedIn = t3.signedIn != nil
        let reason: String? = !signedIn ? "Sign in to T3 Connect to manage this environment."
            : !canManageRelay ? "Your session does not have permission to manage T3 Connect access." : nil
        let tunnel = linkState?.tunnelActive ?? false
        let publish = linkState?.publishAgentActivity ?? false
        let disabled = !canManageRelay || !signedIn || linkState == nil || linkLoading || linkBusy
        var rows: [ConnectionsPageModel.HostRow] = []
        // ponytail: the switch needs T3's `reconcileCloudState` (useCloudLinkController.ts:85-190: a managed or
        // publish-only link, unlinked only when neither is wanted) in front of the relay install flow
        // (`DesktopManagedController.ensureRelayClient`); left to T3 Code's app until it is ported and tried on a real account with the user
        // The reachability line and description (SavedEnvironmentRows.tsx:495-515, 585-596).
        // ponytail: the unreachable line leaves out T3's inline "More info" link, add it when SettingsRowView's status takes links
        let reachability = tunnel ? linkState?.reachability : nil
        let detail = !tunnel ? "Make this environment available to your other devices through T3 Connect."
            : reachability?.status == "unreachable" ? "T3 Connect is on, but other devices cannot reach this environment."
            : reachability?.status == "reachable" ? "This environment is available to your other devices through T3 Connect."
            : "T3 Connect is on. Reachability has not been checked yet."
        let unreachable = linkError == nil && reachability?.status == "unreachable"
        rows.append(.init(id: "t3-connect", title: "T3 Connect",
                          detail: detail,
                          status: linkError ?? reachability?.statusLine,
                          statusIsError: unreachable,
                          control: .toggle(.init(isOn: tunnel, isEnabled: false, tooltip: reason ?? Self.bridgeTooltip, label: "Enable T3 Connect"))))
        // Publishing alone needs a publish-only link; with the tunnel up it is a preference the server sets.
        rows.append(.init(id: "publish-agent-activity", title: "Publish agent activity",
                          detail: "Send activity to mobile notifications and Live Activities without T3 Connect.",
                          control: .toggle(.init(isOn: publish, isEnabled: !disabled && tunnel,
                                                 tooltip: reason ?? (tunnel ? nil : Self.linkTooltip),
                                                 label: "Publish agent activity to mobile clients"))))
        if tunnel {
            rows.append(.init(id: "hold-webhooks-while-offline", title: "Hold webhooks while offline",
                              detail: "Keep webhook requests for up to 24 hours while this environment is offline, then deliver them. Off: T3 Connect only forwards requests and stores nothing.",
                              control: .toggle(.init(isOn: linkState?.holdsWebhooks ?? false,
                                                     isEnabled: !(!canManageRelay || !signedIn || linkLoading || linkBusy), tooltip: reason,
                                                     label: "Hold webhook requests while this environment is offline"))))
        }
        return rows
    }

    /// `SessionPermissions`: the grant list while connected with an authenticated session.
    func permissions(_ id: String, routeContext: Bool) -> ConnectionsPageModel.Permissions {
        guard environments.state(id)?.status == .connected, let s = session(id), s.authenticated else {
            return .init(routeContext: routeContext, grants: nil)
        }
        return .init(routeContext: routeContext, grants: AuthScopes.options.map { .init(title: $0.title, allowed: s.grants($0.scope)) })
    }

    /// `EnvironmentIconMenu` with `resolveEnvironmentIconPickerLock`.
    func iconMenu(_ id: String) -> ConnectionsPageModel.IconMenu {
        let d = hosts[id]?.descriptor ?? (id == environments.primaryId ? primaryDescriptor : nil)
        let connected = environments.state(id)?.status == .connected
        let detected = d?.platform?.machine ?? environments.detectedMachine(id) ?? "server"
        let lock: String? = !connected || d == nil ? "Connect to this environment to change its icon."
            : !d!.capability("environmentIcon") ? "This environment's server is too old to keep an icon. Update it to choose one."
            : !grants(id, AuthScopes.settingsWrite) ? "Your session on this environment cannot change its settings." : nil
        return .init(resolved: environments.machine(id) ?? detected, detected: detected,
                     detectedTag: d?.platform?.machine != nil ? "detected" : "default", lock: lock)
    }

    /// "Authorized clients", with `access:read` or `access:write` on this machine.
    func accessModel() -> ConnectionsPageModel.Access? {
        guard let id = environments.primaryId else { return nil }
        let canRead = grants(id, AuthScopes.accessRead), canWrite = grants(id, AuthScopes.accessWrite)
        guard canRead || canWrite else { return nil }
        let now = Date()
        let route = environments.routeInUse(id)
        let links = access.sortedLinks.compactMap { l -> ConnectionsPageModel.Access.PairingLink? in
            guard let expires = l.expiresAt.date, expires > now else { return nil }
            let credential = credentials[l.id]
            // `resolveDesktopPairingUrl` on the route in use: `<origin>/pair#token=<credential>`.
            let share = credential.flatMap { c in route.map { EnvironmentRoute.origin($0) + "/pair#" + Self.formEncode("token", c) } }
            return .init(id: l.id, label: l.label ?? "Pairing link",
                         createdTooltip: "Link created at \(l.createdAt.date.map(AccessTime.absolute) ?? l.createdAt.raw)",
                         expires: AccessTime.expiresIn(expires, now: now), expiresAbsolute: AccessTime.absolute(expires),
                         scopes: l.granted, credential: credential, shareURL: share,
                         qrShareable: route.map { EnvironmentRoute.kind($0) != .loopback } ?? false, revoking: revokingLink == l.id)
        }
        let clients = access.sortedSessions.map { c -> ConnectionsPageModel.Access.Client in
            let live = c.current || c.connected
            let last = c.lastConnectedAt?.date
            let tooltip = live ? (last.map { "Connected for \(AccessTime.elapsed(since: $0, now: now))" } ?? "Connected")
                : (last.map { "Last connected at \(AccessTime.absolute($0))" } ?? "Not connected yet.")
            let device = c.client.deviceType == "unknown" ? nil : c.client.deviceType.prefix(1).uppercased() + c.client.deviceType.dropFirst()
            let bits = [device, c.client.os, c.client.browser, c.client.ipAddress].compactMap { $0 }
            let fallback = [c.client.os, c.client.browser].compactMap { $0 }.joined(separator: " · ")
            return .init(id: c.sessionId, label: c.client.label ?? (fallback.isEmpty ? c.subject : fallback), live: live,
                         statusTooltip: tooltip, current: c.current, info: bits.isEmpty ? nil : bits.joined(separator: " · "),
                         scopes: c.granted, revoking: revokingClient == c.sessionId)
        }
        let known = canRead && accessError == nil && accessLoaded
        return .init(summary: ConnectionsPageModel.Access.summary(clients: access.clientSessions.count, links: access.pairingLinks.count),
                     canRead: canRead, canWrite: canWrite, loading: canRead && !accessLoaded, error: accessError,
                     links: links, clients: clients, revokingOthers: revokingOthers,
                     canRevokeOthers: !known || access.clientSessions.contains { !$0.current })
    }

    /// `URLSearchParams([[key, value]]).toString()`.
    static func formEncode(_ key: String, _ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._")
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return key + "=" + v
    }

    // MARK: Actions

    func setHostSwitch(_ rowId: String, _ on: Bool) {
        switch rowId {
        case "publish-agent-activity":
            updateCloudPreferences(CloudPreferencesRequest(publishAgentActivity: on)) { [weak self] in
                self?.toast(on ? "Agent activity enabled" : "Agent activity disabled",
                            on ? "This environment publishes agent activity to your mobile clients."
                               : "This environment will stop publishing agent activity.", .success)
            }
        case "hold-webhooks-while-offline":
            updateCloudPreferences(CloudPreferencesRequest(publishAgentActivity: linkState?.publishAgentActivity ?? false,
                                                           holdWebhooksWhileOffline: on)) { [weak self] in
                self?.toast(on ? "Webhooks held while offline" : "Webhooks no longer held",
                            on ? "T3 Connect keeps webhook requests for up to 24 hours while this environment is offline."
                               : "Requests to an offline environment now fail. Anything already held is still delivered.", .success)
            }
        default:
            // Bridge-only rows are disabled; nothing reaches here.
            refreshPage()
        }
    }

    /// `reconcileCloudState` when only preferences change: the server stores them and tells the relay.
    private func updateCloudPreferences(_ request: CloudPreferencesRequest, done: @escaping () -> Void) {
        guard let id = environments.primaryId, let shell = environments.session(id), grants(id, AuthScopes.relayWrite), !linkBusy else { return }
        linkBusy = true
        linkError = nil
        refreshPage()
        let http = shell.http, token = shell.token
        Task {
            do {
                linkState = try await http.setCloudPreferences(request, token: token)
                done()
                t3.refreshMachines()
            } catch {
                let message = Self.message(error, fallback: "Could not update T3 Connect access.")
                linkError = message
                toast("Could not update T3 Connect", message, .error)
                loadLinkState()
            }
            linkBusy = false
            refreshPage()
        }
    }

    /// The Icon submenu: `server.updateSettings({environmentIcon})`, null for the detected kind.
    func setIcon(_ id: String, _ kind: String) {
        let menu = iconMenu(id)
        guard menu.lock == nil else { return }
        let value: JSONValue = kind == menu.detected ? .null : .string(kind)
        environments.setIconOverride(id, kind == menu.detected ? nil : kind)
        Task {
            do {
                _ = try await environments.request(id, "server.updateSettings", .object(["patch": .object(["environmentIcon": value])]))
            } catch {
                toast("Could not change icon", "\(error)", .error)
            }
        }
    }

    func reorderRoutes(_ id: String, _ routes: [URL]) {
        Task {
            do { try await environments.reorderRoutes(routes, environmentId: id) } catch {
                toast("Could not reorder routes", "\(error)", .error)
                refreshPage()
            }
        }
    }

    // MARK: Authorized clients

    /// `Create link`: the dialog with T3's presets, limited to what this session may delegate.
    func presentCreateLink() {
        guard let window, modal == nil, let id = environments.primaryId, let shell = environments.session(id) else { return }
        let delegatable = session(id)?.grantedScopes ?? []
        let (dialog, form, cancel, create) = CreatePairingLinkDialog.make(delegatable: delegatable)
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
        cancel.action = { [weak host] in host?.close() }
        let http = shell.http, token = shell.token
        create.action = { [weak self, weak form, weak host] in
            guard let self, let form, !form.isCreating, !form.selected.isEmpty else { return }
            let label = form.labelInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let scopes = form.selected
            form.isCreating = true
            Task {
                do {
                    let created = try await http.createPairingCredential(PairingCredentialRequest(label: label.isEmpty ? nil : label, scopes: scopes), token: token)
                    self.credentials[created.id] = created.credential
                    host?.close()
                    self.refreshPage()
                } catch {
                    form.isCreating = false
                    self.toast("Could not create pairing URL", Self.message(error, fallback: "Failed to create pairing URL."), .error)
                }
            }
        }
        window.makeFirstResponder(form.labelInput)
    }

    func revokePairingLink(_ linkId: String) {
        guard let id = environments.primaryId, let shell = environments.session(id), grants(id, AuthScopes.accessWrite) else { return }
        revokingLink = linkId
        accessError = nil
        refreshPage()
        let http = shell.http, token = shell.token
        Task {
            do { try await http.revokePairingLink(id: linkId, token: token) } catch {
                let message = Self.message(error, fallback: "Failed to revoke pairing link.")
                accessError = message
                toast("Could not revoke pairing link", message, .error)
            }
            revokingLink = nil
            refreshPage()
        }
    }

    func revokeClient(_ sessionId: String) {
        guard let id = environments.primaryId, let shell = environments.session(id), grants(id, AuthScopes.accessWrite) else { return }
        revokingClient = sessionId
        accessError = nil
        refreshPage()
        let http = shell.http, token = shell.token
        Task {
            do { try await http.revokeClient(sessionId: sessionId, token: token) } catch {
                let message = Self.message(error, fallback: "Failed to revoke client access.")
                accessError = message
                toast("Could not revoke client access", message, .error)
            }
            revokingClient = nil
            refreshPage()
        }
    }

    func revokeOtherClients() {
        guard let id = environments.primaryId, let shell = environments.session(id), grants(id, AuthScopes.accessWrite) else { return }
        revokingOthers = true
        accessError = nil
        refreshPage()
        let http = shell.http, token = shell.token
        Task {
            do {
                let count = try await http.revokeOtherClients(token: token)
                toast(count == 1 ? "Revoked 1 other client" : "Revoked \(count) clients",
                      "Other paired clients will need a new pairing link before reconnecting.", .success)
            } catch {
                let message = Self.message(error, fallback: "Failed to revoke other clients.")
                accessError = message
                toast("Could not revoke other clients", message, .error)
            }
            revokingOthers = false
            refreshPage()
        }
    }

    /// The server's own message when it sent one, else T3's fallback text.
    static func message(_ error: Error, fallback: String) -> String {
        if case EnvironmentHTTPError.status(_, let body?) = error, let text = body.message ?? body.reason, !text.isEmpty { return text }
        return fallback
    }
}
