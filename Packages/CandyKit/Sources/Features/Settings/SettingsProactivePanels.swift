import Foundation

/// ChatView.logic.ts:117-207 and ChatView.tsx:5740-5835. Observe once, defer until the checkpoint arrives,
/// and never override a panel choice made after the turn began.
public struct SettingsProactivePanels: Sendable {
    public enum Action: Equatable, Sendable { case none, pullRequest, diff }
    private var thread: String?
    private var running: String?
    private var first = true
    private var target: String?
    private var revision = 0
    private var handled: String?
    public init() {}
    public mutating func update(thread: String, running: String?, settled: String?, completed: Bool, linkedTarget: String?,
                                revision: Int, enabled: Bool, checkpointStatus: String?, fileCount: Int, changedLines: Int,
                                isRepository: Bool?, activeSurface: String?) -> Action {
        if self.thread != thread {
            self = Self(); self.thread = thread; self.revision = revision
        } else if let running, running != self.running { self.revision = revision }
        let mayOpen = enabled && self.revision == revision
        if linkedTarget != target {
            target = linkedTarget
            if linkedTarget != nil, mayOpen { self.running = running; first = false; return .pullRequest }
        }
        let eligible = running == nil && completed && settled != nil && settled != handled && (first || settled == self.running)
        if eligible, mayOpen, linkedTarget == nil, activeSurface != "diff", activeSurface != "pullRequest" {
            if checkpointStatus == nil || checkpointStatus == "missing" || isRepository == nil { return .none }
            handled = settled
            self.running = running; first = false
            if isRepository == true, checkpointStatus == "ready", fileCount > 0, fileCount >= 3 || changedLines >= 50 { return .diff }
        }
        self.running = running; first = false
        return .none
    }
}
