import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// The open thread's guest share (GuestShareControls.tsx at 3669): the header's indicator with Stop sharing, and the
/// waiting messages with Dismiss and Send, which `ThreadLineageController` puts in the timeline footer. Both read
/// `thread.guestShare` from the projection, which `thread.guest-share-updated` keeps current.
@MainActor
public final class GuestShareThreadController {
    private let panel: ThreadPanelView
    let pending = GuestPendingMessagesView()
    private var threadId: ThreadId?
    private var share: ThreadGuestShare?
    /// Guest message ids with a Send or Dismiss in flight.
    private var busy: Set<String> = []
    private var stopping: ThreadId?

    /// `orchestration.dispatchCommand` for a scoped thread id.
    var dispatch: ((ThreadId, JSONValue) async throws -> JSONValue)?
    /// `orchestration:operate` on an environment (`useEnvironmentScope`): without it the messages show no buttons.
    public var canOperate: ((String) -> Bool)?
    /// The footer's height changed.
    var onChange: (() -> Void)?

    init(panel: ThreadPanelView) {
        self.panel = panel
        pending.onResolve = { [weak self] id, send in self?.resolve(id, send: send) }
        panel.header.onStopSharing = { [weak self] in self?.stop() }
    }

    /// The open thread or its projection changed. `threadId` is scoped; nil on a draft.
    func update(threadId: ThreadId?, projection: ThreadProjection?) {
        if threadId != self.threadId { busy = []; stopping = nil }
        self.threadId = threadId
        share = projection?.thread.guestShare
        panel.header.guestShare = share
        panel.header.guestStopping = stopping != nil && stopping == threadId
        let messages = share?.pendingMessages ?? []
        busy = busy.intersection(messages.map(\.id))
        let operate = threadId?.environmentId.map { canOperate?($0) ?? true } ?? false
        pending.configure(messages, guestName: share?.guestName, canOperate: operate, busy: busy, model: panel.model)
    }

    /// The open thread's share, when `threadId` (scoped) is the open thread.
    public func share(for threadId: ThreadId) -> ThreadGuestShare? { threadId == self.threadId ? share : nil }

    /// The waiting messages, or nil while none wait.
    var footerView: GuestPendingMessagesView? { pending.isEmpty ? nil : pending }

    /// `resolveGuestMessage` (commands.ts:444-474) for one message, its buttons disabled until it lands.
    private func resolve(_ guestMessageId: String, send: Bool) {
        guard let threadId, let dispatch, !busy.contains(guestMessageId) else { return }
        busy.insert(guestMessageId)
        refresh()
        Task { [weak self] in
            // T3 only logs a failure (`useOrchestrationCommand` with a label); the buttons come back.
            _ = try? await dispatch(threadId, ThreadCommands.resolveGuestMessage(threadId.localId, guestMessageId: guestMessageId, send: send))
            self?.busy.remove(guestMessageId)
            self?.refresh()
        }
    }

    /// `closeGuestShare` (commands.ts:437-442), from the header's Stop sharing.
    private func stop() {
        guard let threadId, let dispatch, stopping == nil else { return }
        stopping = threadId
        panel.header.guestStopping = true
        Task { [weak self] in
            _ = try? await dispatch(threadId, ThreadCommands.closeGuestShare(threadId.localId))
            // A thread opened meanwhile may have a Stop of its own in flight.
            guard let self, self.stopping == threadId else { return }
            self.stopping = nil
            self.panel.header.guestStopping = false
        }
    }

    private func refresh() {
        let messages = share?.pendingMessages ?? []
        let operate = threadId?.environmentId.map { canOperate?($0) ?? true } ?? false
        pending.configure(messages, guestName: share?.guestName, canOperate: operate, busy: busy, model: panel.model)
        onChange?()
    }
}
