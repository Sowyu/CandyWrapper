import DesignSystem
import Foundation
import T3Protocol

/// An error that still holds the server's typed error, so a state can say what failed. The app's loaders wrap
/// `RPCClientError` in one, since Features never sees T3Client.
public protocol TypedErrorCarrying: Error {
    var typedError: RPCTypedError? { get }
}

/// Plain sentences for failures shown in a Redesign state: what failed and what to try. The raw tag and fields stay in
/// `details` for bug reports and never become the message.
public enum StateErrorText {
    /// The state for `error`, under `title` (what was being done, such as "Could not load changes") unless the error
    /// has a sharper one.
    public static func describe(_ error: Error, title: String, icon: IconName = .circleAlert) -> StateCopy {
        if let typed = error as? RPCTypedError { return describe(typed: typed, title: title, icon: icon) }
        if let carrier = error as? TypedErrorCarrying, let typed = carrier.typedError { return describe(typed: typed, title: title, icon: icon) }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return describe(raw: text, title: title, icon: icon)
    }

    /// The state for text the request failed with when no typed error is left: a server-written sentence is kept, a
    /// bare type name or code goes to `details`.
    public static func describe(raw: String?, title: String, icon: IconName = .circleAlert) -> StateCopy {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return StateCopy(title: title, detail: generic, icon: icon) }
        if isTypeName(text) { return StateCopy(title: title, detail: generic, icon: icon, details: text) }
        return StateCopy(title: title, detail: sentence(text), icon: icon)
    }

    public static func describe(typed e: RPCTypedError, title: String, icon: IconName = .circleAlert) -> StateCopy {
        let raw = details(e)
        func f(_ k: String) -> String? { e.fields[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        let place = f("cwd").map { " in \($0)" } ?? ""
        func copy(_ t: String, _ d: String, _ i: IconName = icon) -> StateCopy { StateCopy(title: t, detail: d, icon: i, details: raw) }
        switch e.tag {
        case "VcsProcessSpawnError":
            return copy("Git could not start", "Git could not be started\(place). Check that git is installed and the folder still exists, then retry.", .gitBranch)
        case "VcsProcessExitError":
            switch f("failureKind") {
            case "authentication": return copy("Git could not sign in", "The remote refused git's credentials\(place). Sign in again, then retry.", .lock)
            case "rate-limited": return copy("Rate limited", "The remote's API rate limit was reached. Wait a minute, then retry.", .clock)
            case "not-found": return copy(title, sentence(f("detail") ?? "Git could not find what it was asked for\(place)."))
            default:
                let code = e.fields["exitCode"]?.doubleValue.map { " with code \(Int($0))" } ?? ""
                return copy(title, "Git exited\(code)\(place). Retry, or open Details for git's output.")
            }
        case "VcsProcessTimeoutError":
            return copy("Git timed out", "Git took too long to answer\(place). Retry in a moment.", .clock)
        case "VcsProcessOutputLimitError":
            return copy("Too large to show", "Git's output was larger than the server allows. Narrow the selection, then retry.")
        case "VcsProcessStdinWriteError", "VcsProcessOutputReadError", "VcsProcessMissingExitCodeError":
            return copy(title, "Git stopped before it finished\(place). Retry.")
        case "VcsRepositoryDetectionError":
            return copy("Not a git repository", "\(f("cwd") ?? "This folder") is not inside a git repository, so there are no changes to show.", .folderGit)
        case "VcsUnsupportedOperationError":
            return copy("Not supported here", sentence(f("detail") ?? "This repository does not support this operation."))
        case "VcsCheckpointStorageError":
            return copy(title, "The server could not store this turn's checkpoint\(place). Retry.")
        case "GitCommandError", "GitManagerError":
            return copy(title, sentence(f("detail") ?? "A git command failed\(place). Retry."))
        case "EnvironmentRpcUnavailableError":
            return copy("Not connected", "The environment is not connected. It reconnects on its own. Retry once it is back.", .unplug)
        default:
            if let m = e.message, !isTypeName(m) { return copy(title, sentence(m)) }
            return copy(title, generic)
        }
    }

    /// For a failure nobody explained.
    public static let generic = StateCopy.unexplained

    /// The raw text kept for a bug report: the tag, then each field.
    public static func details(_ e: RPCTypedError) -> String {
        let fields = e.fields.keys.sorted().compactMap { k -> String? in
            guard let v = e.fields[k] else { return nil }
            return "\(k): \(v.stringValue ?? compact(v))"
        }
        return ([e.tag] + fields).joined(separator: "\n")
    }

    static func compact(_ v: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }

    public static func isTypeName(_ s: String) -> Bool { StateCopy.isTypeName(s) }

    /// Ends the text with a full stop.
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?…".contains(last) ? t : t + "."
    }
}
