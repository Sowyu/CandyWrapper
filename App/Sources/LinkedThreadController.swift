import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store
import T3Transport

/// Linked threads (5258 LinkedThreadPane.tsx, state/linkedThreadView.ts, T3 commits 1cb3a8c753 #39406 and
/// 7c6e889ddb #39515): a thread on a machine the open thread's environment links to, opened read only as a tab of
/// its right panel. The shown tab's pane streams through that environment while it shows and is torn down when it
/// hides, so a hidden tab holds nothing.
@MainActor
final class LinkedThreadController {
    private let panel: ThreadPanelView
    private let environments: Environments
    private var shown: Shown?
    /// The main-screen page (LinkedThreadPage.tsx), over the thread panel while it shows.
    private var page: Shown?
    var isShowingPage: Bool { page != nil }
    /// The thread opens where every thread on a connected environment does once pairing connects it
    /// (linkedThreadView.ts:251-263); a tab is closed first.
    var openConnected: ((ThreadId) -> Void)?
    /// Enter code: Settings > Connections with the add dialog prefilled (`addEnvironmentPrefillAtom`).
    var addWithCode: ((String?) -> Void)?

    @MainActor private final class Shown {
        let target: LinkedThreadSurfaceTarget
        let pane: LinkedThreadPaneView
        let page: LinkedThreadPageView?
        var session: ThreadSession?
        var working = false
        var hasThread = false
        var failure: RPCClientError?
        /// "Connect to interact" (linkedEnvironmentConnectAtom).
        var connect: LinkedThreadConnect.Phase = .idle
        init(target: LinkedThreadSurfaceTarget, page: LinkedThreadPageView? = nil) {
            self.target = target
            self.page = page
            pane = page?.pane ?? LinkedThreadPaneView()
        }
    }

    init(panel: ThreadPanelView, environments: Environments) {
        self.panel = panel
        self.environments = environments
        panel.onLinkedThreadShown = { [weak self] target in self?.show(target) }
    }

    /// The via environment's name (`useEnvironment(viaEnvironmentId)?.label ?? "this environment"`, LinkedThreadPane.tsx:90).
    private func via(_ target: LinkedThreadSurfaceTarget) -> String { environments.label(target.viaEnvironmentId) ?? "this environment" }

    /// A shell for the via environment arrived or changed: the shown pane follows it.
    func sync() {
        for s in [shown, page].compactMap({ $0 }) {
            if let shell = environments.session(s.target.viaEnvironmentId) { s.session?.attach(shell) }
        }
    }

    /// Shows `target` on the main screen over `host`, replacing a page already there.
    func showPage(_ target: LinkedThreadSurfaceTarget, over host: NSView) {
        closePage()
        let view = LinkedThreadPageView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        view.title = target.title ?? "Thread on \(target.label)"
        let s = Shown(target: target, page: view)
        page = s
        start(s)
        host.addSubview(view)
    }

    /// Leaves the page: its stream ends, so nothing runs for it once another route shows.
    func closePage() {
        guard let s = page else { return }
        s.session?.end()
        s.page?.removeFromSuperview()
        page = nil
    }

    private func show(_ target: LinkedThreadSurfaceTarget?) {
        if let old = shown {
            old.session?.end()
            old.pane.removeFromSuperview()
            shown = nil
        }
        if panel.sideChatHost.pane is LinkedThreadPaneView { panel.sideChatHost.show(nil) }
        guard let target else { return }
        let s = Shown(target: target)
        shown = s
        start(s)
        panel.sideChatHost.show(s.pane)
        syncPane(s)
    }

