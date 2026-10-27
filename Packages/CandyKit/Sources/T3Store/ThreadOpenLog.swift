import Foundation
import T3Protocol

/// `claimThreadOpen` (packages/client-runtime/src/state/threadSearch.ts:24-44): when this client last opened each
/// thread, and last sent an open, by its own clock. The server merges opens closer together than ten minutes, so
/// skipping them saves a command and a broadcast while flipping between threads.
@MainActor public enum ThreadOpenLog {
    /// `THREAD_OPEN_DEDUPE_MS` (paletteSearch.ts:722).
    public static let dedupeMs = 10.0 * 60 * 1000
    private static var sent: [ThreadId: Double] = [:]
    private static var local: [ThreadId: Double] = [:]

    /// Records an open and says whether to send it to the server now.
    public static func claim(_ id: ThreadId, now: Double) -> Bool {
        local[id] = now
        if let last = sent[id], now - last < dedupeMs { return false }
        sent[id] = now
        return true
    }

    /// This client's latest open, sent or not, so recent threads follow quick switches the server merges.
    public static func localOpenedAt(_ id: ThreadId) -> Double? { local[id] }
}
