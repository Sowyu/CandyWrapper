import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The open thread's place among its relatives and its shell state, in the thread view: the details card's Lineage
/// section with its merge back, session detach and subagent Stop (ThreadRelationshipsControl.tsx), the subagent bar
/// that replaces the composer on a provider-native subagent thread (ProviderSubagentBar.tsx, ChatView.tsx:4262-4285),
/// the "Subagent of" link over the timeline (MessagesTimeline.tsx:1409-1437), Fork from a response
/// (ChatView.tsx:8605-8650), and the snoozed or settled status line under the last message (ThreadStatusLine.tsx).
/// The app supplies the shells, providers and the dispatch; ids it passes are scoped.
@MainActor
public final class ThreadLineageController {
    private let panel: ThreadPanelView
    private let bar = ProviderSubagentBarView()
    private let parentLink = TimelineParentLinkView()
    private let statusLine = ThreadStatusLineView()
    /// The pending handoff row over the status line (ChatView.tsx:11588-11603).
    private let pendingHandoff = HandoffDividerView()
    private let footer = FooterStack()
    /// Wake or Un-settle in flight, for the thread it was asked for.
    private var statusBusy: ThreadId?

    /// Every environment's live then archived shells, scoped.
    public var shells: (() -> [ThreadShell])?
    /// The environment's providers.
    public var providers: ((String) -> [ServerProvider])?
    /// `orchestration.dispatchCommand` for a scoped thread id.
    public var dispatch: ((ThreadId, JSONValue) async throws -> JSONValue)?
    /// One RPC on an environment (environment id, method, payload).
    public var request: ((String, String, JSONValue) async throws -> JSONValue)?
    /// Opens a scoped thread id in the panel.
    public var openThread: ((ThreadId) -> Void)?
    public var localVisit: ((ThreadId) -> T3Timestamp?)?
    public var acknowledgeWake: ((ThreadId, T3Timestamp) -> Void)?
    /// The composer's model for the next send.
    public var selectedModel: (() -> ModelSelection?)?
    /// The open thread's shell as of the last `sync`.
    private var shell: ThreadShell?

    private var threadId: ThreadId?
    private var projection: ThreadProjection?

    public init(panel: ThreadPanelView) {
        self.panel = panel
        // The card is built the first time it opens; `sync` keeps its lineage in `lazyDetailsCard` until then.
        panel.lazyDetailsCard.configure { [weak self] card in
            let section = card.lineage
            section.provider = { [weak self] instance in
                guard let self, let env = threadId?.environmentId,
                      let p = providers?(env).first(where: { $0.instanceId.rawValue == instance }) else { return nil }
                return (p.driver, p.displayName ?? p.driver)
            }
            section.onOpen = { [weak self] id in self?.open(id) }
            section.onMerge = { [weak self] in self?.merge() }
            section.onStop = { [weak self] id in self?.stop(id) }
            section.onStopWorkflow = { [weak self] id, coordinator in self?.stopWorkflow(id, coordinator: coordinator) }
            section.onDetach = { [weak self] in self?.detach() }
        }
        panel.model.onForkFromRun = { [weak self] source, run in self?.fork(source: source, run: run) }
    }

    /// The open thread changed or one of its inputs did. `threadId` is scoped; nil on a draft.
    public func update(threadId: ThreadId?, projection: ThreadProjection?) {
        if threadId != self.threadId { panel.lazyDetailsCard.loaded?.lineage.reset() }
        self.threadId = threadId
        self.projection = projection
        sync()
    }

    /// Shells or providers changed.
    public func sync() {
        let card = panel.lazyDetailsCard
        guard let threadId, let env = threadId.environmentId, let projection else {
            card.set(\.lineage.lineage, ThreadRelationships.Lineage())
            panel.composer.replacement = nil
            panel.timeline.setHeader(nil, height: 0)
            panel.timeline.setFooter(nil, height: 0)
            panel.header.parentThreadTitle = nil
            panel.childInputKey = nil
            return
        }
        let all = shells?() ?? []
        let local = ThreadRelationships.unscoped(ThreadRelationships.related(all, to: threadId, projection: projection), environmentId: env)
        var lineage = ThreadRelationships.lineage(threadId: threadId.localId, threads: local, projection: projection)
        #if DEBUG
        if let count = ProcessInfo.processInfo.environment["CANDY_FAKE_LINEAGE"].flatMap(Int.init) {
            lineage.previous += ThreadRelationships.Lineage.syntheticPrevious(count, current: threadId.localId)
        }
        #endif
        let byId = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        card.set(\.lineage.mergeTargetTitle, lineage.mergeTarget.flatMap { byId[$0]?.title })
        card.set(\.lineage.lineage, lineage)
        // "Subagent of" over the timeline and the parent crumb in the header: any thread whose lineage names a
        // subagent parent.
        let thread = projection.thread
        if let link = ThreadRelationships.parentLink(thread.lineage, threads: local) {
            parentLink.parentTitle = link.title
            parentLink.onOpen = { [weak self] in self?.open(link.threadId) }
            panel.timeline.setHeader(parentLink, height: TimelineParentLinkView.height)
            panel.header.parentThreadTitle = link.title
            panel.header.onOpenParent = { [weak self] in self?.open(link.threadId) }
        } else {
            panel.timeline.setHeader(nil, height: 0)
            panel.header.parentThreadTitle = nil
        }
        updateBar(projection, shell: byId[thread.id], parent: thread.lineage?.parentThreadId, env: env)
        shell = all.first { $0.id == threadId }
        syncFooter()
        updateChildInputs(all, threadId: threadId)
    }

