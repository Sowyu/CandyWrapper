import Foundation
import T3Protocol
import T3Store

/// Turns one thread's projection into timeline rows, rebuilding only what changed since the last
/// request. T3 does the same per update (ChatView.tsx:3911-3942, MessagesTimeline.tsx:874-920):
/// entries are reused across streaming updates, a streaming answer's rows are patched in place,
/// and anything else runs the full row pass. Here entries are also reused per row for tool and
/// status updates.
///
/// Requests run one at a time, on the main thread for short threads and off it for long ones;
/// `ThreadViewModel` guarantees that, which is why the class can be `@unchecked Sendable`.
final class TimelinePipeline: @unchecked Sendable {
    struct Request: Sendable {
        var projection: ThreadProjection?
        var projectionChanged: Bool
        var expandedRunIds: Set<RunId>
        var expandedAttemptIds: Set<RunAttemptId>
        var expandedWorkGroupIds: Set<String>
        /// Optimistic user messages, shown after the server's rows.
        var pending: [ChatMessage]
    }

    struct Result: Sendable {
        var rows: [TimelineRow]
        /// Which rows differ from the previous result.
        var change: TimelineChange
    }

    private var memo = TimelineRowsInput.Memo()
    /// The projection's entries and run state, before UI state and optimistic messages.
    private var base: TimelineRowsInput?
    /// The rows last handed out and the optimistic messages in them.
    private var shown: TimelineRows.Derived?
    private var shownPending: [ChatMessage] = []
    /// Entries of `base` replaced in place since `shown`; nil once the list changed shape.
    private var changedSinceShown: Set<Int>? = []
    /// Entries an older history page put in front of `shown`'s, with every later entry unchanged.
    private var prependedSinceShown: Int?
    /// Full row passes run so far. Tests read it to check that streaming updates patch rows instead.
    private(set) var fullPasses = 0

    /// The rows for `request`, or nil when nothing changed.
    func run(_ request: Request) -> Result? {
        if request.projectionChanged {
            if let projection = request.projection {
                let (input, changed) = OpenTiming.measure("timeline entries") { TimelineRowsInput.derive(projection: projection, memo: &memo) }
                prependedSinceShown = changedSinceShown == [] && shown != nil ? memo.prepended : nil
                base = input
                if let changed, let since = changedSinceShown { changedSinceShown = since.union(changed) } else { changedSinceShown = nil }
            } else {
                base = nil
                memo = TimelineRowsInput.Memo()
                changedSinceShown = nil
            }
        }
        var source = base
        source?.expandedRunIds = request.expandedRunIds
        source?.expandedAttemptIds = request.expandedAttemptIds
        source?.expandedWorkGroupIds = request.expandedWorkGroupIds
        if !request.pending.isEmpty {
            if source == nil { source = TimelineRowsInput(entries: []) }
            source?.entries += request.pending.map { TimelineEntry.message($0.id.rawValue, $0) }
            // The optimistic half of `isCompacting` (ChatView.tsx:3601-3604): a `/compact` on its way
            // already counts as work, with the Compacting header.
            if let last = request.pending.last, ComposerCompaction.isCompactCommand(last.text, attachments: last.attachments.count) {
                source?.isWorking = true
                source?.isCompacting = true
            }
        }
        let changed = changedSinceShown
        changedSinceShown = []
        let prepended = prependedSinceShown
        prependedSinceShown = nil
        guard let source else {
            shown = nil
            shownPending = []
            return Result(rows: [], change: .all)
        }
        if let shown, let changed, request.pending == shownPending,
           let (patched, rows) = OpenTiming.measure("timeline rows", "patch", {
               TimelineRows.patchingStreamingText(shown, input: source, changedEntries: changed.sorted())
           }) {
            self.shown = patched
            return rows.isEmpty ? nil : Result(rows: patched.rows, change: .rows(rows))
        }
        // An older page derives only its own rows and the ones it reaches (`Derived.prepend`).
        if let prepended, var previous = shown, request.pending == shownPending {
            shown = nil  // `previous` holds the only reference, so the splice edits in place
            let splice = OpenTiming.measure("timeline rows", "page of \(prepended)") { previous.prepend(source, count: prepended) }
            shown = previous
            if let splice { return Result(rows: previous.rows, change: .head(replaced: splice.replaced, inserted: splice.inserted)) }
        }
        fullPasses += 1
        let derived = OpenTiming.measure("timeline rows", "\(source.entries.count) entries") { TimelineRows.Derived(source) }
        let previous = shown?.rows
        shown = derived
        shownPending = request.pending
        guard let previous else { return Result(rows: derived.rows, change: .all) }
        // T3 keeps unchanged rows (`computeStableMessagesTimelineRows`); here the diff tells the
        // main thread which rows to touch, so it never walks the whole list.
        let change = Self.diff(previous, derived.rows)
        if case .rows(let changed) = change, changed.isEmpty { return nil }
        return Result(rows: derived.rows, change: change)
    }

    /// The rows that differ: by index when the ids line up, else everything after the common prefix.
    static func diff(_ old: [TimelineRow], _ new: [TimelineRow]) -> TimelineChange {
        if old.count == new.count {
            var changed: [Int] = []
            for i in new.indices {
                guard old[i].id == new[i].id else { return .tail(firstDifference(old, new)) }
                if old[i] != new[i] { changed.append(i) }
            }
            return .rows(changed)
        }
        return .tail(firstDifference(old, new))
    }

    private static func firstDifference(_ old: [TimelineRow], _ new: [TimelineRow]) -> Int {
        var i = 0
        while i < old.count, i < new.count, old[i] == new[i] { i += 1 }
        return i
    }
}
