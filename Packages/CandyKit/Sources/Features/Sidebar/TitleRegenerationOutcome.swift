import DesignSystem
import T3Protocol

/// Title regeneration outcomes (#31418 at 4928): what a `regenerateTitle` request ended as, read from the thread's
/// `lastTitleRegeneration` (threadTitleRegeneration.ts), and the toast T3 shows for them (threadTitleRegenerationToast.ts).
public enum TitleRegenerationOutcome: Equatable, Sendable {
    /// The dispatch failed with this message.
    case failure(String)
    /// The server reported `renamed`, `unchanged` or `failed`.
    case reported(status: String, message: String?)
    /// The server finished without reporting, as servers before 4928 do, or the thread went away.
    case unreported

    /// `settledOutcome`: nil while the request may still run. `seenPending` says the thread showed this request
    /// running; without it a thread that shows neither is still waiting for the server to take the request.
    public static func settled(_ thread: ThreadShell?, requestId: String, seenPending: Bool) -> TitleRegenerationOutcome? {
        guard let thread else { return .unreported }
        if let last = thread.lastTitleRegeneration, last.requestId == requestId { return .reported(status: last.status, message: last.message) }
        if thread.titleRegeneration?.requestId == requestId { return nil }
        return seenPending ? .unreported : nil
    }

    private var failureMessage: String? {
        switch self {
        case .failure(let message): message
        case .reported(let status, let message): status == "failed" ? message ?? "Title generation failed." : nil
        case .unreported: nil
        }
    }

    /// `titleRegenerationToast`: failures first, then kept titles; renamed ones show no toast.
    public static func toast(_ results: [TitleRegenerationOutcome]) -> (kind: ToastQueue.Kind, title: String, message: String)? {
        let failures = results.compactMap(\.failureMessage)
        if let first = failures.first {
            return (.error, results.count == 1 ? "Failed to regenerate thread title"
                        : "Failed to regenerate \(failures.count) of \(results.count) thread titles", first)
        }
        let kept = results.filter { if case .reported("unchanged", _) = $0 { true } else { false } }.count
        guard kept > 0 else { return nil }
        if results.count == 1 { return (.info, "Title kept", "The current title already fits this thread.") }
        return kept == results.count
            ? (.info, "Titles kept", "The current titles already fit these threads.")
            : (.info, "Kept \(kept) of \(results.count) titles", "Those titles already fit their threads.")
    }
}
