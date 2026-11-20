import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// Side chats (4928 #26901, useSideChat.ts and SideChatPane.tsx): forks of the open thread that run in a tab
/// of its right panel. Starts them from the + menu and `/side`, keeps their tabs' titles and dots, and builds
/// the shown tab's pane with its own thread subscription, torn down when the tab hides.
@MainActor
final class SideChatController {
    private let panel: ThreadPanelView
    private weak var sidebar: SidebarContentView?
    private let environments: Environments
    private weak var composer: ComposerController?
    /// The open thread, scoped; nil on a draft.
    var parentId: () -> ThreadId? = { nil }
    /// A start is in flight (`pendingRef`, useSideChat.ts:41): a second one waits for it.
    private var starting = false
    private var shown: Shown?

    /// The shown tab's pane, its embedded chat, subscription and model controls.
    private final class Shown {
        let id: ThreadId
        let pane: SideChatPaneView
        let chat = ThreadPanelView()
        var session: ThreadSession?
        let pickers: ComposerPickers
        var projection: ThreadProjection?
        var bringingBack = false
        var deleting = false
        init(id: ThreadId, pickers: ComposerPickers) {
            self.id = id
            self.pickers = pickers
            pane = SideChatPaneView(threadId: id.localId)
        }
    }

    init(panel: ThreadPanelView, sidebar: SidebarContentView, environments: Environments, composer: ComposerController) {
        self.panel = panel
        self.sidebar = sidebar
        self.environments = environments
        self.composer = composer
        panel.onAddSideChat = { [weak self] in Task { await self?.start(message: nil) } }
        panel.onSideChatShown = { [weak self] id in self?.show(id) }
        panel.onSideChatsClosed = { [weak self] ids in self?.closed(ids) }
    }

    private var threads: [ThreadShell] { (sidebar?.snapshot?.threads ?? []) + (sidebar?.snapshot?.archivedThreads ?? []) }
    private func shell(_ id: ThreadId) -> ThreadShell? { threads.first { $0.id == id } }

    /// What the open thread is, for `SideChats.disabledReason`.
    private func parentFacts() -> SideChats.Parent {
        guard let parent = parentId(), let env = parent.environmentId else {
            return .init(isServerThread: false)
        }
        let shell = shell(parent)
        let config = composer?.config(env)
        let pending = shell.map { $0.worktreePath == nil && $0.activeRunId != nil && $0.status == .preparing } ?? false
        return .init(isSideChat: shell?.lineage.sideChat == true,
                     isSubagent: shell?.lineage.relationshipToParent == .subagent || shell?.lineage.delegatedUnderParent == true,
                     configLoaded: config != nil, capable: config?.capabilities.contains(SideChats.capability) == true,
                     isServerThread: shell != nil, worktreePending: pending, canOperate: environments.canOperate(env))
    }

    /// The tabs' titles and dots, the + menu row and the shown pane's header, after a shell or route change.
    func sync() {
        let facts = parentFacts()
        var titles: [String: String] = [:], states: [String: SideChats.TabState] = [:]
        if let env = parentId()?.environmentId {
            for surface in panel.panelState.surfaces {
                guard let local = surface.sideChatThreadId, let shell = shell(local.scoped(to: env)) else { continue }
                titles[surface.id] = shell.title
                states[surface.id] = SideChats.tabState(shell)
            }
        }
        panel.setSideChatTabs(titles: titles, states: states, offered: facts.offered, disabledReason: SideChats.disabledReason(facts))
        syncPane()
    }

    // MARK: Starting

