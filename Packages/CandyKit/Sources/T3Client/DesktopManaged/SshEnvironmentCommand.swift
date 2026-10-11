import Foundation
import CryptoKit

/// packages/ssh/src/command.ts:41-117. Only resolved values are persisted, never passwords.
public struct SshEnvironmentTarget: Codable, Equatable, Sendable {
    public var alias: String
    public var hostname: String
    public var username: String?
    public var port: Int?
    public init(alias: String, hostname: String? = nil, username: String? = nil, port: Int? = nil) throws {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !alias.hasPrefix("-"), !alias.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
              username.map({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("@") && !$0.contains(where: { $0.isWhitespace || $0 == "\0" }) }) ?? true,
              port.map({ (1...65535).contains($0) }) ?? true else { throw SshEnvironmentError("SSH target is invalid.") }
        self.alias = alias; self.hostname = hostname ?? alias; self.username = username; self.port = port
    }
    /// `parseManualDesktopSshTarget` (ConnectionsSettings.tsx:273-327): `user@host`, `host:port` and
    /// `[v6]:port` in the host field; the Username and Port fields win over them.
    public static func manual(host: String, username: String, port: String) throws -> Self {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw SshEnvironmentError("SSH host or alias is required.") }
        var user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedPort: Int?
        if let at = host.lastIndex(of: "@"), at > host.startIndex {
            let inline = host[..<at].trimmingCharacters(in: .whitespaces)
            host = host[host.index(after: at)...].trimmingCharacters(in: .whitespaces)
            if user.isEmpty { user = inline }
        }
        if let m = host.wholeMatch(of: /\[([^\]]+)\](?::(\d+))?/) {
            parsedPort = m.2.flatMap { Int($0) }
            host = m.1.trimmingCharacters(in: .whitespaces)
        } else {
            let parts = host.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCII), let value = Int(parts[1]) {
                host = parts[0].trimmingCharacters(in: .whitespaces); parsedPort = value
            }
        }
        let rawPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawPort.isEmpty {
            // `Number.parseInt` reads the leading digits; anything else is out of range.
            parsedPort = Int(rawPort.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
        guard !host.isEmpty else { throw SshEnvironmentError("SSH host or alias is required.") }
        if let parsedPort, !(1...65535).contains(parsedPort) { throw SshEnvironmentError("SSH port must be between 1 and 65535.") }
        return try Self(alias: host, username: user.isEmpty ? nil : user, port: parsedPort)
    }
    /// `formatDesktopSshTarget` (EnvironmentRow.tsx:16-19): `user@hostname:port`.
    public var display: String {
        let authority = username.map { "\($0)@\(hostname)" } ?? hostname
        return port.map { "\(authority):\($0)" } ?? authority
    }
    /// The route's label (routes.ts:180-185): `SSH user@hostname`.
    public var routeLabel: String { "SSH " + (username.map { "\($0)@" } ?? "") + hostname }
    /// Applies `ssh -G`'s answer the way `ensureEnvironment` does (tunnel.ts:1690-1695): its hostname, and
    /// its user and port unless this target names them.
    public func merging(resolved: Self) -> Self {
        var merged = resolved
        merged.alias = alias
        if let username { merged.username = username }
        if let port { merged.port = port }
        return merged
    }
    public var destination: String { username.map { "\($0)@\(alias)" } ?? alias }
    public var stateKey: String {
        let key = [alias, hostname, username ?? "", port.map(String.init) ?? ""].joined(separator: "\0")
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public static func resolved(alias: String, output: String) throws -> Self {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count > 1, values[String(words[0])] == nil else { continue }
            values[String(words[0])] = words.dropFirst().joined(separator: " ")
        }
        return try Self(alias: alias, hostname: values["hostname"], username: values["user"], port: values["port"].flatMap(Int.init))
    }
}

public struct SshEnvironmentError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
    public var isAuthenticationFailure: Bool {
        let s = description.lowercased()
        return s.contains("authentication failed") || s.contains("too many authentication failures") ||
            s.range(of: #"permission denied \((?:publickey|password|keyboard-interactive|hostbased|gssapi-with-mic)[^)]*\)"#, options: .regularExpression) != nil
    }
}

public enum SshEnvironmentCommand {
    public static func base(_ target: SshEnvironmentTarget, interactive: Bool = false) -> [String] {
        ["-o", "BatchMode=\(interactive ? "no" : "yes")", "-o", "ConnectTimeout=10"] + (target.port.map { ["-p", String($0)] } ?? [])
    }
    public static func resolve(_ alias: String) throws -> [String] {
        let target = try SshEnvironmentTarget(alias: alias)
        return base(target) + ["-G", target.destination]
    }
    public static func launch(_ target: SshEnvironmentTarget, interactive: Bool) -> [String] {
        base(target, interactive: interactive) + [target.destination, "sh", "-l", "-s", "--", target.stateKey]
    }
    public static func pairing(_ target: SshEnvironmentTarget, interactive: Bool) -> [String] {
        base(target, interactive: interactive) + [target.destination, "sh", "-s"]
    }
    public static func tunnel(_ target: SshEnvironmentTarget, localPort: Int, remotePort: Int, interactive: Bool) throws -> [String] {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort) else { throw SshEnvironmentError("Invalid SSH tunnel port.") }
        return base(target, interactive: interactive) + ["-o", "ExitOnForwardFailure=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-n", "-N", "-L", "\(localPort):127.0.0.1:\(remotePort)", target.destination]
    }
    /// `ASKPASS_POSIX_SCRIPT` (auth.ts:74-84). It holds no secret: ssh runs it with the password in its
    /// environment (`T3_SSH_AUTH_SECRET`), never on a command line or on disk.
    public static let askpassScript = #"""
