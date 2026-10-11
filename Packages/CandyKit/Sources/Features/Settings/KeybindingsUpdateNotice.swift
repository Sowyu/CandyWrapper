import Foundation

/// KeybindingsUpdateToast.logic.ts:3-48: successes coalesce for two seconds; errors never do.
public struct KeybindingsUpdateNotice: Sendable {
    private var lastSuccess: TimeInterval?
    public init() {}
    public mutating func shouldShowSuccess(now: TimeInterval) -> Bool {
        if let lastSuccess, now - lastSuccess < 2 { return false }
        lastSuccess = now
        return true
    }
}
