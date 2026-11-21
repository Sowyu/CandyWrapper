import Foundation

/// One explicit footer check. Every source finishes before the result is announced.
@MainActor
public final class SidebarUpdateCheck {
    /// `busy`: nothing failed, but a check or download already under way answered instead of a new check.
    public enum State: Equatable { case idle, checking, updatesAvailable, upToDate, failed, busy }

    /// What one source reports.
    public enum Outcome: Equatable, Sendable {
        case checked
        /// A check or download is already running there, so this one was not started. Not a failure.
        case busy
        /// The app's own update check failed, with the updater's reason when it gave one.
        case appFailed(reason: String?)
        /// The server or provider check failed on this machine, by its name.
        case machineFailed(String)
    }

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }
    /// The failed sources of the last run, in order, one per app or machine.
    public private(set) var failures: [Outcome] = []
    public var onChange: ((State) -> Void)?
    public init() {}

    public func run(checks: [@MainActor @Sendable () async -> [Outcome]], hasUpdates: () -> Bool) async {
        guard state != .checking else { return }
        state = .checking
        let outcomes = await withTaskGroup(of: (Int, [Outcome]).self) { group in
            for (i, check) in checks.enumerated() { group.addTask { (i, await check()) } }
            var all: [(Int, [Outcome])] = []
            for await result in group { all.append(result) }
            return all.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var failed: [Outcome] = []
        for o in outcomes where o != .checked && o != .busy && !failed.contains(o) { failed.append(o) }
        failures = failed
        // A partial failure must never claim that everything is current.
        state = !failed.isEmpty ? .failed : outcomes.contains(.busy) ? .busy : hasUpdates() ? .updatesAvailable : .upToDate
    }

    /// The toast for a failed run, after T3's "Could not check for updates" (SidebarUpdatePill.tsx:351), naming
    /// what failed: the app's own check, or the machines whose server check failed.
    public static func failureCopy(_ failures: [Outcome]) -> (title: String, message: String?) {
        var machines: [String] = []
        var app: String?? = nil
        for f in failures {
            switch f {
            case .appFailed(let reason): app = .some(reason)
            case .machineFailed(let name): if !machines.contains(name) { machines.append(name) }
            case .checked, .busy: break
            }
        }
        let appLine = app.map { reason in reason.map { "This app's own update check failed: \($0)" } ?? "This app's own update check failed." }
        guard !machines.isEmpty else { return ("Could not check for updates", appLine) }
        let names = machines.count == 1 ? machines[0] : machines.dropLast().joined(separator: ", ") + " and " + machines.last!
        let retry = machines.count == 1 ? "Try again once it is reachable." : "Try again once they are reachable."
        return ("Could not check updates on \(names)", appLine.map { "\($0) \(retry)" } ?? retry)
    }
}
