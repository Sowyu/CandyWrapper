import Foundation

/// requestLatencyState.ts:6-62. Deadlines exist only while tracked unary calls are in flight.
@MainActor
public final class SlowRPCRequestTracker {
    public struct Request: Sendable, Equatable {
        public let id: UUID
        public let method: String
        public let startedAt: Date
        public let threshold: TimeInterval
    }
    public static let shared = SlowRPCRequestTracker()
    public static let didChange = Notification.Name("SlowRPCRequestTracker.didChange")
    public private(set) var slow: [Request] = []
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var order: [UUID] = []

    public nonisolated static func threshold(for method: String) -> TimeInterval? {
        guard !method.contains("subscribe"), !method.hasPrefix("pullRequests."), !["server.getUsageSummary", "server.reportClientActivity"].contains(method) else { return nil }
        return ["server.updateProvider", "server.refreshProviders", "server.updateServer", "vcs.refreshStatus"].contains(method) ? 120 : 15
    }
    public func start(id: UUID, method: String) {
        guard let threshold = Self.threshold(for: method) else { return }
        if order.count >= 256, let oldest = order.first { finish(id: oldest) }
        order.append(id)
        let request = Request(id: id, method: method, startedAt: Date(), threshold: threshold)
        pending[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(threshold)) } catch { return }
            guard let self, pending.removeValue(forKey: id) != nil else { return }
            slow.append(request)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    public func finish(id: UUID) {
        pending.removeValue(forKey: id)?.cancel()
        order.removeAll { $0 == id }
        if slow.contains(where: { $0.id == id }) {
            slow.removeAll { $0.id == id }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
