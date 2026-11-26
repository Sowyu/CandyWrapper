import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Transport

/// What a host's `peerLinks.list` returned while Connections shows.
enum PeerLinkLoad {
    case loading
    case failed(String)
    case links([PeerLinkSummary])
}

/// Settings > Connections > Linked environments (LinkedEnvironmentsSettings.tsx, state/peerLinks.ts at 3814). Each
/// connected environment that offers links (`peerLinks` capability and its Beta switch on) gets a section listing its
/// links (`peerLinks.list`), with Link (`peerLinks.link`) and Forget (`peerLinks.unlink`). Listing asks every linked
/// machine whether it answers, so the page reads a host's list once per visit and again after a change.
extension SettingsController {
    /// `usePeerLinkHosts`: connected environments offering links where this session may read access.
    func peerLinkHosts() -> [String] {
        environments.environmentIds.filter { id in
            guard environments.state(id)?.status == .connected, let config = composer?.config(id) else { return false }
            return PeerLinks.offered(capabilities: config.capabilities, settings: config.settings.raw)
                && hosts[id]?.session?.grants(AuthScopes.accessRead) == true
        }
    }

    /// Reads hosts that offer links and haven't been read this visit. Called on each refresh.
    func loadPeerLinks() {
        guard isOpen, section == .connections else { return }
        for id in peerLinkHosts() where peerLinks[id] == nil { reloadPeerLinks(id) }
    }

    /// After an answered link request: reload a list on screen in place, or drop it so the next visit reads it.
    func peerLinksChanged(_ id: String) {
        guard peerLinks[id] != nil else { return }
        if isOpen, section == .connections { reloadPeerLinks(id) } else { peerLinks[id] = nil }
    }

    func reloadPeerLinks(_ id: String) {
        if peerLinks[id] == nil { peerLinks[id] = .loading }
        Task {
            let next: PeerLinkLoad
            do {
                next = .links(try PeerLinkSummary.list(try await environments.request(id, "peerLinks.list", .object([:]))))
            } catch {
                next = .failed(PeerLinkDialog.message(error, fallback: "Could not list linked environments."))
            }
            guard isOpen else { return }
            peerLinks[id] = next
            refreshPage()
            linkSeveralSync?()
        }
    }

    func linkedEnvironmentsModel() -> [ConnectionsPageModel.LinkedEnvironments] {
        let ids = peerLinkHosts()
        let now = Date()
        return ids.map { id in
            let canWrite = hosts[id]?.session?.grants(AuthScopes.accessWrite) == true
            let state: ConnectionsPageModel.LinkedEnvironments.State = switch peerLinks[id] ?? .loading {
            case .loading: .loading
            case .failed(let reason): .failed(reason)
            case .links(let links):
                .links(links.map { ConnectionsPageModel.LinkedEnvironments.link($0, now: now, canForget: canWrite, forgetting: forgettingLinks.contains("\(id)/\($0.environmentId)")) })
            }
            let label = id == environments.primaryId ? (primaryDescriptor?.label ?? environments.label(id)) : environments.label(id)
            let title = ids.count > 1 ? "Linked environments · \(label ?? id)" : "Linked environments"
            return .init(hostId: id, title: title, canLink: canWrite, state: state)
        }
    }

    /// "Link": the shared dialog, then `peerLinks.link` on the host. A map offer prefills the machine or the address
    /// (EnvironmentsMap.tsx:448-468 `openLinkDialog`).
    func presentLinkEnvironment(_ hostId: String, offer: FleetLinkOffer.Link? = nil) {
        guard let window, modal == nil else { return }
        let linked: Set<String> = {
            guard case .links(let links)? = peerLinks[hostId] else { return [] }
            return Set(links.filter { $0.status != .expired }.map(\.environmentId))
        }()
        let machines = PeerLinkDialog.machines(environments, hostId: hostId, primaryLabel: primaryDescriptor?.label, linked: linked,
                                                  reported: { composer?.config($0)?.directEndpoints ?? [] })
        var choice: String?, address: String?
        switch offer?.target {
        case .machine(let id)?: choice = id
        case .address(let a, _)?: address = a ?? ""
        case nil: break
        }
        let host = PeerLinkDialog.present(
            in: window, environments: environments, machines: machines, initialChoice: choice, address: address,
            toast: { [weak self] title, message, kind in self?.toast(title, message, kind) },
            failureMessage: { PeerLinkDialog.message($0, fallback: "Could not link the environment.") },
            commit: { [weak self] choice in
                guard let self else { return nil }
                var input: [String: JSONValue] = ["url": .string(choice.urls[0]), "pairingCode": .string(choice.pairingCode),
                                                  "access": .string(choice.access)]
                if choice.urls.count > 1 { input["alternateUrls"] = .array(choice.urls.dropFirst().map(JSONValue.string)) }
                if let m = choice.machine {
                    input["expectedEnvironmentId"] = .string(m.environmentId)
                    input["expectedLabel"] = .string(m.label)
                }
                let reply = try await self.environments.request(hostId, "peerLinks.link", .object(input))
                self.reloadPeerLinks(hostId)
                return reply["label"]?.stringValue
            })
        host.onDismiss = { [weak self] in self?.modal = nil }
        modal = host
    }

