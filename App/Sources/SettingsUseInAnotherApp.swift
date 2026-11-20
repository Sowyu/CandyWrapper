import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol

/// The open "Use T3 Code in another app (MCP)" wizard and what its gate reads (UseInAnotherAppDialog.tsx:257-395
/// at 4928): the session and descriptor, the T3 Connect link state, and one reachability check.
@MainActor
final class McpWizardState {
    enum Check: Equatable {
        case idle, running
        case done(result: ConnectReachability?, since: String?)
    }
    let environmentId: String
    let dialog: UseInAnotherAppDialog
    var session: AuthSessionState?
    var descriptor: EnvironmentDescriptor?
    var linkState: CloudLinkState?
    var linkStateError: String?
    var check: Check = .idle
    /// T3 rereads the link state every 5 s while the tunnel is offline; the server has no push for it.
    var poll: Timer?
    init(environmentId: String, dialog: UseInAnotherAppDialog) { self.environmentId = environmentId; self.dialog = dialog }
}

extension SettingsController {
    /// Opens the wizard on `environmentId`, or on this machine (`openUseInAnotherApp`).
    func presentUseInAnotherApp(_ environmentId: String? = nil) {
        guard let window, modal == nil, let id = environmentId ?? environments.primaryId else { return }
        let label = environments.label(id) ?? "T3 Code"
        let hosted = hosts[id]?.descriptor?.capability("mcpHostedApproval") == true
        let dialog = UseInAnotherAppDialog(environment: label, hostedApproval: hosted)
        let state = McpWizardState(environmentId: id, dialog: dialog)
        state.session = hosts[id]?.session
        state.descriptor = hosts[id]?.descriptor
        let host = ModalHost.present(dialog.dialog, in: window)
        modal = host
        mcpWizard = state
        host.onDismiss = { [weak self, weak dialog] in
            dialog?.stop()
            self?.mcpWizard?.poll?.invalidate()
            self?.mcpWizard = nil
            self?.modal = nil
        }
        dialog.onClose = { [weak host] in host?.close() }
        dialog.onSignIn = { [weak self, weak host] in
            // The sign-in sheet is its own modal, so the wizard closes first.
            host?.close(animated: false)
            if let self, let window = self.window { self.t3.presentSignIn(in: window) }
        }
        dialog.onCheckAgain = { [weak self] in self?.mcpRunCheck() }
        dialog.onRefreshList = { [weak self] in self?.t3.refreshMachines() }
        dialog.onManageAccess = { [weak self, weak host] in host?.close(); self?.open(.connections) }
        dialog.onMint = { [weak self] level in self?.mcpMint(level) }
        dialog.onCopy = { text, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        dialog.onOpenLink = { [weak self] link in self?.mcpOpen(link) }
        dialog.onHandOff = { [weak self] action, _ in
            guard let self else { return }
            // The app opens only once the copy lands, so it never gets an older clipboard.
            if let copy = action.copy {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(copy.text, forType: .string) else {
                    self.toast("Could not copy", "Use Set up another way.", .error)
                    return
                }
                self.toast(copy.title, nil, .success)
            }
            // A desktop app reports a link nothing opens and falls back to the web page.
            if let appLink = action.appLink, let url = URL(string: appLink), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            } else {
                self.mcpOpen(action.link)
            }
        }
        mcpLoad()
    }

    /// Reads what the gate needs that the page has not loaded yet, then the link state.
    private func mcpLoad() {
        guard let state = mcpWizard, let shell = environments.session(state.environmentId) else { return mcpRefresh() }
        let http = shell.http, token = shell.token, id = state.environmentId
        // T3 Connect lists machines only once something asks, and a saved machine's gate reads that list.
        if t3.signedIn != nil, t3.machines == nil, id != environments.primaryId { t3.refreshMachines() }
        Task {
            if state.session == nil { state.session = try? await http.session(token: token) }
            if state.descriptor == nil { state.descriptor = try? await http.descriptor() }
            guard mcpWizard === state else { return }
            state.dialog.blocked = UseInAnotherApp.blockedLevels(session: state.session, environment: environments.label(id) ?? "T3 Code")
            mcpReadLinkState()
        }
        mcpRefresh()
    }

