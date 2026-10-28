import Foundation

/// Native recovery for T3 3814 lib/bootError.ts:15-35,38-48,80-150,260-390.
public enum StartupRecovery {
    public static let issueURL = URL(string: "https://github.com/Sowyu/CandyWrapper/issues/new")!
    public static let downloadURL = URL(string: "https://github.com/Sowyu/CandyWrapper/releases/latest")!

    public static func repeats(previous: Date?, now: Date) -> Bool {
        previous.map { now >= $0 && now.timeIntervalSince($0) < 300 } ?? false
    }

    public static func triageCommand(launcher: String?, home: String, userHome: String, path: String) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let cli = launcher.map(quote) ?? "npx t3"
        // Keep inherited service variables out and diagnose this app's home, including sandbox homes.
        return "env -i HOME=\(quote(userHome)) PATH=\(quote(path)) \(cli) triage --base-dir \(quote(home))"
    }

    public static func redacted(_ text: String, userHome: String = NSHomeDirectory()) -> String {
        var result = ConnectionDiagnosis.redacted(text)
        for (pattern, replacement) in [
            (#"(?i)\b[a-z][\w+.-]*://[^\s/?#'"()]+"#, "[origin]"),
            (#"[?#][^\s'"()]*=[^\s'"()]*"#, "[parameters]"),
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]")
        ] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        if !userHome.isEmpty { result = result.replacingOccurrences(of: userHome, with: "~") }
        return result
    }

    public static func report(_ error: Error, version: String, runtimeVersion: String?, now: Date = Date(), userHome: String = NSHomeDirectory()) -> String {
        var parts: [String] = []
        var seen: Set<ObjectIdentifier> = []
        var current: NSError? = error as NSError
        while let cause = current, parts.count < 4, seen.insert(ObjectIdentifier(cause)).inserted {
            let description = parts.isEmpty ? String(describing: error) : cause.localizedDescription
            parts.append((parts.isEmpty ? "" : "Caused by: ") + description)
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let safe = redacted(parts.joined(separator: "\n"), userHome: userHome)
        let detail = String(safe.prefix(6_000)) + (safe.count > 6_000 ? "\n[truncated]" : "")
        return [detail, "", "CandyWrapper: \(version)", "T3 runtime: \(runtimeVersion ?? "unknown")",
                "Surface: native macOS", "Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "Time: \(ISO8601DateFormatter().string(from: now))"].joined(separator: "\n")
    }

    public enum UpdateAction: Equatable, Sendable {
        case download, downloading(Int), install
        public var title: String {
            switch self {
            case .download: "Download update"
            case .downloading(let percent): "Downloading update (\(percent)%)"
            case .install: "Restart to update"
            }
        }
    }

    public static func updateAction(_ state: DesktopUpdateState?) -> UpdateAction? {
        guard let state, state.enabled else { return nil }
        switch state.status {
        case .available: return .download
        case .downloading:
            let progress = state.downloadPercent ?? 0
            return .downloading(progress.isFinite ? Int(min(100, max(0, progress)).rounded()) : 0)
        case .downloaded: return .install
        default: return nil
        }
    }
}
