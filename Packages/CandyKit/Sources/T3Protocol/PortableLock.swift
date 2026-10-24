import Foundation

#if canImport(os)
import os
/// `OSAllocatedUnfairLock` on Apple platforms; the Linux helper gets an NSLock with the same calls.
package typealias PortableLock<State> = OSAllocatedUnfairLock<State>
#else
package final class PortableLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    package init(initialState: State) { state = initialState }
    package func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
#endif