    private func mcpReadLinkState() {
        guard let state = mcpWizard, state.session?.grants(AuthScopes.relayRead) == true,
              let shell = environments.session(state.environmentId) else { return mcpRefresh() }
        let http = shell.http, token = shell.token
        Task {
            do {
                state.linkState = try await http.cloudLinkState(token: token)
                state.linkStateError = nil
            } catch {
                state.linkStateError = Self.message(error, fallback: "Could not read T3 Connect.")
            }
            guard mcpWizard === state else { return }
            // Ask the server to check its tunnel once one exists (`checkOnce`).
            if state.check == .idle, environments.state(state.environmentId)?.status == .connected,
               state.linkState?.managedTunnelActive(relayProviderKind: nil) == true {
                mcpRunCheck()
            }
            mcpRefresh()
        }
    }

    /// `runReachabilityCheck`: the server checks its tunnel; a failed request still counts a newer server check.
    func mcpRunCheck() {
        guard let state = mcpWizard, let shell = environments.session(state.environmentId) else { return }
        state.check = .running
        if state.environmentId != environments.primaryId { t3.refreshMachines() }
        mcpRefresh()
        let http = shell.http, token = shell.token, prior = state.linkState
        Task {
            do {
                let result = try await http.checkReachability(token: token)
                state.check = .done(result: result, since: result.checkedAt)
                state.linkState = (try? await http.cloudLinkState(token: token)) ?? state.linkState
            } catch {
                let latest = try? await http.cloudLinkState(token: token)
                if let latest { state.linkState = latest }
                let after = UseInAnotherApp.afterFailedCheck(prior: prior, latest: latest)
                state.check = .done(result: after.result, since: after.since)
            }
            guard mcpWizard === state else { return }
            mcpRefresh()
        }
    }

    private func mcpMint(_ level: McpClientAccess) {
        guard let state = mcpWizard, let shell = environments.session(state.environmentId) else { return }
        state.dialog.code = .pending
        let http = shell.http, token = shell.token
        Task {
            do {
                let minted = try await http.createPairingCredential(.mcpApproval(level), token: token)
                state.dialog.code = .live(credential: minted.credential, expiresAt: minted.expiresAt.date ?? Date().addingTimeInterval(300))
            } catch {
                state.dialog.code = .failed
            }
        }
    }

    private func mcpOpen(_ link: String) {
        guard let url = URL(string: link), url.scheme == "https", NSWorkspace.shared.open(url) else {
            toast("Could not open the link", link, .error)
            return
        }
    }

    /// Recomputes the gate. T3 Connect's sign-in and machine list call this through the page refresh too.
    func mcpRefresh() {
        guard let state = mcpWizard else { return }
        let id = state.environmentId
        let thisMachine = id == environments.primaryId
        let relay: UseInAnotherApp.Relay = {
            if let machines = t3.machines, !t3.discovering {
                guard let m = machines.first(where: { $0.environmentId == id }) else { return .listed(providerKind: nil, httpBaseUrl: nil, availability: nil) }
                let availability: UseInAnotherApp.Relay.Availability = switch m.availability {
                case .checking: .checking
                case .online: .online
                case .offline: .offline
                case .error: .error
                }
                return .listed(providerKind: m.record.endpoint.providerKind, httpBaseUrl: m.record.endpoint.httpBaseUrl, availability: availability)
            }
            return t3.discoveryError != nil && !t3.discovering ? .failed : .loading
        }()
        let reachability: UseInAnotherApp.Reachability = switch state.check {
        case .idle, .running: .checking
        case .done(let result, let since):
            if let reported = state.linkState?.reachability, let since, (reported.checkedAt ?? "") > since { .result(reported) } else { .result(result) }
        }
        let gate = UseInAnotherApp.gate(.init(
            signedIn: t3.loaded ? t3.signedIn != nil : nil,
            connected: environments.state(id)?.status == .connected,
            approvalCodes: state.descriptor.map { $0.capability("mcpApprovalCodes") },
            canReadRelay: state.session?.grants(AuthScopes.relayRead) == true,
            linkState: state.linkState, linkStateError: state.linkStateError,
            thisMachine: thisMachine, relay: relay, reachability: reachability))
        state.dialog.gate = gate
        if case .links(let links) = peerLinks[id] {
            state.dialog.linked = links.map { (environments.label($0.environmentId) ?? $0.label, $0.access, $0.status == .expired) }
        }
        // Poll only while the tunnel is offline and the wizard shows.
        let waiting = if case .offline = gate { true } else { false }
        if waiting, state.poll == nil {
            state.poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.mcpReadLinkState() }
            }
            state.poll?.tolerance = 1
        } else if !waiting {
            state.poll?.invalidate()
            state.poll = nil
        }
    }
}
