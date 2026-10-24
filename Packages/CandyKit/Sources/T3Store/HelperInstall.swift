import Foundation

/// What a CandyWrapper client types into a hidden T3 terminal on the Orchestrator's machine to install, update, renew
/// or remove the helper, and how it reads the answer (docs/orchestrator-helper.md, sections 2 and 6). Shared so the Mac
/// and the Android app type the same thing.
public enum HelperInstall {
    /// A helper build: its version, where its downloads live and each platform's SHA-256 (scripts/build-helper).
    public struct Release: Codable, Equatable, Sendable {
        public var version: String
        public var baseURL: URL
        /// `darwin-universal`, `linux-x86_64` and `linux-aarch64` to the hex SHA-256 of that tarball.
        public var sums: [String: String]
        public init(version: String, baseURL: URL, sums: [String: String]) { self.version = version; self.baseURL = baseURL; self.sums = sums }
    }

    /// One machine the helper should reach, with a fresh one-time pairing code.
    public struct Pairing: Equatable, Sendable {
        public var machineId: String
        public var label: String
        public var url: URL
        public var code: String
        public init(machineId: String, label: String, url: URL, code: String) { self.machineId = machineId; self.label = label; self.url = url; self.code = code }
    }

    /// The scopes a helper session gets: enough to read and prompt threads and hold the task, nothing more.
    public static let scopes = ["orchestration:read", "orchestration:operate"]

    /// The pairing code's label, which T3 shows for the helper's session (Connections) and which tells clients its version.
    public static func sessionLabel(version: String, home: String) -> String { "CandyWrapper Helper \(version) on \(home)" }

    /// The version in a helper session's label, nil for any other session.
    public static func version(fromSessionLabel label: String) -> String? {
        guard label.hasPrefix("CandyWrapper Helper "), let on = label.range(of: " on ") else { return nil }
        return String(label[label.index(label.startIndex, offsetBy: "CandyWrapper Helper ".count)..<on.lowerBound])
    }

    /// One line for whatever shell the terminal runs: everything inside `sh -c '…'`, which zsh, bash and fish all
    /// accept, and a leading space keeps it out of history where the shell honours that. The markers are built from
    /// parts, so the shell echoing this line never reads as a result. `testHome` sets `CANDY_HELPER_HOME`.
    public static func installCommand(_ release: Release, homeId: String, testHome: String? = nil) -> String {
        func sum(_ p: String) -> String { release.sums[p] ?? "missing" }
        let data = testHome.map { "d=\(quoteless($0));export CANDY_HELPER_HOME=\"$d\";" } ?? ""
        let script = """
        set -eu;R=CWH-RES;R=${R}ULT;v=\(quoteless(release.version));b=\(quoteless(release.baseURL.absoluteString));\
        case "$(uname -s)-$(uname -m)" in \
        Darwin-*) p=darwin-universal;s=\(sum("darwin-universal"));d="$HOME/Library/Application Support/CandyWrapper Helper";; \
        Linux-x86_64) p=linux-x86_64;s=\(sum("linux-x86_64"));d="${XDG_DATA_HOME:-$HOME/.local/share}/candywrapper-helper";; \
        Linux-aarch64|Linux-arm64) p=linux-aarch64;s=\(sum("linux-aarch64"));d="${XDG_DATA_HOME:-$HOME/.local/share}/candywrapper-helper";; \
        *) echo "$R failed this machine ($(uname -sm)) has no helper build";exit 1;; esac;\(data)\
        f="$d/versions/$v";mkdir -p "$f";t="$f/download.tgz";u="$b/candywrapper-helper-$v-$p.tar.gz";\
        if command -v curl >/dev/null 2>&1;then curl -fsSL "$u" -o "$t" || { echo "$R failed the download from $u did not work";exit 1; };\
        elif command -v wget >/dev/null 2>&1;then wget -qO "$t" "$u" || { echo "$R failed the download from $u did not work";exit 1; };\
        else echo "$R failed this machine has neither curl nor wget";exit 1;fi;\
        h=$( (sha256sum "$t" 2>/dev/null || shasum -a 256 "$t") | cut -d" " -f1);\
        [ "$h" = "$s" ] || { rm -f "$t";echo "$R failed the checksum of the download did not match";exit 1; };\
        tar xzf "$t" -C "$f";rm -f "$t";exec "$f/candywrapper-helper" install --home \(quoteless(homeId))
        """
        return " sh -c '\(script)'\n"
    }

    /// Removes the helper through its own `uninstall`, or says it wasn't there.
    public static func uninstallCommand(testHome: String? = nil) -> String {
        let data = testHome.map { "d=\(quoteless($0));export CANDY_HELPER_HOME=\"$d\";" }
            ?? #"case "$(uname -s)" in Darwin) d="$HOME/Library/Application Support/CandyWrapper Helper";; *) d="${XDG_DATA_HOME:-$HOME/.local/share}/candywrapper-helper";; esac;"#
        let script = #"R=CWH-RES;R=${R}ULT;"# + data + #"if [ -x "$d/current/candywrapper-helper" ];then exec "$d/current/candywrapper-helper" uninstall;else echo "$R ok not installed";fi"#
        return " sh -c '\(script)'\n"
    }

    /// What goes to `install` once it printed its ready line: one tab-separated line per machine, then a lone dot.
    public static func pairingInput(_ pairings: [Pairing]) -> String {
        pairings.map { [$0.machineId, clean($0.label), $0.url.absoluteString, $0.code].joined(separator: "\t") }.joined(separator: "\n") + "\n.\n"
    }

    public enum Line: Equatable, Sendable {
        /// `install` turned echo off and waits for the pairing lines.
        case ready
        case ok(String)
        case failed(String)
        case warning(String)
    }

    /// The marker lines in a stretch of terminal output, colours and carriage returns removed. Only lines that start
    /// with a marker count, so the echoed command (which never contains one whole) can't.
    public static func scan(_ output: String) -> [Line] {
        let plain = output.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}\][^\x{07}]*\x{07}"#, with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline).compactMap { raw -> Line? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "CWH-READY" { return .ready }
            for (prefix, make) in [("CWH-RESULT ok", Line.ok), ("CWH-RESULT failed", Line.failed), ("CWH-WARNING", Line.warning)] as [(String, (String) -> Line)]
            where line.hasPrefix(prefix) {
                return make(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }

    /// No quote, backslash, dollar or backtick can reach the shell from a value; ids, versions and URLs never need one.
    static func quoteless(_ s: String) -> String { String(s.unicodeScalars.filter { !"'\"\\$`".unicodeScalars.contains($0) && $0.value >= 0x20 }) }
    /// A label can't carry a tab or a line break into the pairing input.
    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
}
