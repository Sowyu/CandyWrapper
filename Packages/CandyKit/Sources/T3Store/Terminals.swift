import Foundation
import T3Protocol

/// One thread's drawer as T3 keeps it (`ThreadTerminalUiState`, apps/web/src/terminalUiStateStore.ts):
/// whether it is open, its height and its terminals. Persisted per thread.
public struct TerminalDrawerState: Codable, Sendable, Equatable {
    /// `DEFAULT_THREAD_TERMINAL_HEIGHT` (web types.ts:34).
    public static let defaultHeight: CGFloat = 280
    /// `MIN_DRAWER_HEIGHT` and `MAX_DRAWER_HEIGHT_RATIO` (ThreadTerminalDrawer.tsx:99-100).
    public static let minHeight: CGFloat = 180
    public static let maxHeightRatio: CGFloat = 0.75

    public var open = false
    public var height: CGFloat = defaultHeight
    public var terminalIds: [String] = []
    public var activeTerminalId: String = ""

    public init(open: Bool = false, height: CGFloat = defaultHeight, terminalIds: [String] = [], activeTerminalId: String = "") {
        self.open = open; self.height = height; self.terminalIds = terminalIds; self.activeTerminalId = activeTerminalId
    }

    /// `clampDrawerHeight`: rounded, at least 180, at most 75% of the window (never under 180).
    public static func clampHeight(_ height: CGFloat, windowHeight: CGFloat) -> CGFloat {
        let safe = height.isFinite ? height : defaultHeight
        let maxHeight = max(minHeight, (windowHeight * maxHeightRatio).rounded(.down))
        return min(max(safe.rounded(), minHeight), maxHeight)
    }

    /// The terminal the drawer shows: the active one if it still exists, else the first.
    public var resolvedActiveId: String? {
        terminalIds.contains(activeTerminalId) ? activeTerminalId : terminalIds.first
    }

    /// `ensureTerminal` with `open: true`: adds the id, makes it active and opens the drawer.
    public mutating func ensure(_ terminalId: String) {
        if !terminalIds.contains(terminalId) { terminalIds.append(terminalId) }
        activeTerminalId = terminalId
        open = true
    }

    /// `closeThreadTerminal`: the last terminal resets the drawer to its default (closed, default
    /// height); otherwise the neighbor at the closed one's index becomes active.
    public mutating func close(_ terminalId: String) {
        guard let index = terminalIds.firstIndex(of: terminalId) else { return }
        terminalIds.remove(at: index)
        if terminalIds.isEmpty { self = TerminalDrawerState(); return }
        if activeTerminalId == terminalId { activeTerminalId = terminalIds[min(index, terminalIds.count - 1)] }
    }
}

/// Which threads have a terminal with a running subprocess, from `subscribeTerminalMetadata`
/// (`selectRunningSubprocessTerminalIds`). Feeds the sidebar's terminal indicator.
public struct TerminalActivity: Sendable, Equatable {
    public private(set) var terminals: [String: TerminalSummary] = [:]

    public init() {}

    private static func key(_ threadId: String, _ terminalId: String) -> String { threadId + "\u{0}" + terminalId }

    /// Applies one metadata event; returns whether the running set changed.
    @discardableResult
    public mutating func apply(_ event: TerminalMetadataEvent) -> Bool {
        let before = runningThreads
        switch event {
        case .snapshot(let list):
            terminals = Dictionary(list.map { (Self.key($0.threadId, $0.terminalId), $0) }) { $1 }
        case .upsert(let summary):
            terminals[Self.key(summary.threadId, summary.terminalId)] = summary
        case .remove(let threadId, let terminalId):
            terminals[Self.key(threadId, terminalId)] = nil
        }
        return runningThreads != before
    }

    /// Local thread id to its count of terminals running a subprocess.
    public var runningThreads: [String: Int] {
        var counts: [String: Int] = [:]
        for summary in terminals.values where summary.hasRunningSubprocess { counts[summary.threadId, default: 0] += 1 }
        return counts
    }

    public func summary(threadId: String, terminalId: String) -> TerminalSummary? {
        terminals[Self.key(threadId, terminalId)]
    }

    /// A thread's terminals the server knows, in T3's numeric id order.
    public func terminalIds(threadId: String) -> [String] {
        terminals.values.filter { $0.threadId == threadId }.map(\.terminalId)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// What the renderer does with one attach event.
public enum TerminalRenderAction: Sendable, Equatable {
    /// Clear the screen and scrollback, then write (a snapshot's history, a restart, a clear).
    case reset(String)
    case write(String)
    /// `writeSystemMessage`: "\r\n[terminal] message\r\n".
    case message(String)
}

/// The attach stream's state machine (client-runtime terminalSession.ts `applyTerminalAttachStreamEvent`
/// plus the drawer's exit handling in ThreadTerminalDrawer.tsx `synchronizeTerminalStatus`).
public struct TerminalSessionModel: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case closed, starting, running, exited, error }

    public private(set) var status: Status = .closed
    public private(set) var label = ""
    public private(set) var hasRunningSubprocess = false
    /// Events applied since the attach began (`version`); 0 before the first snapshot.
    public private(set) var version = 0
    private var exitHandled = false

    public init() {}

    /// The server accepts `terminal.resize` only for a running session the client has seen.
    public var canResize: Bool { version > 0 && status == .running }

    public struct Outcome: Sendable, Equatable {
        public var actions: [TerminalRenderAction] = []
        /// The process ended or the server closed the session: the drawer closes the terminal.
        public var sessionEnded = false
        /// The session (re)started: resend the grid size.
        public var resendSize = false
    }

    public mutating func apply(_ event: TerminalAttachEvent) -> Outcome {
        var out = Outcome()
        switch event {
        case .snapshot(let snapshot), .restarted(let snapshot):
            status = Status(snapshot.status)
            label = snapshot.label
            out.actions.append(.reset(snapshot.history))
            out.resendSize = status == .running
        case .output(let data):
            if status == .closed { status = .running; out.resendSize = true }
            out.actions.append(.write(data))
        case .cleared:
            out.actions.append(.reset(""))
        case .exited:
            status = .exited
        case .closed:
            status = .closed
        case .error(let message):
            status = .error
            out.actions.append(.message(message))
        case .activity(let running, let newLabel):
            hasRunningSubprocess = running
            label = newLabel
            return out
        case .unknown:
            return out
        }
        version += 1
        // `shouldHandleTerminalExit`: once per exit, and a running session re-arms it.
        if status == .running {
            exitHandled = false
        } else if (status == .exited || status == .closed) && !exitHandled {
            exitHandled = true
            out.actions.append(.message(status == .closed ? "Terminal closed" : "Process exited"))
            out.sessionEnded = true
        }
        return out
    }

    /// The renderer's bytes for a system message.
    public static func messageText(_ message: String) -> String { "\r\n[terminal] \(message)\r\n" }
}

extension TerminalSessionModel.Status {
    init(_ status: TerminalSessionStatus) {
        switch status {
        case .starting: self = .starting
        case .running: self = .running
        case .exited: self = .exited
        case .error: self = .error
        }
    }
}
