import Foundation

/// One explicit footer check. Every source finishes before the result is announced.
@MainActor
public final class SidebarUpdateCheck {
    public enum State: Equatable { case idle, checking, updatesAvailable, upToDate, failed }
    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }
    public var onChange: ((State) -> Void)?
    public init() {}

    public func run(checks: [@MainActor @Sendable () async -> Bool], hasUpdates: () -> Bool) async {
        guard state != .checking else { return }
        state = .checking
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for check in checks { group.addTask { await check() } }
            var succeeded = true
            for await result in group { if !result { succeeded = false } }
            return succeeded
        }
        // A partial failure must never claim that everything is current.
        state = !succeeded ? .failed : hasUpdates() ? .updatesAvailable : .upToDate
    }
}
