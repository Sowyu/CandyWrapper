import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// Linked threads (5258 LinkedThreadPane.tsx, state/linkedThreadView.ts, T3 commits 1cb3a8c753 #39406 and
/// 7c6e889ddb #39515): a thread on a machine the open thread's environment links to, opened read only as a tab of
/// its right panel. The shown tab's pane streams through that environment while it shows and is torn down when it
/// hides, so a hidden tab holds nothing.
@MainActor
final class LinkedThreadController {
    private let panel: ThreadPanelView
    private let environments: Environments
    private var shown: Shown?

    @MainActor private final class Shown {
        let target: LinkedThreadSurfaceTarget
        let pane = LinkedThreadPaneView()
        var session: ThreadSession?
        var working = false
        var hasThread = false
        var failure: RPCClientError?
        init(target: LinkedThreadSurfaceTarget) { self.target = target }
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
        guard let s = shown, let shell = environments.session(s.target.viaEnvironmentId) else { return }
        s.session?.attach(shell)
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
        s.pane.chat.model.environmentId = target.environmentId
        s.pane.onRetry = { [weak self, weak s] in s?.failure = nil; self?.syncPane(); s?.session?.retryLinked() }
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
            self.syncPane()
        }
        session.onLinkedFailure = { [weak self, weak s] error in
            guard let s else { return }
            s.failure = error
            self?.syncPane()
        }
        s.session = session
        if let shell = environments.session(target.viaEnvironmentId) { session.attach(shell) }
        panel.sideChatHost.show(s.pane)
        syncPane()
    }

    private func syncPane() {
        guard let s = shown else { return }
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
