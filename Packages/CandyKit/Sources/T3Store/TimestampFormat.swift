import Foundation
import T3Protocol

/// Relative time labels, ported from apps/web/src/timestampFormat.ts. Every function takes `now`
/// explicitly; the JS versions read `Date.now()`. Wall-clock formats (`formatShortTimestamp`,
/// `formatDayAwareTimestamp`) are locale work for the UI layer and are not ported here.
public enum TimestampFormat {
    public struct RelativeTimeParts: Equatable, Sendable {
        public var value: String
        public var suffix: String?
    }

    public enum RelativeTimeState: Equatable, Sendable {
        case missing
        case invalid
        case relative(value: String, suffix: String?)
    }

    public static func nowMs(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// `formatRelativeTime` (timestampFormat.ts:235-248).
    public static func formatRelativeTime(_ iso: String, nowMs: Int64) -> RelativeTimeParts? {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return nil }
        let diffMs = nowMs - ms
        if diffMs < 0 { return RelativeTimeParts(value: "just now", suffix: nil) }
        let seconds = diffMs / 1000
        if seconds < 60 { return RelativeTimeParts(value: "just now", suffix: nil) }
        let minutes = seconds / 60
        if minutes < 60 { return RelativeTimeParts(value: "\(minutes)m", suffix: "ago") }
        let hours = minutes / 60
        if hours < 24 { return RelativeTimeParts(value: "\(hours)h", suffix: "ago") }
        return RelativeTimeParts(value: "\(hours / 24)d", suffix: "ago")
    }

    /// `formatRelativeTimeLabel` (timestampFormat.ts:250-254).
    public static func formatRelativeTimeLabel(_ iso: String, nowMs: Int64) -> String {
        guard let relative = formatRelativeTime(iso, nowMs: nowMs) else { return "" }
        return relative.suffix.map { "\(relative.value) \($0)" } ?? relative.value
    }

    /// `getRelativeTimeState` (timestampFormat.ts:256-261).
    public static func getRelativeTimeState(_ iso: String?, nowMs: Int64) -> RelativeTimeState {
        guard let iso, !iso.isEmpty else { return .missing }
        guard let relative = formatRelativeTime(iso, nowMs: nowMs) else { return .invalid }
        return .relative(value: relative.value, suffix: relative.suffix)
    }

    /// `formatElapsedDurationLabel` (timestampFormat.ts:267-284).
    public static func formatElapsedDurationLabel(_ iso: String, nowMs: Int64) -> String {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return "" }
        let diffMs = nowMs - ms
        if diffMs <= 0 { return "just now" }
        let seconds = diffMs / 1000
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// `formatRelativeTimeUntil` (timestampFormat.ts:289-302).
    public static func formatRelativeTimeUntil(_ iso: String, nowMs: Int64) -> RelativeTimeParts? {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return nil }
        let diffMs = ms - nowMs
        if diffMs <= 0 { return RelativeTimeParts(value: "Expired", suffix: nil) }
        let seconds = diffMs / 1000
        if seconds < 5 { return RelativeTimeParts(value: "Soon", suffix: nil) }
        if seconds < 60 { return RelativeTimeParts(value: "\(seconds)s", suffix: "left") }
        let minutes = seconds / 60
        if minutes < 60 { return RelativeTimeParts(value: "\(minutes)m", suffix: "left") }
        let hours = minutes / 60
        if hours < 24 { return RelativeTimeParts(value: "\(hours)h", suffix: "left") }
        return RelativeTimeParts(value: "\(hours / 24)d", suffix: "left")
    }

    /// `formatRelativeTimeUntilLabel` (timestampFormat.ts:304-308).
    public static func formatRelativeTimeUntilLabel(_ iso: String, nowMs: Int64) -> String {
        guard let relative = formatRelativeTimeUntil(iso, nowMs: nowMs) else { return "" }
        return relative.suffix.map { "\(relative.value) \($0)" } ?? relative.value
    }

    /// `formatExpiresInLabel` (timestampFormat.ts:314-355).
    public static func formatExpiresInLabel(_ iso: String, nowMs: Int64) -> String {
        guard let ms = T3Timestamp.parseEpochMs(iso) else { return "" }
        let diffMs = ms - nowMs
        if diffMs <= 0 { return "Expired" }
        let total = diffMs / 1000
        if total < 5 { return "Expires in a moment" }
        if total < 60 { return "Expires in \(total)s" }
        if total < 3600 {
            let minutes = total / 60, seconds = total % 60
            return seconds == 0 ? "Expires in \(minutes)m" : "Expires in \(minutes)m \(seconds)s"
        }
        func tail(_ rem: Int64) -> [String] {
            var parts: [String] = []
            if rem / 3600 > 0 { parts.append("\(rem / 3600)h") }
            if rem % 3600 / 60 > 0 { parts.append("\(rem % 3600 / 60)m") }
            if rem % 60 > 0 { parts.append("\(rem % 60)s") }
            return parts
        }
        if total < 86_400 {
            // Hours are always shown here, even when zero minutes and seconds follow.
            var parts = ["\(total / 3600)h"]
            parts += tail(total % 3600)
            return "Expires in \(parts.joined(separator: " "))"
        }
        let days = total / 86_400
        let rest = tail(total % 86_400)
        return rest.isEmpty ? "Expires in \(days)d" : "Expires in \(days)d \(rest.joined(separator: " "))"
    }

    /// `compactSidebarTimeLabel` (apps/web/src/components/Sidebar.tsx:327-330).
    public static func compactSidebarTimeLabel(_ label: String) -> String {
        if label == "just now" { return "now" }
        return label.hasSuffix(" ago") ? String(label.dropLast(4)) : label
    }
}