    /// `childInputBannerItem` (ChatView.tsx:7462-7497): subagents waiting on a question, unless this thread waits on
    /// the user itself. Hidden subagent rows still ask through their parent.
    // ponytail: the children's titles are plain text where T3 makes each an inline button; Open question opens the first
    private func updateChildInputs(_ all: [ThreadShell], threadId: ThreadId) {
        let children = shell?.pendingRuntimeRequest == nil ? ChildThreadInputs.pending(for: threadId, in: all) : []
        guard let first = children.first else { panel.childInputKey = nil; return }
        panel.childInputBanner.apply(.init(variant: .neutral, icon: .messageCircle,
                                           title: children.count == 1 ? "Subagent needs input" : "\(children.count) subagents need input",
                                           description: children.map(\.title).joined(separator: ", "), actions: ["Open question"],
                                           priority: .activity))
        panel.childInputBanner.onAction = { [weak self] index in if index == 0 { self?.openThread?(first.id) } }
        panel.childInputKey = first.id.rawValue
    }

    /// The footer under the last row: a pending context handoff when the composer's model needs one
    /// (`resolvePendingHandoff`, ChatView.tsx:7744-7757), then the snoozed or settled status line.
    public func syncFooter() {
        guard let threadId, let env = threadId.environmentId, let projection else { return }
        let providers = providers?(env) ?? []
        let handoff = HandoffEndpoints.pending(projection.runs, selection: selectedModel?(), providers: providers,
                                                threadModel: shell?.modelSelection)
        if let handoff { pendingHandoff.configure(handoff, providers: providers, pending: true) }
        let status = updateStatusLine(shell)
        footer.set(handoff == nil ? nil : pendingHandoff, status ? statusLine : nil)
        panel.timeline.setFooter(footer.height > 0 ? footer : nil, height: footer.height)
    }

    /// The timeline footer for a snoozed or settled thread (ChatView.tsx:7613-7646).
    // ponytail: relative times refresh on pushed state and navigation, add a shared visible clock only if idle wakeup measurements allow it
    private func updateStatusLine(_ shell: ThreadShell?) -> Bool {
        guard let shell, let threadId else { return false }
        let now = TimestampFormat.nowMs()
        let busy = statusBusy == threadId
        if SidebarModel.effectiveSnoozed(SidebarThread(shell), nowMs: now) {
            statusLine.icon = .alarmClock
            statusLine.label = shell.snoozedUntil.map { "Snoozed, " + TimestampFormat.formatRelativeTimeUntilLabel($0.raw, nowMs: now) } ?? "Snoozed"
            statusLine.actionLabel = busy ? "Waking..." : "Wake now"
            statusLine.onAction = { [weak self] in self?.statusAction(ThreadCommands.unsnooze(threadId.localId), "Could not wake thread") }
        } else if shell.settledOverride == .settled {
            statusLine.icon = .circleCheck
            statusLine.label = shell.settledAt.map { "Settled " + TimestampFormat.formatRelativeTimeLabel($0.raw, nowMs: now) } ?? "Settled"
            statusLine.actionLabel = busy ? "Un-settling..." : "Un-settle"
            statusLine.onAction = { [weak self] in self?.statusAction(ThreadCommands.unsettle(threadId.localId), "Could not un-settle thread") }
        } else if let wake = SidebarModel.threadWokeAt(SidebarThread(shell), nowMs: now),
                  (wake.epochMs ?? 0) > max(
                    SidebarModel.resolveThreadLastVisitedAt(server: shell.lastVisitedAt, local: localVisit?(threadId))?.epochMs ?? Int64.min,
                    SidebarThread(shell).latestRun?.completedAt?.epochMs ?? Int64.min) {
            statusLine.icon = .alarmClock
            statusLine.label = "Woke from snooze"
            statusLine.actionLabel = "Dismiss"
            statusLine.onAction = { [weak self] in self?.acknowledgeWake?(threadId, wake); self?.sync() }
        } else {
            return false
        }
        statusLine.actionEnabled = !busy
        return true
    }

