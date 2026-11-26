import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Transport

/// The "Link an environment" dialog shared by Settings > Connections and an agent's link request card
/// (LinkedEnvironmentsSettings.tsx and LinkRequestCard.tsx at 3814). The caller decides what Link sends.
@MainActor
enum PeerLinkDialog {
    /// What the dialog settled on when Link was pressed. The pairing code never leaves this value and the RPC payload.
    struct Choice {
        var urls: [String]
        var machine: LinkableMachine?
        var access: String
        var pairingCode: String
        /// A link request answered with the machine's existing link.
        var useExisting = false
    }

    /// `linkableMachines` (client-runtime/src/linkRequest.ts:82-170): this machine and the saved ones other than the
    /// host, in catalog order, each with the addresses another machine could reach: those it reports
    /// (`directEndpoints`), its saved routes, then its T3 Connect address. An SSH machine's forward lives in this app,
    /// so only its relay counts. A loopback address names whichever machine opens it, so it's offered only to a host on
    /// this Mac; T3 sends it anyway and the host spends its probe timeout learning nothing answers there
    /// (PeerLinks.ts:42-43, 347-380). This app mints a code where its session grants `access:write`.
    // ponytail: machines known only to T3 Connect aren't offered; type their address. Add them when users link Connect-only hosts.
    static func machines(_ environments: Environments, hostId: String, primaryLabel: String?, linked: Set<String>,
                         reported: (String) -> [String] = { _ in [] }) -> [LinkableMachine] {
        func canMint(_ id: String) -> Bool {
            environments.state(id)?.status == .connected && environments.canCreateGuestShare(id)
        }
        let hostIsLocal = environments.saved.first { $0.environmentId == hostId }?.sshTarget == nil
            && (environments.session(hostId).map { $0.http.baseURL.host.map { ConnectRoutes.kind(host: $0) == .loopback } ?? false } ?? false)
        func reachable(_ id: String, routes: [String]) -> [String] {
            ConnectRoutes.linkURLs(reported: reported(id).compactMap(URL.init(string:)).map(EnvironmentRoute.origin), routes: routes,
                                   connect: environments.connectEndpoints[id], hostIsLocal: hostIsLocal)
        }
        var machines: [LinkableMachine] = []
        if let primary = environments.primaryId, primary != hostId, let shell = environments.session(primary) {
            let label = primaryLabel ?? environments.label(primary) ?? "This machine"
            machines.append(LinkableMachine(environmentId: primary, label: label,
                                            connected: environments.state(primary)?.status == .connected, linked: linked.contains(primary),
                                            urls: reachable(primary, routes: [EnvironmentRoute.origin(shell.http.baseURL)]), canMint: canMint(primary),
                                            noAddressHint: "Other machines can't reach \(label): its server listens only on this Mac and it isn't on "
                                                + "T3 Connect. Turn on T3 Connect or Network access for it in T3 Code's Settings → Connections, "
                                                + "or enter its https or Tailscale address."))
        }
        for r in environments.saved where r.environmentId != hostId && r.environmentId != environments.primaryId {
            let routes = r.sshTarget != nil ? [] : ([r.httpBaseURL] + r.alternateRoutes).map(EnvironmentRoute.origin)
            machines.append(LinkableMachine(environmentId: r.environmentId, label: r.label,
                                            connected: environments.state(r.environmentId)?.status == .connected,
                                            linked: linked.contains(r.environmentId),
                                            urls: reachable(r.environmentId, routes: routes + [r.relay?.endpoint.httpBaseUrl].compactMap { $0 }),
                                            canMint: canMint(r.environmentId)))
        }
        return machines
    }

