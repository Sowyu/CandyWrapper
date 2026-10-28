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
        let machines = PeerLinkDialog.machines(environments, hostId: hostId, primaryLabel: primaryDescriptor?.label, linked: linked)
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
        let message = "Forget \(link.label)? Agents here stop working there. Revoke \"T3 Code · …\" in \(link.label)'s Connections to end the session there too."
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
