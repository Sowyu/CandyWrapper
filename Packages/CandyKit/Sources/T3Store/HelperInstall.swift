import Foundation

/// What a CandyWrapper client types into a hidden T3 terminal to remove an old Orchestrator relay helper, and how it
/// reads the answer. The helper itself was removed with Connectors (docs/research/connectors-removal-2026-11-21.md).
public enum HelperInstall {
    /// The label the old relay helper's sessions carried, "CandyWrapper Helper <version> on <machine>".
    public static func sessionLabel(version: String, home: String) -> String { "CandyWrapper Helper \(version) on \(home)" }

    /// The version in an old relay helper session's label, nil for any other session.
    public static func version(fromSessionLabel label: String) -> String? {
        guard label.hasPrefix("CandyWrapper Helper "), let on = label.range(of: " on ") else { return nil }
        return String(label[label.index(label.startIndex, offsetBy: "CandyWrapper Helper ".count)..<on.lowerBound])
    }

    /// Removes an Orchestrator relay helper that CandyWrapper 1.14 or older installed, through that installed binary's own
    /// `uninstall` (it stops the service and deletes its tokens and files), or says it wasn't there. One line for any
    /// shell inside `sh -c '…'`, and a leading space keeps it out of history. The markers are built from parts, so the
    /// shell echoing this line never reads as a result. `testHome` sets `CANDY_HELPER_HOME`.
    public static func uninstallCommand(testHome: String? = nil) -> String {
        let data = testHome.map { "d=\(quoteless($0));export CANDY_HELPER_HOME=\"$d\";" }
            ?? #"case "$(uname -s)" in Darwin) d="$HOME/Library/Application Support/CandyWrapper Helper";; *) d="${XDG_DATA_HOME:-$HOME/.local/share}/candywrapper-helper";; esac;"#
        let script = #"R=CWH-RES;R=${R}ULT;"# + data + #"if [ -x "$d/current/candywrapper-helper" ];then exec "$d/current/candywrapper-helper" uninstall;else echo "$R ok not installed";fi"#
        return " sh -c '\(script)'\n"
    }

    public enum Line: Equatable, Sendable {
        case ok(String)
        case failed(String)
    }

    /// The marker lines in a stretch of terminal output, colours and carriage returns removed. Only lines that start
    /// with a marker count, so the echoed command (which never contains one whole) can't.
    public static func scan(_ output: String) -> [Line] {
        let plain = output.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}\][^\x{07}]*\x{07}"#, with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isNewline).compactMap { raw -> Line? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            for (prefix, make) in [("CWH-RESULT ok", Line.ok), ("CWH-RESULT failed", Line.failed)] as [(String, (String) -> Line)]
            where line.hasPrefix(prefix) {
                return make(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
    }

    /// Collects the marker lines of a terminal's output as it arrives. Each finished line is scanned once and only the
    /// unfinished one is kept, so a marker split across chunks still counts.
    public struct MarkerReader: Sendable {
        public private(set) var lines: [Line] = []
        public private(set) var started = false
        private var partial = ""
        public init() {}

        public mutating func append(_ chunk: String) {
            started = started || !chunk.isEmpty
            guard let cut = chunk.lastIndex(where: \.isNewline) else {
                // ponytail: a line past 16M characters is dropped; markers are short, raise it only if one ever isn't
                partial = partial.count + chunk.count > 16_000_000 ? "" : partial + chunk
                return
            }
            lines += scan(partial + chunk[...cut])
            partial = String(chunk[chunk.index(after: cut)...])
        }
    }

    /// No quote, backslash, dollar or backtick can reach the shell from a value; ids, versions and URLs never need one.
    static func quoteless(_ s: String) -> String { String(s.unicodeScalars.filter { !"'\"\\$`".unicodeScalars.contains($0) && $0.value >= 0x20 }) }
}
