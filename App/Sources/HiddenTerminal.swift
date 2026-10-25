import Foundation
import T3Client
import T3Protocol
import T3Store

/// A T3 terminal no one sees, for the helper's install and for the Connectors tab's `config` command
/// (docs/orchestrator-helper.md section 2, docs/connectors.md).
@MainActor
enum HiddenTerminal {
    /// Opens a terminal no one sees, types `command` in slices a PTY's small input queue keeps up with, answers
    /// `CWH-READY` with `input`, and returns the marker lines once a result arrives. The terminal and its history go.
    static func run(_ environments: Environments, session: ShellSession, env: String, thread local: String, cwd: String, command: String, input: String?) async -> [HelperInstall.Line] {
        let terminal = "candywrapper-helper-\(UUID().uuidString.prefix(8).lowercased())"
        let base: [String: JSONValue] = ["threadId": .string(local), "terminalId": .string(terminal)]
        func with(_ extra: [String: JSONValue]) -> JSONValue { .object(base.merging(extra) { a, _ in a }) }
        let output = OutputBox()
        let attach = with(["cwd": .string(cwd), "cols": .number(200), "rows": .number(50)])
        let stream = session.supervisor.subscribe(TerminalRPC.attach, payload: { attach }) { event in
            guard case .value(let json) = event, json["type"]?.stringValue == "output", let data = json["data"]?.stringValue else { return }
            await output.append(data)
        }
        defer {
            stream.cancel()
            Task { @MainActor in _ = try? await environments.request(env, TerminalRPC.close, with(["deleteHistory": .bool(true)])) }
        }
        do {
            // Wait for the shell's first prompt before typing.
            for _ in 0..<40 where await output.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            var rest = Substring(command)
            while !rest.isEmpty {
                _ = try await environments.request(env, TerminalRPC.write, with(["data": .string(String(rest.prefix(256)))]))
                rest = rest.dropFirst(256)
                try await Task.sleep(for: .milliseconds(40))
            }
            var sentInput = input == nil
            // ponytail: 3 minutes covers a 25 MB download on a slow line; raise it if installs time out there
            for _ in 0..<720 {
                try await Task.sleep(for: .milliseconds(250))
                let lines = HelperInstall.scan(await output.text)
                if !sentInput, lines.contains(.ready), let input {
                    sentInput = true
                    _ = try await environments.request(env, TerminalRPC.write, with(["data": .string(input)]))
                }
                if lines.contains(where: { if case .ok = $0 { true } else if case .failed = $0 { true } else { false } }) { return lines }
            }
        } catch {}
        return []
    }

    private actor OutputBox {
        private(set) var text = ""
        // ponytail: keeps the last 64 KB; the markers are always in the newest lines
        func append(_ s: String) { text = String((text + s).suffix(65_536)) }
    }
}