    /// Presents the dialog. `commit` runs on Link with the choice and returns the linked machine's name for the toast,
    /// or throws; a failure keeps the dialog open.
    @discardableResult
    static func present(in window: NSWindow, environments: Environments, machines: [LinkableMachine],
                        throughRoutes: [LinkThroughRoute] = [], sourceLabel: String? = nil, through: LinkThroughRoute? = nil,
                        initialChoice: String? = nil, initialAccess: String? = nil, lockMachine: Bool = false, address: String? = nil,
                        answersRequest: Bool = false, successToast: Bool = true,
                        toast: @escaping @MainActor (String, String?, ToastQueue.Kind) -> Void,
                        failureMessage: @escaping @MainActor (Error) -> String,
                        commit: @escaping @MainActor (Choice) async throws -> String?) -> ModalHost {
        let (dialog, form, cancel, link) = LinkEnvironmentDialog.make(machines: machines, throughRoutes: throughRoutes, sourceLabel: sourceLabel)
        form.answersRequest = answersRequest
        form.preset(choice: initialChoice, access: initialAccess, lockMachine: lockMachine, address: address, through: through)
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        let host = ModalHost.present(dialog, in: window)
        cancel.action = { [weak host, weak form] in if form?.isBusy != true { host?.close() } }
        let submit: @MainActor () -> Void = { [weak form, weak host] in
            guard let form, !form.isBusy, form.ready else { return }
            let through = form.through
            guard through != nil || form.urls.first?.isEmpty == false else { return }
            form.isBusy = true
            var machine = form.machine, urls = form.urls
            let access = form.access, typed = form.pairingCode
            let existing = form.usesExisting, mints = form.mints && !existing && through == nil
            Task {
                var code = typed
                if let through {
                    guard let paired = await pairThrough(environments, through, access: access) else {
                        form.isBusy = false
                        form.throughFailed.insert(through.environmentId)
                        toast("\(through.viaLabel) could not get a pairing code from \(through.label)",
                              "Enter its address and a pairing code from it instead.", .error)
                        return
                    }
                    urls = paired.urls
                    code = paired.credential ?? ""
                    machine = LinkableMachine(environmentId: paired.environmentId, label: paired.label, connected: false, linked: false,
                                              urls: paired.urls, canMint: false)
                }
                if mints, let machine {
                    guard let minted = await mintPairingCode(environments, on: machine.environmentId, access: access, toast: toast) else {
                        form.isBusy = false
                        form.mintFailed.insert(machine.environmentId)
                        return
                    }
                    code = minted
                }
                do {
                    let label = try await commit(Choice(urls: urls, machine: machine, access: access, pairingCode: code, useExisting: existing))
                    // An answered request shows on its card instead (LinkRequestCard.tsx:300-303).
                    if successToast { toast("Linked \(label ?? machine?.label ?? "environment")", nil, .success) }
                    host?.close()
                } catch {
                    form.isBusy = false
                    toast("Could not link the environment", failureMessage(error), .error)
                }
            }
        }
        link.action = submit
        form.addressInput.onSubmit = submit
        form.codeInput.onSubmit = submit
        if form.needsAddress { window.makeFirstResponder(form.addressInput) }
        return host
    }

    /// `peerLinks.pairLink` on the environment holding the full-access link: the linked machine mints a code for a link at
    /// `access` and answers with where it listens (LinkedEnvironmentsSettings.tsx:368-395 at 5258). Nil when it gives none.
    static func pairThrough(_ environments: Environments, _ through: LinkThroughRoute, access: String) async -> PeerLinkClientPairingResult? {
        guard let reply = try? await environments.request(through.viaEnvironmentId, PeerLinkRPC.pairLink,
                                                          PeerLinkRPC.pairLinkInput(environmentId: through.environmentId, access: access)),
              let result = try? reply.decode(as: PeerLinkClientPairingResult.self),
              result.type == "credential", result.credential?.isEmpty == false, !result.urls.isEmpty else { return nil }
        return result
    }

    /// A one-use code minted on `environmentId` with this app's session there (state/peerPairingCode.ts at 3814), carrying
    /// exactly the scopes an agent sign-in with `access` needs. Nil after a toast when it can't.
    static func mintPairingCode(_ environments: Environments, on environmentId: String, access: String,
                                toast: (@MainActor (String, String?, ToastQueue.Kind) -> Void)?) async -> String? {
        guard let shell = environments.session(environmentId) else { return nil }
        do {
            let created = try await shell.http.createPairingCredential(
                PairingCredentialRequest(label: "T3 Code link", scopes: PeerLinks.scopes(for: access)), token: shell.token)
            return created.credential
        } catch {
            let forbidden: Bool = if case EnvironmentHTTPError.status(let code, _) = error { code == 401 || code == 403 } else { false }
            toast?("Could not link the environment", forbidden
                  ? "Your session there cannot create pairing codes. Paste a code from there instead."
                  : "Could not get a pairing code from there. Paste a code from there instead.", .error)
            return nil
        }
    }

    /// A `PeerLinkError`'s message is written for the user (peerLink.ts:60-73); other failures fall back.
    static func message(_ error: Error, fallback: String) -> String {
        if let rpc = error as? RPCClientError, let message = rpc.typedError?.message, !message.isEmpty { return message }
        return fallback
    }

    /// `PeerLinkRequestError` and authorization failures carry user text; anything else gets the generic line, so the
    /// pairing code can never surface (linkRequest.ts:300-314). The request error's text comes from its reason.
    static func answerFailure(_ error: Error) -> String {
        if let typed = (error as? RPCClientError)?.typedError {
            if typed.tag == "PeerLinkRequestError", let text = PeerLinks.requestFailure(typed.fields["reason"]?.stringValue) { return text }
            if ["PeerLinkRequestError", "EnvironmentAuthorizationError"].contains(typed.tag), let m = typed.message, !m.isEmpty { return m }
        }
        return "Could not answer the request. Try again."
    }
}