    /// "Forget": confirm, then `peerLinks.unlink` on the host.
    func forgetPeerLink(_ hostId: String, _ peerId: String) {
        guard case .links(let links)? = peerLinks[hostId], let link = links.first(where: { $0.environmentId == peerId }) else { return }
        let key = "\(hostId)/\(peerId)"
        let message = "Forget \(link.label)? Agents here stop working there. Revoke \"T3 Code · …\" in \(link.label)'s Sharing & access to end the session there too."
        let copy = ConfirmCopy.resolve(message)
        confirm(copy.title, copy.description ?? "") { [weak self] in
            guard let self else { return }
            self.forgettingLinks.insert(key)
            self.refreshPage()
            Task {
                do {
                    _ = try await self.environments.request(hostId, "peerLinks.unlink", .object(["environmentId": .string(peerId)]))
                } catch {
                    self.toast("Could not forget the link", PeerLinkDialog.message(error, fallback: "Could not forget the link."), .error)
                }
                self.forgettingLinks.remove(key)
                self.reloadPeerLinks(hostId)
            }
        }
    }
}

/// Settings > Environments as a map (T3 5258 EnvironmentsMap.tsx:269-357 `useFleetGraph`): every environment this app
/// knows with its saved routes and the links it holds, and the T3 Connect machines not added here.
extension SettingsController {
    func environmentsMapModel() -> EnvironmentsMapModel {
        let primary = environments.primaryId
        // Where another machine can reach each one, as the Link dialog offers it (`hasLinkAddress`).
        let reachable = Dictionary(PeerLinkDialog.machines(environments, hostId: "", primaryLabel: primaryDescriptor?.label, linked: [],
                                                           reported: { self.composer?.config($0)?.directEndpoints ?? [] })
                                       .map { ($0.environmentId, !$0.urls.isEmpty) }, uniquingKeysWith: { a, _ in a })
        let hostsOffering = Set(peerLinkHosts())
        func input(_ id: String, label: String, enabled: Bool, routes: [FleetRouteInput], active: String?) -> FleetEnvironmentInput {
            let state = environments.state(id)
            let phase = FleetPhase(rawValue: (state?.status ?? .available).rawValue) ?? .available
            let offers = composer?.config(id).map { PeerLinks.offered(capabilities: $0.capabilities, settings: $0.settings.raw) } ?? false
            let outgoing: FleetOutgoingLinks = switch peerLinks[id] {
            case nil: phase == .connected && !offers ? .off : .unknown
            case .loading?: hostsOffering.contains(id) ? .loading : .unknown
            case .failed(let reason)?: .error(reason)
            case .links(let links)?: .loaded(links)
            }
            return FleetEnvironmentInput(environmentId: id, label: label, machine: environments.machine(id), phase: phase, enabled: enabled,
                                         routes: routes, activeRouteId: phase == .connected ? active : nil, outgoing: outgoing,
                                         offersLinks: offers, canWriteAccess: hosts[id]?.session?.grants(AuthScopes.accessWrite) == true,
                                         hasLinkAddress: reachable[id] ?? false)
        }
        var inputs: [FleetEnvironmentInput] = []
        if let primary, let shell = environments.session(primary) {
            let origin = EnvironmentRoute.origin(shell.http.baseURL)
            inputs.append(input(primary, label: primaryDescriptor?.label ?? environments.label(primary) ?? "This machine", enabled: true,
                                routes: [FleetRouteInput(id: origin, kind: Self.routeKind(shell.http.baseURL))], active: origin))
        }
        for r in environments.saved where r.environmentId != primary {
            let routes = r.routes.map { url in
                FleetRouteInput(id: EnvironmentRoute.origin(url),
                                kind: r.isRelayRoute(url) ? "relay" : r.sshTarget != nil && url == r.httpBaseURL ? "ssh" : Self.routeKind(url))
            }
            let session = environments.session(r.environmentId)
            let active = session?.isRelay == true ? r.relayRoute.map(EnvironmentRoute.origin)
                : environments.routeInUse(r.environmentId).map(EnvironmentRoute.origin)
            inputs.append(input(r.environmentId, label: r.label, enabled: r.enabled, routes: routes, active: active))
        }
        let saved = Set(inputs.map(\.environmentId))
        let connect = (t3.machines ?? []).filter { !saved.contains($0.environmentId) }.map { m in
            FleetConnectMachineInput(environmentId: m.environmentId, label: m.record.label, machine: m.machine, availability: {
                switch m.availability {
                case .online: .online
                case .offline: .offline
                case .checking: .checking
                case .error: .error
                }
            }())
        }
        var map = EnvironmentsMapModel(clientLabel: "This device", environments: inputs, connectMachines: connect,
                                       awaitingApproval: Set(inputs.map(\.environmentId).filter { environments.state($0)?.awaitingApproval == true }))
        map.details = mapDetailsModel(primary)
        return map
    }

