import Foundation
import T3Protocol

/// packages/client-runtime/src/load-balancing.ts:4-43. Receipt times avoid remote clock skew.
public enum ProviderLoadBalanceLogic {
    public struct Candidate: Sendable {
        public var id: String, resources: JSONValue
        public var receivedAt: Double, weight: Double
        public init(id: String, resources: JSONValue, receivedAt: Double, weight: Double) {
            self.id = id; self.resources = resources; self.receivedAt = receivedAt; self.weight = weight
        }
    }
    public static func choose(_ candidates: [Candidate], now: Double) -> String? {
        var selected: String?, best = 0.0
        for c in candidates {
            func n(_ key: String) -> Double? { c.resources[key]?.doubleValue }
            guard c.weight.isFinite, c.weight > 0, now - c.receivedAt <= 15000, c.receivedAt <= now + 5000,
                  let cpu = n("cpuUtilization"), cpu < 0.95, let total = n("totalMemoryBytes"), total > 0,
                  let available = n("availableMemoryBytes"), let count = n("cpuCount"), count > 0 else { continue }
            let memory = available / total
            guard memory > 0.05 else { continue }
            let score = c.weight * count * (1 - cpu) * memory
            if score > best { selected = c.id; best = score }
        }
        return selected
    }
}
