import Foundation
import Testing
@testable import T3Protocol

/// Terminal payloads and stream values (packages/contracts/src/terminal.ts).
struct TerminalTests {
    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    let launch = TerminalRPC.Launch(projectRoot: "/repo", worktreePath: nil)

    @Test func openAndAttachInputs() throws {
        #expect(TerminalRPC.openInput(threadId: "t1", terminalId: "term-1", launch: launch) == (try Self.json(
            #"{"threadId":"t1","terminalId":"term-1","cwd":"/repo","env":{"T3CODE_PROJECT_ROOT":"/repo"}}"#)))
        let worktree = TerminalRPC.Launch(projectRoot: "/repo", worktreePath: "/wt")
        #expect(worktree.cwd == "/wt")
        #expect(TerminalRPC.attachInput(threadId: "t1", terminalId: "term-2", launch: worktree) == (try Self.json(
            #"{"threadId":"t1","terminalId":"term-2","cwd":"/wt","worktreePath":"/wt","env":{"T3CODE_PROJECT_ROOT":"/repo","T3CODE_WORKTREE_PATH":"/wt"}}"#)))
    }

    @Test func writeResizeClose() throws {
        #expect(TerminalRPC.writeInput(threadId: "t", terminalId: "term-1", data: "ls\r") == (try Self.json(#"{"threadId":"t","terminalId":"term-1","data":"ls\r"}"#)))
        // Clamped to the contract's 1...1000 by 1...500.
        #expect(TerminalRPC.resizeInput(threadId: "t", terminalId: "term-1", cols: 4000, rows: 0) == (try Self.json(#"{"threadId":"t","terminalId":"term-1","cols":1000,"rows":1}"#)))
        #expect(TerminalRPC.closeInput(threadId: "t", terminalId: "term-1", deleteHistory: true) == (try Self.json(#"{"threadId":"t","terminalId":"term-1","deleteHistory":true}"#)))
    }

    @Test func writeChunksKeepCharacters() {
        let long = String(repeating: "é", count: TerminalRPC.maxWriteLength + 3)
        let chunks = TerminalRPC.writeChunks(long)
        #expect(chunks.map(\.count) == [TerminalRPC.maxWriteLength, 3])
        #expect(chunks.joined() == long)
        #expect(TerminalRPC.writeChunks("") == [])
    }

    @Test func attachEvents() throws {
        let snapshot = try Self.json(#"{"type":"snapshot","snapshot":{"threadId":"t","terminalId":"term-1","cwd":"/repo","worktreePath":null,"status":"running","pid":42,"history":"$ ls\r\n","exitCode":null,"exitSignal":null,"label":"zsh","updatedAt":"2026-10-10T12:00:00.000Z","sequence":3}}"#)
        guard case .snapshot(let s)? = TerminalAttachEvent(json: snapshot) else { Issue.record("snapshot"); return }
        #expect(s.history == "$ ls\r\n" && s.status == .running && s.pid == 42 && s.sequence == 3)
        #expect(TerminalAttachEvent(json: try Self.json(#"{"type":"output","threadId":"t","terminalId":"term-1","data":"\u001b[31mhi"}"#)) == .output("\u{1b}[31mhi"))
        #expect(TerminalAttachEvent(json: try Self.json(#"{"type":"exited","threadId":"t","terminalId":"term-1","exitCode":0,"exitSignal":null}"#)) == .exited(code: 0, signal: nil))
        #expect(TerminalAttachEvent(json: try Self.json(#"{"type":"activity","threadId":"t","terminalId":"term-1","hasRunningSubprocess":true,"label":"top"}"#)) == .activity(hasRunningSubprocess: true, label: "top"))
        #expect(TerminalAttachEvent(json: try Self.json(#"{"type":"future","threadId":"t","terminalId":"term-1"}"#)) == .unknown("future"))
    }

    @Test func metadataEvents() throws {
        let summary = #"{"threadId":"t","terminalId":"term-1","cwd":"/repo","worktreePath":null,"status":"running","pid":1,"exitCode":null,"exitSignal":null,"hasRunningSubprocess":true,"label":"sleep","updatedAt":"x"}"#
        guard case .snapshot(let list)? = TerminalMetadataEvent(json: try Self.json(#"{"type":"snapshot","terminals":[\#(summary)]}"#)) else { Issue.record("snapshot"); return }
        #expect(list.first?.hasRunningSubprocess == true)
        #expect(TerminalMetadataEvent(json: try Self.json(#"{"type":"remove","threadId":"t","terminalId":"term-1"}"#)) == .remove(threadId: "t", terminalId: "term-1"))
    }

    @Test func labels() {
        #expect(TerminalLabels.label("term-3") == "Terminal 3")
        #expect(TerminalLabels.label("terminal-2-0123abcd-0000-1111-2222-333344445555") == "Terminal 2")
        #expect(TerminalLabels.label("custom") == "custom")
        #expect(TerminalLabels.nextId(["term-1", "term-3"]) == "term-2")
        #expect(TerminalLabels.nextId([]) == "term-1")
    }
}