    private func start(_ s: Shown) {
        let target = s.target
        s.pane.chat.model.environmentId = target.environmentId
        s.pane.onRetry = { [weak self, weak s] in
            guard let s else { return }
            s.failure = nil
            self?.syncPane(s)
            s.session?.retryLinked()
        }
        // LinkedThreadPane.tsx:146-153: `Button size="sm" variant="outline"` with `PlugIcon`.
        let connect = ButtonView("Connect to interact", icon: .plug, variant: .outline, size: .sm)
        connect.action = { [weak self, weak s] in if let s { self?.connect(s) } }
        s.pane.bar.action = connect
        s.pane.chat.noticeBanner.onAction = { [weak self, weak s] index in
            guard let s, index == 0, case .manual(_, let host) = s.connect else { return }
            self?.addWithCode?(host)
        }
        let id = ThreadId(target.threadId).scoped(to: target.environmentId)
        let session = ThreadSession(threadId: id, panel: s.pane.chat, sidebar: nil,
                                    linked: .init(via: target.viaEnvironmentId, environmentId: target.environmentId))
        session.onProjection = { [weak self, weak s] projection, onlyStreamingText in
            guard !onlyStreamingText, let self, let s, let projection else { return }
            s.hasThread = true
            s.working = LinkedThreads.isWorking(projection)
            // `tabViewAtom` keeps the tab's title to the thread's own (linkedThreadView.ts:107-123).
            let title = projection.thread.title
            if !title.isEmpty, self.shown === s {
                self.panel.mutatePanel { $0.setLinkedThreadTitle(target.surfaceId, title: title); return [] }
            }
            if !title.isEmpty { s.page?.title = title }
            self.syncPane(s)
        }
        session.onLinkedFailure = { [weak self, weak s] error in
            guard let s else { return }
            s.failure = error
            self?.syncPane(s)
        }
        s.session = session
        if let shell = environments.session(target.viaEnvironmentId) { session.attach(shell) }
        syncPane(s)
    }

    /// `useConnectLinkedEnvironment().connect` (linkedThreadView.ts:209-273).
    private func connect(_ s: Shown) {
        guard s.connect != .connecting else { return }
        s.connect = .connecting
        syncPane(s)
        let target = s.target, environments = self.environments
        // `pairClient.permissionAtom`: `peerLinks.pairClient` needs `access:write` (clientRpcPermissions.ts:104).
        let mayPair = environments.canCreateGuestShare(target.viaEnvironmentId)
        let supervisor = environments.session(target.viaEnvironmentId)?.supervisor
        let fromPage = s === page
        Task { [weak self, weak s] in
            let outcome = await LinkedThreadConnect.connect(
                label: target.label,
                requestPairing: {
                    guard mayPair, let supervisor,
                          let json = try? await supervisor.request(PeerLinkRPC.pairClient, payload: PeerLinkRPC.pairClientInput(environmentId: target.environmentId))
                    else { return nil }
                    return try? json.decode(as: PeerLinkClientPairingResult.self)
                },
                reaches: { host in await Self.reaches(host, environmentId: target.environmentId) },
                pair: { host, code in (try? await environments.pair(host: host, code: code, routeTarget: target.environmentId)) != nil })
            guard let self, let s else { return }
            s.connect = LinkedThreadConnect.phase(after: outcome)
            self.syncPane(s)
            switch outcome {
            case .connected:
                // LinkedThreadPane.tsx:100-107.
                self.panel.toasts.show(ToastView(title: "Connected to \(target.label)", message: "This device is paired with it and can use its threads.",
                                                 kind: .success))
                // A pane closed or replaced since is not moved again.
                guard s === self.shown || s === self.page else { return }
                if !fromPage { self.panel.mutatePanel { _ = $0.close(target.surfaceId); return [] } }
                self.openConnected?(ThreadId(target.threadId).scoped(to: target.environmentId))
            case .manual(_, let host):
                if s === self.shown || s === self.page { self.addWithCode?(host) }
            case .unreachable:
                break
            }
        }
    }

    /// `reachesEnvironment` (5258 client-runtime connection/onboarding.ts:222-241): the address answers as that
    /// environment within 6 s.
    nonisolated static func reaches(_ host: String, environmentId: String) async -> Bool {
        guard let base = try? Pairing.baseURL(host: host) else { return false }
        var http = EnvironmentHTTP(baseURL: base)
        http.timeout = 6
        return (try? await http.descriptor())?.environmentId == environmentId
    }

    private func syncPane(_ s: Shown) {
        guard s === shown || s === page else { return }
        s.pane.bar.action?.isEnabled = s.connect != .connecting
        s.pane.showConnectNotice(LinkedThreadConnect.notice(s.connect, label: s.target.label))
        let target = s.target
        s.pane.bar.status = LinkedThreads.status(label: target.label, via: via(target), working: s.hasThread && s.working)
        if let failure = s.failure, !failure.isTransport {
            s.pane.notice = .failure(LinkedThreads.failure(failure.typedError, message: failure.description, via: via(target), label: target.label),
                                     overThread: s.hasThread)
        } else {
            s.pane.notice = s.hasThread ? .none : .reading(label: target.label)
        }
    }
}