    private func statusAction(_ command: JSONValue, _ failure: String) {
        guard let threadId, statusBusy == nil, let dispatch else { return }
        statusBusy = threadId
        sync()
        Task { [weak self] in
            do { _ = try await dispatch(threadId, command) } catch { self?.toast(failure, error) }
            self?.statusBusy = nil
            self?.sync()
        }
    }

    /// The bar stands in for the composer only on a provider-native subagent thread.
    private func updateBar(_ projection: ThreadProjection, shell: ThreadShell?, parent: ThreadId?, env: String) {
        guard projection.thread.isProviderNativeSubagent else {
            if panel.composer.replacement === bar { panel.composer.replacement = nil }
            return
        }
        let selection = shell?.modelSelection
        let provider = providers?(env).first { $0.instanceId == (selection?.instanceId ?? projection.thread.providerInstanceId) }
        let model = provider.flatMap { p in selection.flatMap { ThreadRelationships.resolveModel(p.models, $0.model) } }
        bar.driver = provider?.driver
        bar.providerName = provider?.displayName ?? provider?.driver ?? ""
        bar.modelLabel = model.map { ModelNames.trigger($0) } ?? ThreadRelationships.modelSlugName(selection?.model ?? "")
        bar.effortLabel = selection.flatMap { ThreadRelationships.effortLabel($0, model: model) }
        bar.status = ThreadRelationships.providerSubagentStatus(projection)
        bar.onOpenParent = parent.map { p in { [weak self] in self?.open(p) } }
        if panel.composer.replacement !== bar { panel.composer.replacement = bar }
    }

    private func open(_ local: ThreadId) {
        guard let env = threadId?.environmentId else { return }
        openThread?(local.scoped(to: env))
    }

    private func toast(_ title: String, _ error: Error? = nil) {
        let message = error.map { ($0 as? LocalizedError)?.errorDescription ?? "\($0)" }
        _ = panel.toasts.show(ToastView(title: title, message: message, kind: .error))
    }

    // MARK: Actions

    /// `merge` (:294-307): `thread.merge_back` from the latest finished run, then the target opens.
    private func merge() {
        let section = panel.detailsCard.lineage
        guard let threadId, section.busy == nil, let target = section.lineage.mergeTarget, let run = section.lineage.mergeRunId,
              let dispatch else { return }
        section.busy = .merge
        Task { [weak self] in
            do {
                _ = try await dispatch(threadId, ThreadRelationshipCommands.mergeBack(source: threadId.localId, target: target, runId: run))
                self?.panel.detailsCard.lineage.busy = nil
                self?.open(target)
            } catch {
                self?.panel.detailsCard.lineage.busy = nil
                self?.toast("Could not merge back", error)
            }
        }
    }

    /// `detach` (:309-317): `provider-session.detach` for each of the thread's sessions.
    private func detach() {
        let section = panel.detailsCard.lineage
        guard let threadId, let projection, section.busy == nil, section.lineage.canDetach, let dispatch else { return }
        section.busy = .detach
        let commands = ThreadRelationshipCommands.detachSessions(threadId.localId, projection)
        Task { [weak self] in
            do { for c in commands { _ = try await dispatch(threadId, c) } } catch { self?.toast("Could not disconnect agent session", error) }
            self?.panel.detailsCard.lineage.busy = nil
        }
    }

    /// `stopSubagent` (:319-330): Stop on the child thread's live run; a failure says "Could not stop subagent".
    private func stop(_ child: ThreadId) {
        let section = panel.detailsCard.lineage
        guard let env = threadId?.environmentId, section.busy == nil, let dispatch else { return }
        let scoped = child.scoped(to: env)
        guard let run = shells?().first(where: { $0.id == scoped })?.activeRunId else { toast("Could not stop subagent"); return }
        section.busy = .stop(child)
        Task { [weak self] in
            do { _ = try await dispatch(scoped, ThreadRelationshipCommands.interrupt(child, runId: run)) } catch { self?.toast("Could not stop subagent") }
            self?.panel.detailsCard.lineage.busy = nil
        }
    }