#!/bin/sh
# Invoked by ssh via SSH_ASKPASS when T3 Code re-runs ssh with a cached password
# from the renderer's in-app prompt. We never expose a native dialog here - if
# T3_SSH_AUTH_SECRET is missing, that's a caller bug and we fail loudly.
if [ "${T3_SSH_AUTH_SECRET+x}" = "x" ]; then
  printf "%s\n" "$T3_SSH_AUTH_SECRET"
  exit 0
fi
printf 'T3 Code ssh-askpass invoked without T3_SSH_AUTH_SECRET.\n' >&2
exit 1

"""#
    /// `buildSshChildEnvironment` (auth.ts:166-198). Drops the live service's `T3_*` and `T3CODE_*` variables
    /// (CLAUDE.md) and any inherited askpass setting.
    public static func childEnvironment(base: [String: String], helper: String?, password: String?) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("T3_") && !$0.key.hasPrefix("T3CODE_") && !$0.key.hasPrefix("SSH_ASKPASS") }
        if let helper, let password {
            env["SSH_ASKPASS"] = helper; env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? "t3code"; env["T3_SSH_AUTH_SECRET"] = password
        }
        return env
    }
    /// `EXACT_ARCHIVE_VERSION` (tunnel.ts:779-780): one SemVer segment, safe as a directory name and in quotes.
    static var exactVersion: Regex<Substring> { #/(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/# }
    /// The launch, pairing and stop scripts in archive mode (tunnel.ts:791-853): the remote downloads the
    /// pinned release and uses the helpers inside it, so it needs no Node.
    public static func scripts(version: String, stateKey: String) throws -> (launch: String, pairing: String, stop: String) {
        guard version.wholeMatch(of: exactVersion) != nil,
              stateKey.range(of: #"^[a-f0-9]{16}$"#, options: .regularExpression) != nil else { throw SshEnvironmentError("Invalid SSH runtime version or state key.") }
        func replace(_ text: String, _ values: [String: String]) -> String {
            values.reduce(text) { $0.replacingOccurrences(of: "@@\($1.key)@@", with: $1.value) }
        }
        // `stripTrailingNewlines` (tunnel.ts:229-231) on every nested script.
        func strip(_ text: String) -> String { String(text.reversed().drop { $0 == "\n" }.reversed()) }
        // ponytail: the archive runner leaves out T3's node-env prelude (only a dev-mode node runner calls it, and its
        // engine check is a serialized JS function), so the remote run-t3.sh differs from the official app's and a
        // managed server one app started restarts once when the other connects. Port the prelude if that matters.
        let runner = strip(replace(SshRemoteScripts.REMOTE_RUNNER_SCRIPT, [
            "T3_NODE_ENV_SCRIPT": "", "T3_NODE_SCRIPT_PATH": "''", "T3_ARCHIVE_VERSION": "'\(version)'",
            "T3_RELEASE_BASE_URL": "'https://github.com/pingdotgg/t3code/releases/download'",
            "T3_ARCHIVE_LOCK_WAIT_SECONDS": "360", "T3_ARCHIVE_DOWNLOAD_SECONDS": "240", "T3_ARCHIVE_CHECKSUMS_SECONDS": "30"]))
        let launch = replace(SshRemoteScripts.REMOTE_LAUNCH_SCRIPT, [
            "T3_NODE_ENV_SCRIPT": "", "T3_ARCHIVE_MODE": "1", "T3_RUNNER_SCRIPT": runner,
            "T3_PICK_PORT_SCRIPT": strip(SshRemoteScripts.REMOTE_PICK_PORT_SCRIPT), "T3_WAIT_READY_SCRIPT": strip(SshRemoteScripts.REMOTE_WAIT_READY_SCRIPT),
            "T3_DEFAULT_REMOTE_PORT": "3773", "T3_REMOTE_PORT_SCAN_WINDOW": "200", "T3_READY_TIMEOUT_MS": "60000",
            "T3_REUSE_READY_TIMEOUT_MS": "2000", "T3_READY_PROBE_TIMEOUT_MS": "1000"])
        return (launch, replace(SshRemoteScripts.REMOTE_PAIRING_SCRIPT, ["T3_STATE_KEY": stateKey, "T3_RUNNER_SCRIPT": runner]),
                replace(SshRemoteScripts.REMOTE_STOP_SCRIPT, ["T3_STATE_KEY": stateKey]))
    }
    /// The last non-empty stdout line as JSON (`getLastNonEmptyOutputLine`, command.ts:117-125); login banners come first.
    public static func lastJSON<T: Decodable>(_ output: String, as: T.Type) throws -> T {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let data = String(line).data(using: .utf8), let value = try? JSONDecoder().decode(T.self, from: data) else { throw SshEnvironmentError("SSH returned unparseable output.") }
        return value
    }
    /// `redactSshErrorOutput` (command.ts:139-147).
    public static func diagnostic(_ text: String) -> String {
        let redacted = text.replacingOccurrences(of: #"("(?:access_token|bearerToken|credential|pairingToken|token)"\s*:\s*")[^"]+(")"#, with: "$1[redacted]$2", options: [.regularExpression, .caseInsensitive])
        return redacted.count > 4000 ? redacted.prefix(4000) + "\n[truncated]" : redacted
    }
    /// `normalizeSshErrorMessage` (command.ts:149-160): stderr, else redacted stdout, else a fallback.
    public static func failureMessage(stdout: String, stderr: String, destination: String, status: Int32) -> String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = diagnostic(stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "SSH command failed for \(destination) (exit \(status))." : out
    }
}
