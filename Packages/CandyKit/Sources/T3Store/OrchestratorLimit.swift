import Foundation
import T3Protocol

/// The Orchestrator's provider hit a usage limit (docs/orchestrator.md, "When its provider is limited"). While it is
/// limited, the app and the helper hold events and send them once after the reset, instead of starting a run per event
/// that fails at once.
public enum OrchestratorLimit {
    /// How long to wait when no reset time is known: 15 min, 30 min, then hourly.
    public static let backoff: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60]

    /// Whether a failure is a usage limit: T3's failure class, else the provider's text.
    public static func isLimit(_ errorClass: ProviderFailureClass?, message: String?) -> Bool {
        if errorClass == .usageLimit { return true }
        guard errorClass == nil || errorClass == .unknown || errorClass == .providerError, let message else { return false }
        return message.range(of: #"hit your .*limit|usage limit|rate limit reached"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The thread's limit, if its last run failed on one: when it resets, from T3's `usageLimitResetAt` or the text.
    public static func of(_ thread: ThreadShell) -> (failedAt: Date?, reset: Date?)? {
        guard thread.status == .failed, isLimit(thread.lastErrorClass, message: thread.lastError) else { return nil }
        let failedAt = thread.latestRunCompletedAt.value?.date ?? thread.updatedAt.date
        let reset = thread.usageLimitResetAt?.date ?? thread.lastError.flatMap { resetTime(in: $0, after: failedAt ?? Date()) }
        return (failedAt, reset)
    }

    /// The first time after `after` that matches "resets 8pm (Europe/Paris)", "resets 7:30am" or "resets Oct 28, 8pm".
    /// Without a zone it reads the time in this Mac's.
    public static func resetTime(in message: String, after: Date) -> Date? {
        let pattern = /resets (?:(?<month>[A-Z][a-z]{2}) (?<day>\d{1,2}),? (?:at )?)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))? ?(?<ampm>am|pm)(?: \((?<zone>[^)]+)\))?/
        guard let m = message.firstMatch(of: pattern.ignoresCase()), var hour = Int(m.output.hour), hour <= 12 else { return nil }
        hour = hour % 12 + (m.output.ampm.lowercased() == "pm" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = m.output.zone.flatMap { TimeZone(identifier: String($0)) } ?? .current
        var c = calendar.dateComponents([.year, .month, .day], from: after)
        c.hour = hour
        c.minute = m.output.minute.flatMap { Int($0) } ?? 0
        if let month = m.output.month, let day = m.output.day.flatMap({ Int($0) }) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let index = f.shortMonthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(String(month)) == .orderedSame }) else { return nil }
            c.month = index + 1
            c.day = day
            guard let date = calendar.date(from: c) else { return nil }
            return date > after ? date : calendar.date(byAdding: .year, value: 1, to: date)
        }
        guard let date = calendar.date(from: c) else { return nil }
        return date > after ? date : calendar.date(byAdding: .day, value: 1, to: date)
    }

    /// "8pm", "7:30am", or "Tue 8pm" when it isn't today, in this Mac's time zone.
    public static func shortTime(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let minutes = Calendar.current.component(.minute, from: date) != 0
        f.dateFormat = (Calendar.current.isDate(date, inSameDayAs: now) ? "" : "EEE ") + (minutes ? "h:mma" : "ha")
        return f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }
}