    /// `useSideChat.open` (useSideChat.ts:20-130): forks the open thread's latest stable point, gives it the parent
    /// composer's permission mode, sends `message` when there is one and shows its tab. False when it did not start.
    @discardableResult
    func start(message: String?) async -> Bool {
        guard !starting, let parent = parentId(), let env = parent.environmentId else { return false }
        if let reason = SideChats.disabledReason(parentFacts()) {
            toast("Side chat not started", reason, kind: .warning)
            return false
        }
        starting = true
        defer { starting = false }
        let runtimeMode = composer?.pickers.current.runtimeMode
        let selection = composer?.pickers.current.modelSelection
        let target = ThreadId(UUID().uuidString.lowercased())
        let scoped = target.scoped(to: env)
        do {
            _ = try await environments.dispatch(parent, SideChats.fork(source: parent.localId, target: target))
        } catch {
            toast("Could not start a side chat.", error)
            return false
        }
        let discard = { [environments] in Task { _ = try? await environments.dispatch(scoped, SideChats.discard(target)) } }
        // `waitForThreadShell`: the fork's shell reaches this client over the shell stream.
        var sideChat: ThreadShell?
        for _ in 0..<50 {
            if let found = shell(scoped) { sideChat = found; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let sideChat else {
            toast("The side chat was created, but it did not reach this client.")
            discard()
            return false
        }
        if let runtimeMode, runtimeMode.rawValue != sideChat.runtimeMode {
            do { _ = try await environments.dispatch(scoped, SideChats.setRuntimeMode(target, runtimeMode.rawValue)) } catch {
                toast("Could not set the side chat's permission mode.", error)
                discard()
                return false
            }
        }
        // Send before showing the tab: closing a tab whose side chat has no run deletes it.
        if let message {
            let payload = OrchestrationCommands.message(threadId: target.rawValue, messageId: UUID().uuidString.lowercased(), text: message,
                                                        selection: selection ?? sideChat.modelSelection, queue: false)
            do { _ = try await environments.dispatch(scoped, payload) } catch {
                toast("Could not send the side chat message.", error)
                discard()
                return false
            }
        }
        // The parent may have changed while the fork ran; its own panel keeps the tab.
        guard parentId() == parent else { return true }
        panel.mutatePanel { $0.openSideChat(target); return [] }
        // A new side chat focuses its composer (#32929).
        shown?.chat.composer.focus()
        return true
    }

    // MARK: The pane

    /// Builds the shown side chat's pane or tears the last one down, so a hidden tab holds nothing.
    private func show(_ local: ThreadId?) {
        if let old = shown {
            old.session?.end()
            old.pane.removeFromSuperview()
            shown = nil
        }
        panel.sideChatHost.show(nil)
        guard let local, let env = parentId()?.environmentId, let composer else { return }
        let id = local.scoped(to: env)
        let pickers = ComposerPickers(store: composer.pickers.store, draftKey: "side-chat:" + id.rawValue,
                                      context: ComposerSelectionContext(catalog: ProviderCatalog([])))
        let s = Shown(id: id, pickers: pickers)
        shown = s
        s.chat.isEmbedded = true
        s.chat.model.environmentId = env
        s.pane.content = s.chat
        s.pane.onClose = { [weak self] in self?.panel.mutatePanel { $0.close("side-chat:" + local.rawValue) } }
        s.pane.onDelete = { [weak self] in self?.confirmDelete(id) }
        s.pane.onBringBack = { [weak self] in self?.bringBack(id) }
        s.chat.composer.footerControls = [pickers.controlsView]
        s.chat.composer.onSend = { [weak self, weak s] text, mode, _ in
            guard let self, let s else { return }
            self.send(text, mode: mode, in: s)
        }
        s.chat.composer.onStop = { [weak self, weak s] in
            guard let self, let s, let run = s.projection?.runs.last(where: { ComposerLogic.RunState(runs: [$0]).canInterrupt })?.id else { return }
            Task { _ = try? await self.environments.dispatch(id, ThreadRelationshipCommands.interrupt(local, runId: run)) }
        }
        let session = ThreadSession(threadId: id, panel: s.chat, sidebar: nil, cache: environments.threadCache)
        session.onProjection = { [weak self, weak s] projection, onlyStreamingText in
            guard let self, let s, !onlyStreamingText else { return }
            s.projection = projection
            s.chat.composer.runState = ComposerLogic.RunState(runs: projection?.runs ?? [])
            self.syncPane()
        }
        if let shellSession = environments.session(env) { session.attach(shellSession) }
        s.session = session
        panel.sideChatHost.show(s.pane)
        syncPane()
    }

    /// The pane's header and model controls from the side chat's and its parent's shells (SideChatPane.tsx:61-68).
    private func syncPane() {
        guard let s = shown, let env = s.id.environmentId else { return }
        let sideChat = shell(s.id)
        let parent = parentId().flatMap(shell)
        let canOperate = environments.canOperate(env)
        let mergeRun = s.projection.flatMap(ThreadRelationships.latestMergeBackRun)
        let parentActive = parent.map { [.preparing, .queued, .starting, .running, .waiting].contains($0.activityRunStatus ?? $0.status) } ?? false
        let blocked: String? = !canOperate ? "This connection cannot change threads."
            : parentActive ? "Available when the main thread is idle."
            : mergeRun == nil ? "Available after a finished reply." : nil
        s.pane.apply(.init(title: sideChat?.title, bringBackBlockedReason: blocked, bringingBack: s.bringingBack,
                           canDelete: canOperate && sideChat != nil, deleting: s.deleting,
                           deleted: sideChat == nil && sidebar?.snapshot != nil))
        if let config = composer?.config(env) {
            let project = sidebar?.snapshot?.projects.first { $0.id == sideChat?.projectId }
            s.pickers.update(context: ComposerSelectionContext(
                catalog: ProviderCatalog(config.providers, settings: ServerSettingsValues(config.settings.raw), projectId: sideChat?.projectId.localId.rawValue),
                thread: sideChat, projectDefaultModel: project?.defaultModelSelection, serverDefaults: config.settings,
                hasStartedSession: ComposerLogic.QueueState.hasStartedSession(s.projection),
                supportsProviderHandoff: ComposerLogic.QueueState.supportsProviderHandoff(s.projection)))
        }
    }

    /// The side chat's own composer: a plain `message.dispatch`, queued behind its running turn.
    // ponytail: text only; attachments, chips, `/` commands and drafts stay with the main composer until side chats need them
    private func send(_ text: String, mode: ComposerLogic.SendMode, in s: Shown) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sideChat = shell(s.id) else { return }
        let payload = OrchestrationCommands.message(threadId: s.id.localId.rawValue, messageId: UUID().uuidString.lowercased(), text: trimmed,
                                                    selection: s.pickers.current.modelSelection ?? sideChat.modelSelection, queue: mode == .queue)
        s.chat.composer.text = ""
        Task { [weak self] in
            do { _ = try await self?.environments.dispatch(s.id, payload) } catch {
                s.chat.composer.text = text
                self?.toast("Could not send the side chat message.", error)
            }
        }
    }

    /// `bringBack` (SideChatPane.tsx:70-92): `thread.merge_back` of the latest finished run into the parent.
    private func bringBack(_ id: ThreadId) {
        guard let s = shown, s.id == id, !s.bringingBack, let parent = parentId(),
              let run = s.projection.flatMap(ThreadRelationships.latestMergeBackRun)?.id else { return }
        s.bringingBack = true
        syncPane()
        Task { [weak self] in
            do {
                _ = try await self?.environments.dispatch(parent, ThreadRelationshipCommands.mergeBack(source: id.localId, target: parent.localId, runId: run))
                self?.toast("Brought back", message: "The main thread gets this side chat with your next message there.", kind: .success)
            } catch {
                self?.toast("Could not bring back the side chat", error)
            }
            s.bringingBack = false
            self?.syncPane()
        }
    }

    /// `deleteSideChat` (SideChatPane.tsx:94-129): confirms when `confirmThreadDelete` is on, deletes, closes the tab.
    private func confirmDelete(_ id: ThreadId) {
        guard let s = shown, s.id == id, !s.deleting, let sideChat = shell(id) else { return }
        let run: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            s.deleting = true
            self.syncPane()
            Task { [weak self] in
                do {
                    _ = try await self?.environments.dispatch(id, ThreadCommands.delete(id.localId))
                    self?.panel.mutatePanel { $0.close("side-chat:" + id.localId.rawValue) }
                } catch {
                    self?.toast("Could not delete the side chat", error)
                }
                s.deleting = false
                self?.syncPane()
            }
        }
        guard ClientSettingsStore.shared.current.bool("confirmThreadDelete"), let window = panel.window else { return run() }
        ConfirmCopy.present("Delete side chat \"\(sideChat.title)\"?\nThis permanently clears its conversation history.",
                            destructive: true, in: window) { yes in if yes { run() } }
    }

    /// Closing a tab deletes a side chat that never ran (useRightPanelSurfaceClose.ts:74-88); the server keeps one
    /// with a run or message. A side chat whose shell is already gone was deleted.
    private func closed(_ ids: [ThreadId]) {
        guard let env = parentId()?.environmentId, environments.canOperate(env) else { return }
        for local in ids where shell(local.scoped(to: env)) != nil {
            Task { [environments] in _ = try? await environments.dispatch(local.scoped(to: env), SideChats.discard(local)) }
        }
    }

    private func toast(_ title: String, _ error: Error? = nil) {
        toast(title, message: error.map { ($0 as? LocalizedError)?.errorDescription ?? "\($0)" }, kind: .error)
    }

    private func toast(_ title: String, _ message: String? = nil, kind: ToastQueue.Kind) {
        toast(title, message: message, kind: kind)
    }

    private func toast(_ title: String, message: String?, kind: ToastQueue.Kind) {
        _ = panel.toasts.show(ToastView(title: title, message: message, kind: kind))
    }
}
