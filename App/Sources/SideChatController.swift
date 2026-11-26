import AppKit
import DesignSystem
import Features
import T3Client
import T3Protocol
import T3Store

/// What `/side` sends as the side chat's first message (`SideChatMessage`, useSideChat.ts:23-26): the text,
/// the draft's uploaded attachments and its chips' records.
struct SideChatMessage {
    var text: String
    var attachments: [JSONValue] = []
    var context: JSONValue?
}

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
    /// The side chat the right panel shows. At launch the panel restores its tab before the parent thread is known,
    /// and asks only once, so `sync` builds the pane when it can.
    private var requested: ThreadId?
    private weak var windowShortcuts: Shortcuts?

    /// The shown tab's pane, its embedded chat, subscription and composer. The composer is a second
    /// `ComposerController` on the panel's shared drafts, so attachments, chips, `/` and drafts work as in the
    /// main chat (SideChatPane.tsx:178-190 renders the full `ChatView`).
    @MainActor private final class Shown {
        let id: ThreadId
        let pane: SideChatPaneView
        let chat = ThreadPanelView()
        /// "Context from · parent", the chat's list header.
        let contextDivider = TimelineParentLinkView()
        var session: ThreadSession?
        var composer: ComposerController?
        /// The side chat's composer chords and F6, run while focus is in its pane.
        let shortcuts = Shortcuts()
        var projection: ThreadProjection?
        var deleting = false
        init(id: ThreadId) {
            self.id = id
            pane = SideChatPaneView(threadId: id.localId)
            contextDivider.sideChat = true
            chat.timeline.setHeader(contextDivider, height: TimelineParentLinkView.height)
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
        composer.sideChatSlash = { [weak self] in
            guard let facts = self?.parentFacts(), facts.offered, facts.isServerThread else { return nil }
            return .init(disabledReason: SideChats.disabledReason(facts))
        }
        composer.sideChatDisabledReason = { [weak self] in self.flatMap { SideChats.disabledReason($0.parentFacts()) } }
        composer.onSideChat = { [weak self] prompt in await self?.start(message: prompt) ?? false }
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
        if let requested, shown?.id.localId != requested { show(requested) }
        syncPane()
    }

    // MARK: Starting

    /// `useSideChat.open` (useSideChat.ts:20-130): forks the open thread's latest stable point, gives it the parent
    /// composer's permission mode, sends `message` when there is one and shows its tab. False when it did not start.
    @discardableResult
    func start(message: SideChatMessage?) async -> Bool {
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
            let payload = OrchestrationCommands.message(threadId: target.rawValue, messageId: UUID().uuidString.lowercased(), text: message.text,
                                                        selection: selection ?? sideChat.modelSelection, queue: false,
                                                        attachments: message.attachments, context: message.context)
            do { _ = try await environments.dispatch(scoped, payload) } catch {
                toast("Could not send the side chat message.", error)
                discard()
                return false
            }
        } else if let selection, let composer {
            // An empty start seeds the side chat's draft with the parent's model (useSideChat.ts:119-121).
            composer.pickers.store.pickModel(scoped.rawValue, instance: selection.instanceId, model: selection.model,
                                             composer.pickers.context)
        }
        // The parent may have changed while the fork ran; its own panel keeps the tab.
        guard parentId() == parent else { return true }
        panel.mutatePanel { $0.openSideChat(target); return [] }
        // A new side chat focuses its composer (#32929).
        shown?.composer?.focusComposer()
        return true
    }

    // MARK: Keys

    /// Keys pressed in the side chat's pane run its own table first (useChatShortcuts.ts:26-30, 75-95 at 4928).
    /// F6 from the main chat moves into the shown side chat's composer.
    // ponytail: F6 visits only the two chats; port workspaceFocus.ts's area cycle (sidebar, panel) when F6 is asked for elsewhere
    func registerShortcuts(_ shortcuts: Shortcuts) {
        windowShortcuts = shortcuts
        shortcuts.nested = { [weak self] in self?.focusedShortcuts() }
        shortcuts.on(["workspace.focusNext", "workspace.focusPrevious"]) { [weak self] call in
            guard let s = self?.shown, s.pane.window != nil, let composer = s.composer else { return false }
            if !call.isRepeat { composer.focusComposer() }
            return true
        }
    }

    private func focusedShortcuts() -> Shortcuts? {
        guard let s = shown, let responder = s.pane.window?.firstResponder as? NSView, responder.isDescendant(of: s.pane) else { return nil }
        return s.shortcuts
    }

    // MARK: The pane

    /// Builds the shown side chat's pane or tears the last one down, so a hidden tab holds nothing.
    private func show(_ local: ThreadId?) {
        requested = local
        if let old = shown {
            old.session?.end()
            old.composer?.tearDown()
            old.pane.removeFromSuperview()
            shown = nil
        }
        panel.sideChatHost.show(nil)
        guard let local, let env = parentId()?.environmentId, let composer, let sidebar else { return }
        let id = local.scoped(to: env)
        let s = Shown(id: id)
        shown = s
        s.chat.isEmbedded = true
        s.chat.model.environmentId = env
        s.pane.content = s.chat
        s.pane.onClose = { [weak self] in self?.panel.mutatePanel { $0.close("side-chat:" + local.rawValue) } }
        s.pane.onDelete = { [weak self] in self?.confirmDelete(id) }
        s.pane.onAddToChat = { [weak self] in self?.addToChat(id) }
        let chatComposer = ComposerController(panel: s.chat, sidebar: sidebar, environments: environments, embeddedIn: composer)
        s.composer = chatComposer
        chatComposer.showThread(id)
        s.shortcuts.context = { [weak self] in self?.windowShortcuts?.context() ?? KeybindingContext() }
        chatComposer.registerShortcuts(s.shortcuts)
        // Shift+F6 (and F6) from the side chat goes back to the main chat's composer.
        s.shortcuts.on(["workspace.focusNext", "workspace.focusPrevious"]) { [weak self] call in
            if !call.isRepeat { self?.composer?.focusComposer() }
            return true
        }
        let session = ThreadSession(threadId: id, panel: s.chat, sidebar: nil, cache: environments.threadCache)
        session.onProjection = { [weak self, weak s, weak chatComposer] projection, onlyStreamingText in
            if onlyStreamingText {
                chatComposer?.projectionTextChanged(projection, threadId: id)
                return
            }
            chatComposer?.projectionChanged(projection, threadId: id)
            guard let self, let s else { return }
            s.projection = projection
            self.syncPane()
        }
        session.onStatus = { [weak chatComposer] status in chatComposer?.threadStatusChanged(status, threadId: id) }
        if let shellSession = environments.session(env) { session.attach(shellSession) }
        s.session = session
        panel.sideChatHost.show(s.pane)
        syncPane()
    }

    /// The pane's header and model controls from the side chat's and its parent's shells (SideThreadPane.tsx:99 at 5258).
    private func syncPane() {
        guard let s = shown, let env = s.id.environmentId else { return }
        let sideChat = shell(s.id)
        let parent = parentId().flatMap(shell)
        // The list header of an embedded side chat (ChatView.tsx:918-928, MessagesTimeline.tsx:1206-1230): "Context from"
        // and the parent's title, which opens nothing since the parent is the view around it.
        s.contextDivider.parentTitle = parent?.title ?? "Parent thread"
        let canOperate = environments.canOperate(env)
        s.pane.apply(.init(title: sideChat?.title, canAddToChat: sideChat?.latestUserMessageAt != nil,
                           canDelete: canOperate && sideChat != nil, deleting: s.deleting,
                           deleted: sideChat == nil && sidebar?.snapshot != nil))
    }

    /// `addToChat` (SideThreadPane.tsx:99-108 at 5258, #38323): the side chat as a thread reference in the main thread's
    /// draft. It replaced Bring back's `thread.merge_back`.
    private func addToChat(_ id: ThreadId) {
        guard let s = shown, s.id == id, let sideChat = shell(id), sideChat.latestUserMessageAt != nil else { return }
        composer?.addSideChatContext(id, title: sideChat.title)
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