    /// `stopWorkflow` (ThreadRelationshipsControl.tsx:391-402 in 2994): `orchestration.stopWorkflow` with this
    /// thread and the coordinator subagent; a failure says "Could not stop workflow".
    private func stopWorkflow(_ row: ThreadId, coordinator: String) {
        let section = panel.detailsCard.lineage
        guard let threadId, let env = threadId.environmentId, section.busy == nil, let request else { return }
        section.busy = .stop(row)
        let payload: JSONValue = .object(["threadId": .string(threadId.localId.rawValue), "subagentId": .string(coordinator)])
        Task { [weak self] in
            do { _ = try await request(env, "orchestration.stopWorkflow", payload) } catch { self?.toast("Could not stop workflow") }
            self?.panel.detailsCard.lineage.busy = nil
        }
    }

    /// `onForkFromRun` (ChatView.tsx:8605-8650): `thread.fork` into a new thread titled "{title} fork", then
    /// it opens once its shell arrives.
    private func fork(source: ThreadId, run: RunId) {
        guard let threadId, let env = threadId.environmentId, let dispatch else { return }
        let target = ThreadId(UUID().uuidString.lowercased())
        let title = (projection?.thread.title ?? "Thread") + " fork"
        Task { [weak self] in
            do {
                _ = try await dispatch(threadId, ThreadRelationshipCommands.fork(source: source, target: target, runId: run, title: title))
            } catch {
                self?.toast("Failed to fork this response.", error)
                return
            }
            // `waitForThreadShell`: the fork opens when its shell reaches this client.
            let scoped = target.scoped(to: env)
            for _ in 0..<50 {
                if self?.shells?().contains(where: { $0.id == scoped }) == true { self?.openThread?(scoped); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.toast("The fork was created, but its thread data did not reach this client. Reconnect and try opening it from the sidebar.")
        }
    }
}

/// The dispatch payloads behind Lineage and Fork (packages/client-runtime/src/operations/commands.ts).
public enum ThreadRelationshipCommands {
    /// `mergeThreadBack` (:952-965).
    public static func mergeBack(source: ThreadId, target: ThreadId, runId: RunId, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object(["type": .string("thread.merge_back"), "commandId": .string(commandId), "createdBy": .string("user"), "creationSource": .string("web"),
                 "sourceThreadId": .string(source.rawValue), "targetThreadId": .string(target.rawValue),
                 "sourcePoint": .object(["type": .string("run"), "runId": .string(runId.rawValue)])])
    }

    /// `forkThreadFromRun` (:937-950).
    public static func fork(source: ThreadId, target: ThreadId, runId: RunId, title: String?, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("thread.fork"), "commandId": .string(commandId), "createdBy": .string("user"), "creationSource": .string("web"),
                                      "sourceThreadId": .string(source.rawValue), "targetThreadId": .string(target.rawValue),
                                      "sourcePoint": .object(["type": .string("run"), "runId": .string(runId.rawValue)])]
        if let title { o["title"] = .string(title) }
        return .object(o)
    }

    /// `stopThreadSession` (:919-935): one detach per provider session, ids derived from one command id.
    public static func detachSessions(_ threadId: ThreadId, _ projection: ThreadProjection, commandId: String = ThreadCommands.newCommandId()) -> [JSONValue] {
        projection.providerSessions.compactMap { $0["id"]?.stringValue }.map { session in
            .object(["type": .string("provider-session.detach"), "commandId": .string("\(commandId):detach:\(session)"),
                     "threadId": .string(threadId.rawValue), "providerSessionId": .string(session), "reason": .string("client-requested")])
        }
    }

    /// `interruptThreadTurn` (:780-829) with a known run: `run.interrupt` holding the queue.
    public static func interrupt(_ threadId: ThreadId, runId: RunId, commandId: String = ThreadCommands.newCommandId()) -> JSONValue {
        .object(["type": .string("run.interrupt"), "commandId": .string(commandId), "threadId": .string(threadId.rawValue),
                 "runId": .string(runId.rawValue), "holdQueue": .bool(true)])
    }
}

/// The timeline footer's rows, stacked.
@MainActor
private final class FooterStack: DSView {
    private var rows: [(NSView, CGFloat)] = []
    var height: CGFloat { rows.reduce(0) { $0 + $1.1 } }

    func set(_ handoff: HandoffDividerView?, _ status: ThreadStatusLineView?) {
        let next = [handoff.map { ($0 as NSView, HandoffDividerView.height) }, status.map { ($0 as NSView, ThreadStatusLineView.height) }].compactMap { $0 }
        for (v, _) in rows where !next.contains(where: { $0.0 === v }) { v.removeFromSuperview() }
        rows = next
        for (v, _) in rows where v.superview !== self { addSubview(v) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (v, h) in rows { v.frame = NSRect(x: 0, y: y, width: bounds.width, height: h); y += h }
    }
}