    /// What the map's details panel says beyond the graph (EnvironmentsMapDetails.tsx).
    func mapDetailsModel(_ primary: String?) -> EnvironmentsMapDetailsModel {
        var d = EnvironmentsMapDetailsModel()
        for r in environments.saved {
            d.statusText[r.environmentId] = EnvironmentRowStatus(enabled: r.enabled, state: environments.state(r.environmentId)).text
        }
        if let primary {
            // `EnvironmentRow` for the primary (:805-820): `transport · connectionStatusTitle · serverVersion`.
            let status = EnvironmentRowStatus(enabled: true, state: environments.state(primary)).text
            // `environmentTransportLabel` names a primary target "This machine" (EnvironmentRow.tsx:32).
            let version = primaryDescriptor?.serverVersion
            let transport = "This machine"
            d.primary = .init(environmentId: primary, label: primaryDescriptor?.label ?? environments.label(primary) ?? "This machine",
                              machine: environments.machine(primary) ?? "server",
                              subtitle: [transport, status, version].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if case .failed(let reason) = t3.cloudModel(primaryId: primary) { d.connectProblem = reason }
        d.forgetting = forgettingLinks
        return d
    }

    static func routeKind(_ url: URL) -> String {
        switch EnvironmentRoute.kind(url) {
        case .loopback: "loopback"
        case .lan: "lan"
        case .tailnet: "tailnet"
        case .public: "public"
        }
    }

    /// The map's link handle (EnvironmentsMap.tsx:735-800 `onLink`): pressed, or dropped on a machine or stack.
    func mapLink(_ sourceId: String, _ targetId: String?, ticked: [String]) {
        let model = environmentsMapModel()
        let graph = buildFleetGraph(clientLabel: model.clientLabel, environments: model.environments,
                                    connectMachines: model.connectMachines, now: Date())
        let stacks = fleetStacks(graph, expanded: [])
        switch fleetLinkAction(graph, stacks, selected: ticked, sourceId: sourceId, targetId: targetId) {
        case .batch(let source, let ids)?: presentLinkSeveral(source, ids, presetOnly: true)
        case .single(let source, let offer)?: presentLinkEnvironment(source, offer: offer)
        case .codeOnly(_, let source, _)?: presentLinkEnvironment(source)
        case nil: break
        }
    }

    /// `requestOneLink` (EnvironmentsMap.tsx:469-473): one link from `sourceId` to `targetId`, whatever is ticked.
    func mapLinkOne(_ sourceId: String, _ targetId: String) {
        let model = environmentsMapModel()
        let graph = buildFleetGraph(clientLabel: model.clientLabel, environments: model.environments,
                                    connectMachines: model.connectMachines, now: Date())
        if case .link(let offer) = fleetLinkOffer(graph, sourceId, targetId) {
            presentLinkEnvironment(offer.sourceEnvironmentId, offer: offer)
        }
    }

    /// "Link several…" (LinkSeveralEnvironments.tsx): the machines this app reaches, ticked, linked from `source` in
    /// one run. Each code is minted on its machine with this app's session there and goes straight into
    /// `peerLinks.link`; none is held, shown or logged. `presetOnly` lists only the machines picked on the map.
    func presentLinkSeveral(_ sourceEnvironmentId: String?, _ environmentIds: [String], presetOnly: Bool = false) {
        guard let window, modal == nil, let source = sourceEnvironmentId ?? peerLinkHosts().first else { return }
        if peerLinks[source] == nil { reloadPeerLinks(source) }
        let all = PeerLinkDialog.machines(environments, hostId: source, primaryLabel: primaryDescriptor?.label, linked: linkedFrom(source),
                                          reported: { self.composer?.config($0)?.directEndpoints ?? [] })
        let machines = presetOnly ? all.filter { environmentIds.contains($0.environmentId) } : all
        let unlisted = presetOnly ? environmentIds.filter { id in !machines.contains { $0.environmentId == id } }.count : 0
        let sourceLabel = source == environments.primaryId ? (primaryDescriptor?.label ?? environments.label(source)) : environments.label(source)
        let kinds = Dictionary(machines.map { ($0.environmentId, environments.machine($0.environmentId) ?? "server") }, uniquingKeysWith: { a, _ in a })
        let form = LinkSeveralEnvironmentsFormView(candidates: linkCandidates(source, machines), kinds: kinds, sourceLabel: sourceLabel,
                                                   preset: environmentIds, presetOnly: presetOnly, unlisted: unlisted,
                                                   linksState: linkListState(source))
        let (dialog, cancel, link) = LinkSeveralEnvironmentsDialog.make(form: form)
        form.onHeightChange = { [weak dialog] in dialog?.superview?.needsLayout = true }
        form.onRetryLinks = { [weak self] in self?.reloadPeerLinks(source) }
        let host = ModalHost.present(dialog, in: window)
        host.onDismiss = { [weak self] in self?.modal = nil; self?.linkSeveralSync = nil }
        modal = host
        // The source's list and each machine's own list (for the link back) land while the dialog shows.
        let sync: @MainActor () -> Void = { [weak self, weak form] in
            guard let self, let form else { return }
            if case .failed(let reason)? = self.peerLinks[source] { form.linksError = reason }
            form.setLinks(self.linkListState(source), candidates: self.linkCandidates(source, machines))
            form.backOffered = self.linkBackOffers(source, machines)
        }
        linkSeveralSync = sync
        for m in machines where peerLinkHosts().contains(m.environmentId) && peerLinks[m.environmentId] == nil { reloadPeerLinks(m.environmentId) }
        sync()
        cancel.action = { [weak host, weak form] in if form?.busy != true { host?.close() } }
        let sourceMachine = PeerLinkDialog.machines(environments, hostId: "", primaryLabel: primaryDescriptor?.label, linked: [],
                                                    reported: { self.composer?.config($0)?.directEndpoints ?? [] })
            .first { $0.environmentId == source }
        link.action = { [weak self, weak form] in
            guard let self, let form else { return }
            self.runLinkSeveral(form, source: source, sourceMachine: sourceMachine)
        }
    }

    /// `submit` (:150-201): the batch, each outcome on its row as it lands, the failed ones left picked.
    func runLinkSeveral(_ form: LinkSeveralEnvironmentsFormView, source: String, sourceMachine: LinkableMachine?) {
        guard !form.busy, !form.chosen.isEmpty else { return }
        let chosen = form.chosen, access = form.access
        let back: Set<String> = form.alsoLinkBack && sourceMachine != nil ? form.backOffered : []
        form.linking = Set(chosen.map(\.environmentId))
        let link: @MainActor (LinkableMachine) async -> LinkBatch.Attempt = { [weak self] machine in
            guard let self else { return .failed(.other, detail: nil) }
            return await self.linkWithMintedCode(machine, from: source, access: access)
        }
        let linkBack: @MainActor (LinkableMachine) async -> LinkBatch.Attempt? = { [weak self] machine in
            guard let self, back.contains(machine.environmentId), let sourceMachine else { return nil }
            return await self.linkWithMintedCode(sourceMachine, from: machine.environmentId, access: access)
        }
        Task { @MainActor [weak self, weak form] in
            let results = await LinkBatch.run(chosen, link: link, back: back.isEmpty ? nil : linkBack, onOutcome: { id, outcome in
                form?.outcomes[id] = outcome
                form?.linking.remove(id)
            })
            form?.linking = []
            form?.keepFailed()
            // Listing probes every linked machine, so it is read once, at the end (linkBatch.ts:316).
            guard let self, results.values.contains(where: { if case .linked = $0 { true } else { false } }) else { return }
            self.reloadPeerLinks(source)
            for id in back { self.peerLinksChanged(id) }
        }
    }

    /// Environments `source` links to already, by id.
    func linkedFrom(_ source: String) -> Set<String> {
        guard case .links(let links)? = peerLinks[source] else { return [] }
        return Set(links.filter { $0.status != .expired }.map(\.environmentId))
    }

    func linkListState(_ source: String) -> LinkBatch.ListState {
        switch peerLinks[source] {
        case .links?: .loaded
        case .failed?: .failed
        default: .loading
        }
    }

    func linkCandidates(_ source: String, _ machines: [LinkableMachine]) -> [LinkBatch.Candidate] {
        let linked = linkedFrom(source)
        let fresh = machines.map { m in var m = m; m.linked = linked.contains(m.environmentId); return m }
        return LinkBatch.candidates(fresh, writable: Set(fresh.filter(\.canMint).map(\.environmentId)), links: linkListState(source))
    }

    /// `useLinkBackOffers`: machines that can link back to `source` with no pasted code (LinkBackOffer).
    func linkBackOffers(_ source: String, _ machines: [LinkableMachine]) -> Set<String> {
        let sourceUrls = PeerLinkDialog.machines(environments, hostId: "", primaryLabel: primaryDescriptor?.label, linked: [],
                                                 reported: { self.composer?.config($0)?.directEndpoints ?? [] })
            .first { $0.environmentId == source }?.urls ?? []
        let hosts = Set(peerLinkHosts())
        return Set(machines.filter { m in
            let links: [PeerLinkSummary]? = if case .links(let l)? = peerLinks[m.environmentId] { l } else { nil }
            let offer = LinkBackOffer.evaluate(
                target: .init(connected: environments.state(m.environmentId)?.status == .connected, offersLinks: hosts.contains(m.environmentId),
                              writable: self.hosts[m.environmentId]?.session?.grants(AuthScopes.accessWrite) == true, links: links),
                source: .init(environmentId: source, connected: environments.state(source)?.status == .connected,
                              writable: m.canMint, urls: sourceUrls))
            return offer == .offered
        }.map(\.environmentId))
    }

    /// `linkWithMintedCode` (linkBatch.ts:240-268): a code minted on `machine`, handed to `host`'s `peerLinks.link`.
    /// Only a `PeerLinkError`'s own message passes through; anything else may carry the request and its code.
    func linkWithMintedCode(_ machine: LinkableMachine, from host: String, access: String) async -> LinkBatch.Attempt {
        guard let url = machine.urls.first else { return .failed(.unreachable, detail: nil) }
        guard let code = await PeerLinkDialog.mintPairingCode(environments, on: machine.environmentId, access: access, toast: nil) else {
            return .failed(.noCode, detail: nil)
        }
        var input: [String: JSONValue] = ["url": .string(url), "pairingCode": .string(code), "access": .string(access),
                                          "expectedEnvironmentId": .string(machine.environmentId), "expectedLabel": .string(machine.label)]
        if machine.urls.count > 1 { input["alternateUrls"] = .array(machine.urls.dropFirst().map(JSONValue.string)) }
        do {
            _ = try await environments.request(host, "peerLinks.link", .object(input))
            return .linked
        } catch {
            guard let typed = (error as? RPCClientError)?.typedError, typed.tag == "PeerLinkError" else { return .failed(.other, detail: nil) }
            return .failed(LinkBatch.failure(reason: typed.fields["reason"]?.stringValue, answeredAs: typed.fields["answeredAs"] != nil),
                           detail: typed.message)
        }
    }
}
