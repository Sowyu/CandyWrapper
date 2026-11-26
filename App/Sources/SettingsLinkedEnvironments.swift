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

    /// "Link": the shared dialog, then `peerLinks.link` on the host.
    func presentLinkEnvironment(_ hostId: String) {
        guard let window, modal == nil else { return }
        let linked: Set<String> = {
            guard case .links(let links)? = peerLinks[hostId] else { return [] }
            return Set(links.filter { $0.status != .expired }.map(\.environmentId))
        }()
        let machines = PeerLinkDialog.machines(environments, hostId: hostId, primaryLabel: primaryDescriptor?.label, linked: linked,
                                                  reported: { composer?.config($0)?.directEndpoints ?? [] })
        let host = PeerLinkDialog.present(
            in: window, environments: environments, machines: machines,
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
        return EnvironmentsMapModel(clientLabel: "This device", environments: inputs, connectMachines: connect,
                                    awaitingApproval: Set(inputs.map(\.environmentId).filter { environments.state($0)?.awaitingApproval == true }))
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
        case .batch(let source, let ids)?: presentLinkSeveral(source, ids)
        case .single(let source, _)?, .codeOnly(_, let source, _)?: presentLinkEnvironment(source)
        case nil: break
        }
    }

    /// "Link several…". Until the batch dialog lands, it opens the single Link dialog on the source.
    // ponytail: one machine at a time; replace with LinkSeveralEnvironments (7.2) when it is ported
    func presentLinkSeveral(_ sourceEnvironmentId: String?, _ environmentIds: [String]) {
        guard let source = sourceEnvironmentId ?? peerLinkHosts().first else { return }
        presentLinkEnvironment(source)
    }
}
