import Foundation
import T3Protocol
import T3Store

/// View state of one row that the row pass doesn't know about. It travels with the row so a
/// recycled view shows the same thing, and it is part of the measured-height cache key.
struct TimelineRowUI: Hashable {
    /// Work log entries (and thoughts) whose details are open, limited to this row's entries.
    var expandedEntries: Set<String> = []
    /// A long user message shows in full.
    var messageExpanded = false
    /// A long plan shows in full.
    var planExpanded = false
    /// The changed files card's fold-all state and the folders toggled since.
    var filesExpanded = false
    var folderOverrides: [String: Bool] = [:]
}

/// One row as the timeline draws it.
struct TimelineItem: Hashable {
    var row: TimelineRow
    var ui = TimelineRowUI()
    var id: String { row.id }
}

/// The read-only thread: the projection, the expand and collapse state, and the rows derived from
/// both. Expansion lives here, not in the row views, so recycling a view never loses it.
@MainActor
public final class ThreadViewModel {
    public private(set) var projection: ThreadProjection?
    /// Shown in the breadcrumb.
    public var projectTitle = ""
    /// Makes read paths workspace relative in labels and details.
    public var workspaceRoot: String?

    private var input: TimelineRowsInput?
    private var expandedEntries: Set<String> = []
    private var expandedMessages: Set<String> = []
    private var expandedPlans: Set<String> = []
    /// Per run, like T3's `threadChangedFilesExpandedById` (kept for the thread, not persisted).
    private var expandedChangedFiles: Set<RunId> = []
    /// Per run, folder path to open; cleared when the run's fold-all changes (ChangedFilesTree.tsx).
    private var folderOverrides: [RunId: [String: Bool]] = [:]
    private(set) var items: [TimelineItem] = []

    /// Rows changed; the panel re-applies them.
    var onChange: (@MainActor () -> Void)?
    /// The changed files card asks for a run's diff, at a file (`onOpenTurnDiff`).
    public var onOpenTurnDiff: (@MainActor (RunId, String?) -> Void)?

    public init() {}

    /// Replaces the projection (nil clears the view) and re-derives the rows.
    public func setProjection(_ projection: ThreadProjection?) {
        guard projection != self.projection else { return }
        let threadChanged = projection?.thread.id != self.projection?.thread.id
        self.projection = projection
        var fresh = projection.map(TimelineRowsInput.init(projection:))
        if let old = input, !threadChanged {
            fresh?.expandedRunIds = old.expandedRunIds
            fresh?.expandedAttemptIds = old.expandedAttemptIds
            fresh?.expandedWorkGroupIds = old.expandedWorkGroupIds
        } else {
            expandedEntries = []; expandedMessages = []; expandedPlans = []
            expandedChangedFiles = []; folderOverrides = [:]
        }
        input = fresh
        derive()
    }

    func toggleRun(_ id: RunId) { mutateInput { $0.expandedRunIds.formSymmetricDifference([id]) } }
    func toggleAttempt(_ id: RunAttemptId) { mutateInput { $0.expandedAttemptIds.formSymmetricDifference([id]) } }
    func toggleGroup(_ id: String) { mutateInput { $0.expandedWorkGroupIds.formSymmetricDifference([id]) } }
    func toggleEntry(_ id: String) { expandedEntries.formSymmetricDifference([id]); derive() }
    func toggleMessage(_ id: String) { expandedMessages.formSymmetricDifference([id]); derive() }
    func togglePlan(_ id: String) { expandedPlans.formSymmetricDifference([id]); derive() }
    func toggleChangedFiles(_ run: RunId) {
        expandedChangedFiles.formSymmetricDifference([run])
        folderOverrides[run] = nil
        derive()
    }
    func toggleChangedFolder(_ run: RunId, _ path: String) {
        folderOverrides[run, default: [:]][path] = !(folderOverrides[run]?[path] ?? expandedChangedFiles.contains(run))
        derive()
    }

    private func mutateInput(_ body: (inout TimelineRowsInput) -> Void) {
        guard input != nil else { return }
        body(&input!)
        derive()
    }

    private func derive() {
        let rows = input.map(TimelineRows.derive) ?? []
        items = rows.map { row in
            var ui = TimelineRowUI()
            switch row.kind {
            case .work(let entries, _, _): ui.expandedEntries = expandedEntries.intersection(entries.map(\.id))
            case .workLive(_, _, _, _, _, let thought?): ui.expandedEntries = expandedEntries.intersection([thought.id])
            case .message(let m, _, _, _, _, let summary):
                ui.messageExpanded = expandedMessages.contains(m.id.rawValue)
                if let run = summary?.runId {
                    ui.filesExpanded = expandedChangedFiles.contains(run)
                    ui.folderOverrides = folderOverrides[run] ?? [:]
                }
            case .proposedPlan(let p): ui.planExpanded = expandedPlans.contains(p.id.rawValue)
            default: break
            }
            return TimelineItem(row: row, ui: ui)
        }
        onChange?()
    }
}
